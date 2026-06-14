import Foundation

public enum STTJobKind: Sendable, Equatable {
    case dictation
    case meetingFinalize
    case meetingLiveChunk
    case fileTranscription
}

public enum STTWarmUpState: Sendable, Equatable {
    case idle
    case working(message: String, progress: Double?)
    case ready
    case failed(message: String)
}

public protocol STTTranscribing: Sendable {
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
}

public enum STTLiveDictationTranscriptionError: Error, LocalizedError, Equatable {
    case unsupportedEngine(SpeechEnginePreference)
    case modelNotReady
    case sessionNotActive

    public var errorDescription: String? {
        switch self {
        case .unsupportedEngine(let engine):
            return "\(engine.displayName) does not support live dictation partials."
        case .modelNotReady:
            return "Speech model is not ready for live dictation."
        case .sessionNotActive:
            return "Live dictation transcription is not active."
        }
    }
}

public protocol STTLiveDictationTranscribing: Sendable {
    func beginLiveDictationTranscription(
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> UUID

    func appendLiveDictationSamples(_ samples: [Float], sessionID: UUID) async throws

    func finishLiveDictationTranscription(sessionID: UUID) async throws -> STTResult

    func cancelLiveDictationTranscription(sessionID: UUID) async
}

public protocol STTDictationPreviewTranscribing: Sendable {
    func transcribeDictationPreview(
        samples: [Float],
        speechEngine: SpeechEngineSelection
    ) async throws -> STTResult

    func cancelDictationPreview() async
}

public protocol SpeechEngineRoutedTranscribing: STTTranscribing {
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
}

public protocol STTRuntimeManaging: Sendable {
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func backgroundWarmUp() async
    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>)
    func removeWarmUpObserver(id: UUID) async
    func isReady() async -> Bool
    func clearModelCache() async
    func shutdown() async
}

public typealias STTManaging = STTTranscribing & STTRuntimeManaging
public typealias STTClientProtocol = STTManaging

public protocol SpeechEngineSwitching: Sendable {
    func setSpeechEngine(_ preference: SpeechEnginePreference) async throws
    func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    /// Switches the active Parakeet build (multilingual `v3` ↔ English-only
    /// `v2`). Like an engine switch, this may download the target and reloads
    /// the runtime when Parakeet is active; see
    /// ``STTRuntime/setParakeetModelVariant(_:onProgress:)``.
    func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    /// Switches the active Nemotron build (multilingual ↔ English-only).
    /// Like an engine switch, this may download the target and reloads the
    /// runtime when Nemotron is active; see
    /// ``STTRuntime/setNemotronModelVariant(_:onProgress:)``.
    func setNemotronModelVariant(
        _ variant: NemotronModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
}

public enum SpeechEngineSwitchAvailability: Sendable, Equatable {
    case available
    case meetingActive
    case transcribing
    case switchInProgress
    case unavailable
}

public protocol SpeechEngineSwitchAvailabilityProviding: Sendable {
    func engineSwitchAvailability() async -> SpeechEngineSwitchAvailability
}

extension SpeechEngineSwitching {
    public func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        onProgress?("Preparing \(preference.displayName)...")
        try await setSpeechEngine(preference)
    }
}

public protocol SpeechEngineSessionManaging: Sendable {
    func beginSpeechEngineSession() async -> SpeechEngineLease
    func endSpeechEngineSession(_ lease: SpeechEngineLease) async
}

extension STTTranscribing {
    public func transcribe(audioPath: String, job: STTJobKind) async throws -> STTResult {
        try await transcribe(audioPath: audioPath, job: job, onProgress: nil)
    }
}

extension STTRuntimeManaging {
    public func warmUp() async throws {
        try await warmUp(onProgress: nil)
    }
}

public enum STTError: Error, LocalizedError {
    case engineNotRunning
    case engineStartFailed(String)
    case transcriptionFailed(String)
    case timeout
    case modelNotLoaded
    case modelDownloadFailed
    case outOfMemory
    case invalidResponse
    case engineBusy

    public var errorDescription: String? {
        switch self {
        case .engineNotRunning: return "Speech engine is not running"
        case .engineStartFailed(let reason): return "Failed to start speech engine: \(reason)"
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        case .timeout: return "STT request timed out"
        case .modelNotLoaded: return "STT model not loaded"
        case .modelDownloadFailed: return "Speech model isn't downloaded yet — check your internet connection and try again."
        case .outOfMemory: return "Out of memory during transcription"
        case .invalidResponse: return "Invalid response from speech engine"
        case .engineBusy: return "Speech engine is busy. Try again after the current transcription finishes."
        }
    }
}
