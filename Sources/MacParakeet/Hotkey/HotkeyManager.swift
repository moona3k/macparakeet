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
    /// Hold-to-talk release with a stop tail: recording continues for the
    /// tail, then `onStopRecording` fires. Lets the UI answer the release now.
    public var onStopPending: (() -> Void)?
    /// A pending stop tail was abandoned before `onStopRecording` fired.
    public var onStopPendingCancelled: (() -> Void)?
    public var onEscapeWhileIdle: (() -> Void)?
    /// When false, a live take ignores Escape so the key reaches other apps.
    /// Pending gestures that have not started a take still clear, and an idle
    /// overlay still dismisses. Read on the main thread while processing a
    /// forwarded Escape; Escape itself is never consumed.
    public var shouldCancelOnEscape: () -> Bool = { true }

    private let gestureController: HotkeyGestureController
    private let trigger: HotkeyTrigger
    private let gestureMode: HotkeyGestureController.Mode
    private let holdToTalkStopTailMs: Int
    private let targetMask: CGEventFlags?
    public let tapThresholdMs: Int
    /// The tap runs on `EventTapThread`. It decides what to consume there and
    /// forwards each event here, to the main thread, for gesture processing
    /// (#1142). All state below is main-thread only.
    private var backgroundTap: BackgroundEventTap?
    /// Bumped on every start and stop so events forwarded by an earlier tap
    /// are dropped instead of driving the current session.
    private var tapGeneration: UInt64 = 0
    /// Mirrors the tap-thread filter for the `…ForTesting` decision seams.
    private var testingTapFilter: HotkeyTapFilter
    private var startupTimer: DispatchWorkItem?
    private var holdTimer: DispatchWorkItem?
    private var stopTailTimer: DispatchWorkItem?
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

    /// Passive ledger for ordinary virtual key codes. The canonical macOS
    /// keyboard range is 0...127; Fn's synthetic 179 is deliberately excluded.
    private static let ordinaryKeyCodeRange: ClosedRange<UInt16> = 0...127
    /// Caps Lock latch is reported as key 57 still down by
    /// `CGEventSource.keyState`. That is not a held key. Transitions are
    /// observed via flagsChanged keyCode 57 + alphaShift delta.
    private static let capsLockKeyCode: UInt16 = 57
    private var pressedNonFnKeyCodes: Set<UInt16> = []
    /// Keys whose most recent event seen by the tap was a keyUp. The
    /// session key-state snapshot can report a key as held forever when some
    /// app posted a keyDown without its keyUp; a physical press cannot clear
    /// that. A release the tap saw overrides the snapshot. Cleared whenever
    /// the tap may have missed events.
    private var releaseObservedKeyCodes: Set<UInt16> = []
    private var physicalKeyStateProvider: (UInt16) -> Bool
    private var physicalFlagsProvider: () -> CGEventFlags = {
        CGEventSource.flagsState(.combinedSessionState)
    }

    /// Bare-tap filtering: true until another physical key or modifier transition is observed.
    private var bareTap = true

    /// Mask of the 4 relevant modifier bits (⌃⌥⇧⌘) for chord matching.
    static let relevantModifierBits: UInt64 = HotkeyTrigger.relevantModifierBits

    /// Required modifier flags for `.chord` triggers, precomputed from `trigger.chordEventFlags`.
    private let requiredChordFlags: UInt64

    public init(
        trigger: HotkeyTrigger = .fn,
        gestureMode: HotkeyGestureController.Mode = .doubleTapAndHold,
        tapThresholdMs: Int = FnKeyStateMachine.defaultTapThresholdMs,
        startupDebounceMs: Int = FnKeyStateMachine.defaultStartupDebounceMs,
        holdToTalkStopTailMs: Int = 0
    ) {
        self.trigger = trigger
        self.gestureMode = gestureMode
        self.holdToTalkStopTailMs = max(0, holdToTalkStopTailMs)
        self.gestureController = HotkeyGestureController(
            mode: gestureMode,
            tapThresholdMs: tapThresholdMs,
            startupDebounceMs: startupDebounceMs
        )
        self.tapThresholdMs = self.gestureController.tapThresholdMs
        self.targetMask = trigger.kind == .modifier ? ModifierKeyMatcher.mask(for: trigger.modifierName) : nil
        self.requiredChordFlags = trigger.chordEventFlags
        self.testingTapFilter = HotkeyTapFilter(trigger: trigger)
        self.physicalKeyStateProvider = { keyCode in
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        }
    }

    /// The built-in bare-Fn gesture is observational only. A listen-only tap
    /// cannot consume or rewrite the physical Fn event (or any cancellation
    /// event observed while Fn is held). Configurable non-Fn triggers retain
    /// their established active-tap behavior.
    static func eventTapOptions(for trigger: HotkeyTrigger) -> CGEventTapOptions {
        trigger == .fn ? .listenOnly : .defaultTap
    }

    static func eventMask(for trigger: HotkeyTrigger) -> CGEventMask {
        var mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        if trigger == .fn || trigger.kind == .keyCode || trigger.kind == .chord {
            mask |= (1 << CGEventType.keyUp.rawValue)
        }
        return mask
    }

    deinit {
        backgroundTap?.stop()
        startupTimer?.cancel()
        holdTimer?.cancel()
        stopTailTimer?.cancel()
    }

    /// Start listening for key events. Requires Accessibility permission.
    public func start() -> Bool {
        // Guard against double-start: stop existing tap to prevent leaking it
        if backgroundTap != nil { stop() }

        tapGeneration &+= 1
        let relay = HotkeyTapRelay(manager: self, generation: tapGeneration, trigger: trigger)
        guard let tap = BackgroundEventTap.start(
            options: Self.eventTapOptions(for: trigger),
            eventsOfInterest: Self.eventMask(for: trigger),
            handler: { type, event in relay.handle(type: type, event: event) }
        ) else {
            // Log the trust state so logs distinguish "permission not granted"
            // from a generic system error. AXIsProcessTrusted is read-only and
            // doesn't trigger a permission prompt (we pass `nil` options).
            let isTrusted = AXIsProcessTrusted()
            Self.logger.error(
                "hotkey_tap_create_failed accessibility_trusted=\(isTrusted, privacy: .public)"
            )
            return false
        }

        backgroundTap = tap
        recoverFromDisabledTap()

        return true
    }

    /// Stop listening for key events
    public func stop() {
        backgroundTap?.stop()
        backgroundTap = nil
        tapGeneration &+= 1
        startupTimer?.cancel()
        holdTimer?.cancel()
        cancelStopTailTimer()
        targetModifierWasPressed = false
        previousModifierFlags = []
        targetModifierGestureIsActive = false
        triggerKeyIsPressed = false
        chordModifierReleased = false
        modifierChordRequiredWasPressed = false
        modifierChordGestureIsActive = false
        modifierChordBlockedUntilRelease = false
        activeRecordingMode = nil
        pressedNonFnKeyCodes.removeAll(keepingCapacity: true)
        releaseObservedKeyCodes.removeAll(keepingCapacity: true)
        bareTap = true
        gestureController.reset()
        testingTapFilter = HotkeyTapFilter(trigger: trigger)
    }

    var runLoopSourceForTesting: CFRunLoopSource? {
        backgroundTap?.runLoopSourceForTesting
    }

    // MARK: - Private

    fileprivate func isCurrentTap(_ generation: UInt64) -> Bool {
        backgroundTap != nil && generation == tapGeneration
    }

    /// Main-thread processing of an event the tap thread already let through
    /// or consumed.
    fileprivate func process(_ tapEvent: HotkeyTapEvent) {
        switch tapEvent {
        case .tapReenabled:
            // macOS disabled the tap (slow callback or secure input) and the
            // tap thread re-enabled it; resync with the physical key state.
            AudioCaptureDiagnostics.append(
                "dictation_hotkey_tap_reenabled mode=\(diagnosticMode(activeRecordingMode))"
            )
            recoverFromDisabledTap()
        case .key(let event):
            process(event)
        }
    }

    private func process(_ event: KeyEventSnapshot) {
        switch trigger.kind {
        case .disabled:
            return
        case .modifier:
            handleModifierEvent(event)
        case .keyCode:
            handleKeyCodeEvent(event)
        case .chord:
            handleChordEvent(event)
        case .modifierChord:
            handleModifierChordEvent(event)
        }
    }

    // MARK: - Modifier Trigger Path (existing behavior)

    private func handleModifierEvent(_ event: KeyEventSnapshot) {
        let type = event.type
        let timestampMs = UInt64(event.timestamp / 1_000_000)

        if type == .flagsChanged {
            let flags = event.flags
            let changedKeyCode = UInt16(event.keyCode)
            handleOutputs(
                modifierFlagsChangedOutputs(
                    flags: flags,
                    timestampMs: timestampMs,
                    changedKeyCode: changedKeyCode
                )
            )
            previousModifierFlags = flags
        } else if type == .keyDown {
            handleOutputs(
                modifierKeyDownOutputs(
                    keyCode: event.keyCode,
                    timestampMs: timestampMs
                )
            )
        } else if type == .keyUp {
            handleOutputs(
                modifierKeyUpOutputs(
                    keyCode: event.keyCode,
                    timestampMs: timestampMs
                )
            )
        }
    }

    private func modifierFlagsChangedOutputs(
        flags: CGEventFlags,
        timestampMs: UInt64,
        changedKeyCode: UInt16? = nil
    ) -> [HotkeyGestureController.Output] {
        if let targetKeyCode = trigger.modifierKeyCode {
            // ── Side-specific detection (e.g. right-option only) ──
            let wasPressed = targetModifierWasPressed
            let isPressed = ModifierKeyMatcher.sideSpecificModifierIsPressed(
                flags: flags,
                keyCode: targetKeyCode,
                changedKeyCode: changedKeyCode,
                previouslyPressed: wasPressed
            )
            targetModifierWasPressed = isPressed

            if isPressed != wasPressed {
                if isPressed {
                    guard !ModifierKeyMatcher.oppositeSideModifierIsPressed(
                        flags: flags,
                        keyCode: targetKeyCode,
                        changedKeyCode: changedKeyCode
                    ) else {
                        return []
                    }

                    targetModifierGestureIsActive = true
                    bareTap = true
                    if gestureMode == .singleTapToggle {
                        return []
                    }
                    return gestureController.triggerPressed(timestampMs: timestampMs)
                }

                guard targetModifierGestureIsActive else {
                    logReleaseIgnoredIfRecording()
                    return []
                }
                targetModifierGestureIsActive = false

                let outputs: [HotkeyGestureController.Output]
                if bareTap {
                    outputs = gestureMode == .singleTapToggle
                        ? gestureController.triggerPressed(timestampMs: timestampMs)
                        : gestureController.triggerReleased(timestampMs: timestampMs)
                } else {
                    outputs = gestureMode == .singleTapToggle ? [] : gestureController.nonBareTriggerReleased()
                }
                bareTap = true
                return outputs
            }

            // Prefer side-specific flag transitions, but include the changed
            // modifier keyCode as a fallback when macOS only reports the
            // generic modifier bit.
            let changedTrackedModifiers = Self.changedTrackedModifierKeyCodes(
                from: previousModifierFlags,
                to: flags,
                changedKeyCode: changedKeyCode
            ).subtracting([targetKeyCode])
            if targetModifierGestureIsActive, !changedTrackedModifiers.isEmpty {
                bareTap = false
                return gestureMode == .singleTapToggle ? [] : gestureController.interrupted()
            }
            // The target gesture is inactive while double-tap mode waits for a
            // second tap. Opposite-side modifier taps still need to cancel
            // that pending tap.
            if let oppositeKeyCode = HotkeyTrigger.oppositeModifierKeyCode(for: targetKeyCode),
               changedTrackedModifiers.contains(oppositeKeyCode),
               ModifierKeyMatcher.sideSpecificModifierIsPressed(
                   flags: flags,
                   keyCode: oppositeKeyCode,
                   changedKeyCode: changedKeyCode,
                   previouslyPressed: false
               ) {
                return gestureMode == .singleTapToggle ? [] : gestureController.interrupted()
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
                if trigger == .fn {
                    reconcilePassiveFnKeyState()
                    if passiveFnInputIsContaminated(flags: flags) {
                        logFnAdmissionRejected(flags: flags)
                        targetModifierGestureIsActive = false
                        bareTap = false
                        return interruptPendingPassiveFnWindow()
                    }
                }
                if gestureMode == .singleTapToggle {
                    return []
                }
                return gestureController.triggerPressed(timestampMs: timestampMs)
            }

            guard targetModifierGestureIsActive else {
                logReleaseIgnoredIfRecording()
                return []
            }
            targetModifierGestureIsActive = false
            let outputs: [HotkeyGestureController.Output]
            if bareTap {
                outputs = gestureMode == .singleTapToggle
                    ? gestureController.triggerPressed(timestampMs: timestampMs)
                    : gestureController.triggerReleased(timestampMs: timestampMs)
            } else {
                outputs = gestureMode == .singleTapToggle ? [] : gestureController.nonBareTriggerReleased()
            }
            bareTap = true
            return outputs
        }

        // Additional modifier changes invalidate the "bare modifier" assumption
        // just like a regular keyDown would. For passive built-in Fn, key off the
        // physical transition rather than current flags so both press and release
        // cancel an active gesture or an outstanding second-tap window.
        if trigger == .fn {
            let changedModifiers = Self.changedTrackedModifierKeyCodes(
                from: previousModifierFlags,
                to: flags,
                changedKeyCode: changedKeyCode
            ).subtracting([HotkeyTrigger.canonicalFnKeyCode])
            let capsLockChanged =
                changedKeyCode == 57
                && previousModifierFlags.contains(.maskAlphaShift) != flags.contains(.maskAlphaShift)
            guard !changedModifiers.isEmpty || capsLockChanged else { return [] }

            if targetModifierGestureIsActive {
                bareTap = false
                return gestureMode == .singleTapToggle ? [] : gestureController.interrupted()
            }
            return interruptPendingPassiveFnWindow()
        }

        guard targetModifierGestureIsActive else { return [] }
        let activeTrackedModifiers = flags.intersection(ModifierKeyMatcher.trackedModifierMasks)
        let nonTargetTrackedModifiers = activeTrackedModifiers.subtracting(mask)
        guard !nonTargetTrackedModifiers.isEmpty else { return [] }

        bareTap = false
        return gestureMode == .singleTapToggle ? [] : gestureController.interrupted()
    }

    private func modifierKeyDownOutputs(
        keyCode: Int64,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let physicalKeyCode = UInt16(keyCode)
        if trigger == .fn, Self.isTrackableNonFnKeyCode(physicalKeyCode) {
            releaseObservedKeyCodes.remove(physicalKeyCode)
            guard pressedNonFnKeyCodes.insert(physicalKeyCode).inserted else {
                return []
            }
            if targetModifierGestureIsActive {
                bareTap = false
            }
        }

        if keyCode == 53 { // Escape
            return escapeOutputs()
        } else if !HotkeyTrigger.isFnKeyCode(physicalKeyCode) {
            // Skip Fn/Globe key (63/179) — macOS generates a synthetic keyDown
            // with keyCode 179 when Fn is released (for "Change Input Source" or
            // "Show Emoji & Symbols"). Without this guard, that keyDown resets the
            // gesture state machine during modifier-only gestures.
            // Non-Escape key pressed — invalidate bare-tap if modifier is held
            if targetModifierGestureIsActive {
                bareTap = false
            }

            // Gesture interruption: a regular key press means the user is typing,
            // not performing a bare hotkey gesture.
            if gestureMode == .singleTapToggle {
                return []
            }
            return gestureController.interrupted()
        }
        return []
    }

    private func modifierKeyUpOutputs(
        keyCode: Int64,
        timestampMs _: UInt64
    ) -> [HotkeyGestureController.Output] {
        let physicalKeyCode = UInt16(keyCode)
        guard trigger == .fn,
            Self.isTrackableNonFnKeyCode(physicalKeyCode)
        else {
            return []
        }
        pressedNonFnKeyCodes.remove(physicalKeyCode)
        releaseObservedKeyCodes.insert(physicalKeyCode)
        guard targetModifierGestureIsActive else {
            return interruptPendingPassiveFnWindow()
        }

        bareTap = false
        return gestureMode == .singleTapToggle ? [] : gestureController.interrupted()
    }

    // Test seam: lets unit tests exercise the real modifier-path state logic
    // without constructing CGEvents or arming timers.
    func modifierFlagsChangedOutputsForTesting(
        flags: CGEventFlags,
        timestampMs: UInt64,
        changedKeyCode: UInt16? = nil
    ) -> [HotkeyGestureController.Output] {
        let outputs = modifierFlagsChangedOutputs(
            flags: flags,
            timestampMs: timestampMs,
            changedKeyCode: changedKeyCode
        )
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

    func modifierKeyUpOutputsForTesting(
        keyCode: Int64,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        let outputs = modifierKeyUpOutputs(keyCode: keyCode, timestampMs: timestampMs)
        rememberRecordingState(for: outputs)
        return outputs
    }

    func setPhysicalKeyStateProviderForTesting(
        _ provider: @escaping (UInt16) -> Bool
    ) {
        physicalKeyStateProvider = provider
        reconcilePassiveFnKeyState()
    }

    func setPhysicalFlagsProviderForTesting(_ provider: @escaping () -> CGEventFlags) {
        physicalFlagsProvider = provider
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
        testingTapFilter.tapReenabled(triggerKeyPressed: triggerKeyPressed)
        return recoverFromDisabledTap(
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

    /// Runs the tap-thread consume decision and the main-thread gesture step
    /// for one event, as a live tap would.
    func chordEventDecisionForTesting(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64,
        timestampMs: UInt64
    ) -> (outputs: [HotkeyGestureController.Output], shouldSwallow: Bool) {
        let shouldSwallow = testingTapFilter.shouldSwallow(type: type, keyCode: keyCode, flags: flags)
        let outputs = chordEventOutputs(
            type: type,
            keyCode: keyCode,
            flags: flags & Self.relevantModifierBits,
            timestampMs: timestampMs
        )
        rememberRecordingState(for: outputs)
        return (outputs, shouldSwallow)
    }

    func keyCodeEventDecisionForTesting(
        type: CGEventType,
        keyCode: UInt16,
        timestampMs: UInt64
    ) -> (outputs: [HotkeyGestureController.Output], shouldSwallow: Bool) {
        guard let triggerCode = trigger.keyCode else {
            return ([], false)
        }
        let shouldSwallow = testingTapFilter.shouldSwallow(type: type, keyCode: keyCode, flags: 0)
        let outputs = keyCodeEventOutputs(
            type: type,
            keyCode: keyCode,
            triggerCode: triggerCode,
            timestampMs: timestampMs
        )
        rememberRecordingState(for: outputs)
        return (outputs, shouldSwallow)
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

    private func handleKeyCodeEvent(_ event: KeyEventSnapshot) {
        guard let triggerCode = trigger.keyCode else { return }

        handleOutputs(
            keyCodeEventOutputs(
                type: event.type,
                keyCode: UInt16(event.keyCode),
                triggerCode: triggerCode,
                timestampMs: UInt64(event.timestamp / 1_000_000)
            )
        )
    }

    private func keyCodeEventOutputs(
        type: CGEventType,
        keyCode: UInt16,
        triggerCode: UInt16,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        if type == .keyDown {
            if keyCode == triggerCode {
                // Edge detection: ignore key-repeat (macOS sends repeated keyDown for held keys)
                guard !triggerKeyIsPressed else { return [] }
                triggerKeyIsPressed = true

                return gestureController.triggerPressed(timestampMs: timestampMs)
            } else if keyCode == 53 { // Escape
                return escapeOutputs()
            } else {
                // Gesture interruption: a regular key press means the user is typing,
                // not performing a bare hotkey gesture.
                return gestureController.interrupted()
            }
        } else if type == .keyUp {
            if keyCode == triggerCode {
                guard triggerKeyIsPressed else { return [] }
                triggerKeyIsPressed = false
                return gestureController.triggerReleased(timestampMs: timestampMs)
            }
        }
        // flagsChanged events are ignored for keyCode triggers

        return []
    }

    // MARK: - Chord Trigger Path

    private func handleChordEvent(_ event: KeyEventSnapshot) {
        handleOutputs(
            chordEventOutputs(
                type: event.type,
                keyCode: UInt16(event.keyCode),
                flags: event.flags.rawValue & Self.relevantModifierBits,
                timestampMs: UInt64(event.timestamp / 1_000_000)
            )
        )
    }

    private func chordEventOutputs(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64,
        timestampMs: UInt64
    ) -> [HotkeyGestureController.Output] {
        guard let triggerCode = trigger.keyCode else { return [] }

        if type == .keyDown {
            if keyCode == triggerCode {
                // Check required modifiers are held
                guard flags & requiredChordFlags == requiredChordFlags else {
                    return gestureController.interrupted()
                }

                // Edge detection: ignore key-repeat
                guard !triggerKeyIsPressed else { return [] }
                triggerKeyIsPressed = true
                chordModifierReleased = false

                return gestureController.triggerPressed(timestampMs: timestampMs)
            } else if keyCode == 53 { // Escape
                return escapeOutputs()
            } else {
                // Gesture interruption
                return gestureController.interrupted()
            }
        } else if type == .keyUp {
            if keyCode == triggerCode {
                guard triggerKeyIsPressed else { return [] }
                return chordTriggerKeyUpOutputs(timestampMs: timestampMs)
            }
        } else if type == .flagsChanged {
            // Release-any-part: if a required modifier is released while trigger key is held,
            // end dictation and mark that we already sent fnUp.
            if triggerKeyIsPressed && !chordModifierReleased {
                if flags & requiredChordFlags != requiredChordFlags {
                    chordModifierReleased = true
                    return gestureController.triggerReleased(timestampMs: timestampMs)
                }
            }
        }

        return []
    }

    // MARK: - Modifier-Only Chord Trigger Path

    private func handleModifierChordEvent(_ event: KeyEventSnapshot) {
        let type = event.type
        let timestampMs = UInt64(event.timestamp / 1_000_000)

        if type == .flagsChanged {
            handleOutputs(
                modifierChordFlagsChangedOutputs(
                    flags: event.flags,
                    timestampMs: timestampMs
                )
            )
        } else if type == .keyDown {
            handleOutputs(
                modifierChordKeyDownOutputs(
                    keyCode: event.keyCode,
                    timestampMs: timestampMs
                )
            )
        }
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
                outputs = gestureMode == .singleTapToggle
                    ? gestureController.triggerPressed(timestampMs: timestampMs)
                    : gestureController.triggerReleased(timestampMs: timestampMs)
            } else {
                outputs = gestureMode == .singleTapToggle ? [] : gestureController.nonBareTriggerReleased()
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
            return gestureMode == .singleTapToggle ? [] : gestureController.interrupted()
        }

        if exactPressed, !modifierChordGestureIsActive {
            guard !modifierChordBlockedUntilRelease else { return [] }
            modifierChordGestureIsActive = true
            bareTap = true
            if gestureMode == .singleTapToggle {
                return []
            }
            return gestureController.triggerPressed(timestampMs: timestampMs)
        }

        return []
    }

    private func modifierChordKeyDownOutputs(
        keyCode: Int64,
        timestampMs _: UInt64
    ) -> [HotkeyGestureController.Output] {
        if keyCode == 53 {
            return escapeOutputs()
        } else if !HotkeyTrigger.isFnKeyCode(UInt16(keyCode)) {
            if modifierChordGestureIsActive {
                bareTap = false
            }
            if gestureMode == .singleTapToggle {
                return []
            }
            return gestureController.interrupted()
        }
        return []
    }

    private func escapeOutputs() -> [HotkeyGestureController.Output] {
        // A pending hold or second-tap window has not started a take, so Escape
        // still clears it. A live take keeps `activeRecordingMode` set, so
        // Escape stays ignored when the setting is off.
        if shouldCancelOnEscape() || activeRecordingMode == nil {
            return gestureController.escapePressed()
        }
        return []
    }

    /// Notify state machine that cancel was triggered via UI (not Esc).
    /// Blocks hotkey during the cancel countdown window.
    public func notifyCancelledByUI() {
        cancelStopTailTimer()
        gestureController.notifyCancelledByUI()
        activeRecordingMode = nil
    }

    public func suppressUntilReset() {
        cancelStartupTimer()
        cancelHoldTimer()
        cancelStopTailTimer()
        gestureController.suppressUntilReset()
        activeRecordingMode = nil
    }

    /// Resume recording mode after undo, so hotkey stops the recording correctly.
    public func resumeRecording(mode: FnKeyStateMachine.RecordingMode) {
        gestureController.resumeRecording(mode: mode)
        activeRecordingMode = mode
    }

    public func syncRecordingMode(_ mode: FnKeyStateMachine.RecordingMode) {
        // Startup can finish during a hold-to-talk stop tail. That take is
        // ending; resuming it would ignore a re-press until the tail stops
        // capture under the held trigger.
        guard stopTailTimer == nil else { return }
        if let resumeMode = Self.resumeMode(mode, for: gestureMode) {
            resumeRecording(mode: resumeMode)
        } else {
            suppressUntilReset()
        }
    }

    /// Reset state machine to idle (e.g., after cancel countdown expires).
    public func resetToIdle(flags: CGEventFlags? = nil) {
        resetGestureState(flags: flags, triggerKeyPressed: false)
    }

    static func resumeMode(
        _ activeMode: FnKeyStateMachine.RecordingMode?,
        for gestureMode: HotkeyGestureController.Mode
    ) -> FnKeyStateMachine.RecordingMode? {
        guard let activeMode else { return nil }
        switch (activeMode, gestureMode) {
        case (.persistent, .singleTapToggle),
             (.persistent, .doubleTapOnly),
             (.persistent, .doubleTapAndHold),
             (.holdToTalk, .holdOnly),
             (.holdToTalk, .doubleTapAndHold):
            return activeMode
        case (.persistent, .holdOnly),
             (.holdToTalk, .singleTapToggle),
             (.holdToTalk, .doubleTapOnly):
            return nil
        }
    }

    static func shouldSuppressPeer(
        _ activeMode: FnKeyStateMachine.RecordingMode?,
        for gestureMode: HotkeyGestureController.Mode
    ) -> Bool {
        guard activeMode != nil else { return false }
        return resumeMode(activeMode, for: gestureMode) == nil
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
        // The tap may have missed events, so trust the key-state snapshot again.
        releaseObservedKeyCodes.removeAll(keepingCapacity: true)
        let triggerPressed = currentPhysicalTriggerIsPressed(
            flags: flags,
            triggerKeyPressed: triggerKeyPressed
        )

        if trigger == .fn {
            let currentFlags = flags ?? physicalFlagsProvider()
            let capsLockChangedWhileTapWasDisabled =
                previousModifierFlags.contains(.maskAlphaShift)
                != currentFlags.contains(.maskAlphaShift)
            let capsLockContaminatesCurrentGesture =
                capsLockChangedWhileTapWasDisabled
                && (targetModifierGestureIsActive || gestureController.hasPendingTriggerPress)
            reconcilePassiveFnKeyState()
            if triggerPressed,
                passiveFnInputIsContaminated(flags: currentFlags)
                    || capsLockContaminatesCurrentGesture
            {
                cancelStartupTimer()
                cancelHoldTimer()
                syncRecoveredTriggerState(
                    flags: flags,
                    triggerKeyPressed: triggerKeyPressed,
                    triggerPressed: triggerPressed
                )
                let outputs = gestureController.interrupted()
                targetModifierGestureIsActive = false
                bareTap = false
                handleOutputs(outputs)
                return outputs
            }
        }

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
            // A tap-disable + recovery can land in the brief window after a fresh
            // trigger press but before its startup timer has fired, when no
            // recording is active yet. Hard-resetting here cancels the armed
            // startup timer and gesture state, dropping the start the user is
            // mid-gesture on — and because the key is still physically held, no
            // new edge arrives to re-arm it, so "nothing happens" until they
            // release and press again. (The Instant-Dictation warm-mic restart
            // right after a paste is what disables the tap in the first place.)
            // If a press is still pending and the trigger is still held, preserve
            // the gesture across the recovery instead of resetting it.
            if triggerPressed, gestureController.hasPendingTriggerPress {
                syncRecoveredTriggerState(
                    flags: flags,
                    triggerKeyPressed: triggerKeyPressed,
                    triggerPressed: triggerPressed
                )
                return []
            }
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
        reconcilePassiveFnKeyState()
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
            let currentFlags = flags ?? physicalFlagsProvider()
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
            let currentFlags = flags ?? physicalFlagsProvider()
            return currentFlags.rawValue & requiredChordFlags == requiredChordFlags
        case .modifierChord:
            let currentFlags = flags ?? physicalFlagsProvider()
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
        let currentFlags = flags ?? physicalFlagsProvider()

        switch trigger.kind {
        case .modifier:
            guard let mask = targetMask else { return false }
            let activeTrackedModifiers = currentFlags.intersection(ModifierKeyMatcher.trackedModifierMasks)
            if !activeTrackedModifiers.subtracting(mask).isEmpty {
                return true
            }
            if trigger == .fn {
                if !pressedNonFnKeyCodes.isEmpty {
                    return true
                }
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

    private static func isTrackableNonFnKeyCode(_ keyCode: UInt16) -> Bool {
        ordinaryKeyCodeRange.contains(keyCode)
            && !HotkeyTrigger.isFnKeyCode(keyCode)
            && keyCode != capsLockKeyCode
    }

    private func reconcilePassiveFnKeyState() {
        guard trigger == .fn else { return }
        pressedNonFnKeyCodes = Set(
            Self.ordinaryKeyCodeRange.filter { keyCode in
                Self.isTrackableNonFnKeyCode(keyCode)
                    && !releaseObservedKeyCodes.contains(keyCode)
                    && physicalKeyStateProvider(keyCode)
            }
        )
    }

    private func passiveFnInputIsContaminated(flags: CGEventFlags) -> Bool {
        guard let fnMask = targetMask else { return true }
        let activeTrackedModifiers = flags.intersection(ModifierKeyMatcher.trackedModifierMasks)
        // Alpha Shift is a latched state, not proof that Caps Lock is held.
        // A physical Caps key is covered by the key ledger; transitions are
        // handled from changedKeyCode in modifierFlagsChangedOutputs.
        return !activeTrackedModifiers.subtracting(fnMask).isEmpty
            || !pressedNonFnKeyCodes.isEmpty
    }

    private func interruptPendingPassiveFnWindow() -> [HotkeyGestureController.Output] {
        guard activeRecordingMode == nil, gestureController.hasPendingTriggerPress else {
            return []
        }
        return gestureController.interrupted()
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
        Self.physicalTriggerKeyIsPressed(trigger)
    }

    fileprivate static func physicalTriggerKeyIsPressed(_ trigger: HotkeyTrigger) -> Bool {
        guard trigger.kind == .keyCode || trigger.kind == .chord,
              let keyCode = trigger.keyCode else {
            return false
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func syncModifierPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifier else { return }

        let currentFlags = flags ?? physicalFlagsProvider()
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

        let currentFlags = flags ?? physicalFlagsProvider()
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
        to currentFlags: CGEventFlags,
        changedKeyCode: UInt16?
    ) -> Set<UInt16> {
        ModifierKeyMatcher.changedTrackedModifierKeyCodes(
            from: previousFlags,
            to: currentFlags,
            changedKeyCode: changedKeyCode
        )
    }

    private func handleOutputs(_ outputs: [HotkeyGestureController.Output]) {
        let recordingModeBeforeOutputs = activeRecordingMode
        rememberRecordingState(for: outputs)

        for output in outputs {
            switch output {
            case .startRecording(let mode):
                cancelStopTailTimer()
                AudioCaptureDiagnostics.append("dictation_hotkey_start mode=\(diagnosticMode(mode))")
                onStartRecording?(mode)
            case .stopRecording:
                handleStopRecordingOutput(recordingModeBeforeOutputs: recordingModeBeforeOutputs)
            case .cancelRecording:
                cancelStopTailTimer()
                onCancelRecording?()
            case .discardRecording(let showReadyPill):
                cancelStopTailTimer()
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

    private func handleStopRecordingOutput(
        recordingModeBeforeOutputs: FnKeyStateMachine.RecordingMode?
    ) {
        cancelStopTailTimer()
        guard recordingModeBeforeOutputs == .holdToTalk, holdToTalkStopTailMs > 0 else {
            AudioCaptureDiagnostics.append(
                "dictation_hotkey_stop mode=\(diagnosticMode(recordingModeBeforeOutputs)) tail_ms=0"
            )
            onStopRecording?()
            return
        }

        let tailMs = holdToTalkStopTailMs
        AudioCaptureDiagnostics.append(
            "dictation_hotkey_stop_tail_scheduled mode=hold_to_talk tail_ms=\(tailMs)"
        )
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopTailTimer = nil
            AudioCaptureDiagnostics.append(
                "dictation_hotkey_stop_tail_fired mode=hold_to_talk tail_ms=\(tailMs)"
            )
            self.onStopRecording?()
        }
        stopTailTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(tailMs),
            execute: timer
        )
        onStopPending?()
    }

    private func diagnosticMode(_ mode: FnKeyStateMachine.RecordingMode?) -> String {
        switch mode {
        case .holdToTalk:
            return "hold_to_talk"
        case .persistent:
            return "persistent"
        case nil:
            return "unknown"
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

    private func cancelStopTailTimer() {
        guard let timer = stopTailTimer else { return }
        timer.cancel()
        stopTailTimer = nil
        onStopPendingCancelled?()
    }

    /// Bare Fn refused because another key or modifier reads as held. Key
    /// codes only, never characters.
    private func logFnAdmissionRejected(flags: CGEventFlags) {
        let heldKeyCodes = pressedNonFnKeyCodes.sorted().map(String.init).joined(separator: ",")
        let otherModifiers = flags.intersection(ModifierKeyMatcher.trackedModifierMasks)
            .subtracting(targetMask ?? [])
        AudioCaptureDiagnostics.append(
            "dictation_hotkey_fn_rejected held_keycodes=[\(heldKeyCodes)] other_modifiers=0x\(String(otherModifiers.rawValue, radix: 16))"
        )
    }

    /// A trigger release that cannot stop a live hold-to-talk take.
    private func logReleaseIgnoredIfRecording() {
        guard activeRecordingMode == .holdToTalk else { return }
        AudioCaptureDiagnostics.append("dictation_hotkey_release_ignored mode=hold_to_talk reason=gesture_inactive")
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

/// A keyboard event copied out of the tap callback so the main thread can
/// process it after the callback has returned.
struct KeyEventSnapshot: Sendable {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
    let timestamp: CGEventTimestamp

    init(type: CGEventType, event: CGEvent) {
        self.type = type
        self.keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        self.flags = event.flags
        self.timestamp = event.timestamp
    }
}

fileprivate enum HotkeyTapEvent: Sendable {
    case key(KeyEventSnapshot)
    case tapReenabled
}

/// Tap-thread half of a running `HotkeyManager` tap: consumes what the
/// trigger owns and forwards every event to the main queue in order.
private final class HotkeyTapRelay: @unchecked Sendable {
    private let generation: UInt64
    private let trigger: HotkeyTrigger
    /// Tap thread only.
    private var filter: HotkeyTapFilter
    /// Read on the main thread only.
    private weak var manager: HotkeyManager?

    init(manager: HotkeyManager, generation: UInt64, trigger: HotkeyTrigger) {
        self.manager = manager
        self.generation = generation
        self.trigger = trigger
        self.filter = HotkeyTapFilter(trigger: trigger)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            filter.tapReenabled(triggerKeyPressed: HotkeyManager.physicalTriggerKeyIsPressed(trigger))
            forward(.tapReenabled)
            return Unmanaged.passUnretained(event)
        }

        if StreamingCursorEventMarker.isMarked(event) {
            return Unmanaged.passUnretained(event)
        }

        let snapshot = KeyEventSnapshot(type: type, event: event)
        let shouldSwallow = filter.shouldSwallow(
            type: type,
            keyCode: UInt16(truncatingIfNeeded: snapshot.keyCode),
            flags: snapshot.flags.rawValue
        )
        forward(.key(snapshot))
        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    private func forward(_ tapEvent: HotkeyTapEvent) {
        // Never wait on the main thread from here: that is the stall #1142 removes.
        DispatchQueue.main.async { [self] in
            guard let manager, manager.isCurrentTap(generation) else { return }
            manager.process(tapEvent)
        }
    }
}
