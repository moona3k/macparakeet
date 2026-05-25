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
