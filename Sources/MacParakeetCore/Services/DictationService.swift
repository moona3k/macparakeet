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
    func stopRecording() async throws -> Dictation
    func cancelRecording(reason: TelemetryDictationCancelReason?) async
    /// Confirm cancel immediately (discard any pending audio and reset to idle).
    func confirmCancel() async
    /// Undo a soft-cancel: transcribe the cancelled recording and return a Dictation.
    func undoCancel() async throws -> Dictation
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
    private let sttClient: STTClientProtocol
    private let dictationRepo: DictationRepositoryProtocol
    private let shouldSaveAudio: (@Sendable () -> Bool)?
    private let shouldSaveDictationHistory: (@Sendable () -> Bool)?
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let processingMode: @Sendable () -> Dictation.ProcessingMode
    private let textRefinementService: TextRefinementService
    private let cancelWindow: Duration

    private var _state: DictationState = .idle
    private var cancelResetTask: Task<Void, Never>?
    private var cancelGeneration: Int = 0
    private var pendingCancelledAudioURL: URL?
    private var currentTelemetryContext = DictationTelemetryContext()
    private var recordingStartedAt: Date?

    public var state: DictationState {
        _state
    }

    public var audioLevel: Float {
        get async { await audioProcessor.audioLevel }
    }

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttClient: STTClientProtocol,
        dictationRepo: DictationRepositoryProtocol,
        shouldSaveAudio: (@Sendable () -> Bool)? = nil,
        shouldSaveDictationHistory: (@Sendable () -> Bool)? = nil,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        cancelWindow: Duration = .seconds(5)
    ) {
        self.audioProcessor = audioProcessor
        self.sttClient = sttClient
        self.dictationRepo = dictationRepo
        self.shouldSaveAudio = shouldSaveAudio
        self.shouldSaveDictationHistory = shouldSaveDictationHistory
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.processingMode = processingMode ?? { .raw }
        self.textRefinementService = TextRefinementService()
        self.cancelWindow = cancelWindow
    }

    public func startRecording(context: DictationTelemetryContext = DictationTelemetryContext()) async throws {
        logger.debug("startRecording requested state=\(self.debugStateLabel(self._state), privacy: .public)")
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        switch _state {
        case .idle, .cancelled:
            break
        default:
            return
        }

        discardPendingCancelledAudio()

        cancelResetTask?.cancel()
        cancelResetTask = nil

        _state = .recording
        do {
            try await audioProcessor.startCapture()
            // Guard against reentrancy: cancel may have run during the await above
            guard case .recording = _state else {
                let _ = try? await audioProcessor.stopCapture()
                recordingStartedAt = nil
                return
            }
            currentTelemetryContext = context
            recordingStartedAt = Date()
            Telemetry.send(.dictationStarted(trigger: context.trigger, mode: context.mode))
            logger.debug("startRecording capture started")
        } catch {
            let device = await audioProcessor.recordingDeviceInfo
            _state = .idle
            recordingStartedAt = nil
            Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            logger.error("startRecording failed error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func stopRecording() async throws -> Dictation {
        guard case .recording = _state else {
            logger.warning("stopRecording rejected state=\(self.debugStateLabel(self._state), privacy: .public)")
            throw DictationServiceError.notRecording
        }

        _state = .processing
        logger.debug("stopRecording processing begin")

        do {
            let audioURL = try await audioProcessor.stopCapture()
            let device = await audioProcessor.recordingDeviceInfo
            logger.debug("stopRecording capture stopped url=\(audioURL.path, privacy: .public)")
            let dictation = try await processCapturedAudio(audioURL: audioURL)
            _state = .success(dictation)
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(dictation.durationMs) / 1000.0,
                wordCount: dictation.wordCount,
                mode: currentTelemetryContext.mode,
                device: device
            ))
            logger.debug("stopRecording success rawChars=\(dictation.rawTranscript.count) cleanChars=\(dictation.cleanTranscript?.count ?? 0)")
            try? await Task.sleep(for: .milliseconds(500))
            _state = .idle
            recordingStartedAt = nil
            return dictation
        } catch {
            // Snapshot device before setting state to .idle — prevents reentrancy
            // window where a new startRecording() could overwrite the device info.
            let device = await audioProcessor.recordingDeviceInfo
            _state = .idle
            if error is DictationServiceError, case DictationServiceError.emptyTranscript = error {
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
            logger.error("stopRecording failed error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func cancelRecording(reason: TelemetryDictationCancelReason? = nil) async {
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

    public func undoCancel() async throws -> Dictation {
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
            let dictation = try await processCapturedAudio(audioURL: audioURL)
            let device = await audioProcessor.recordingDeviceInfo
            _state = .success(dictation)
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(dictation.durationMs) / 1000.0,
                wordCount: dictation.wordCount,
                mode: currentTelemetryContext.mode,
                device: device
            ))
            try? await Task.sleep(for: .milliseconds(500))
            _state = .idle
            recordingStartedAt = nil
            return dictation
        } catch {
            let device = await audioProcessor.recordingDeviceInfo
            _state = .idle
            if error is DictationServiceError, case DictationServiceError.emptyTranscript = error {
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
            throw error
        }
    }

    // MARK: - Private

    private func discardPendingCancelledAudio() {
        if let url = pendingCancelledAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingCancelledAudioURL = nil
    }

    private func processCapturedAudio(audioURL: URL) async throws -> Dictation {
        // Track whether the audio file is consumed (moved or explicitly deleted).
        // If an error occurs before that point, clean up the temp file.
        var audioConsumed = false
        defer {
            if !audioConsumed {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        let result = try await sttClient.transcribe(audioPath: audioURL.path)
        logger.debug("processCapturedAudio transcription complete chars=\(result.text.count)")

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // defer will clean up audioURL
            logger.warning("processCapturedAudio empty transcript")
            throw DictationServiceError.emptyTranscript
        }

        let mode = processingMode()
        let words = mode.usesDeterministicPipeline ? ((try? customWordRepo?.fetchEnabled()) ?? []) : []
        let snippets = mode.usesDeterministicPipeline ? ((try? snippetRepo?.fetchEnabled()) ?? []) : []
        let refinement = await textRefinementService.refine(
            rawText: result.text,
            mode: mode,
            customWords: words,
            snippets: snippets
        )
        let cleanTranscript = refinement.text
        let expandedSnippetIDs = refinement.expandedSnippetIDs

        let finalText = cleanTranscript ?? result.text
        let wc = finalText.split(whereSeparator: \.isWhitespace).count
        let saveHistory = shouldSaveDictationHistory?() ?? true

        var dictation = Dictation(
            durationMs: computeDurationMs(from: result),
            rawTranscript: result.text,
            cleanTranscript: cleanTranscript,
            processingMode: mode,
            status: .completed,
            hidden: !saveHistory,
            wordCount: wc
        )

        if saveHistory, shouldSaveAudio?() ?? false {
            try? AppPaths.ensureDirectories()
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

        return dictation
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
