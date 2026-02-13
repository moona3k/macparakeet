import Foundation

public enum DictationState: Sendable {
    case idle
    case recording
    case processing
    case success(Dictation)
    case cancelled
    case error(String)
}

public protocol DictationServiceProtocol: Sendable {
    func startRecording() async throws
    func stopRecording() async throws -> Dictation
    func cancelRecording() async
    /// Confirm cancel immediately (discard any pending audio and reset to idle).
    func confirmCancel() async
    /// Undo a soft-cancel: transcribe the cancelled recording and return a Dictation.
    func undoCancel() async throws -> Dictation
    var state: DictationState { get async }
    var audioLevel: Float { get async }
}

public actor DictationService: DictationServiceProtocol {
    private let audioProcessor: AudioProcessorProtocol
    private let sttClient: STTClientProtocol
    private let dictationRepo: DictationRepositoryProtocol
    private let clipboardService: ClipboardServiceProtocol
    private let shouldSaveAudio: (@Sendable () -> Bool)?
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let processingMode: @Sendable () -> Dictation.ProcessingMode
    private let cancelWindow: Duration

    private var _state: DictationState = .idle
    private var cancelResetTask: Task<Void, Never>?
    private var cancelGeneration: Int = 0
    private var pendingCancelledAudioURL: URL?

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
        clipboardService: ClipboardServiceProtocol,
        shouldSaveAudio: (@Sendable () -> Bool)? = nil,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        cancelWindow: Duration = .seconds(5)
    ) {
        self.audioProcessor = audioProcessor
        self.sttClient = sttClient
        self.dictationRepo = dictationRepo
        self.clipboardService = clipboardService
        self.shouldSaveAudio = shouldSaveAudio
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.processingMode = processingMode ?? { .raw }
        self.cancelWindow = cancelWindow
    }

    public func startRecording() async throws {
        if let entitlements {
            try await entitlements.assertCanTranscribe(now: Date())
        }

        // Allow starting a new recording from idle or during the cancel window (Undo flow).
        switch _state {
        case .idle, .cancelled:
            break
        default:
            return
        }

        // Starting a new recording implicitly discards any pending cancelled audio.
        discardPendingCancelledAudio()

        cancelResetTask?.cancel()
        cancelResetTask = nil

        _state = .recording
        do {
            try await audioProcessor.startCapture()
        } catch {
            _state = .idle
            throw error
        }
    }

    public func stopRecording() async throws -> Dictation {
        guard case .recording = _state else {
            throw DictationServiceError.notRecording
        }

        _state = .processing

        do {
            let audioURL = try await audioProcessor.stopCapture()
            let dictation = try await processCapturedAudio(audioURL: audioURL)
            _state = .success(dictation)
            try? await Task.sleep(for: .milliseconds(500))
            _state = .idle
            return dictation
        } catch {
            // Reset to idle so a new recording can be started.
            // The caller (AppDelegate) handles error display timing on the overlay.
            _state = .idle
            throw error
        }
    }

    public func cancelRecording() async {
        // Soft cancel: stop capture and hold the audio briefly so Undo can proceed.
        guard case .recording = _state else { return }

        cancelGeneration += 1
        let generation = cancelGeneration

        let audioURL = try? await audioProcessor.stopCapture()
        pendingCancelledAudioURL = audioURL
        _state = .cancelled

        cancelResetTask?.cancel()
        cancelResetTask = Task { [generation] in
            try? await Task.sleep(for: cancelWindow)
            // This Task is created from within the actor, so it inherits actor isolation.
            resetAfterCancelIfStillCurrent(generation: generation)
        }
    }

    public func confirmCancel() async {
        cancelGeneration += 1
        cancelResetTask?.cancel()
        cancelResetTask = nil
        discardPendingCancelledAudio()

        // If we're still recording (shouldn't happen if cancelRecording was used),
        // make a best-effort attempt to stop capture and discard.
        if case .recording = _state {
            if let url = try? await audioProcessor.stopCapture() {
                try? FileManager.default.removeItem(at: url)
            }
        }

        _state = .idle
    }

    public func undoCancel() async throws -> Dictation {
        guard case .cancelled = _state else {
            throw DictationServiceError.notCancelled
        }
        guard let audioURL = pendingCancelledAudioURL else {
            // Nothing to undo; behave like a no-op.
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
            _state = .success(dictation)
            try? await Task.sleep(for: .milliseconds(500))
            _state = .idle
            return dictation
        } catch {
            _state = .idle
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
        // Transcribe
        let result = try await sttClient.transcribe(audioPath: audioURL.path)

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Clean up temp audio file; do not paste/save empty transcripts.
            try? FileManager.default.removeItem(at: audioURL)
            throw DictationServiceError.emptyTranscript
        }

        // Run pipeline if not raw mode
        let mode = processingMode()
        var cleanTranscript: String? = nil
        var expandedSnippetIDs = Set<UUID>()

        if mode != .raw {
            let words = (try? customWordRepo?.fetchEnabled()) ?? []
            let snippets = (try? snippetRepo?.fetchEnabled()) ?? []
            let pipeline = TextProcessingPipeline()
            let pipelineResult = pipeline.process(
                text: result.text,
                customWords: words,
                snippets: snippets
            )
            cleanTranscript = pipelineResult.text
            expandedSnippetIDs = pipelineResult.expandedSnippetIDs
        }

        // Create dictation record
        var dictation = Dictation(
            durationMs: computeDurationMs(from: result),
            rawTranscript: result.text,
            cleanTranscript: cleanTranscript,
            processingMode: mode,
            status: .completed
        )

        // Persist audio if enabled; otherwise delete it.
        if shouldSaveAudio?() ?? false {
            try? AppPaths.ensureDirectories()
            let destURL = URL(fileURLWithPath: AppPaths.dictationsDir, isDirectory: true)
                .appendingPathComponent("\(dictation.id.uuidString).wav")

            if (try? FileManager.default.moveItem(at: audioURL, to: destURL)) != nil {
                dictation.audioPath = destURL.path
            } else {
                // Best-effort fallback: don't fail dictation if file I/O fails.
                try? FileManager.default.removeItem(at: audioURL)
            }
        } else {
            try? FileManager.default.removeItem(at: audioURL)
        }

        // Save to database
        try dictationRepo.save(dictation)

        // Update snippet use counts
        if !expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: expandedSnippetIDs)
        }

        return dictation
    }

    private func computeDurationMs(from result: STTResult) -> Int {
        if let lastWord = result.words.last {
            return lastWord.endMs
        }
        // Rough estimate: ~150ms per word
        return result.text.split(separator: " ").count * 150
    }

    private func resetAfterCancelIfStillCurrent(generation: Int) {
        guard generation == cancelGeneration else { return }
        if case .cancelled = _state {
            discardPendingCancelledAudio()
            _state = .idle
        }
        cancelResetTask = nil
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
