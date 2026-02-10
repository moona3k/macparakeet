import Foundation

/// Pure state machine for Fn key gesture detection.
/// Detects double-tap (persistent mode) and hold (push-to-talk mode).
/// Testable without CGEvent — operates on abstract key up/down events.
public final class FnKeyStateMachine {
    public enum State: Equatable {
        case idle
        case waitingForSecondTap   // Fn pressed once, waiting to see if double-tap
        case persistent            // Double-tap confirmed, recording
        case holdToTalk            // Held past threshold, recording
        case cancelWindow          // Esc pressed, in undo window
        case blocked               // Fn blocked during cancel window
    }

    public enum Action: Equatable {
        case none
        case startRecording(mode: RecordingMode)
        case stopRecording
        case cancelRecording
    }

    public enum RecordingMode: Equatable {
        case persistent   // Double-tap: stays on until explicitly stopped
        case holdToTalk   // Hold: stops when Fn released
    }

    /// The 400ms threshold distinguishing taps from holds
    public static let tapThresholdMs: Int = 400

    /// Cancel window duration (5 seconds)
    public static let cancelWindowMs: Int = 5000

    public private(set) var state: State = .idle
    private var fnDownTimestamp: UInt64 = 0  // milliseconds
    private var firstTapTimestamp: UInt64 = 0  // milliseconds

    public init() {}

    /// Called when Fn key is pressed down
    public func fnDown(timestampMs: UInt64) -> Action {
        switch state {
        case .idle:
            fnDownTimestamp = timestampMs
            state = .waitingForSecondTap
            return .none

        case .waitingForSecondTap:
            // Second tap within threshold = double-tap
            let elapsed = timestampMs - firstTapTimestamp
            if elapsed <= Self.tapThresholdMs {
                state = .persistent
                return .startRecording(mode: .persistent)
            } else {
                // Too slow, treat as new first tap
                fnDownTimestamp = timestampMs
                return .none
            }

        case .persistent:
            // Fn pressed again during persistent recording = stop
            state = .idle
            return .stopRecording

        case .holdToTalk:
            // Shouldn't happen (Fn is already held)
            return .none

        case .cancelWindow, .blocked:
            // Fn blocked during cancel window
            state = .blocked
            return .none
        }
    }

    /// Called when Fn key is released
    public func fnUp(timestampMs: UInt64) -> Action {
        switch state {
        case .waitingForSecondTap:
            let holdDuration = timestampMs - fnDownTimestamp
            if holdDuration >= Self.tapThresholdMs {
                // Held too long — this was a hold, but released now
                // Treat as a short press, wait for potential second tap
                // Actually, if held > threshold, it should have been hold-to-talk
                // But we only detect that via the timer callback
            }
            // Quick release = first tap of potential double-tap
            firstTapTimestamp = timestampMs
            return .none

        case .holdToTalk:
            // Release during hold-to-talk = stop and paste
            state = .idle
            return .stopRecording

        case .blocked:
            state = .cancelWindow
            return .none

        default:
            return .none
        }
    }

    /// Called when the 400ms timer fires (Fn is still held)
    public func holdTimerFired() -> Action {
        switch state {
        case .waitingForSecondTap:
            // Fn held past threshold = hold-to-talk mode
            state = .holdToTalk
            return .startRecording(mode: .holdToTalk)
        default:
            return .none
        }
    }

    /// Called when Escape is pressed during recording
    public func escapePressed() -> Action {
        switch state {
        case .persistent, .holdToTalk:
            state = .cancelWindow
            return .cancelRecording
        default:
            return .none
        }
    }

    /// Called when the cancel window expires
    public func cancelWindowExpired() -> Action {
        if state == .cancelWindow || state == .blocked {
            state = .idle
        }
        return .none
    }

    /// Called when the user taps "Undo" during cancel window
    public func undoPressed() -> Action {
        if state == .cancelWindow || state == .blocked {
            state = .idle
        }
        return .none
    }

    /// Called when cancel is triggered via UI button (not Esc key).
    /// Transitions to cancelWindow so Fn is blocked during the countdown.
    public func cancelledByUI() {
        if state == .persistent || state == .holdToTalk {
            state = .cancelWindow
        }
    }

    /// Resume recording after undo — sets the state machine to the active recording mode
    /// so Fn key gestures work correctly.
    public func resumeRecording(mode: RecordingMode) {
        switch mode {
        case .persistent: state = .persistent
        case .holdToTalk: state = .holdToTalk
        }
    }

    /// Reset to idle (for testing or error recovery)
    public func reset() {
        state = .idle
        fnDownTimestamp = 0
        firstTapTimestamp = 0
    }
}
