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
        }
    }
}
