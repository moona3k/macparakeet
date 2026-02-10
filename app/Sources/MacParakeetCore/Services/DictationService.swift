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
    var state: DictationState { get async }
    var audioLevel: Float { get async }
}

public actor DictationService: DictationServiceProtocol {
    private let audioProcessor: AudioProcessorProtocol
    private let sttClient: STTClientProtocol
    private let dictationRepo: DictationRepositoryProtocol
    private let clipboardService: ClipboardServiceProtocol
    private let entitlements: EntitlementsChecking?

    private var _state: DictationState = .idle
    private var cancelResetTask: Task<Void, Never>?
    private var cancelGeneration: Int = 0

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
        entitlements: EntitlementsChecking? = nil
    ) {
        self.audioProcessor = audioProcessor
        self.sttClient = sttClient
        self.dictationRepo = dictationRepo
        self.clipboardService = clipboardService
        self.entitlements = entitlements
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

            // Transcribe
            let result = try await sttClient.transcribe(audioPath: audioURL.path)

            // Clean up temp audio file
            try? FileManager.default.removeItem(at: audioURL)

            // Create dictation record
            let dictation = Dictation(
                durationMs: computeDurationMs(from: result),
                rawTranscript: result.text,
                processingMode: .raw,
                status: .completed
            )

            // Save to database
            try dictationRepo.save(dictation)

            // Paste to active app
            try await clipboardService.pasteText(result.text)

            _state = .success(dictation)

            // Reset to idle after brief delay
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
        cancelGeneration += 1
        let generation = cancelGeneration

        if case .recording = _state {
            // Stop capture but discard the result.
            _ = try? await audioProcessor.stopCapture()
        }

        _state = .cancelled

        // Reset to idle after cancel window (do not block the caller).
        cancelResetTask?.cancel()
        cancelResetTask = Task.detached { [generation, weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.resetAfterCancelIfStillCurrent(generation: generation)
        }
    }

    // MARK: - Private

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
            _state = .idle
        }
        cancelResetTask = nil
    }
}

public enum DictationServiceError: Error, LocalizedError {
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .notRecording: return "Not currently recording"
        }
    }
}
