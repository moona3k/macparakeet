import Cocoa
import Foundation
import MacParakeetCore

/// Manages system-wide Fn key detection via CGEvent tap.
/// Requires Accessibility permission.
public final class HotkeyManager {
    public var onStartRecording: ((FnKeyStateMachine.RecordingMode) -> Void)?
    public var onStopRecording: (() -> Void)?
    public var onCancelRecording: (() -> Void)?

    private let stateMachine = FnKeyStateMachine()
    private var eventTap: CFMachPort?
    private var holdTimer: DispatchWorkItem?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    /// Start listening for Fn key events. Requires Accessibility permission.
    public func start() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return true
    }

    /// Stop listening for key events
    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        holdTimer?.cancel()
        eventTap = nil
        runLoopSource = nil
        stateMachine.reset()
    }

    // MARK: - Private

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let timestampMs = UInt64(event.timestamp / 1_000_000)

        if type == .flagsChanged {
            let flags = event.flags
            let fnPressed = flags.contains(.maskSecondaryFn)

            if fnPressed {
                let action = stateMachine.fnDown(timestampMs: timestampMs)
                handleAction(action)

                // Schedule hold timer
                holdTimer?.cancel()
                let timer = DispatchWorkItem { [weak self] in
                    let action = self?.stateMachine.holdTimerFired() ?? .none
                    self?.handleAction(action)
                }
                holdTimer = timer
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(FnKeyStateMachine.tapThresholdMs),
                    execute: timer
                )
            } else {
                holdTimer?.cancel()
                let action = stateMachine.fnUp(timestampMs: timestampMs)
                handleAction(action)
            }
        } else if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 { // Escape
                let action = stateMachine.escapePressed()
                handleAction(action)
            }
        }

        return Unmanaged.passRetained(event)
    }

    /// Notify state machine that cancel was triggered via UI (not Esc).
    /// Blocks Fn during the cancel countdown window.
    public func notifyCancelledByUI() {
        stateMachine.cancelledByUI()
    }

    /// Resume recording mode after undo, so Fn stops the recording correctly.
    public func resumeRecording(mode: FnKeyStateMachine.RecordingMode) {
        stateMachine.resumeRecording(mode: mode)
    }

    /// Reset state machine to idle (e.g., after cancel countdown expires).
    public func resetToIdle() {
        stateMachine.reset()
    }

    private func handleAction(_ action: FnKeyStateMachine.Action) {
        switch action {
        case .none:
            break
        case .startRecording(let mode):
            onStartRecording?(mode)
        case .stopRecording:
            onStopRecording?()
        case .cancelRecording:
            onCancelRecording?()
        }
    }
}
