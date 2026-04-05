import Foundation

/// Pure controller for hotkey gesture flow.
/// Owns gesture semantics and timer directives, but no OS event-tap wiring.
public final class HotkeyGestureController {
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

    private let stateMachine: FnKeyStateMachine

    public init(
        tapThresholdMs: Int = FnKeyStateMachine.defaultTapThresholdMs,
        startupDebounceMs: Int = FnKeyStateMachine.defaultStartupDebounceMs
    ) {
        let clampedTapThreshold = FnKeyStateMachine.clampTapThresholdMs(tapThresholdMs)
        self.tapThresholdMs = clampedTapThreshold
        self.startupDebounceMs = min(clampedTapThreshold, max(0, startupDebounceMs))
        self.stateMachine = FnKeyStateMachine(tapThresholdMs: clampedTapThreshold)
    }

    public func triggerPressed(timestampMs: UInt64) -> [Output] {
        let action = stateMachine.fnDown(timestampMs: timestampMs)
        var results = outputs(for: action)
        if action == .none, stateMachine.state == .waitingForSecondTap {
            results.append(.scheduleStartupDebounce(milliseconds: startupDebounceMs))
            results.append(.scheduleHoldWindow(milliseconds: tapThresholdMs))
        }
        return results
    }

    public func triggerReleased(timestampMs: UInt64) -> [Output] {
        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        let action = stateMachine.fnUp(timestampMs: timestampMs)
        results.append(contentsOf: outputs(for: action))
        if action == .none, stateMachine.state == .waitingForSecondTap {
            results.append(.showReadyForSecondTap)
        }
        return results
    }

    public func nonBareTriggerReleased() -> [Output] {
        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]

        switch stateMachine.state {
        case .holdToTalk:
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
        guard stateMachine.state == .waitingForSecondTap else { return [] }
        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        results.append(contentsOf: outputs(for: stateMachine.interruptWaitingForSecondTap()))
        return results
    }

    public func escapePressed() -> [Output] {
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
        outputs(for: stateMachine.startupTimerFired())
    }

    public func holdWindowElapsed() -> [Output] {
        outputs(for: stateMachine.holdTimerFired())
    }

    public func notifyCancelledByUI() {
        stateMachine.cancelledByUI()
    }

    public func resumeRecording(mode: FnKeyStateMachine.RecordingMode) {
        stateMachine.resumeRecording(mode: mode)
    }

    public func reset() {
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
