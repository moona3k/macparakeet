import Foundation

public protocol AudioProcessorProtocol: Sendable {
    /// Convert an audio/video file to 16kHz mono WAV for STT processing
    func convert(fileURL: URL) async throws -> URL

    /// Start microphone capture
    func startCapture() async throws

    /// Stop microphone capture and return the path to the recorded WAV file
    func stopCapture() async throws -> URL

    /// Current audio level (0.0 to 1.0) for waveform visualization
    var audioLevel: Float { get async }

    /// Whether the microphone is currently recording
    var isRecording: Bool { get async }
}

public enum AudioProcessorError: Error, LocalizedError {
    case microphonePermissionDenied
    case microphoneNotAvailable
    case recordingFailed(String)
    case conversionFailed(String)
    case unsupportedFormat(String)
    case fileTooLarge(String)
    case insufficientSamples

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone permission denied"
        case .microphoneNotAvailable: return "No microphone available"
        case .recordingFailed(let reason): return "Recording failed: \(reason)"
        case .conversionFailed(let reason): return "Audio conversion failed: \(reason)"
        case .unsupportedFormat(let format): return "Unsupported audio format: \(format)"
        case .fileTooLarge(let info): return "File too large: \(info)"
        case .insufficientSamples: return "Recording too short"
        }
    }
}
