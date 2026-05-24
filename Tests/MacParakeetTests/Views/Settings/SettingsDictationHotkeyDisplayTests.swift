import XCTest
import MacParakeetCore
@testable import MacParakeet

final class SettingsDictationHotkeyDisplayTests: XCTestCase {
    func testDefaultFnSharedGestureKeepsExistingPushToTalkLabel() {
        XCTAssertNil(
            SettingsDictationHotkeyDisplay.pushToTalkDisplayLabelOverride(
                pushToTalk: .fn,
                handsFree: .fn
            )
        )
        XCTAssertEqual(
            SettingsDictationHotkeyDisplay.handsFreeDisplayLabelOverride(
                handsFree: .fn,
                pushToTalk: .fn
            ),
            "Double-tap Fn"
        )
    }

    func testSharedLeftShiftUsesRoleSpecificCompactLabels() {
        let leftShift = HotkeyTrigger(
            kind: .modifier,
            modifierName: "shift",
            keyCode: nil,
            modifierKeyCode: 56
        )

        XCTAssertEqual(
            SettingsDictationHotkeyDisplay.pushToTalkDisplayLabelOverride(
                pushToTalk: leftShift,
                handsFree: leftShift
            ),
            "Hold L⇧"
        )
        XCTAssertEqual(
            SettingsDictationHotkeyDisplay.handsFreeDisplayLabelOverride(
                handsFree: leftShift,
                pushToTalk: leftShift
            ),
            "Double-tap L⇧"
        )
    }

    func testSharedLeftCommandUsesRoleSpecificCompactLabels() {
        let leftCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 55
        )

        XCTAssertEqual(
            SettingsDictationHotkeyDisplay.pushToTalkDisplayLabelOverride(
                pushToTalk: leftCommand,
                handsFree: leftCommand
            ),
            "Hold L⌘"
        )
        XCTAssertEqual(
            SettingsDictationHotkeyDisplay.handsFreeDisplayLabelOverride(
                handsFree: leftCommand,
                pushToTalk: leftCommand
            ),
            "Double-tap L⌘"
        )
    }

    func testDistinctDictationHotkeysDoNotOverrideLabels() {
        XCTAssertNil(
            SettingsDictationHotkeyDisplay.pushToTalkDisplayLabelOverride(
                pushToTalk: .option,
                handsFree: .control
            )
        )
        XCTAssertNil(
            SettingsDictationHotkeyDisplay.handsFreeDisplayLabelOverride(
                handsFree: .control,
                pushToTalk: .option
            )
        )
    }

    func testHandsFreeDefaultLabelOnlyDescribesSharedDefault() {
        XCTAssertEqual(
            SettingsDictationHotkeyDisplay.handsFreeDefaultLabelOverride(
                pushToTalk: .fn
            ),
            "Double-tap Fn"
        )
        XCTAssertNil(
            SettingsDictationHotkeyDisplay.handsFreeDefaultLabelOverride(
                pushToTalk: .option
            )
        )
    }
}
