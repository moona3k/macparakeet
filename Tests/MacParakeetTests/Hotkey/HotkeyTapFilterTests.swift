import CoreGraphics
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

/// The tap-thread consume decision for `HotkeyManager` (#1142). Gesture
/// behavior is covered through `HotkeyManagerTests`' decision seams.
final class HotkeyTapFilterTests: XCTestCase {
    private let chord = HotkeyTrigger.chord(modifiers: ["control", "shift"], keyCode: 15)

    func testModifierTriggersNeverConsume() {
        for trigger in [HotkeyTrigger.fn, .control, .modifierChord(modifiers: ["control", "option"])] {
            var filter = HotkeyTapFilter(trigger: trigger)
            for type in [CGEventType.flagsChanged, .keyDown, .keyUp] {
                XCTAssertFalse(filter.shouldSwallow(type: type, keyCode: 63, flags: 0))
                XCTAssertFalse(filter.shouldSwallow(type: type, keyCode: 15, flags: 0))
            }
        }
    }

    func testKeyCodeTriggerConsumesOnlyItsKey() {
        var filter = HotkeyTapFilter(trigger: .fromKeyCode(119))
        XCTAssertTrue(filter.shouldSwallow(type: .keyDown, keyCode: 119, flags: 0))
        XCTAssertTrue(filter.shouldSwallow(type: .keyDown, keyCode: 119, flags: 0))
        XCTAssertTrue(filter.shouldSwallow(type: .keyUp, keyCode: 119, flags: 0))
        XCTAssertFalse(filter.shouldSwallow(type: .keyDown, keyCode: 53, flags: 0))
        XCTAssertFalse(filter.shouldSwallow(type: .flagsChanged, keyCode: 119, flags: 0))
    }

    /// An unconsumed trigger keyDown reaches the app, so its keyUp must too,
    /// even after an earlier chord press was consumed.
    func testChordKeyUpFollowsItsKeyDown() {
        var filter = HotkeyTapFilter(trigger: chord)
        let required = chord.chordEventFlags

        XCTAssertTrue(filter.shouldSwallow(type: .keyDown, keyCode: 15, flags: required))
        // Modifiers released while the key auto-repeats: repeats reach the app.
        XCTAssertFalse(filter.shouldSwallow(type: .keyDown, keyCode: 15, flags: 0))
        XCTAssertFalse(filter.shouldSwallow(type: .keyUp, keyCode: 15, flags: 0))

        XCTAssertTrue(filter.shouldSwallow(type: .keyDown, keyCode: 15, flags: required))
        XCTAssertTrue(filter.shouldSwallow(type: .keyUp, keyCode: 15, flags: 0))
        XCTAssertFalse(filter.shouldSwallow(type: .keyUp, keyCode: 15, flags: 0))
    }

    func testChordToleratesExtraFlagBits() {
        var filter = HotkeyTapFilter(trigger: .chord(modifiers: ["control"], keyCode: 80))
        let flags = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 80).chordEventFlags
            | CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertTrue(filter.shouldSwallow(type: .keyDown, keyCode: 80, flags: flags))
    }

    func testTapReenabledResyncsChordKeyUpToPhysicalState() {
        var filter = HotkeyTapFilter(trigger: chord)
        filter.tapReenabled(triggerKeyPressed: true)
        XCTAssertTrue(filter.shouldSwallow(type: .keyUp, keyCode: 15, flags: 0))

        XCTAssertTrue(filter.shouldSwallow(type: .keyDown, keyCode: 15, flags: chord.chordEventFlags))
        filter.tapReenabled(triggerKeyPressed: false)
        XCTAssertFalse(filter.shouldSwallow(type: .keyUp, keyCode: 15, flags: 0))
    }
}
