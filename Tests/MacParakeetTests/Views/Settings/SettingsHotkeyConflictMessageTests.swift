import XCTest
import MacParakeetCore
@testable import MacParakeet

final class SettingsHotkeyConflictMessageTests: XCTestCase {
    func testDisabledConflictMessageNamesRowAndFormattedLabel() {
        let trigger = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )

        XCTAssertEqual(
            SettingsHotkeyConflictMessage.disabled(conflictingWith: "push to talk", trigger: trigger),
            "Disabled — conflicts with push to talk (R⌘ Right Command)."
        )
    }

    func testBlockedConflictMessageNamesRowAndFormattedLabel() {
        XCTAssertEqual(
            SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "meeting recording",
                trigger: .defaultMeetingRecording
            ),
            "Conflicts with meeting recording (⇧⌘M)."
        )
    }
}
