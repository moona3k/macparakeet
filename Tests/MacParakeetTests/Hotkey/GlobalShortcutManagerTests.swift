import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class GlobalShortcutManagerTests: XCTestCase {
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
}
