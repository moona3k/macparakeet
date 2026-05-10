import Cocoa
import CoreGraphics
import Foundation
import MacParakeetCore
import OSLog

/// Manages system-wide hotkey detection via CGEvent tap.
/// Supports any single key as trigger: modifier keys (Fn, Control, Option, Shift, Command)
/// or regular key codes (F13, End, Home, etc.). See ADR-009.
/// Requires Accessibility permission.
public final class HotkeyManager {
    private static let logger = Logger(subsystem: "com.macparakeet.app", category: "HotkeyManager")

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
    private var modifierChordRequiredWasPressed = false
    private var modifierChordGestureIsActive = false
    private var modifierChordBlockedUntilRelease = false
    private var activeRecordingMode: FnKeyStateMachine.RecordingMode?

    /// Bare-tap filtering: true until a non-Escape key is pressed while modifier is held.
    private var bareTap = true

    /// Mask of the 4 relevant modifier bits (⌃⌥⇧⌘) for chord matching.
    static let relevantModifierBits: UInt64 = HotkeyTrigger.relevantModifierBits

    /// Required modifier flags for `.chord` triggers, precomputed from `trigger.chordEventFlags`.
    private let requiredChordFlags: UInt64

    public init(
        trigger: HotkeyTrigger = .fn,
        tapThresholdMs: Int = FnKeyStateMachine.defaultTapThresholdMs
    ) {
        self.trigger = trigger
        self.gestureController = HotkeyGestureController(tapThresholdMs: tapThresholdMs)
        self.tapThresholdMs = self.gestureController.tapThresholdMs
        self.targetMask = trigger.kind == .modifier ? ModifierKeyMatcher.mask(for: trigger.modifierName) : nil
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
            // Log the trust state so logs distinguish "permission not granted"
            // from a generic system error. AXIsProcessTrusted is read-only and
            // doesn't trigger a permission prompt (we pass `nil` options).
            let isTrusted = AXIsProcessTrusted()
            Self.logger.error(
                "hotkey_tap_create_failed accessibility_trusted=\(isTrusted, privacy: .public)"
            )
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        recoverFromDisabledTap()

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
        modifierChordRequiredWasPressed = false
        modifierChordGestureIsActive = false
        modifierChordBlockedUntilRelease = false
        activeRecordingMode = nil
        bareTap = true
        gestureController.reset()
    }

