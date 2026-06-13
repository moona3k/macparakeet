import XCTest
import CoreGraphics
import IOKit.hidsystem
@testable import MacParakeet
@testable import MacParakeetCore

final class GlobalShortcutManagerTests: XCTestCase {
    private let leftOptionMask = UInt64(NX_DEVICELALTKEYMASK)
    private let rightOptionMask = UInt64(NX_DEVICERALTKEYMASK)
    private let leftCommandMask = UInt64(NX_DEVICELCMDKEYMASK)
    private let rightCommandMask = UInt64(NX_DEVICERCMDKEYMASK)

    private func sideSpecificFlags(_ masks: UInt64...) -> CGEventFlags {
        CGEventFlags(rawValue: masks.reduce(0, |))
    }

    func testTapRecoveryResyncsModifierAfterMissedRelease() {
        let manager = GlobalShortcutManager(trigger: .fn)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        manager.modifierFlagsChangedForTesting(flags: [.maskSecondaryFn])
        XCTAssertEqual(triggerCount, 1)

        manager.recoverFromDisabledTapForTesting(flags: [])
        manager.modifierFlagsChangedForTesting(flags: [.maskSecondaryFn])

        XCTAssertEqual(triggerCount, 2)
    }

    func testTapRecoveryAllowsChordAfterMissedKeyUp() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 46)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        XCTAssertEqual(triggerCount, 1)

        manager.recoverFromDisabledTapForTesting(triggerKeyPressed: false)
        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )

        XCTAssertEqual(triggerCount, 2)
    }

    func testTapRecoveryPreservesHeldChordKeyToAvoidRepeatTrigger() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 46)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        manager.recoverFromDisabledTapForTesting(triggerKeyPressed: true)

        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        XCTAssertEqual(triggerCount, 1)
        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyUp,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        XCTAssertEqual(triggerCount, 2)
    }

    func testChordRequiresExactModifierMatch() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 46)
        let manager = GlobalShortcutManager(trigger: trigger)
        let extraControl = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 46).chordEventFlags
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        let swallowed = manager.handleChordEventForTesting(
            type: .keyDown,
            keyCode: 46,
            flags: trigger.chordEventFlags | extraControl
        )

        XCTAssertFalse(swallowed)
        XCTAssertEqual(triggerCount, 0)
    }

    func testChordExactMatchTriggersAndSwallows() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 46)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        let swallowed = manager.handleChordEventForTesting(
            type: .keyDown,
            keyCode: 46,
            flags: trigger.chordEventFlags
        )

        XCTAssertTrue(swallowed)
        XCTAssertEqual(triggerCount, 1)
    }

    func testFunctionKeyChordTriggersWithPhantomFnFlagBit() {
        // Hardware F-key events carry NX_SECONDARYFNMASK even when the
        // physical Fn key is not held. A ⌃F19 chord must still fire.
        let trigger = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 80)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        let swallowed = manager.handleChordEventForTesting(
            type: .keyDown,
            keyCode: 80,
            flags: trigger.chordEventFlags | CGEventFlags.maskSecondaryFn.rawValue
        )

        XCTAssertTrue(swallowed)
        XCTAssertEqual(triggerCount, 1)
    }

    func testFunctionKeyChordTriggersWithoutFnFlagBit() {
        // Synthetic F-key events (Karabiner/QMK remaps) often omit the fn
        // bit entirely; the clean chord must fire for those too.
        let trigger = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 80)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        let swallowed = manager.handleChordEventForTesting(
            type: .keyDown,
            keyCode: 80,
            flags: trigger.chordEventFlags
        )

        XCTAssertTrue(swallowed)
        XCTAssertEqual(triggerCount, 1)
    }

    func testFunctionKeyChordStillRequiresExactRealModifiers() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 80)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        XCTAssertFalse(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 80,
                flags: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
        XCTAssertFalse(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 80,
                flags: trigger.chordEventFlags
                    | CGEventFlags.maskShift.rawValue
                    | CGEventFlags.maskSecondaryFn.rawValue
            )
        )
        XCTAssertEqual(triggerCount, 0)
    }

    func testFnRequiringFunctionKeyChordStillRequiresFnBit() {
        // Chords that genuinely include fn (e.g. previously recorded
        // fn+⌃F19 triggers) keep their exact requirement.
        let trigger = HotkeyTrigger.chord(modifiers: ["fn", "control"], keyCode: 80)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        XCTAssertFalse(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 80,
                flags: CGEventFlags.maskControl.rawValue
            )
        )
        XCTAssertEqual(triggerCount, 0)

        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 80,
                flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue
            )
        )
        XCTAssertEqual(triggerCount, 1)
    }

    func testChordKeyUpPassesThroughWhenChordWasNotHandled() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 46)
        let manager = GlobalShortcutManager(trigger: trigger)

        let swallowed = manager.handleChordEventForTesting(
            type: .keyUp,
            keyCode: 46,
            flags: trigger.chordEventFlags
        )

        XCTAssertFalse(swallowed)
    }

    func testChordKeyUpSwallowsOnlyAfterHandledKeyDown() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 46)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyDown,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        XCTAssertEqual(triggerCount, 1)

        XCTAssertTrue(
            manager.handleChordEventForTesting(
                type: .keyUp,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
        XCTAssertFalse(
            manager.handleChordEventForTesting(
                type: .keyUp,
                keyCode: 46,
                flags: trigger.chordEventFlags
            )
        )
    }

    func testModifierChordTriggersOncePerPress() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        manager.modifierChordFlagsChangedForTesting(flags: [.maskCommand])
        manager.modifierChordFlagsChangedForTesting(flags: [.maskCommand, .maskAlternate])
        manager.modifierChordFlagsChangedForTesting(flags: [.maskCommand, .maskAlternate])
        manager.modifierChordFlagsChangedForTesting(flags: [])
        manager.modifierChordFlagsChangedForTesting(flags: [.maskCommand, .maskAlternate])

        XCTAssertEqual(triggerCount, 2)
    }

    func testModifierChordRequiresExactModifierSet() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        manager.modifierChordFlagsChangedForTesting(flags: [.maskCommand, .maskAlternate, .maskShift])
        manager.modifierChordFlagsChangedForTesting(flags: [.maskCommand, .maskAlternate])

        XCTAssertEqual(triggerCount, 0)

        manager.modifierChordFlagsChangedForTesting(flags: [])
        manager.modifierChordFlagsChangedForTesting(flags: [.maskCommand, .maskAlternate])

        XCTAssertEqual(triggerCount, 1)
    }

    func testSideSpecificModifierDoesNotRetriggerWhenOppositeSideIsReleased() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        manager.modifierFlagsChangedForTesting(
            flags: sideSpecificFlags(CGEventFlags.maskAlternate.rawValue, rightOptionMask)
        )
        manager.modifierFlagsChangedForTesting(
            flags: sideSpecificFlags(CGEventFlags.maskAlternate.rawValue, leftOptionMask, rightOptionMask)
        )
        manager.modifierFlagsChangedForTesting(
            flags: sideSpecificFlags(CGEventFlags.maskAlternate.rawValue, rightOptionMask)
        )

        XCTAssertEqual(triggerCount, 1)

        manager.modifierFlagsChangedForTesting(flags: [])
        manager.modifierFlagsChangedForTesting(
            flags: sideSpecificFlags(CGEventFlags.maskAlternate.rawValue, rightOptionMask)
        )

        XCTAssertEqual(triggerCount, 2)
    }

    func testSideSpecificRightCommandTriggersFromChangedKeyCodeWhenSideFlagsAreMissing() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        manager.modifierFlagsChangedForTesting(flags: [.maskCommand], changedKeyCode: 55)
        manager.modifierFlagsChangedForTesting(flags: [.maskCommand], changedKeyCode: 54)
        manager.modifierFlagsChangedForTesting(flags: [.maskCommand], changedKeyCode: 54)
        manager.modifierFlagsChangedForTesting(flags: [], changedKeyCode: 54)
        manager.modifierFlagsChangedForTesting(flags: [.maskCommand], changedKeyCode: 54)

        XCTAssertEqual(triggerCount, 2)
    }

    func testSideSpecificModifierChordDoesNotTriggerAfterOppositeSideIsReleased() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        manager.modifierChordFlagsChangedForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                CGEventFlags.maskCommand.rawValue,
                leftOptionMask,
                rightOptionMask,
                rightCommandMask
            )
        )
        manager.modifierChordFlagsChangedForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                CGEventFlags.maskCommand.rawValue,
                rightOptionMask,
                rightCommandMask
            )
        )

        XCTAssertEqual(triggerCount, 0)

        manager.modifierChordFlagsChangedForTesting(flags: [])
        manager.modifierChordFlagsChangedForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                CGEventFlags.maskCommand.rawValue,
                rightOptionMask,
                rightCommandMask
            )
        )

        XCTAssertEqual(triggerCount, 1)
    }

    func testSideSpecificModifierChordTriggersRecordedSideOnly() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
        let manager = GlobalShortcutManager(trigger: trigger)
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        manager.modifierChordFlagsChangedForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                CGEventFlags.maskCommand.rawValue,
                leftOptionMask,
                leftCommandMask
            )
        )
        manager.modifierChordFlagsChangedForTesting(
            flags: sideSpecificFlags(
                CGEventFlags.maskAlternate.rawValue,
                CGEventFlags.maskCommand.rawValue,
                rightOptionMask,
                rightCommandMask
            )
        )

        XCTAssertEqual(triggerCount, 1)
    }
}
