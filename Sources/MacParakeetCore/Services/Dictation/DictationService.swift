import Foundation
import os
import OSLog

public enum DictationState: Sendable {
    case idle
    case recording
    case processing
    case success(Dictation)
    case cancelled
    case error(String)
}

public struct DictationTelemetryContext: Sendable, Equatable {
    public var trigger: TelemetryDictationTrigger?
    public var mode: TelemetryDictationMode?
    /// Coarse category of the app expected to receive the dictation paste.
    /// The app layer refreshes this near stop/undo time so the value follows
    /// the finish-target paste model instead of locking to the app active at
    /// recording start. See `TelemetryAppCategory` for the privacy contract.
    public var appCategory: TelemetryAppCategory?

    public init(
        trigger: TelemetryDictationTrigger? = nil,
        mode: TelemetryDictationMode? = nil,
        appCategory: TelemetryAppCategory? = nil
    ) {
        self.trigger = trigger
        self.mode = mode
        self.appCategory = appCategory
    }
}

public protocol DictationServiceProtocol: Sendable {
    func startRecording(context: DictationTelemetryContext) async throws
    func stopRecording() async throws -> DictationResult
    func cancelRecording(reason: TelemetryDictationCancelReason?) async
    /// Confirm cancel immediately (discard any pending audio and reset to idle).
    func confirmCancel() async
    /// Undo a soft-cancel: transcribe the cancelled recording and return a DictationResult.
    func undoCancel() async throws -> DictationResult
    var state: DictationState { get async }
    var audioLevel: Float { get async }
    var liveTranscript: String { get async }
}

private struct FormatterOutcome: Sendable {
    let text: String?
    let run: LLMRun?
    let resolution: AIFormatterPromptResolution?

    static let skipped = FormatterOutcome(text: nil, run: nil, resolution: nil)
}

private struct LiveDictationTranscriptionState: Sendable {
    let dictationSessionID: Int
    let sttSessionID: UUID
    let sampleContinuation: AsyncStream<[Float]>.Continuation
    let partialContinuation: AsyncStream<String>.Continuation
    let partialTask: Task<Void, Never>
    let task: Task<STTResult, Error>
    /// Set when the live stream is no longer a faithful rendition of the
    /// recorded WAV (backpressure dropped samples, or the pre-roll was
    /// discarded from the file after being streamed). A degraded session's
    /// final text is discarded and the recorded file is transcribed instead.
    let degradeReason: OSAllocatedUnfairLock<String?>

    func markDegraded(reason: String) {
        degradeReason.withLock { current in
            if current == nil { current = reason }
        }
    }
}

public enum AIFormatterAppContextPhase: Sendable {
    case start
    case finish
}

extension DictationServiceProtocol {
    public func startRecording() async throws {
        try await startRecording(context: DictationTelemetryContext())
    }

    public func cancelRecording() async {
        await cancelRecording(reason: nil)
    }
}

