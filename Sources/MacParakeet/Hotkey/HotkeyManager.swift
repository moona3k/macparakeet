import Cocoa
import Foundation
import IOKit.hidsystem
import MacParakeetCore

/// Manages system-wide hotkey detection via CGEvent tap.
/// Supports any single key as trigger: modifier keys (Fn, Control, Option, Shift, Command)
/// or regular key codes (F13, End, Home, etc.). See ADR-009.
/// Requires Accessibility permission.
public final class HotkeyManager {
    public var onStartRecording: ((FnKeyStateMachine.RecordingMode) -> Void)?
    public var onStopRecording: (() -> Void)?
    public var onCancelRecording: (() -> Void)?
    public var onDiscardRecording: ((Bool) -> Void)?
    public var onReadyForSecondTap: (() -> Void)?
    public var onEscapeWhileIdle: (() -> Void)?

    private let gestureController: HotkeyGestureController
    private let trigger: HotkeyTrigger
    private let targetMask: CGEventFlags?
    public let tapThresholdMs: Int
    private var eventTap: CFMachPort?
    private var startupTimer: DispatchWorkItem?
    private var holdTimer: DispatchWorkItem?
    private var runLoopSource: CFRunLoopSource?
    /// Retained reference to self passed to the CGEvent tap callback.
    /// Prevents use-after-free if the tap fires during deallocation.
    private var retainedSelf: Unmanaged<HotkeyManager>?
    /// The run loop the source was installed on, so stop() removes from the correct one.
    private var installedRunLoop: CFRunLoop?
    /// Edge detection: was the target modifier pressed in the previous event?
    private var targetModifierWasPressed = false
    /// Previous modifier flags snapshot for deriving side-specific transitions from flagsChanged.
    private var previousModifierFlags: CGEventFlags = []
    /// True when the current modifier press is actively driving the gesture state machine.
    private var targetModifierGestureIsActive = false
    /// Edge detection for keyCode triggers: true while the trigger key is physically held.
    private var triggerKeyIsPressed = false
    /// For chord triggers: true after a required modifier was released while the key was still held.
    /// Prevents double fnUp when the key is subsequently released.
    private var chordModifierReleased = false

    /// Bare-tap filtering: true until a non-Escape key is pressed while modifier is held.
    private var bareTap = true

    /// Mask of the 4 relevant modifier bits (⌃⌥⇧⌘) for chord matching.
    static let relevantModifierBits: UInt64 = HotkeyTrigger.relevantModifierBits

    /// Required modifier flags for `.chord` triggers, precomputed from `trigger.chordEventFlags`.
    private let requiredChordFlags: UInt64
    /// The modifier bits that participate in bare-modifier gesture detection.
    private static let trackedModifierMasks: CGEventFlags = [
        .maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand,
    ]
    /// Device-dependent modifier bits used to distinguish left/right variants.
    private static let sideSpecificModifierMasks: [UInt16: UInt64] = [
        56: UInt64(NX_DEVICELSHIFTKEYMASK),
        60: UInt64(NX_DEVICERSHIFTKEYMASK),
        59: UInt64(NX_DEVICELCTLKEYMASK),
        62: UInt64(NX_DEVICERCTLKEYMASK),
        58: UInt64(NX_DEVICELALTKEYMASK),
        61: UInt64(NX_DEVICERALTKEYMASK),
        55: UInt64(NX_DEVICELCMDKEYMASK),
        54: UInt64(NX_DEVICERCMDKEYMASK),
    ]
    private static let oppositeSideModifierKeyCodes: [UInt16: UInt16] = [
        56: 60,
        60: 56,
        59: 62,
        62: 59,
        58: 61,
        61: 58,
        55: 54,
        54: 55,
    ]

    public init(
        trigger: HotkeyTrigger = .fn,
        tapThresholdMs: Int = FnKeyStateMachine.defaultTapThresholdMs
    ) {
        self.trigger = trigger
        self.gestureController = HotkeyGestureController(tapThresholdMs: tapThresholdMs)
        self.tapThresholdMs = self.gestureController.tapThresholdMs
        self.targetMask = trigger.kind == .modifier ? Self.mask(for: trigger) : nil
        self.requiredChordFlags = trigger.chordEventFlags
    }

    deinit {
        // Inline cleanup — deinit is nonisolated, can't call @MainActor stop().
        // Safe because deinit guarantees exclusive access to self.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
        startupTimer?.cancel()
        holdTimer?.cancel()
    }

