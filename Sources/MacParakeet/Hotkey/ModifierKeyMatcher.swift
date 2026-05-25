import CoreGraphics
import IOKit.hidsystem
import MacParakeetCore

enum ModifierKeyMatcher {
    static let relevantModifierBits: UInt64 = HotkeyTrigger.relevantModifierBits

    static let trackedModifierMasks: CGEventFlags = [
        .maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand,
    ]

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

    static func modifierIsPressed(trigger: HotkeyTrigger, flags: CGEventFlags) -> Bool {
        guard trigger.kind == .modifier else { return false }
        if let keyCode = trigger.modifierKeyCode {
            return sideSpecificModifierIsPressed(flags: flags, keyCode: keyCode)
                && !oppositeSideModifierIsPressed(flags: flags, keyCode: keyCode)
        }
        guard let mask = mask(for: trigger.modifierName) else { return false }
        return flags.contains(mask)
    }

    static func modifierChordRequiredComponentsArePressed(
        trigger: HotkeyTrigger,
        flags: CGEventFlags
    ) -> Bool {
        trigger.modifierChordRequiredComponentsArePressed(
            flags: flags.rawValue,
            sideSpecificPressed: { sideSpecificModifierIsPressed(flags: flags, keyCode: $0) }
        )
    }

    static func modifierChordMatches(trigger: HotkeyTrigger, flags: CGEventFlags) -> Bool {
        trigger.modifierChordMatches(
            flags: flags.rawValue,
            sideSpecificPressed: { sideSpecificModifierIsPressed(flags: flags, keyCode: $0) }
        )
    }

    static func changedTrackedModifierKeyCodes(
        from previousFlags: CGEventFlags,
        to currentFlags: CGEventFlags
    ) -> Set<UInt16> {
        var changed: Set<UInt16> = []

        for keyCode in HotkeyTrigger.sideSpecificModifierKeyCodes {
            let wasPressed = sideSpecificModifierIsPressed(flags: previousFlags, keyCode: keyCode)
            let isPressed = sideSpecificModifierIsPressed(flags: currentFlags, keyCode: keyCode)
            if wasPressed != isPressed {
                changed.insert(keyCode)
            }
        }

        if previousFlags.contains(.maskSecondaryFn) != currentFlags.contains(.maskSecondaryFn) {
            changed.insert(HotkeyTrigger.canonicalFnKeyCode)
        }

        return changed
    }

    static func sideSpecificModifierIsPressed(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        guard let mask = sideSpecificModifierMasks[keyCode] else { return false }
        return (flags.rawValue & mask) != 0
    }

    static func sideSpecificModifierIsPressed(
        flags: CGEventFlags,
        keyCode: UInt16,
        changedKeyCode: UInt16?,
        previouslyPressed: Bool
    ) -> Bool {
        guard let changedKeyCode else {
            return sideSpecificModifierIsPressed(flags: flags, keyCode: keyCode)
        }
        if sideSpecificModifierSideIsPressed(flags: flags, keyCode: keyCode) {
            return sideSpecificModifierIsPressed(flags: flags, keyCode: keyCode)
        }
        guard changedKeyCode == keyCode,
              let modifierName = HotkeyTrigger.modifierName(forKeyCode: keyCode),
              let mask = mask(for: modifierName) else {
            return previouslyPressed
        }
        return flags.contains(mask)
    }

    static func oppositeSideModifierIsPressed(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        guard let oppositeKeyCode = HotkeyTrigger.oppositeModifierKeyCode(for: keyCode) else { return false }
        return sideSpecificModifierIsPressed(flags: flags, keyCode: oppositeKeyCode)
    }

    static func oppositeSideModifierIsPressed(
        flags: CGEventFlags,
        keyCode: UInt16,
        changedKeyCode: UInt16?
    ) -> Bool {
        guard let changedKeyCode else {
            return oppositeSideModifierIsPressed(flags: flags, keyCode: keyCode)
        }
        guard let oppositeKeyCode = HotkeyTrigger.oppositeModifierKeyCode(for: keyCode) else { return false }
        if sideSpecificModifierSideIsPressed(flags: flags, keyCode: keyCode) {
            return sideSpecificModifierIsPressed(flags: flags, keyCode: oppositeKeyCode)
        }
        // Without side-specific device bits, the current event can only prove
        // which physical modifier changed; it cannot prove the opposite side
        // was already held from an earlier event.
        guard changedKeyCode == oppositeKeyCode,
              let modifierName = HotkeyTrigger.modifierName(forKeyCode: oppositeKeyCode),
              let mask = mask(for: modifierName) else {
            return false
        }
        return flags.contains(mask)
    }

    static func changedTrackedModifierKeyCodes(
        from previousFlags: CGEventFlags,
        to currentFlags: CGEventFlags,
        changedKeyCode: UInt16?
    ) -> Set<UInt16> {
        var changed = changedTrackedModifierKeyCodes(from: previousFlags, to: currentFlags)
        guard let changedKeyCode else { return changed }
        if HotkeyTrigger.isFnKeyCode(changedKeyCode) {
            changed.insert(HotkeyTrigger.canonicalFnKeyCode)
        } else if HotkeyTrigger.modifierComponent(forKeyCode: changedKeyCode) != nil {
            changed.insert(changedKeyCode)
        }
        return changed
    }

    private static func sideSpecificModifierSideIsPressed(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        guard let oppositeKeyCode = HotkeyTrigger.oppositeModifierKeyCode(for: keyCode),
              let mask = sideSpecificModifierMasks[keyCode],
              let oppositeMask = sideSpecificModifierMasks[oppositeKeyCode] else {
            return false
        }
        return (flags.rawValue & (mask | oppositeMask)) != 0
    }

    static func mask(for name: String?) -> CGEventFlags? {
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
