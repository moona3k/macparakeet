import Foundation

public struct DictationAudioSampleSink: Sendable {
    public let onSamples: @Sendable ([Float]) -> Void
    public let onFinish: @Sendable () -> Void
    public let onCancel: @Sendable () -> Void

    public init(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.onSamples = onSamples
        self.onFinish = onFinish
        self.onCancel = onCancel
    }
}

public protocol AudioProcessorProtocol: Sendable {
    /// Convert an audio/video file to 16kHz mono WAV for STT processing
    func convert(fileURL: URL) async throws -> URL

    /// Start microphone capture
    func startCapture() async throws

    /// Start microphone capture and mirror converted 16 kHz mono Float32
    /// samples to `sampleSink` for engines that can consume live audio.
    func startCapture(sampleSink: DictationAudioSampleSink?) async throws

    /// Stop microphone capture and return the path to the recorded WAV file
    func stopCapture() async throws -> URL

    /// Current audio level (0.0 to 1.0) for waveform visualization
    var audioLevel: Float { get async }

    /// Whether the microphone is currently recording
    var isRecording: Bool { get async }

    /// Device info from the most recent recording (name, transport, format, fallback status).
    var recordingDeviceInfo: RecordingDeviceInfo? { get async }

    /// Discard the instant-dictation pre-roll from the active capture (no-op
    /// when idle or when no pre-roll was prepended). Called when system media
    /// was confirmed playing at dictation start, so the pre-roll is known to
    /// be pre-press media audio (issue #474).
    func discardPreRollForActiveCapture() async
}

public extension AudioProcessorProtocol {
    func startCapture(sampleSink: DictationAudioSampleSink?) async throws {
        try await startCapture()
    }

    /// Capture-only implementations (file converters, test doubles) have no
    /// pre-roll; discarding is a no-op unless a conformer opts in.
    func discardPreRollForActiveCapture() async {}
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