    /// Start listening for key events. Requires Accessibility permission.
    public func start() -> Bool {
        // Guard against double-start: stop existing tap to prevent leaking it
        if eventTap != nil { stop() }

        var eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        if trigger.kind == .keyCode || trigger.kind == .chord {
            eventMask |= (1 << CGEventType.keyUp.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
            // tapCreate failed — release the retained reference to avoid a permanent leak.
            // Without this, deinit can never fire (the +1 prevents deallocation).
            retainedSelf?.release()
            retainedSelf = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        syncModifierPressedState()

        return true
    }

    /// Stop listening for key events
    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        // Balance the passRetained from start() to avoid leaking self
        retainedSelf?.release()
        retainedSelf = nil
        startupTimer?.cancel()
        holdTimer?.cancel()
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        targetModifierWasPressed = false
        previousModifierFlags = []
        targetModifierGestureIsActive = false
        triggerKeyIsPressed = false
        chordModifierReleased = false
        bareTap = true
        gestureController.reset()
    }

    // MARK: - Private

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS can disable our tap if the callback is slow or for user-input conditions.
        // Re-enable it to prevent the hotkey from silently dying.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            syncModifierPressedState()
            return Unmanaged.passUnretained(event)
        }

        switch trigger.kind {
        case .modifier:
            return handleModifierEvent(type: type, event: event)
        case .keyCode:
            return handleKeyCodeEvent(type: type, event: event)
        case .chord:
            return handleChordEvent(type: type, event: event)
        }
    }

    // MARK: - Modifier Trigger Path (existing behavior)

    private func handleModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let timestampMs = UInt64(event.timestamp / 1_000_000)

        if type == .flagsChanged {
            let flags = event.flags
            handleOutputs(
                modifierFlagsChangedOutputs(
                    flags: flags,
                    timestampMs: timestampMs
                )
            )
            previousModifierFlags = flags
        } else if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleOutputs(
                modifierKeyDownOutputs(
                    keyCode: keyCode,
                    timestampMs: timestampMs
                )
            )
        }

        return Unmanaged.passUnretained(event)
    }

    private func modifierFlagsChangedOutputs(
        flags: CGEventFlags,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        if let targetKeyCode = trigger.modifierKeyCode {
            // ── Side-specific detection (e.g. right-option only) ──
            let isPressed = Self.sideSpecificModifierIsPressed(flags: flags, keyCode: targetKeyCode)
            let wasPressed = targetModifierWasPressed
            targetModifierWasPressed = isPressed

            if isPressed != wasPressed {
                if isPressed {
                    guard !Self.oppositeSideModifierIsPressed(flags: flags, keyCode: targetKeyCode) else {
                        return []
                    }

                    targetModifierGestureIsActive = true
                    bareTap = true
                    return gestureController.triggerPressed(timestampMs: timestampMs)
                }

                guard targetModifierGestureIsActive else { return [] }
                targetModifierGestureIsActive = false

                let outputs: [HotkeyGestureController.Output]
                if bareTap {
                    outputs = gestureController.triggerReleased(timestampMs: timestampMs)
                } else {
                    outputs = gestureController.nonBareTriggerReleased()
                }
                bareTap = true
                return outputs
            }

            // Derive tracked modifier changes from the previous/current flags instead of
            // relying on kCGKeyboardEventKeycode, which is undefined for flagsChanged.
            let changedTrackedModifiers = Self.changedTrackedModifierKeyCodes(
                from: previousModifierFlags,
                to: flags
            ).subtracting([targetKeyCode])
            if targetModifierGestureIsActive, !changedTrackedModifiers.isEmpty {
                bareTap = false
                return gestureController.interrupted()
            }
            return []
        }

        guard let mask = targetMask else { return [] }

        // ── Generic detection (either side) ──
        let isPressed = flags.contains(mask)
        if isPressed != targetModifierWasPressed {
            targetModifierWasPressed = isPressed

            if isPressed {
                targetModifierGestureIsActive = true
                // Modifier down — start bare-tap tracking
                bareTap = true
                return gestureController.triggerPressed(timestampMs: timestampMs)
            }

            targetModifierGestureIsActive = false
            let outputs: [HotkeyGestureController.Output]
            if bareTap {
                outputs = gestureController.triggerReleased(timestampMs: timestampMs)
            } else {
                outputs = gestureController.nonBareTriggerReleased()
            }
            bareTap = true
            return outputs
        }

        // Additional modifier changes while the trigger is still held invalidate the
        // "bare modifier" assumption just like a regular keyDown would.
        guard targetModifierGestureIsActive else { return [] }
        let activeTrackedModifiers = flags.intersection(Self.trackedModifierMasks)
        let nonTargetTrackedModifiers = activeTrackedModifiers.subtracting(mask)
        guard !nonTargetTrackedModifiers.isEmpty else { return [] }

        bareTap = false
        return gestureController.interrupted()
    }

    private func modifierKeyDownOutputs(
        keyCode: Int64,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        if keyCode == 53 { // Escape
            return gestureController.escapePressed()
        } else if keyCode != 63 && keyCode != 179 {
            // Skip Fn/Globe key (63/179) — macOS generates a synthetic keyDown
            // with keyCode 179 when Fn is released (for "Change Input Source" or
            // "Show Emoji & Symbols"). Without this guard, that keyDown resets
            // the state machine between the first and second tap of a double-tap.
            // Non-Escape key pressed — invalidate bare-tap if modifier is held
            if targetModifierGestureIsActive {
                bareTap = false
            }

            // Gesture interruption: if waiting for second tap, a regular key press
            // means the user is typing, not double-tapping the hotkey
            return gestureController.interrupted()
        }
        return []
    }

    // Test seam: lets unit tests exercise the real modifier-path state logic
    // without constructing CGEvents or arming timers.
    func modifierFlagsChangedOutputsForTesting(
        flags: CGEventFlags,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let outputs = modifierFlagsChangedOutputs(flags: flags, timestampMs: timestampMs)
        previousModifierFlags = flags
        return outputs
    }

    func modifierKeyDownOutputsForTesting(
        keyCode: Int64,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        modifierKeyDownOutputs(keyCode: keyCode, timestampMs: timestampMs)
    }

    func startupDebounceElapsedForTesting() -> [HotkeyGestureController.Output] {
        gestureController.startupDebounceElapsed()
    }

    func holdWindowElapsedForTesting() -> [HotkeyGestureController.Output] {
        gestureController.holdWindowElapsed()
    }

    func syncModifierPressedStateForTesting(flags: CGEventFlags) {
        syncModifierPressedState(flags: flags)
    }

    // MARK: - KeyCode Trigger Path

    private func handleKeyCodeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let timestampMs = UInt64(event.timestamp / 1_000_000)
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            if keyCode == triggerCode {
                // Edge detection: ignore key-repeat (macOS sends repeated keyDown for held keys)
                guard !triggerKeyIsPressed else {
                    return nil // Swallow repeated keyDown
                }
                triggerKeyIsPressed = true

                handleOutputs(gestureController.triggerPressed(timestampMs: timestampMs))

                return nil // Swallow the trigger key event
            } else if keyCode == 53 { // Escape
                handleOutputs(gestureController.escapePressed())
            } else {
                // Gesture interruption: if waiting for second tap, a regular key press
                // means the user is typing, not double-tapping the hotkey
                handleOutputs(gestureController.interrupted())
            }
        } else if type == .keyUp {
            if keyCode == triggerCode {
                guard triggerKeyIsPressed else {
                    return nil // Swallow stale keyUp
                }
                triggerKeyIsPressed = false
                handleOutputs(gestureController.triggerReleased(timestampMs: timestampMs))

                return nil // Swallow the trigger key event
            }
        }
        // flagsChanged events are ignored for keyCode triggers

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Chord Trigger Path

    private func handleChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let timestampMs = UInt64(event.timestamp / 1_000_000)
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            if keyCode == triggerCode {
                // Check required modifiers are held
                let flags = event.flags.rawValue & Self.relevantModifierBits
                guard flags & requiredChordFlags == requiredChordFlags else {
                    return Unmanaged.passUnretained(event)
                }

                // Edge detection: ignore key-repeat
                guard !triggerKeyIsPressed else {
                    return nil // Swallow repeated keyDown
                }
                triggerKeyIsPressed = true
                chordModifierReleased = false

                handleOutputs(gestureController.triggerPressed(timestampMs: timestampMs))

                return nil // Swallow the trigger key
            } else if keyCode == 53 { // Escape
                handleOutputs(gestureController.escapePressed())
            } else {
                // Gesture interruption
                handleOutputs(gestureController.interrupted())
            }
        } else if type == .keyUp {
            if keyCode == triggerCode {
                if triggerKeyIsPressed {
                    triggerKeyIsPressed = false
                    if !chordModifierReleased {
                        // Normal key release — end dictation
                        handleOutputs(gestureController.triggerReleased(timestampMs: timestampMs))
                    }
                    chordModifierReleased = false
                }
                // Always swallow the trigger key's keyUp
                return nil
            }
        } else if type == .flagsChanged {
            // Release-any-part: if a required modifier is released while trigger key is held,
            // end dictation and mark that we already sent fnUp.
            if triggerKeyIsPressed && !chordModifierReleased {
                let flags = event.flags.rawValue & Self.relevantModifierBits
                if flags & requiredChordFlags != requiredChordFlags {
                    chordModifierReleased = true
                    handleOutputs(gestureController.triggerReleased(timestampMs: timestampMs))
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Notify state machine that cancel was triggered via UI (not Esc).
    /// Blocks hotkey during the cancel countdown window.
    public func notifyCancelledByUI() {
        gestureController.notifyCancelledByUI()
    }

    /// Resume recording mode after undo, so hotkey stops the recording correctly.
    public func resumeRecording(mode: FnKeyStateMachine.RecordingMode) {
        gestureController.resumeRecording(mode: mode)
    }

    /// Reset state machine to idle (e.g., after cancel countdown expires).
    public func resetToIdle(flags: CGEventFlags? = nil) {
        cancelStartupTimer()
        cancelHoldTimer()
        triggerKeyIsPressed = false
        chordModifierReleased = false
        targetModifierGestureIsActive = false
        bareTap = true
        gestureController.reset()
        syncModifierPressedState(flags: flags)
    }

    private func syncModifierPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifier else { return }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        if let targetKeyCode = trigger.modifierKeyCode {
            targetModifierWasPressed = Self.sideSpecificModifierIsPressed(flags: currentFlags, keyCode: targetKeyCode)
        } else if let mask = targetMask {
            targetModifierWasPressed = currentFlags.contains(mask)
        } else {
            targetModifierWasPressed = false
        }
        previousModifierFlags = currentFlags

        if !targetModifierWasPressed {
            targetModifierGestureIsActive = false
            bareTap = true
        }
    }

    private static func changedTrackedModifierKeyCodes(
        from previousFlags: CGEventFlags,
        to currentFlags: CGEventFlags
    ) -> Set<UInt16> {
        var changed: Set<UInt16> = []

        for keyCode in sideSpecificModifierMasks.keys {
            let wasPressed = sideSpecificModifierIsPressed(flags: previousFlags, keyCode: keyCode)
            let isPressed = sideSpecificModifierIsPressed(flags: currentFlags, keyCode: keyCode)
            if wasPressed != isPressed {
                changed.insert(keyCode)
            }
        }

        if previousFlags.contains(.maskSecondaryFn) != currentFlags.contains(.maskSecondaryFn) {
            changed.insert(63)
        }

        return changed
    }

    private static func sideSpecificModifierIsPressed(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        guard let mask = sideSpecificModifierMasks[keyCode] else { return false }
        return (flags.rawValue & mask) != 0
    }

    private static func oppositeSideModifierIsPressed(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        guard let oppositeKeyCode = oppositeSideModifierKeyCodes[keyCode] else { return false }
        return sideSpecificModifierIsPressed(flags: flags, keyCode: oppositeKeyCode)
    }

    private func handleOutputs(_ outputs: [HotkeyGestureController.Output]) {
        for output in outputs {
            switch output {
            case .startRecording(let mode):
                onStartRecording?(mode)
            case .stopRecording:
                onStopRecording?()
            case .cancelRecording:
                onCancelRecording?()
            case .discardRecording(let showReadyPill):
                onDiscardRecording?(showReadyPill)
            case .showReadyForSecondTap:
                onReadyForSecondTap?()
            case .escapeWhileIdle:
                onEscapeWhileIdle?()
            case .scheduleStartupDebounce(let milliseconds):
                scheduleStartupTimer(after: milliseconds)
            case .scheduleHoldWindow(let milliseconds):
                scheduleHoldTimer(after: milliseconds)
            case .cancelStartupDebounce:
                cancelStartupTimer()
            case .cancelHoldWindow:
                cancelHoldTimer()
            }
        }
    }

    private func scheduleStartupTimer(after milliseconds: Int) {
        startupTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            let outputs = self?.gestureController.startupDebounceElapsed() ?? []
            self?.handleOutputs(outputs)
        }
        startupTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: timer
        )
    }

    private func scheduleHoldTimer(after milliseconds: Int) {
        holdTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            let outputs = self?.gestureController.holdWindowElapsed() ?? []
            self?.handleOutputs(outputs)
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: timer
        )
    }

    private func cancelStartupTimer() {
        startupTimer?.cancel()
        startupTimer = nil
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    // MARK: - Key Mapping

    private static func mask(for trigger: HotkeyTrigger) -> CGEventFlags? {
        guard trigger.kind == .modifier, let name = trigger.modifierName else { return nil }
        switch name {
        case "fn": return .maskSecondaryFn
        case "control": return .maskControl
        case "option": return .maskAlternate
        case "shift": return .maskShift
        case "command": return .maskCommand
        default: return nil
        }
    }
}
