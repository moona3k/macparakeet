import Foundation

/// Pure controller for hotkey gesture flow.
/// Owns gesture semantics and timer directives, but no OS event-tap wiring.
public final class HotkeyGestureController {
    public enum Mode: Equatable, Sendable {
        case doubleTapAndHold
        case doubleTapOnly
        case holdOnly
    }

    public enum Output: Equatable, Sendable {
        case startRecording(mode: FnKeyStateMachine.RecordingMode)
        case stopRecording
        case cancelRecording
        case discardRecording(showReadyPill: Bool)
        case showReadyForSecondTap
        case escapeWhileIdle
        case scheduleStartupDebounce(milliseconds: Int)
        case scheduleHoldWindow(milliseconds: Int)
        case cancelStartupDebounce
        case cancelHoldWindow
    }

    public let tapThresholdMs: Int
    public let startupDebounceMs: Int

    private enum HoldOnlyState: Equatable {
        case idle
        case pressed
        case active
        case cancelWindow
        case blocked
    }

    private let mode: Mode
    private let stateMachine: FnKeyStateMachine
    private var holdOnlyState: HoldOnlyState = .idle
    private var suppressedUntilReset = false

    public init(
        mode: Mode = .doubleTapAndHold,
        tapThresholdMs: Int = FnKeyStateMachine.defaultTapThresholdMs,
        startupDebounceMs: Int = FnKeyStateMachine.defaultStartupDebounceMs
    ) {
        let clampedTapThreshold = FnKeyStateMachine.clampTapThresholdMs(tapThresholdMs)
        self.mode = mode
        self.tapThresholdMs = clampedTapThreshold
        self.startupDebounceMs = min(clampedTapThreshold, max(0, startupDebounceMs))
        self.stateMachine = FnKeyStateMachine(tapThresholdMs: clampedTapThreshold)
    }

    public func triggerPressed(timestampMs: UInt64) -> [Output] {
        guard !suppressedUntilReset else { return [] }

        if mode == .holdOnly {
            switch holdOnlyState {
            case .idle:
                holdOnlyState = .pressed
                return [.scheduleStartupDebounce(milliseconds: startupDebounceMs)]
            case .cancelWindow, .blocked:
                holdOnlyState = .blocked
                return []
            case .pressed, .active:
                return []
            }
        }

        let action = stateMachine.fnDown(timestampMs: timestampMs)
        var results = outputs(for: action)
        if mode == .doubleTapAndHold, action == .none, stateMachine.state == .waitingForSecondTap {
            results.append(.scheduleStartupDebounce(milliseconds: startupDebounceMs))
            results.append(.scheduleHoldWindow(milliseconds: tapThresholdMs))
        }
        return results
    }

    public func triggerReleased(timestampMs: UInt64) -> [Output] {
        guard !suppressedUntilReset else { return [] }

        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        if mode == .holdOnly {
            switch holdOnlyState {
            case .pressed:
                holdOnlyState = .idle
            case .active:
                holdOnlyState = .idle
                results.append(.stopRecording)
            case .blocked:
                holdOnlyState = .cancelWindow
            case .idle, .cancelWindow:
                break
            }
            return results
        }

        let action = stateMachine.fnUp(timestampMs: timestampMs)
        results.append(contentsOf: outputs(for: action))
        if action == .none, stateMachine.state == .waitingForSecondTap {
            results.append(.showReadyForSecondTap)
        }
        return results
    }

    public func nonBareTriggerReleased() -> [Output] {
        guard !suppressedUntilReset else { return [] }

        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]

        if mode == .holdOnly {
            switch holdOnlyState {
            case .pressed:
                holdOnlyState = .idle
            case .active:
                holdOnlyState = .idle
                results.append(.cancelRecording)
            case .blocked:
                holdOnlyState = .cancelWindow
            case .idle, .cancelWindow:
                break
            }
            return results
        }

        switch stateMachine.state {
        case .holdToTalk:
            // Non-bare releases bypass outputs(for:) so the hotkey returns to idle
            // immediately before we propagate the explicit cancel side effect.
            stateMachine.reset()
            results.append(.cancelRecording)
        case .waitingForSecondTap:
            results.append(contentsOf: outputs(for: stateMachine.interruptWaitingForSecondTap()))
        default:
            break
        }

        return results
    }

    public func interrupted() -> [Output] {
        guard !suppressedUntilReset else { return [] }

        if mode == .holdOnly {
            return nonBareTriggerReleased()
        }

        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        switch stateMachine.state {
        case .waitingForSecondTap:
            results.append(contentsOf: outputs(for: stateMachine.interruptWaitingForSecondTap()))
            return results
        case .holdToTalk:
            stateMachine.reset()
            results.append(.cancelRecording)
            return results
        default:
            return []
        }
    }

    public func escapePressed() -> [Output] {
        guard !suppressedUntilReset else { return [] }

        if mode == .holdOnly {
            var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
            switch holdOnlyState {
            case .pressed:
                holdOnlyState = .idle
            case .active:
                holdOnlyState = .cancelWindow
                results.append(.cancelRecording)
            case .cancelWindow, .blocked:
                holdOnlyState = .idle
                results.append(.cancelRecording)
            case .idle:
                return [.escapeWhileIdle]
            }
            return results
        }

        let wasWaitingForSecondTap = stateMachine.state == .waitingForSecondTap
        let action = stateMachine.escapePressed()

        if action == .none {
            if wasWaitingForSecondTap {
                stateMachine.reset()
                return [.cancelStartupDebounce, .cancelHoldWindow]
            }
            return [.escapeWhileIdle]
        }

        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        results.append(contentsOf: outputs(for: action))
        return results
    }

    public func startupDebounceElapsed() -> [Output] {
        guard !suppressedUntilReset else { return [] }

        if mode == .doubleTapOnly { return [] }
        if mode == .holdOnly {
            guard holdOnlyState == .pressed else { return [] }
            holdOnlyState = .active
            return [.startRecording(mode: .holdToTalk)]
        }
        return outputs(for: stateMachine.startupTimerFired())
    }

    public func holdWindowElapsed() -> [Output] {
        guard !suppressedUntilReset else { return [] }

        if mode == .doubleTapOnly { return [] }
        if mode == .holdOnly { return [] }
        return outputs(for: stateMachine.holdTimerFired())
    }

    public func suppressUntilReset() {
        suppressedUntilReset = true
        holdOnlyState = .idle
        stateMachine.reset()
    }

    public func notifyCancelledByUI() {
        // The dictation flow resets all managers when the cancel window exits.
        // Until then, every dictation trigger stays blocked, even if it did not
        // start the recording that was cancelled.
        suppressedUntilReset = false
        if mode == .holdOnly {
            holdOnlyState = .cancelWindow
            return
        }
        stateMachine.blockUntilReset()
    }

    public func resumeRecording(mode: FnKeyStateMachine.RecordingMode) {
        suppressedUntilReset = false
        if self.mode == .holdOnly {
            holdOnlyState = mode == .holdToTalk ? .active : .idle
            return
        }
        stateMachine.resumeRecording(mode: mode)
    }

    public func reset() {
        suppressedUntilReset = false
        holdOnlyState = .idle
        stateMachine.reset()
    }

    private func outputs(for action: FnKeyStateMachine.Action) -> [Output] {
        switch action {
        case .none:
            return []
        case .startRecording(let mode):
            return [.startRecording(mode: mode)]
        case .stopRecording:
            return [.stopRecording]
        case .cancelRecording:
            return [.cancelRecording]
        case .discardRecording(let showReadyPill):
            return [.discardRecording(showReadyPill: showReadyPill)]
        }
    }
}