    // MARK: - Private

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS can disable our tap if the callback is slow or for user-input conditions.
        // Re-enable it to prevent the hotkey from silently dying.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            recoverFromDisabledTap()
            return Unmanaged.passUnretained(event)
        }

        switch trigger.kind {
        case .disabled:
            return Unmanaged.passUnretained(event)
        case .modifier:
            return handleModifierEvent(type: type, event: event)
        case .keyCode:
            return handleKeyCodeEvent(type: type, event: event)
        case .chord:
            return handleChordEvent(type: type, event: event)
        case .modifierChord:
            return handleModifierChordEvent(type: type, event: event)
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
            let isPressed = ModifierKeyMatcher.sideSpecificModifierIsPressed(flags: flags, keyCode: targetKeyCode)
            let wasPressed = targetModifierWasPressed
            targetModifierWasPressed = isPressed

            if isPressed != wasPressed {
                if isPressed {
                    guard !ModifierKeyMatcher.oppositeSideModifierIsPressed(flags: flags, keyCode: targetKeyCode) else {
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
            if let oppositeKeyCode = HotkeyTrigger.oppositeModifierKeyCode(for: targetKeyCode),
               changedTrackedModifiers.contains(oppositeKeyCode),
               ModifierKeyMatcher.sideSpecificModifierIsPressed(flags: flags, keyCode: oppositeKeyCode) {
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

        // Additional modifier changes while the trigger is still held invalidate the
        // "bare modifier" assumption just like a regular keyDown would.
        guard targetModifierGestureIsActive else { return [] }
        let activeTrackedModifiers = flags.intersection(ModifierKeyMatcher.trackedModifierMasks)
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
        } else if !HotkeyTrigger.isFnKeyCode(UInt16(keyCode)) {
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
        rememberRecordingState(for: outputs)
        previousModifierFlags = flags
        return outputs
    }

    func modifierKeyDownOutputsForTesting(
        keyCode: Int64,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let outputs = modifierKeyDownOutputs(keyCode: keyCode, timestampMs: timestampMs)
        rememberRecordingState(for: outputs)
        return outputs
    }

    func startupDebounceElapsedForTesting() -> [HotkeyGestureController.Output] {
        let outputs = gestureController.startupDebounceElapsed()
        rememberRecordingState(for: outputs)
        return outputs
    }

    func holdWindowElapsedForTesting() -> [HotkeyGestureController.Output] {
        let outputs = gestureController.holdWindowElapsed()
        rememberRecordingState(for: outputs)
        return outputs
    }

    func syncModifierPressedStateForTesting(flags: CGEventFlags) {
        syncModifierPressedState(flags: flags)
    }

    @discardableResult
    func recoverFromDisabledTapForTesting(
        flags: CGEventFlags? = nil,
        triggerKeyPressed: Bool = false,
        timestampMs: UInt64 = HotkeyManager.currentTimestampMs()
    ) -> [HotkeyGestureController.Output] {
        recoverFromDisabledTap(
            flags: flags,
            triggerKeyPressed: triggerKeyPressed,
            timestampMs: timestampMs
        )
    }

    func chordTriggerKeyUpOutputsForTesting(
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let outputs = chordTriggerKeyUpOutputs(timestampMs: timestampMs)
        rememberRecordingState(for: outputs)
        return outputs
    }

    func chordEventDecisionForTesting(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64,
        timestampMs: UInt64
    ) -> (outputs: [HotkeyGestureController.Output], shouldSwallow: Bool) {
        let decision = chordEventDecision(
            type: type,
            keyCode: keyCode,
            flags: flags & Self.relevantModifierBits,
            timestampMs: timestampMs
        )
        rememberRecordingState(for: decision.outputs)
        return decision
    }

    func modifierChordFlagsChangedOutputsForTesting(
        flags: CGEventFlags,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let outputs = modifierChordFlagsChangedOutputs(flags: flags, timestampMs: timestampMs)
        rememberRecordingState(for: outputs)
        return outputs
    }

    func modifierChordKeyDownOutputsForTesting(
        keyCode: Int64,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let outputs = modifierChordKeyDownOutputs(keyCode: keyCode, timestampMs: timestampMs)
        rememberRecordingState(for: outputs)
        return outputs
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
        let timestampMs = UInt64(event.timestamp / 1_000_000)
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let decision = chordEventDecision(
            type: type,
            keyCode: keyCode,
            flags: event.flags.rawValue & Self.relevantModifierBits,
            timestampMs: timestampMs
        )
        handleOutputs(decision.outputs)

        return decision.shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    private func chordEventDecision(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64,
        timestampMs: UInt64
    ) -> (outputs: [HotkeyGestureController.Output], shouldSwallow: Bool) {
        guard let triggerCode = trigger.keyCode else {
            return ([], false)
        }

        if type == .keyDown {
            if keyCode == triggerCode {
                // Check required modifiers are held
                guard flags & requiredChordFlags == requiredChordFlags else {
                    return (gestureController.interrupted(), false)
                }

                // Edge detection: ignore key-repeat
                guard !triggerKeyIsPressed else {
                    return ([], true) // Swallow repeated keyDown
                }
                triggerKeyIsPressed = true
                chordModifierReleased = false

                return (gestureController.triggerPressed(timestampMs: timestampMs), true)
            } else if keyCode == 53 { // Escape
                return (gestureController.escapePressed(), false)
            } else {
                // Gesture interruption
                return (gestureController.interrupted(), false)
            }
        } else if type == .keyUp {
            if keyCode == triggerCode {
                guard triggerKeyIsPressed else {
                    return ([], false)
                }
                let outputs = chordTriggerKeyUpOutputs(timestampMs: timestampMs)
                return (outputs, true)
            }
        } else if type == .flagsChanged {
            // Release-any-part: if a required modifier is released while trigger key is held,
            // end dictation and mark that we already sent fnUp.
            if triggerKeyIsPressed && !chordModifierReleased {
                if flags & requiredChordFlags != requiredChordFlags {
                    chordModifierReleased = true
                    return (gestureController.triggerReleased(timestampMs: timestampMs), false)
                }
            }
        }

        return ([], false)
    }

    // MARK: - Modifier-Only Chord Trigger Path

    private func handleModifierChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let timestampMs = UInt64(event.timestamp / 1_000_000)

        if type == .flagsChanged {
            handleOutputs(
                modifierChordFlagsChangedOutputs(
                    flags: event.flags,
                    timestampMs: timestampMs
                )
            )
        } else if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleOutputs(
                modifierChordKeyDownOutputs(
                    keyCode: keyCode,
                    timestampMs: timestampMs
                )
            )
        }

        return Unmanaged.passUnretained(event)
    }

    private func modifierChordFlagsChangedOutputs(
        flags: CGEventFlags,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let requiredPressed = ModifierKeyMatcher.modifierChordRequiredComponentsArePressed(
            trigger: trigger,
            flags: flags
        )
        let exactPressed = ModifierKeyMatcher.modifierChordMatches(trigger: trigger, flags: flags)
        let wasRequiredPressed = modifierChordRequiredWasPressed
        modifierChordRequiredWasPressed = requiredPressed

        guard requiredPressed else {
            modifierChordBlockedUntilRelease = false
            guard modifierChordGestureIsActive else {
                bareTap = true
                return []
            }
            modifierChordGestureIsActive = false

            let outputs: [HotkeyGestureController.Output]
            if bareTap {
                outputs = gestureController.triggerReleased(timestampMs: timestampMs)
            } else {
                outputs = gestureController.nonBareTriggerReleased()
            }
            bareTap = true
            return outputs
        }

        if !wasRequiredPressed {
            bareTap = true
            modifierChordBlockedUntilRelease = !exactPressed
        }

        if modifierChordGestureIsActive, !exactPressed {
            modifierChordBlockedUntilRelease = true
            guard bareTap else { return [] }
            bareTap = false
            return gestureController.interrupted()
        }

        if exactPressed, !modifierChordGestureIsActive {
            guard !modifierChordBlockedUntilRelease else { return [] }
            modifierChordGestureIsActive = true
            bareTap = true
            return gestureController.triggerPressed(timestampMs: timestampMs)
        }

        return []
    }

    private func modifierChordKeyDownOutputs(
        keyCode: Int64,
        timestampMs _: UInt64
    ) -> [HotkeyGestureController.Output] {
        if keyCode == 53 {
            return gestureController.escapePressed()
        } else if !HotkeyTrigger.isFnKeyCode(UInt16(keyCode)) {
            if modifierChordGestureIsActive {
                bareTap = false
            }
            return gestureController.interrupted()
        }
        return []
    }

    /// Notify state machine that cancel was triggered via UI (not Esc).
    /// Blocks hotkey during the cancel countdown window.
    public func notifyCancelledByUI() {
        gestureController.notifyCancelledByUI()
        activeRecordingMode = nil
    }

    /// Resume recording mode after undo, so hotkey stops the recording correctly.
    public func resumeRecording(mode: FnKeyStateMachine.RecordingMode) {
        gestureController.resumeRecording(mode: mode)
        activeRecordingMode = mode
    }

    /// Reset state machine to idle (e.g., after cancel countdown expires).
    public func resetToIdle(flags: CGEventFlags? = nil) {
        resetGestureState(flags: flags, triggerKeyPressed: false)
    }

    @discardableResult
    private func recoverFromDisabledTap(
        flags: CGEventFlags? = nil,
        timestampMs: UInt64 = HotkeyManager.currentTimestampMs()
    ) -> [HotkeyGestureController.Output] {
        recoverFromDisabledTap(
            flags: flags,
            triggerKeyPressed: currentPhysicalTriggerKeyIsPressed(),
            timestampMs: timestampMs
        )
    }

    @discardableResult
    private func recoverFromDisabledTap(
        flags: CGEventFlags? = nil,
        triggerKeyPressed: Bool,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let triggerPressed = currentPhysicalTriggerIsPressed(
            flags: flags,
            triggerKeyPressed: triggerKeyPressed
        )

        switch activeRecordingMode {
        case .holdToTalk:
            cancelStartupTimer()
            cancelHoldTimer()
            syncRecoveredTriggerState(
                flags: flags,
                triggerKeyPressed: triggerKeyPressed,
                triggerPressed: triggerPressed
            )
            guard !triggerPressed else { return [] }

            let outputs = gestureController.triggerReleased(timestampMs: timestampMs)
            handleOutputs(outputs)
            return outputs

        case .persistent:
            cancelStartupTimer()
            cancelHoldTimer()
            syncRecoveredTriggerState(
                flags: flags,
                triggerKeyPressed: triggerKeyPressed,
                triggerPressed: triggerPressed
            )
            return []

        case nil:
            resetGestureState(flags: flags, triggerKeyPressed: triggerKeyPressed)
            return []
        }
    }

    private func resetGestureState(flags: CGEventFlags? = nil, triggerKeyPressed: Bool) {
        cancelStartupTimer()
        cancelHoldTimer()
        triggerKeyIsPressed = triggerKeyPressed
        chordModifierReleased = false
        targetModifierGestureIsActive = false
        modifierChordGestureIsActive = false
        modifierChordRequiredWasPressed = false
        modifierChordBlockedUntilRelease = false
        activeRecordingMode = nil
        bareTap = true
        gestureController.reset()
        syncModifierPressedState(flags: flags)
        syncModifierChordPressedState(flags: flags)
    }

    private static func currentTimestampMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func currentPhysicalTriggerIsPressed(
        flags: CGEventFlags? = nil,
        triggerKeyPressed: Bool
    ) -> Bool {
        switch trigger.kind {
        case .modifier:
            let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
            if let targetKeyCode = trigger.modifierKeyCode {
                return ModifierKeyMatcher.sideSpecificModifierIsPressed(
                    flags: currentFlags,
                    keyCode: targetKeyCode
                )
            }
            return ModifierKeyMatcher.modifierIsPressed(trigger: trigger, flags: currentFlags)
        case .keyCode:
            return triggerKeyPressed
        case .chord:
            guard triggerKeyPressed else { return false }
            let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
            return currentFlags.rawValue & requiredChordFlags == requiredChordFlags
        case .modifierChord:
            let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
            return ModifierKeyMatcher.modifierChordRequiredComponentsArePressed(
                trigger: trigger,
                flags: currentFlags
            )
        case .disabled:
            return false
        }
    }

    private func syncRecoveredTriggerState(
        flags: CGEventFlags? = nil,
        triggerKeyPressed: Bool,
        triggerPressed: Bool
    ) {
        triggerKeyIsPressed = triggerKeyPressed
        syncModifierPressedState(flags: flags)
        syncModifierChordPressedState(flags: flags)

        switch trigger.kind {
        case .modifier:
            targetModifierGestureIsActive = triggerPressed
            if triggerPressed, recoveredTriggerIsContaminated(flags: flags) {
                bareTap = false
            }
            if !triggerPressed {
                bareTap = true
            }
        case .chord:
            if triggerPressed {
                chordModifierReleased = false
            } else if triggerKeyPressed {
                chordModifierReleased = true
            }
        case .modifierChord:
            modifierChordGestureIsActive = triggerPressed
            modifierChordBlockedUntilRelease = !triggerPressed && modifierChordRequiredWasPressed
            if triggerPressed, recoveredTriggerIsContaminated(flags: flags) {
                bareTap = false
            }
            if !triggerPressed {
                bareTap = true
            }
        default:
            break
        }
    }

    private func recoveredTriggerIsContaminated(flags: CGEventFlags? = nil) -> Bool {
        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)

        switch trigger.kind {
        case .modifier:
            guard let mask = targetMask else { return false }
            let activeTrackedModifiers = currentFlags.intersection(ModifierKeyMatcher.trackedModifierMasks)
            if !activeTrackedModifiers.subtracting(mask).isEmpty {
                return true
            }
            if let targetKeyCode = trigger.modifierKeyCode {
                return ModifierKeyMatcher.oppositeSideModifierIsPressed(
                    flags: currentFlags,
                    keyCode: targetKeyCode
                )
            }
            return false
        case .modifierChord:
            return !ModifierKeyMatcher.modifierChordMatches(trigger: trigger, flags: currentFlags)
        default:
            return false
        }
    }

    private func chordTriggerKeyUpOutputs(
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        guard triggerKeyIsPressed else { return [] }

        triggerKeyIsPressed = false
        let outputs = chordModifierReleased ? [] : gestureController.triggerReleased(timestampMs: timestampMs)
        chordModifierReleased = false
        return outputs
    }

    private func currentPhysicalTriggerKeyIsPressed() -> Bool {
        guard trigger.kind == .keyCode || trigger.kind == .chord,
              let keyCode = trigger.keyCode else {
            return false
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func syncModifierPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifier else { return }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        if let targetKeyCode = trigger.modifierKeyCode {
            targetModifierWasPressed = ModifierKeyMatcher.sideSpecificModifierIsPressed(
                flags: currentFlags,
                keyCode: targetKeyCode
            )
        } else {
            targetModifierWasPressed = ModifierKeyMatcher.modifierIsPressed(trigger: trigger, flags: currentFlags)
        }
        previousModifierFlags = currentFlags

        if !targetModifierWasPressed {
            targetModifierGestureIsActive = false
            bareTap = true
        }
    }

    private func syncModifierChordPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifierChord else { return }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        modifierChordRequiredWasPressed = ModifierKeyMatcher.modifierChordRequiredComponentsArePressed(
            trigger: trigger,
            flags: currentFlags
        )
        let exactPressed = ModifierKeyMatcher.modifierChordMatches(trigger: trigger, flags: currentFlags)
        modifierChordBlockedUntilRelease = modifierChordRequiredWasPressed && !exactPressed

        if !modifierChordRequiredWasPressed {
            modifierChordGestureIsActive = false
            bareTap = true
        }
    }

    private static func changedTrackedModifierKeyCodes(
        from previousFlags: CGEventFlags,
        to currentFlags: CGEventFlags
    ) -> Set<UInt16> {
        ModifierKeyMatcher.changedTrackedModifierKeyCodes(from: previousFlags, to: currentFlags)
    }

    private func handleOutputs(_ outputs: [HotkeyGestureController.Output]) {
        rememberRecordingState(for: outputs)

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

    private func rememberRecordingState(for outputs: [HotkeyGestureController.Output]) {
        for output in outputs {
            switch output {
            case .startRecording(let mode):
                activeRecordingMode = mode
            case .stopRecording, .cancelRecording, .discardRecording:
                activeRecordingMode = nil
            default:
                break
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
}
