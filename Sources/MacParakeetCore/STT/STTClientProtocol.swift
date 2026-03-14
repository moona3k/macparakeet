import Foundation

public protocol STTClientProtocol: Sendable {
    /// Transcribe an audio file at the given path
    func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)?) async throws -> STTResult

    /// Warm up the STT engine (load model into memory) with optional progress callback.
    /// Progress messages are human-readable strings like "Downloading speech model (571 MB)... 45%".
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws

    /// Check if the STT engine is initialized and ready
    func isReady() async -> Bool

    /// Clear all cached speech and speaker models.
    func clearModelCache() async

    /// Shut down the STT engine
    func shutdown() async
}

extension STTClientProtocol {
    public func transcribe(audioPath: String) async throws -> STTResult {
        try await transcribe(audioPath: audioPath, onProgress: nil)
    }

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
    case outOfMemory
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .engineNotRunning: return "Speech engine is not running"
        case .engineStartFailed(let reason): return "Failed to start speech engine: \(reason)"
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        case .timeout: return "STT request timed out"
        case .modelNotLoaded: return "STT model not loaded"
        case .outOfMemory: return "Out of memory during transcription"
        case .invalidResponse: return "Invalid response from speech engine"
        }
    }
}