public actor DictationService: DictationServiceProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "DictationService")
    private let audioProcessor: AudioProcessorProtocol
    private let sttTranscriber: STTTranscribing
    private let dictationRepo: DictationRepositoryProtocol
    private let shouldSaveAudio: (@Sendable () -> Bool)?
    private let shouldSaveDictationHistory: (@Sendable () -> Bool)?
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let voiceReturnTrigger: @Sendable () -> String?
    private let processingMode: @Sendable () -> Dictation.ProcessingMode
    private let dictationInsertionStyle: @Sendable () -> DictationInsertionStyle
    private let textRefinementService: TextRefinementService
    private let llmService: LLMServiceProtocol?
    private let llmRunRecorder: LLMRunRecorder
    private let shouldUseAIFormatter: @Sendable () -> Bool
    private let aiFormatterPromptResolver: any AIFormatterPromptResolving
    private let shouldAttemptLiveDictationTranscription: @Sendable () -> Bool
    private let markFirstDictationCompleted: (@Sendable () -> Void)?
    private let cancelWindow: Duration

    private var _state: DictationState = .idle
    private var cancelResetTask: Task<Void, Never>?
    private var cancelGeneration: Int = 0
    private var pendingCancelledAudioURL: URL?
    private var currentTelemetryContext = DictationTelemetryContext()
    private var recordingStartedAt: Date?
    private var currentOperationID: String?
    private var currentOperationTelemetryContext = DictationTelemetryContext()
    private var currentObservabilityOperationContext: ObservabilityOperationContext?
    private var currentAIFormatterStartContext: AppPromptContext?
    private var currentAIFormatterFinishContext: AppPromptContext?
    private var liveTranscriptionState: LiveDictationTranscriptionState?
    private var liveTranscriptText: String = ""
    private var activeSessionID: Int = 0
    private var cancellationRequestedDuringStartSessionID: Int?
    private var pendingCancelReason: TelemetryDictationCancelReason?

    public var state: DictationState {
        _state
    }

    public var audioLevel: Float {
        get async { await audioProcessor.audioLevel }
    }

    public var liveTranscript: String {
        liveTranscriptText
    }

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttTranscriber: STTTranscribing,
        dictationRepo: DictationRepositoryProtocol,
        shouldSaveAudio: (@Sendable () -> Bool)? = nil,
        shouldSaveDictationHistory: (@Sendable () -> Bool)? = nil,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        voiceReturnTrigger: (@Sendable () -> String?)? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        dictationInsertionStyle: (@Sendable () -> DictationInsertionStyle)? = nil,
        llmService: LLMServiceProtocol? = nil,
        llmRunRepo: LLMRunRepositoryProtocol? = nil,
        shouldUseAIFormatter: (@Sendable () -> Bool)? = nil,
        aiFormatterPromptTemplate: (@Sendable () -> String)? = nil,
        aiFormatterPromptResolver: (any AIFormatterPromptResolving)? = nil,
        shouldAttemptLiveDictationTranscription: (@Sendable () -> Bool)? = nil,
        markFirstDictationCompleted: (@Sendable () -> Void)? = nil,
        cancelWindow: Duration = .seconds(5)
    ) {
        self.audioProcessor = audioProcessor
        self.sttTranscriber = sttTranscriber
        self.dictationRepo = dictationRepo
        self.shouldSaveAudio = shouldSaveAudio
        self.shouldSaveDictationHistory = shouldSaveDictationHistory
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.voiceReturnTrigger = voiceReturnTrigger ?? { nil }
        self.processingMode = processingMode ?? { .raw }
        self.dictationInsertionStyle = dictationInsertionStyle ?? { .sentence }
        self.textRefinementService = TextRefinementService()
        self.llmService = llmService
        self.llmRunRecorder = LLMRunRecorder(repository: llmRunRepo)
        self.shouldUseAIFormatter = shouldUseAIFormatter ?? { false }
        let promptTemplate = aiFormatterPromptTemplate ?? { AIFormatter.defaultPromptTemplate }
        self.aiFormatterPromptResolver = aiFormatterPromptResolver
            ?? AIFormatterGlobalPromptResolver(promptTemplate: promptTemplate)
        self.shouldAttemptLiveDictationTranscription = shouldAttemptLiveDictationTranscription ?? { false }
        self.markFirstDictationCompleted = markFirstDictationCompleted
        self.cancelWindow = cancelWindow
    }

    public func startRecording(context: DictationTelemetryContext = DictationTelemetryContext()) async throws {
        try await startRecording(context: context, sessionID: nil)
    }

    public func updateTelemetryAppCategory(
        _ appCategory: TelemetryAppCategory?,
        sessionID: Int? = nil
    ) {
        if let sessionID, sessionID != activeSessionID { return }
        switch _state {
        case .recording, .cancelled, .processing:
            let sampledCategory = appCategory ?? .other
            currentTelemetryContext.appCategory = sampledCategory
            currentOperationTelemetryContext.appCategory = sampledCategory
        case .idle, .success, .error:
            return
        }
    }

    public func updateAIFormatterAppContext(
        _ context: AppPromptContext?,
        phase: AIFormatterAppContextPhase,
        sessionID: Int? = nil
    ) {
        if let sessionID, sessionID != activeSessionID { return }
        switch _state {
        case .recording, .cancelled, .processing:
            switch phase {
            case .start:
                currentAIFormatterStartContext = context
            case .finish:
                currentAIFormatterFinishContext = context
            }
        case .idle, .success, .error:
            return
        }
    }

    public func startRecording(
        context: DictationTelemetryContext = DictationTelemetryContext(),
        sessionID: Int?
    ) async throws {
        logger.debug("dictation_start_requested state=\(self.debugStateLabel(self._state), privacy: .public)")
        let operationContext = ObservabilityOperationContext()
        if let entitlements {
            do {
                try await entitlements.assertCanTranscribe(now: Date())
            } catch {
                let device = await audioProcessor.recordingDeviceInfo
                sendDictationOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    telemetryContext: context,
                    outcome: .unavailable,
                    errorType: Self.errorType(for: error),
                    device: device
                )
                throw error
            }
        }

        switch _state {
        case .idle, .cancelled:
            break
        case .recording where sessionID != nil && sessionID != activeSessionID:
            // New session replacing a stale provisional recording whose
            // confirmCancel hasn't arrived yet. Clean up the old capture.
            logger.notice(
                "startRecording replacing stale recording old=\(self.activeSessionID) new=\(sessionID!, privacy: .public)"
            )
            await cancelLiveDictationTranscription(sessionID: activeSessionID)
            if await audioProcessor.isRecording,
               let url = try? await audioProcessor.stopCapture() {
                try? FileManager.default.removeItem(at: url)
            }
        case .processing where sessionID != nil && sessionID != activeSessionID,
             .success where sessionID != nil && sessionID != activeSessionID:
            // Previous transcription still in flight. The reentrancy guards in
            // stopRecording prevent the old call from overwriting this session's state.
            logger.notice(
                "startRecording overriding busy service old=\(self.activeSessionID) new=\(sessionID!, privacy: .public) state=\(self.debugStateLabel(self._state), privacy: .public)"
            )
        default:
            return
        }

        discardPendingCancelledAudio()

        cancelResetTask?.cancel()
        cancelResetTask = nil

        let requestedSessionID = sessionID ?? activeSessionID + 1
        activeSessionID = requestedSessionID
        cancellationRequestedDuringStartSessionID = nil
        pendingCancelReason = nil
        currentAIFormatterStartContext = nil
        currentAIFormatterFinishContext = nil
        liveTranscriptText = ""
        currentOperationID = operationContext.operationID
        currentOperationTelemetryContext = context
        currentObservabilityOperationContext = operationContext
        _state = .recording
        let liveSampleSink = await beginLiveDictationTranscriptionIfAvailable(
            sessionID: requestedSessionID
        )
        do {
            try await audioProcessor.startCapture(sampleSink: liveSampleSink)
            // Guard against reentrancy: cancel or replacement may have run during the await above.
            if cancellationRequestedDuringStartSessionID == requestedSessionID {
                cancellationRequestedDuringStartSessionID = nil
            }
            let activeAtStartCompletion = activeSessionID
            guard activeAtStartCompletion == requestedSessionID, case .recording = _state else {
                let processorIsRecording: Bool
                if activeAtStartCompletion == requestedSessionID {
                    processorIsRecording = await audioProcessor.isRecording
                } else {
                    processorIsRecording = false
                }
                if activeSessionID == requestedSessionID,
                   processorIsRecording,
                   let audioURL = try? await audioProcessor.stopCapture() {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                if activeSessionID == requestedSessionID {
                    recordingStartedAt = nil
                }
                await cancelLiveDictationTranscription(sessionID: requestedSessionID)
                logger.notice(
                    "dictation_start_aborted session=\(requestedSessionID, privacy: .public) active_session=\(activeAtStartCompletion, privacy: .public) state=\(self.debugStateLabel(self._state), privacy: .public)"
                )
                return
            }
            currentTelemetryContext = context
            recordingStartedAt = Date()
            Telemetry.send(.dictationStarted(trigger: context.trigger, mode: context.mode))
            logger.debug("dictation_capture_started session=\(requestedSessionID, privacy: .public)")
        } catch {
            let activeAtFailure = activeSessionID
            guard activeAtFailure == requestedSessionID else {
                await cancelLiveDictationTranscription(sessionID: requestedSessionID)
                logger.notice(
                    "startRecording stale failure ignored session=\(requestedSessionID) active=\(activeAtFailure) error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            let cancellationRequestedDuringStart = cancellationRequestedDuringStartSessionID == requestedSessionID
            if cancellationRequestedDuringStart {
                cancellationRequestedDuringStartSessionID = nil
            }
            await cancelLiveDictationTranscription(sessionID: requestedSessionID)
            if Self.isInterruptedDuringSubscribe(error), cancellationRequestedDuringStart {
                if cancellationRequestedDuringStart, case .recording = _state {
                    _state = .cancelled
                }
                recordingStartedAt = nil
                logger.notice(
                    "startRecording interrupted after cancellation session=\(requestedSessionID) state=\(self.debugStateLabel(self._state), privacy: .public)"
                )
                return
            }
            let device = await audioProcessor.recordingDeviceInfo
            guard activeSessionID == requestedSessionID else {
                logger.notice(
                    "startRecording stale failure ignored session=\(requestedSessionID) active=\(self.activeSessionID) error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            let operationID = currentOperationID
            let telemetryContext = currentOperationTelemetryContext
            let observabilityOperationContext = currentObservabilityOperationContext
            _state = .idle
            recordingStartedAt = nil
            sendDictationOperation(
                operationID: operationID,
                operationContext: observabilityOperationContext,
                telemetryContext: telemetryContext,
                outcome: .failure,
                errorType: Self.errorType(for: error),
                device: device
            )
            clearCurrentOperation()
            Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            logger.error(
                "startRecording failed session=\(requestedSessionID) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    public func stopRecording() async throws -> DictationResult {
        try await stopRecording(sessionID: nil)
    }

    public func stopRecording(sessionID: Int?) async throws -> DictationResult {
        if let sessionID, sessionID != activeSessionID {
            logger.notice(
                "stopRecording ignored stale session requested=\(sessionID) active=\(self.activeSessionID)"
            )
            throw DictationServiceError.notRecording
        }
        guard case .recording = _state else {
            logger.warning(
                "stopRecording rejected session=\(sessionID ?? self.activeSessionID) state=\(self.debugStateLabel(self._state), privacy: .public)"
            )
            throw DictationServiceError.notRecording
        }

        let currentSession = activeSessionID
        let formatterContext = currentAIFormatterFinishContext ?? currentAIFormatterStartContext
        _state = .processing
        logger.debug("dictation_stop_processing_started session=\(currentSession, privacy: .public)")

        do {
            let audioURL = try await audioProcessor.stopCapture()
            let device = await audioProcessor.recordingDeviceInfo
            let liveResult = await finishLiveDictationTranscription(sessionID: currentSession)
            logger.debug(
                "dictation_capture_stopped session=\(currentSession, privacy: .public) path=\(audioURL.path, privacy: .private)"
            )
            let result = try await withCurrentObservabilityContextIfAny {
                try await processCapturedAudio(
                    audioURL: audioURL,
                    formatterContext: formatterContext,
                    liveResult: liveResult
                )
            }
            // Guard against reentrancy: a new session may have started during
            // transcription, replacing this session. Don't overwrite its state.
            guard activeSessionID == currentSession else {
                logger.notice(
                    "stopRecording result discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                return result
            }
            _state = .success(result.dictation)
            sendDictationOperation(
                outcome: .success,
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                device: device
            )
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                mode: currentTelemetryContext.mode,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                appCategory: currentTelemetryContext.appCategory,
                device: device
            ))
            logger.debug(
                "stopRecording success session=\(currentSession) rawChars=\(result.dictation.rawTranscript.count) cleanChars=\(result.dictation.cleanTranscript?.count ?? 0)"
            )
            try? await Task.sleep(for: .milliseconds(500))
            guard activeSessionID == currentSession else { return result }
            _state = .idle
            recordingStartedAt = nil
            clearCurrentOperation()
            return result
        } catch {
            await cancelLiveDictationTranscription(sessionID: currentSession)
            // Snapshot device before setting state to .idle — prevents reentrancy
            // window where a new startRecording() could overwrite the device info.
            let device = await audioProcessor.recordingDeviceInfo
            guard activeSessionID == currentSession else {
                logger.notice(
                    "stopRecording error discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                throw error
            }
            _state = .idle
            if Self.isNoSpeechError(error) {
                sendDictationOperation(
                    outcome: .empty,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                sendDictationOperation(
                    outcome: .failure,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
            clearCurrentOperation()
            logger.error(
                "stopRecording failed session=\(currentSession) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Discard the instant-dictation pre-roll from the active capture because
    /// system media was confirmed playing at press time — the pre-roll is
    /// pre-press media audio that no pause can silence (issue #474).
    /// Best-effort: a stale session ID or a capture that already stopped
    /// keeps its pre-roll, which only re-opens the original bleed window.
    public func discardPreRollForActiveCapture(sessionID: Int?) async {
        if let sessionID, sessionID != activeSessionID {
            logger.notice(
                "discardPreRoll ignored stale session requested=\(sessionID) active=\(self.activeSessionID)"
            )
            return
        }
        guard case .recording = _state else {
            logger.notice(
                "discardPreRoll ignored state=\(self.debugStateLabel(self._state), privacy: .public)"
            )
            return
        }
        // The pre-roll was already mirrored into the live STT stream, but the
        // recorder will now trim it from the WAV. The live final would keep
        // the discarded media audio, so it can no longer stand in for the
        // recorded file.
        if let state = liveTranscriptionState, state.dictationSessionID == activeSessionID {
            state.markDegraded(reason: "preroll_discarded")
        }
        await audioProcessor.discardPreRollForActiveCapture()
    }

    public func cancelRecording(reason: TelemetryDictationCancelReason? = nil) async {
        await cancelRecording(reason: reason, sessionID: nil)
    }

    public func cancelRecording(
        reason: TelemetryDictationCancelReason? = nil,
        sessionID: Int?
    ) async {
        if let sessionID, sessionID != activeSessionID {
            logger.notice(
                "cancelRecording ignored stale session requested=\(sessionID) active=\(self.activeSessionID)"
            )
            return
        }
        guard case .recording = _state else { return }

        cancelGeneration += 1
        let generation = cancelGeneration

        pendingCancelReason = reason
        cancellationRequestedDuringStartSessionID = activeSessionID
        await cancelLiveDictationTranscription(sessionID: activeSessionID)
        let audioURL = try? await audioProcessor.stopCapture()
        let device = await audioProcessor.recordingDeviceInfo
        pendingCancelledAudioURL = audioURL
        _state = .cancelled
        Telemetry.send(.dictationCancelled(
            durationSeconds: currentRecordingDurationSeconds(),
            reason: reason,
            device: device
        ))

        cancelResetTask?.cancel()
        cancelResetTask = Task { [generation] in
            try? await Task.sleep(for: cancelWindow)
            resetAfterCancelIfStillCurrent(generation: generation)
        }
    }

    public func confirmCancel() async {
        await confirmCancel(sessionID: nil)
    }

    public func confirmCancel(sessionID: Int?) async {
        if let sessionID, sessionID != activeSessionID {
            logger.notice(
                "confirmCancel ignored stale session requested=\(sessionID) active=\(self.activeSessionID)"
            )
            return
        }
        cancelGeneration += 1
        cancelResetTask?.cancel()
        cancelResetTask = nil
        discardPendingCancelledAudio()

        if case .recording = _state {
            cancellationRequestedDuringStartSessionID = activeSessionID
            await cancelLiveDictationTranscription(sessionID: activeSessionID)
            if let url = try? await audioProcessor.stopCapture() {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let device = await audioProcessor.recordingDeviceInfo
        sendDictationOperation(
            outcome: .cancelled,
            durationSeconds: currentRecordingDurationSeconds(),
            cancelReason: pendingCancelReason,
            device: device
        )
        recordingStartedAt = nil
        clearCurrentOperation()
        _state = .idle
    }

    public func undoCancel() async throws -> DictationResult {
        guard case .cancelled = _state else {
            throw DictationServiceError.notCancelled
        }
        guard let audioURL = pendingCancelledAudioURL else {
            _state = .idle
            throw DictationServiceError.noPendingCancelledAudio
        }

        cancelGeneration += 1
        cancelResetTask?.cancel()
        cancelResetTask = nil
        pendingCancelledAudioURL = nil

        let currentSession = activeSessionID
        let formatterContext = currentAIFormatterFinishContext ?? currentAIFormatterStartContext
        _state = .processing
        do {
            let result = try await withCurrentObservabilityContextIfAny {
                try await processCapturedAudio(audioURL: audioURL, formatterContext: formatterContext)
            }
            let device = await audioProcessor.recordingDeviceInfo
            // Guard against reentrancy: a new session may have started while we
            // transcribed the undone audio, replacing this one. Don't overwrite
            // its state. Mirrors stopRecording(sessionID:).
            guard activeSessionID == currentSession else {
                logger.notice(
                    "undoCancel result discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                return result
            }
            _state = .success(result.dictation)
            sendDictationOperation(
                outcome: .success,
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                device: device
            )
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                mode: currentTelemetryContext.mode,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                appCategory: currentTelemetryContext.appCategory,
                device: device
            ))
            try? await Task.sleep(for: .milliseconds(500))
            guard activeSessionID == currentSession else { return result }
            _state = .idle
            recordingStartedAt = nil
            clearCurrentOperation()
            return result
        } catch {
            let device = await audioProcessor.recordingDeviceInfo
            guard activeSessionID == currentSession else {
                logger.notice(
                    "undoCancel error discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                throw error
            }
            _state = .idle
            if Self.isNoSpeechError(error) {
                sendDictationOperation(
                    outcome: .empty,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                sendDictationOperation(
                    outcome: .failure,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
            clearCurrentOperation()
            throw error
        }
    }

    // MARK: - Private

    /// Whether the error represents "no speech" (empty transcript or recording too short).
    private static func isNoSpeechError(_ error: Error) -> Bool {
        if let e = error as? DictationServiceError, e == .emptyTranscript { return true }
        if let e = error as? AudioProcessorError, case .insufficientSamples = e { return true }
        return false
    }

    private static func isInterruptedDuringSubscribe(_ error: Error) -> Bool {
        guard let e = error as? AudioProcessorError,
              case .recordingFailed(let reason) = e else {
            return false
        }
        return reason == "interrupted during subscribe"
    }

    private func discardPendingCancelledAudio() {
        if let url = pendingCancelledAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingCancelledAudioURL = nil
    }

    private func withCurrentObservabilityContextIfAny<T: Sendable>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        guard let operationContext = currentObservabilityOperationContext else {
            return try await operation()
        }
        return try await Observability.withOperationContext(operationContext) {
            try await operation()
        }
    }

    private func beginLiveDictationTranscriptionIfAvailable(
        sessionID: Int
    ) async -> DictationAudioSampleSink? {
        guard shouldAttemptLiveDictationTranscription() else { return nil }
        guard liveTranscriptionState == nil else { return nil }
        guard let liveTranscriber = sttTranscriber as? any STTLiveDictationTranscribing else {
            return nil
        }

        var continuation: AsyncStream<[Float]>.Continuation?
        let stream = AsyncStream<[Float]>(bufferingPolicy: .bufferingNewest(120)) {
            continuation = $0
        }
        guard let sampleContinuation = continuation else { return nil }

        // Partials are serialized through a single consumer so a stale
        // partial can never land after a newer one (unstructured Tasks have
        // no ordering guarantee). Only the latest partial matters.
        var partialStreamContinuation: AsyncStream<String>.Continuation?
        let partialStream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(1)) {
            partialStreamContinuation = $0
        }
        guard let partialContinuation = partialStreamContinuation else {
            sampleContinuation.finish()
            return nil
        }
        let partialTask = Task { [weak self] in
            for await partial in partialStream {
                await self?.updateLiveTranscript(partial, sessionID: sessionID)
            }
        }

        let degradeReason = OSAllocatedUnfairLock<String?>(initialState: nil)

        do {
            let sttSessionID = try await liveTranscriber.beginLiveDictationTranscription { partial in
                partialContinuation.yield(partial)
            }
            let task = Task { [liveTranscriber, sttSessionID] in
                do {
                    for await samples in stream {
                        try Task.checkCancellation()
                        try await liveTranscriber.appendLiveDictationSamples(
                            samples,
                            sessionID: sttSessionID
                        )
                    }
                    if degradeReason.withLock({ $0 != nil }) {
                        await liveTranscriber.cancelLiveDictationTranscription(sessionID: sttSessionID)
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                    return try await liveTranscriber.finishLiveDictationTranscription(
                        sessionID: sttSessionID
                    )
                } catch is CancellationError {
                    await liveTranscriber.cancelLiveDictationTranscription(sessionID: sttSessionID)
                    throw CancellationError()
                } catch {
                    await liveTranscriber.cancelLiveDictationTranscription(sessionID: sttSessionID)
                    throw error
                }
            }

            liveTranscriptionState = LiveDictationTranscriptionState(
                dictationSessionID: sessionID,
                sttSessionID: sttSessionID,
                sampleContinuation: sampleContinuation,
                partialContinuation: partialContinuation,
                partialTask: partialTask,
                task: task,
                degradeReason: degradeReason
            )
            AudioCaptureDiagnostics.append("dictation_live_transcribe_started engine=nemotron")
            return DictationAudioSampleSink(
                onSamples: { samples in
                    guard !samples.isEmpty else { return }
                    if case .dropped = sampleContinuation.yield(samples) {
                        // The recorded WAV keeps every sample; the live stream
                        // just lost some, so its final text can no longer be
                        // trusted as the dictation result.
                        degradeReason.withLock { current in
                            if current == nil { current = "backpressure_drop" }
                        }
                    }
                },
                onFinish: {
                    sampleContinuation.finish()
                }
            )
        } catch {
            sampleContinuation.finish()
            partialContinuation.finish()
            partialTask.cancel()
            AudioCaptureDiagnostics.append(
                "dictation_live_transcribe_skipped \(AudioCaptureDiagnostics.errorFields(error))"
            )
            return nil
        }
    }

    private func updateLiveTranscript(_ partial: String, sessionID: Int) {
        guard liveTranscriptionState?.dictationSessionID == sessionID,
              case .recording = _state else {
            return
        }
        liveTranscriptText = partial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finishLiveDictationTranscription(sessionID: Int) async -> STTResult? {
        guard let state = liveTranscriptionState,
              state.dictationSessionID == sessionID else {
            return nil
        }
        liveTranscriptionState = nil
        state.sampleContinuation.finish()
        state.partialContinuation.finish()
        state.partialTask.cancel()

        // Capture stopped before this runs, so no further degrade writes can
        // race this read.
        if let reason = state.degradeReason.withLock({ $0 }) {
            AudioCaptureDiagnostics.append(
                "dictation_live_transcribe_degraded reason=\(reason)"
            )
            state.task.cancel()
            if let liveTranscriber = sttTranscriber as? any STTLiveDictationTranscribing {
                await liveTranscriber.cancelLiveDictationTranscription(sessionID: state.sttSessionID)
            }
            _ = await state.task.result
            return nil
        }

        do {
            let result = try await state.task.value
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                // An empty live final is indistinguishable from a streaming
                // hiccup; let the recorded file decide whether the dictation
                // was really empty before it is silently dismissed.
                AudioCaptureDiagnostics.append("dictation_live_transcribe_empty_fallback")
                return nil
            }
            AudioCaptureDiagnostics.append(
                "dictation_live_transcribe_complete chars=\(result.text.count)"
            )
            return result
        } catch is CancellationError {
            AudioCaptureDiagnostics.append("dictation_live_transcribe_cancelled")
            return nil
        } catch {
            AudioCaptureDiagnostics.append(
                "dictation_live_transcribe_failed \(AudioCaptureDiagnostics.errorFields(error))"
            )
            return nil
        }
    }

    private func cancelLiveDictationTranscription(sessionID: Int) async {
        guard let state = liveTranscriptionState,
              state.dictationSessionID == sessionID else {
            return
        }
        liveTranscriptionState = nil
        liveTranscriptText = ""
        state.sampleContinuation.finish()
        state.partialContinuation.finish()
        state.partialTask.cancel()
        state.task.cancel()
        if let liveTranscriber = sttTranscriber as? any STTLiveDictationTranscribing {
            await liveTranscriber.cancelLiveDictationTranscription(sessionID: state.sttSessionID)
        }
        _ = await state.task.result
    }

    private func processCapturedAudio(
        audioURL: URL,
        formatterContext: AppPromptContext?,
        liveResult: STTResult? = nil
    ) async throws -> DictationResult {
        // Track whether the audio file is consumed (moved or explicitly deleted).
        // If an error occurs before that point, clean up the temp file.
        var audioConsumed = false
        defer {
            if !audioConsumed {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        AudioCaptureDiagnostics.append(
            "dictation_transcribe_begin file_bytes=\(Self.fileSizeBytes(at: audioURL).map(String.init) ?? "unknown")"
        )
        let result: STTResult
        if let liveResult {
            result = liveResult
            AudioCaptureDiagnostics.append(
                "dictation_transcribe_live_result chars=\(liveResult.text.count) engine=\(liveResult.engine.rawValue) variant=\(liveResult.engineVariant ?? "none")"
            )
        } else {
            result = try await sttTranscriber.transcribe(audioPath: audioURL.path, job: .dictation)
        }
        logger.debug("dictation_transcription_complete chars=\(result.text.count, privacy: .public)")
        let transcriptWordCount = result.words.isEmpty
            ? Observability.wordCount(result.text)
            : result.words.count
        AudioCaptureDiagnostics.append(
            "dictation_transcribe_complete chars=\(result.text.count) words=\(transcriptWordCount) engine=\(result.engine.rawValue) variant=\(result.engineVariant ?? "none")"
        )

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // defer will clean up audioURL
            logger.warning("dictation_transcription_empty")
            AudioCaptureDiagnostics.append("dictation_transcribe_empty")
            throw DictationServiceError.emptyTranscript
        }

        let mode = processingMode()
        let insertionStyle = mode.usesDeterministicPipeline ? dictationInsertionStyle() : .sentence
        var words: [CustomWord] = []
        var snippets: [TextSnippet] = []
        if mode.usesDeterministicPipeline {
            do { words = try customWordRepo?.fetchEnabled() ?? [] }
            catch { logger.error("dictation_custom_words_fetch_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
            do { snippets = try snippetRepo?.fetchEnabled() ?? [] }
            catch { logger.error("dictation_snippets_fetch_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
        }

        // Voice Return: inject synthetic action snippet regardless of mode
        // (raw mode extracts trailing action without running the full pipeline)
        if let trigger = voiceReturnTrigger(), !trigger.isEmpty {
            snippets.append(TextSnippet(
                trigger: trigger,
                expansion: KeyAction.returnKey.label,
                action: .returnKey
            ))
        }
        let refinement = await textRefinementService.refine(
            rawText: result.text,
            mode: mode,
            customWords: words,
            snippets: snippets,
            insertionStyle: insertionStyle
        )
        let cleanTranscript = refinement.text
        let expandedSnippetIDs = refinement.expandedSnippetIDs
        let protectedLeadingTerms = TextProcessingPipeline().protectedLeadingTerms(
            customWords: words,
            textSnippets: snippets.filter { $0.action == nil },
            expandedSnippetIDs: expandedSnippetIDs
        )
        let baseText = cleanTranscript ?? result.text
        let saveHistory = shouldSaveDictationHistory?() ?? true
        let dictationID = UUID()
        let formatterOutcome = try await formatTranscriptIfNeeded(
            baseText,
            runSource: saveHistory ? LLMRunSource(dictationId: dictationID) : nil,
            formatterContext: formatterContext
        )
        let formattedTranscript = formatterOutcome.text.map {
            guard insertionStyle == .inline else { return $0 }
            let normalizedFormatterText = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return TextProcessingPipeline().applyInsertionStyle(
                to: normalizedFormatterText,
                insertionStyle: insertionStyle,
                protectedLeadingTerms: protectedLeadingTerms
            )
        }
        let finalText = formattedTranscript ?? baseText
        let wc = finalText.split(whereSeparator: \.isWhitespace).count

        var dictation = Dictation(
            id: dictationID,
            durationMs: computeDurationMs(from: result),
            rawTranscript: result.text,
            cleanTranscript: formattedTranscript ?? cleanTranscript,
            processingMode: mode,
            status: .completed,
            hidden: !saveHistory,
            wordCount: wc,
            engine: result.engine.rawValue,
            engineVariant: result.engineVariant,
            language: SpeechEnginePreference.normalizeKnownLanguage(result.language)
        )

        if saveHistory, let resolution = formatterOutcome.resolution {
            dictation.aiFormatterProfileID = resolution.profileID
            dictation.aiFormatterProfileName = resolution.profileName
            dictation.aiFormatterProfileMatchKind = resolution.matchKind
        }

        if saveHistory, shouldSaveAudio?() ?? false {
            do { try AppPaths.ensureDirectories() }
            catch { logger.error("dictation_directory_create_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
            let destURL = URL(fileURLWithPath: AppPaths.dictationsDir, isDirectory: true)
                .appendingPathComponent("\(dictation.id.uuidString).wav")

            if (try? FileManager.default.moveItem(at: audioURL, to: destURL)) != nil {
                dictation.audioPath = destURL.path
                audioConsumed = true  // moved to permanent storage
            }
            // If move failed, defer will clean up the temp file
        }
        // If not saving audio, defer will clean up the temp file

        if saveHistory {
            try dictationRepo.save(dictation)
            await llmRunRecorder.record(formatterOutcome.run)
        } else {
            var privateCopy = dictation
            privateCopy.rawTranscript = ""
            privateCopy.cleanTranscript = nil
            try dictationRepo.save(privateCopy)
        }
        markFirstDictationCompleted?()

        if !expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }

        return DictationResult(
            dictation: dictation,
            insertionStyle: insertionStyle,
            postPasteAction: refinement.postPasteAction
        )
    }

    private func formatTranscriptIfNeeded(
        _ text: String,
        runSource: LLMRunSource?,
        formatterContext: AppPromptContext?
    ) async throws -> FormatterOutcome {
        guard shouldUseAIFormatter(), let llmService else {
            return .skipped
        }

        // Notify observers (e.g. the dictation flow coordinator) that the
        // LLM formatter is about to run so the overlay pill can switch to
        // its `.formatting` beat. We only post this *after* the guards
        // above so "formatter disabled" dictations never flicker into the
        // formatting visual.
        NotificationCenter.default.post(
            name: .macParakeetAIFormatterDidStart,
            object: nil,
            userInfo: ["source": "dictation"]
        )
        defer {
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterDidFinish,
                object: nil,
                userInfo: ["source": "dictation"]
            )
        }

        let resolution = await aiFormatterPromptResolver.resolvePrompt(for: formatterContext)
        let promptTemplate = resolution.promptTemplate
        // Normalize before comparing: `AIFormatter.renderPrompt` passes the
        // template through `normalizedPromptTemplate` before sending, which
        // trims whitespace and folds legacy-v1 prompts back onto the current
        // default. Raw comparison would report those cases as custom prompts
        // even though the LLM sees the shipped default.
        let defaultPromptUsed = AIFormatter.normalizedPromptTemplate(promptTemplate)
            == AIFormatter.defaultPromptTemplate
        let startedAt = Date()
        do {
            let result = try await llmService.formatTranscriptDetailed(
                transcript: text,
                promptTemplate: promptTemplate,
                source: .dictation,
                defaultPromptUsed: defaultPromptUsed
            )
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let run = runSource.map {
                LLMRun(formatterResult: result, source: $0, feature: .formatterDictation)
            }
            return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run, resolution: resolution)
        } catch {
            if error is CancellationError {
                throw error
            }
            logger.warning("dictation_ai_formatter_failed fallback=standard_cleanup error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            let message = "\(error.localizedDescription) Used standard cleanup."
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterWarning,
                object: nil,
                userInfo: [
                    "source": "dictation",
                    "message": message,
                ]
            )
            let run = runSource.map {
                LLMRun.failedFormatterRun(
                    source: $0,
                    feature: .formatterDictation,
                    errorType: Self.errorType(for: error),
                    inputChars: text.count,
                    defaultPromptUsed: defaultPromptUsed,
                    startedAt: startedAt
                )
            }
            return FormatterOutcome(text: nil, run: run, resolution: resolution)
        }
    }

    private func computeDurationMs(from result: STTResult) -> Int {
        if let lastWord = result.words.last {
            return lastWord.endMs
        }
        return result.text.split(separator: " ").count * 150
    }

    private func resetAfterCancelIfStillCurrent(generation: Int) {
        guard generation == cancelGeneration else { return }
        if case .cancelled = _state {
            sendDictationOperation(
                outcome: .cancelled,
                durationSeconds: currentRecordingDurationSeconds(),
                cancelReason: pendingCancelReason
            )
            discardPendingCancelledAudio()
            recordingStartedAt = nil
            clearCurrentOperation()
            _state = .idle
        }
        cancelResetTask = nil
    }

    private func currentRecordingDurationSeconds() -> Double? {
        guard let recordingStartedAt else { return nil }
        return max(0, Date().timeIntervalSince(recordingStartedAt))
    }

    private static func fileSizeBytes(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else {
            return nil
        }
        return size
    }

    private func debugStateLabel(_ state: DictationState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .recording:
            return "recording"
        case .processing:
            return "processing"
        case .success:
            return "success"
        case .cancelled:
            return "cancelled"
        case .error:
            return "error"
        }
    }

    private static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    private func clearCurrentOperation() {
        currentOperationID = nil
        currentOperationTelemetryContext = DictationTelemetryContext()
        currentObservabilityOperationContext = nil
        currentAIFormatterStartContext = nil
        currentAIFormatterFinishContext = nil
        liveTranscriptText = ""
        pendingCancelReason = nil
    }

    private func sendDictationOperation(
        operationID: String? = nil,
        operationContext: ObservabilityOperationContext? = nil,
        telemetryContext: DictationTelemetryContext? = nil,
        outcome: ObservabilityOutcome,
        durationSeconds: Double? = nil,
        wordCount: Int? = nil,
        errorType: String? = nil,
        cancelReason: TelemetryDictationCancelReason? = nil,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        device: RecordingDeviceInfo? = nil
    ) {
        guard let id = operationID ?? currentOperationID else { return }
        let context = telemetryContext ?? currentOperationTelemetryContext
        let observabilityContext = operationContext ?? currentObservabilityOperationContext
        Telemetry.send(.dictationOperation(
            operationID: id,
            operationContext: observabilityContext,
            outcome: outcome,
            trigger: context.trigger,
            mode: context.mode,
            durationSeconds: durationSeconds,
            wordCount: wordCount,
            errorType: errorType,
            cancelReason: cancelReason,
            speechEngine: speechEngine,
            engineVariant: engineVariant,
            language: language,
            appCategory: context.appCategory,
            device: device
        ))
    }
}

public enum DictationServiceError: Error, LocalizedError {
    case notRecording
    case notCancelled
    case noPendingCancelledAudio
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .notRecording: return "Not currently recording"
        case .notCancelled: return "Not currently in the cancel window"
        case .noPendingCancelledAudio: return "No cancelled recording to process"
        case .emptyTranscript: return "Couldn't hear you — try speaking closer to the microphone."
        }
    }
}
