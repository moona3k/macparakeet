import Cocoa
import Foundation
import MacParakeetCore

/// Lightweight global shortcut listener for immediate actions like toggling
/// meeting recording. Unlike `HotkeyManager`, this does not model hold or
/// dictation gesture handling.
public final class GlobalShortcutManager {
    public var onTrigger: (() -> Void)?

    private let trigger: HotkeyTrigger
    private let requiredChordFlags: UInt64
    private let ignoredChordEventFlags: UInt64
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<GlobalShortcutManager>?
    private var installedRunLoop: CFRunLoop?
    private var targetModifierWasPressed = false
    private var triggerKeyIsPressed = false
    private var modifierChordRequiredWasPressed = false
    private var modifierChordTriggeredDuringPress = false
    private var modifierChordBlockedUntilRelease = false

    public init(trigger: HotkeyTrigger) {
        self.trigger = trigger
        self.requiredChordFlags = trigger.chordEventFlags
        self.ignoredChordEventFlags = trigger.ignoredChordEventFlags
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
    }

    public func start() -> Bool {
        if eventTap != nil {
            stop()
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
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
        recoverFromDisabledTap()
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        targetModifierWasPressed = false
        triggerKeyIsPressed = false
        modifierChordRequiredWasPressed = false
        modifierChordTriggeredDuringPress = false
        modifierChordBlockedUntilRelease = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
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

    private func handleModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        handleModifierFlagsChanged(
            flags: event.flags,
            changedKeyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        )
        return Unmanaged.passUnretained(event)
    }

    private func handleModifierFlagsChanged(flags: CGEventFlags, changedKeyCode: UInt16? = nil) {
        if let targetKeyCode = trigger.modifierKeyCode {
            handleSideSpecificModifierFlagsChanged(
                flags: flags,
                targetKeyCode: targetKeyCode,
                changedKeyCode: changedKeyCode
            )
            return
        }

        let isPressed = ModifierKeyMatcher.modifierIsPressed(trigger: trigger, flags: flags)
        if isPressed != targetModifierWasPressed {
            targetModifierWasPressed = isPressed
            if isPressed {
                onTrigger?()
            }
        }
    }

    private func handleSideSpecificModifierFlagsChanged(
        flags: CGEventFlags,
        targetKeyCode: UInt16,
        changedKeyCode: UInt16?
    ) {
        let isPressed = ModifierKeyMatcher.sideSpecificModifierIsPressed(
            flags: flags,
            keyCode: targetKeyCode,
            changedKeyCode: changedKeyCode,
            previouslyPressed: targetModifierWasPressed
        )
        let oppositeIsPressed = ModifierKeyMatcher.oppositeSideModifierIsPressed(
            flags: flags,
            keyCode: targetKeyCode,
            changedKeyCode: changedKeyCode
        )

        guard isPressed else {
            targetModifierWasPressed = false
            return
        }

        guard !targetModifierWasPressed else { return }
        targetModifierWasPressed = true
        if !oppositeIsPressed {
            onTrigger?()
        }
    }

    private func handleModifierChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        handleModifierChordFlagsChanged(flags: event.flags)
        return Unmanaged.passUnretained(event)
    }

    private func handleModifierChordFlagsChanged(flags: CGEventFlags) {
        let requiredPressed = ModifierKeyMatcher.modifierChordRequiredComponentsArePressed(
            trigger: trigger,
            flags: flags
        )
        let exactPressed = ModifierKeyMatcher.modifierChordMatches(trigger: trigger, flags: flags)

        if !requiredPressed {
            modifierChordRequiredWasPressed = false
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = false
            return
        }

        if !modifierChordRequiredWasPressed {
            modifierChordRequiredWasPressed = true
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = !exactPressed
        }

        guard exactPressed,
              !modifierChordBlockedUntilRelease,
              !modifierChordTriggeredDuringPress else {
            return
        }
        modifierChordTriggeredDuringPress = true
        onTrigger?()
    }

    private func handleKeyCodeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            guard !triggerKeyIsPressed else { return nil }
            triggerKeyIsPressed = true
            onTrigger?()
            return nil
        case .keyUp:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            triggerKeyIsPressed = false
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shouldSwallow = handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: event.flags.rawValue & HotkeyTrigger.relevantModifierBits
        )
        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    private func recoverFromDisabledTap(flags: CGEventFlags? = nil) {
        recoverFromDisabledTap(flags: flags, triggerKeyPressed: currentPhysicalTriggerKeyIsPressed())
    }

    private func recoverFromDisabledTap(flags: CGEventFlags? = nil, triggerKeyPressed: Bool) {
        triggerKeyIsPressed = triggerKeyPressed
        syncModifierPressedState(flags: flags)
        syncModifierChordPressedState(flags: flags)
    }

    private func currentPhysicalTriggerKeyIsPressed() -> Bool {
        guard trigger.kind == .keyCode || trigger.kind == .chord,
              let keyCode = trigger.keyCode else {
            return false
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func syncModifierPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifier else {
            targetModifierWasPressed = false
            return
        }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        if let targetKeyCode = trigger.modifierKeyCode {
            targetModifierWasPressed = ModifierKeyMatcher.sideSpecificModifierIsPressed(
                flags: currentFlags,
                keyCode: targetKeyCode
            )
        } else {
            targetModifierWasPressed = ModifierKeyMatcher.modifierIsPressed(trigger: trigger, flags: currentFlags)
        }
    }

    private func syncModifierChordPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifierChord else {
            modifierChordRequiredWasPressed = false
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = false
            return
        }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        modifierChordRequiredWasPressed = ModifierKeyMatcher.modifierChordRequiredComponentsArePressed(
            trigger: trigger,
            flags: currentFlags
        )
        let exactPressed = ModifierKeyMatcher.modifierChordMatches(trigger: trigger, flags: currentFlags)
        modifierChordBlockedUntilRelease = modifierChordRequiredWasPressed
            && !exactPressed
        modifierChordTriggeredDuringPress = exactPressed
    }

    @discardableResult
    private func handleChordEvent(
        type: CGEventType,
        triggerCode: UInt16,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return false }
            guard flags & ~ignoredChordEventFlags == requiredChordFlags else { return false }
            guard !triggerKeyIsPressed else { return true }
            triggerKeyIsPressed = true
            onTrigger?()
            return true
        case .keyUp:
            guard keyCode == triggerCode else { return false }
            guard triggerKeyIsPressed else { return false }
            triggerKeyIsPressed = false
            return true
        default:
            return false
        }
    }

    @discardableResult
    func handleChordEventForTesting(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        guard let triggerCode = trigger.keyCode else { return false }
        return handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: flags & HotkeyTrigger.relevantModifierBits
        )
    }

    func modifierFlagsChangedForTesting(flags: CGEventFlags, changedKeyCode: UInt16? = nil) {
        guard trigger.kind == .modifier else { return }
        handleModifierFlagsChanged(flags: flags, changedKeyCode: changedKeyCode)
    }

    func modifierChordFlagsChangedForTesting(flags: CGEventFlags) {
        guard trigger.kind == .modifierChord else { return }
        handleModifierChordFlagsChanged(flags: flags)
    }

    func recoverFromDisabledTapForTesting(
        flags: CGEventFlags? = nil,
        triggerKeyPressed: Bool = false
    ) {
        recoverFromDisabledTap(flags: flags, triggerKeyPressed: triggerKeyPressed)
    }

}
