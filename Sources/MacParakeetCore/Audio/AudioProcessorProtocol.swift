import Foundation

public enum AudioCaptureProblem: String, Sendable, Equatable {
    case engineStartFailed = "engine_start_failed"
    case noInputBuffers = "no_input_buffers"
    case silentInput = "silent_input"

    var userMessage: String {
        switch self {
        case .engineStartFailed:
            return "Microphone failed to start. Try again."
        case .noInputBuffers:
            return "No microphone input detected. Check your input device and try again."
        case .silentInput:
            return "No microphone signal detected. Check your input device and try again."
        }
    }
}

public struct AudioCaptureHealth: Sendable, Equatable {
    public static let noBufferMinimumWallDurationSeconds: Double = 2.0
    public static let silentInputMinimumAudioDurationSeconds: Double = 2.0
    public static let silentInputMaximumLevel: Float = 0.02

    public let sampleCount: Int
    public let audioDurationSeconds: Double
    public let wallDurationSeconds: Double
    public let fileBytes: UInt64?
    public let inputBufferCount: Int
    public let outputBufferCount: Int
    public let inputFrameCount: Int
    public let maxRMS: Float
    public let maxAudioLevel: Float
    public let nonSilentBufferCount: Int
    public let missingFloatChannelDataBufferCount: Int
    public let invalidFormatBufferCount: Int
    public let noBufferTimeoutFired: Bool

    public init(
        sampleCount: Int,
        audioDurationSeconds: Double,
        wallDurationSeconds: Double,
        fileBytes: UInt64?,
        inputBufferCount: Int,
        outputBufferCount: Int,
        inputFrameCount: Int,
        maxRMS: Float,
        maxAudioLevel: Float,
        nonSilentBufferCount: Int,
        missingFloatChannelDataBufferCount: Int,
        invalidFormatBufferCount: Int,
        noBufferTimeoutFired: Bool
    ) {
        self.sampleCount = sampleCount
        self.audioDurationSeconds = audioDurationSeconds
        self.wallDurationSeconds = wallDurationSeconds
        self.fileBytes = fileBytes
        self.inputBufferCount = inputBufferCount
        self.outputBufferCount = outputBufferCount
        self.inputFrameCount = inputFrameCount
        self.maxRMS = maxRMS
        self.maxAudioLevel = maxAudioLevel
        self.nonSilentBufferCount = nonSilentBufferCount
        self.missingFloatChannelDataBufferCount = missingFloatChannelDataBufferCount
        self.invalidFormatBufferCount = invalidFormatBufferCount
        self.noBufferTimeoutFired = noBufferTimeoutFired
    }

    public var terminalProblem: AudioCaptureProblem? {
        if noBufferTimeoutFired ||
            (inputBufferCount == 0 && wallDurationSeconds >= Self.noBufferMinimumWallDurationSeconds) {
            return .noInputBuffers
        }

        if inputBufferCount > 0,
           audioDurationSeconds >= Self.silentInputMinimumAudioDurationSeconds,
           nonSilentBufferCount == 0,
           maxAudioLevel < Self.silentInputMaximumLevel {
            return .silentInput
        }

        return nil
    }
}

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

    /// Device info from the most recent recording (name, transport, format, fallback status).
    var recordingDeviceInfo: RecordingDeviceInfo? { get async }

    /// Health metrics from the most recently stopped capture, if the processor has them.
    var lastCaptureHealth: AudioCaptureHealth? { get async }
}

public enum AudioProcessorError: Error, LocalizedError {
    case microphonePermissionDenied
    case microphoneNotAvailable
    case recordingFailed(String)
    case conversionFailed(String)
    case unsupportedFormat(String)
    case fileTooLarge(String)
    case insufficientSamples
    case inputUnavailable(AudioCaptureProblem)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone permission denied"
        case .microphoneNotAvailable: return "No microphone available"
        case .recordingFailed(let reason): return "Recording failed: \(reason)"
        case .conversionFailed(let reason): return "Audio conversion failed: \(reason)"
        case .unsupportedFormat(let format): return "Unsupported audio format: \(format)"
        case .fileTooLarge(let info): return "File too large: \(info)"
        case .insufficientSamples: return "Recording too short"
        case .inputUnavailable(let problem): return problem.userMessage
        }
    }
}

public extension AudioProcessorProtocol {
    var lastCaptureHealth: AudioCaptureHealth? {
        get async { nil }
    }
}
