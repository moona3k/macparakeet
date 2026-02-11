import Foundation

public protocol STTClientProtocol: Sendable {
    /// Transcribe an audio file at the given path
    func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)?) async throws -> STTResult

    /// Warm up the STT engine (start daemon, load model)
    func warmUp() async throws

    /// Check if the daemon is running and responsive
    func isReady() async -> Bool

    /// Shut down the daemon
    func shutdown() async
}

extension STTClientProtocol {
    public func transcribe(audioPath: String) async throws -> STTResult {
        try await transcribe(audioPath: audioPath, onProgress: nil)
    }
}

public enum STTError: Error, LocalizedError {
    case daemonNotRunning
    case daemonStartFailed(String)
    case transcriptionFailed(String)
    case timeout
    case modelNotLoaded
    case outOfMemory
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .daemonNotRunning: return "STT daemon is not running"
        case .daemonStartFailed(let reason): return "Failed to start STT daemon: \(reason)"
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        case .timeout: return "STT request timed out"
        case .modelNotLoaded: return "STT model not loaded"
        case .outOfMemory: return "Out of memory during transcription"
        case .invalidResponse: return "Invalid response from STT daemon"
        }
    }
}
