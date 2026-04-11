import Foundation
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

    public init(trigger: TelemetryDictationTrigger? = nil, mode: TelemetryDictationMode? = nil) {
        self.trigger = trigger
        self.mode = mode
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
    private let textRefinementService: TextRefinementService
    private let llmService: LLMServiceProtocol?
    private let shouldUseAIFormatter: @Sendable () -> Bool
    private let aiFormatterPromptTemplate: @Sendable () -> String
    private let cancelWindow: Duration

    private var _state: DictationState = .idle
    private var cancelResetTask: Task<Void, Never>?
    private var cancelGeneration: Int = 0
    private var pendingCancelledAudioURL: URL?
    private var currentTelemetryContext = DictationTelemetryContext()
    private var recordingStartedAt: Date?
    private var activeSessionID: Int = 0

    public var state: DictationState {
        _state
    }

    public var audioLevel: Float {
        get async { await audioProcessor.audioLevel }
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
        llmService: LLMServiceProtocol? = nil,
        shouldUseAIFormatter: (@Sendable () -> Bool)? = nil,
        aiFormatterPromptTemplate: (@Sendable () -> String)? = nil,
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
        self.textRefinementService = TextRefinementService()
        self.llmService = llmService
        self.shouldUseAIFormatter = shouldUseAIFormatter ?? { false }
        self.aiFormatterPromptTemplate = aiFormatterPromptTemplate ?? { AIFormatter.defaultPromptTemplate }
        self.cancelWindow = cancelWindow
    }

    public func startRecording(context: DictationTelemetryContext = DictationTelemetryContext()) async throws {
        try await startRecording(context: context, sessionID: nil)
    }

    public func startRecording(
        context: DictationTelemetryContext = DictationTelemetryContext(),
        sessionID: Int?
    ) async throws {
        logger.debug("startRecording requested state=\(self.debugStateLabel(self._state), privacy: .public)")
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
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
        _state = .recording
        do {
            try await audioProcessor.startCapture()
            // Guard against reentrancy: cancel may have run during the await above
            guard case .recording = _state else {
                if await audioProcessor.isRecording,
                   let audioURL = try? await audioProcessor.stopCapture() {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                recordingStartedAt = nil
                logger.notice(
                    "startRecording aborted session=\(requestedSessionID) state=\(self.debugStateLabel(self._state), privacy: .public)"
                )
                return
            }
            currentTelemetryContext = context
            recordingStartedAt = Date()
            Telemetry.send(.dictationStarted(trigger: context.trigger, mode: context.mode))
            logger.debug("startRecording capture started session=\(requestedSessionID)")
        } catch {
            let device = await audioProcessor.recordingDeviceInfo
            _state = .idle
            recordingStartedAt = nil
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
        _state = .processing
        logger.debug("stopRecording processing begin session=\(currentSession)")

        do {
            let audioURL = try await audioProcessor.stopCapture()
            let device = await audioProcessor.recordingDeviceInfo
            logger.debug(
                "stopRecording capture stopped session=\(currentSession) url=\(audioURL.path, privacy: .public)"
            )
            let result = try await processCapturedAudio(audioURL: audioURL)
            // Guard against reentrancy: a new session may have started during
            // transcription, replacing this session. Don't overwrite its state.
            guard activeSessionID == currentSession else {
                logger.notice(
                    "stopRecording result discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                return result
            }
            _state = .success(result.dictation)
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                mode: currentTelemetryContext.mode,
                device: device
            ))
            logger.debug(
                "stopRecording success session=\(currentSession) rawChars=\(result.dictation.rawTranscript.count) cleanChars=\(result.dictation.cleanTranscript?.count ?? 0)"
            )
            try? await Task.sleep(for: .milliseconds(500))
            guard activeSessionID == currentSession else { return result }
            _state = .idle
            recordingStartedAt = nil
            return result
        } catch {
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
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
            logger.error(
                "stopRecording failed session=\(currentSession) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
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
            if let url = try? await audioProcessor.stopCapture() {
                try? FileManager.default.removeItem(at: url)
            }
        }

        recordingStartedAt = nil
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

        _state = .processing
        do {
            let result = try await processCapturedAudio(audioURL: audioURL)
            let device = await audioProcessor.recordingDeviceInfo
            _state = .success(result.dictation)
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                mode: currentTelemetryContext.mode,
                device: device
            ))
            try? await Task.sleep(for: .milliseconds(500))
            _state = .idle
            recordingStartedAt = nil
            return result
        } catch {
            let device = await audioProcessor.recordingDeviceInfo
            _state = .idle
            if Self.isNoSpeechError(error) {
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
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

    private func discardPendingCancelledAudio() {
        if let url = pendingCancelledAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingCancelledAudioURL = nil
    }

    private func processCapturedAudio(audioURL: URL) async throws -> DictationResult {
        // Track whether the audio file is consumed (moved or explicitly deleted).
        // If an error occurs before that point, clean up the temp file.
        var audioConsumed = false
        defer {
            if !audioConsumed {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        let result = try await sttTranscriber.transcribe(audioPath: audioURL.path, job: .dictation)
        logger.debug("processCapturedAudio transcription complete chars=\(result.text.count)")

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // defer will clean up audioURL
            logger.warning("processCapturedAudio empty transcript")
            throw DictationServiceError.emptyTranscript
        }

        let mode = processingMode()
        var words: [CustomWord] = []
        var snippets: [TextSnippet] = []
        if mode.usesDeterministicPipeline {
            do { words = try customWordRepo?.fetchEnabled() ?? [] }
            catch { logger.error("Failed to load custom words: \(error.localizedDescription)") }
            do { snippets = try snippetRepo?.fetchEnabled() ?? [] }
            catch { logger.error("Failed to load text snippets: \(error.localizedDescription)") }
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
            snippets: snippets
        )
        let cleanTranscript = refinement.text
        let expandedSnippetIDs = refinement.expandedSnippetIDs
        let baseText = cleanTranscript ?? result.text
        let formattedTranscript = try await formatTranscriptIfNeeded(baseText)
        let finalText = formattedTranscript ?? baseText
        let wc = finalText.split(whereSeparator: \.isWhitespace).count
        let saveHistory = shouldSaveDictationHistory?() ?? true

        var dictation = Dictation(
            durationMs: computeDurationMs(from: result),
            rawTranscript: result.text,
            cleanTranscript: formattedTranscript ?? cleanTranscript,
            processingMode: mode,
            status: .completed,
            hidden: !saveHistory,
            wordCount: wc
        )

        if saveHistory, shouldSaveAudio?() ?? false {
            do { try AppPaths.ensureDirectories() }
            catch { logger.error("Failed to create directories: \(error.localizedDescription, privacy: .public)") }
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
        } else {
            var privateCopy = dictation
            privateCopy.rawTranscript = ""
            privateCopy.cleanTranscript = nil
            try dictationRepo.save(privateCopy)
        }

        if !expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }

        return DictationResult(dictation: dictation, postPasteAction: refinement.postPasteAction)
    }

    private func formatTranscriptIfNeeded(_ text: String) async throws -> String? {
        guard shouldUseAIFormatter(), let llmService else {
            return nil
        }

        do {
            let formatted = try await llmService.formatTranscript(
                transcript: text,
                promptTemplate: aiFormatterPromptTemplate()
            )
            let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            if error is CancellationError {
                throw error
            }
            logger.error("AI formatter failed error=\(error.localizedDescription, privacy: .public)")
            return nil
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
            discardPendingCancelledAudio()
            recordingStartedAt = nil
            _state = .idle
        }
        cancelResetTask = nil
    }

    private func currentRecordingDurationSeconds() -> Double? {
        guard let recordingStartedAt else { return nil }
        return max(0, Date().timeIntervalSince(recordingStartedAt))
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
