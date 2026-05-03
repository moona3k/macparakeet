import Foundation

/// Stop orchestration decision for dictation UI flows.
/// This keeps race handling logic testable and centralized.
public enum DictationStopDecision: Sendable, Equatable {
    /// Dictation service is actively recording and can be stopped immediately.
    case proceed
    /// Start is still in-flight; defer stop until recording is active.
    case deferUntilRecording
    /// Service is not recording and startup is not in-flight.
    case rejectNotRecording
}

public enum DictationStopDecider {
    public static func decide(
        serviceState: DictationState,
        isStartRecordingInFlight: Bool
    ) -> DictationStopDecision {
        if case .recording = serviceState {
            return .proceed
        }
        if isStartRecordingInFlight {
            return .deferUntilRecording
        }
        return .rejectNotRecording
    }
}
