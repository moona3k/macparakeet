import Foundation

public enum MeetingSystemAudioStall: Equatable, Sendable {
    case firstBufferTimeout(seconds: TimeInterval)
    case bufferGap(seconds: TimeInterval)
}

public enum MeetingAudioError: Error, LocalizedError, Sendable {
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case noMicrophoneAvailable
    case microphoneProcessingUnavailable(mode: MeetingMicProcessingMode, reason: String)
    case audioEngineStartFailed(String)
    case systemAudioCaptureFailed(String)
    case unsupportedPlatform
    case alreadyRunning
    case notRunning
    case noAudioCaptured
    case storageFailed(String)
    case mixFailed(String)
    case captureRuntimeFailure(String)
    case systemAudioStalled(MeetingSystemAudioStall)
    case systemAudioStreamStopped(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .screenRecordingPermissionDenied:
            return
                "Screen Recording permission denied. Enable MacParakeet in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .noMicrophoneAvailable:
            return "No microphone available."
        case .microphoneProcessingUnavailable(let mode, let reason):
            return "Microphone processing unavailable (\(String(describing: mode))): \(reason)"
        case .audioEngineStartFailed(let message):
            return "Audio engine failed to start: \(message)"
        case .systemAudioCaptureFailed(let message):
            return "System audio capture failed: \(message)"
        case .unsupportedPlatform:
            return "Meeting recording requires macOS 14.2 or later."
        case .alreadyRunning:
            return "Meeting recording is already running."
        case .notRunning:
            return "Meeting recording is not running."
        case .noAudioCaptured:
            return "No meeting audio was captured."
        case .storageFailed(let message):
            return "Failed to store meeting audio: \(message)"
        case .mixFailed(let message):
            return "Failed to combine meeting audio: \(message)"
        case .captureRuntimeFailure(let message):
            return "Meeting capture failed while running: \(message)"
        case .systemAudioStalled(.firstBufferTimeout(let seconds)):
            return
                "Meeting capture failed while running: system audio stream delivered no buffers within \(Self.formattedSeconds(seconds))s of start"
        case .systemAudioStalled(.bufferGap(let seconds)):
            return
                "Meeting capture failed while running: system audio stream stopped delivering buffers (gap \(Self.formattedSeconds(seconds))s)"
        case .systemAudioStreamStopped(let reason):
            return "Meeting capture failed while running: system audio stream stopped unexpectedly: \(reason)"
        }
    }

    private static func formattedSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }
}
