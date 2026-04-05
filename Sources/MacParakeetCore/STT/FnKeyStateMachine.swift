import Foundation

/// Pure state machine for Fn key gesture detection.
/// Detects double-tap (persistent mode) and hold (push-to-talk mode).
/// Testable without CGEvent — operates on abstract key up/down events.
public final class FnKeyStateMachine {
    public enum State: Equatable, Sendable {
        case idle
        case waitingForSecondTap   // Fn pressed once, waiting to see if double-tap
        case persistent            // Double-tap confirmed, recording
        case holdToTalk            // Held past threshold, recording
        case cancelWindow          // Esc pressed, in undo window
        case blocked               // Fn blocked during cancel window
    }

    public enum Action: Equatable, Sendable {
        case none
        case startRecording(mode: RecordingMode)
        case stopRecording
        case cancelRecording
        case discardRecording(showReadyPill: Bool)
    }

    public enum RecordingMode: Equatable, Sendable {
        case persistent   // Double-tap: stays on until explicitly stopped
        case holdToTalk   // Hold: stops when Fn released
    }

    /// Default threshold distinguishing taps from holds.
    public static let defaultTapThresholdMs: Int = 400
    public static let minimumTapThresholdMs: Int = 50
    public static let maximumTapThresholdMs: Int = 500
    public static let defaultStartupDebounceMs: Int = 100

    /// Cancel window duration (5 seconds)
    public static let cancelWindowMs: Int = 5000

    public private(set) var state: State = .idle
    public let tapThresholdMs: Int
    private var fnDownTimestamp: UInt64 = 0  // milliseconds
    private var firstTapTimestamp: UInt64 = 0  // milliseconds
    private var hasActiveProvisionalRecording = false

    public init(tapThresholdMs: Int = defaultTapThresholdMs) {
        self.tapThresholdMs = Self.clampTapThresholdMs(tapThresholdMs)
    }

    public static func clampTapThresholdMs(_ value: Int) -> Int {
        min(max(value, minimumTapThresholdMs), maximumTapThresholdMs)
    }

    /// Called when Fn key is pressed down
    public func fnDown(timestampMs: UInt64) -> Action {
        switch state {
        case .idle:
            fnDownTimestamp = timestampMs
            state = .waitingForSecondTap
            hasActiveProvisionalRecording = false
            return .none

        case .waitingForSecondTap:
            // Second tap within threshold = double-tap
            let elapsed = timestampMs - firstTapTimestamp
            if elapsed <= UInt64(tapThresholdMs) {
                state = .persistent
                hasActiveProvisionalRecording = false
                return .startRecording(mode: .persistent)
            } else {
                // Too slow, treat as new first tap
                fnDownTimestamp = timestampMs
                hasActiveProvisionalRecording = false
                return .none
            }

        case .persistent:
            // Fn pressed again during persistent recording = stop
            state = .idle
            hasActiveProvisionalRecording = false
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

    /// Called when the startup debounce timer fires while still waiting on the first press.
    public func startupTimerFired() -> Action {
        guard state == .waitingForSecondTap, !hasActiveProvisionalRecording else {
            return .none
        }
        hasActiveProvisionalRecording = true
        return .startRecording(mode: .holdToTalk)
    }

    /// Called when Fn key is released
    public func fnUp(timestampMs: UInt64) -> Action {
        switch state {
        case .waitingForSecondTap:
            let holdDuration = timestampMs - fnDownTimestamp
            if holdDuration >= UInt64(tapThresholdMs) {
                state = .idle
                let shouldStop = hasActiveProvisionalRecording
                hasActiveProvisionalRecording = false
                return shouldStop ? .stopRecording : .none
            }
            // Quick release = discard provisional capture and wait for the second tap.
            firstTapTimestamp = timestampMs
            let shouldDiscard = hasActiveProvisionalRecording
            hasActiveProvisionalRecording = false
            return shouldDiscard ? .discardRecording(showReadyPill: true) : .none

        case .holdToTalk:
            // Release during hold-to-talk = stop and paste
            state = .idle
            hasActiveProvisionalRecording = false
            return .stopRecording

        case .blocked:
            state = .cancelWindow
            return .none

        default:
            return .none
        }
    }

    /// Called when the tap-threshold timer fires while the trigger is still held.
    public func holdTimerFired() -> Action {
        switch state {
        case .waitingForSecondTap:
            // Fn held past threshold = hold-to-talk mode
            state = .holdToTalk
            if hasActiveProvisionalRecording {
                hasActiveProvisionalRecording = false
                return .none
            }
            return .startRecording(mode: .holdToTalk)
        default:
            return .none
        }
    }

    /// Called when some other input interrupts the first-press/double-tap window.
    /// Returns a silent discard only if provisional recording had already started.
    public func interruptWaitingForSecondTap() -> Action {
        guard state == .waitingForSecondTap else { return .none }
        state = .idle
        fnDownTimestamp = 0
        firstTapTimestamp = 0
        let shouldDiscard = hasActiveProvisionalRecording
        hasActiveProvisionalRecording = false
        return shouldDiscard ? .discardRecording(showReadyPill: false) : .none
    }

    /// Called when Escape is pressed during recording or cancel window
    public func escapePressed() -> Action {
        switch state {
        case .waitingForSecondTap where hasActiveProvisionalRecording:
            state = .cancelWindow
            hasActiveProvisionalRecording = false
            return .cancelRecording
        case .persistent, .holdToTalk:
            state = .cancelWindow
            hasActiveProvisionalRecording = false
            return .cancelRecording
        case .cancelWindow, .blocked:
            // Escape during undo countdown = confirm cancel immediately
            state = .idle
            hasActiveProvisionalRecording = false
            return .cancelRecording
        default:
            return .none
        }
    }

    /// Called when the cancel window expires
    public func cancelWindowExpired() -> Action {
        if state == .cancelWindow || state == .blocked {
            state = .idle
            hasActiveProvisionalRecording = false
        }
        return .none
    }

    /// Called when the user taps "Undo" during cancel window
    public func undoPressed() -> Action {
        if state == .cancelWindow || state == .blocked {
            state = .idle
            hasActiveProvisionalRecording = false
        }
        return .none
    }

    /// Called when cancel is triggered via UI button (not Esc key).
    /// Transitions to cancelWindow so Fn is blocked during the countdown.
    public func cancelledByUI() {
        if state == .persistent || state == .holdToTalk || (state == .waitingForSecondTap && hasActiveProvisionalRecording) {
            state = .cancelWindow
            hasActiveProvisionalRecording = false
        }
    }

    /// Resume recording after undo — sets the state machine to the active recording mode
    /// so Fn key gestures work correctly.
    public func resumeRecording(mode: RecordingMode) {
        switch mode {
        case .persistent:
            state = .persistent
        case .holdToTalk:
            state = .holdToTalk
        }
        hasActiveProvisionalRecording = false
    }

    /// Reset to idle (for testing or error recovery)
    public func reset() {
        state = .idle
        fnDownTimestamp = 0
        firstTapTimestamp = 0
        hasActiveProvisionalRecording = false
    }
}
