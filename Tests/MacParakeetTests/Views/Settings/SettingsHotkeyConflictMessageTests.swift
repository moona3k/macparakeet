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

    func testDictationPeerValidationBlocksExactDuplicate() {
        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.validation(
                candidate: .fn,
                peer: .fn,
                peerName: "push to talk"
            ),
            .blocked("Conflicts with push to talk (🌐 Fn).")
        )
    }

    func testDictationPeerValidationBlocksOverlappingDistinctTrigger() {
        let rightCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )
        let genericCommand = HotkeyTrigger.command

        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.validation(
                candidate: rightCommand,
                peer: genericCommand,
                peerName: "hands-free mode"
            ),
            .blocked("Conflicts with hands-free mode (⌘ Command).")
        )
    }

    func testDictationPeerValidationAllowsDistinctDefaults() {
        XCTAssertNil(
            SettingsDictationHotkeyConflictPolicy.validation(
                candidate: .defaultDictation,
                peer: .defaultPushToTalk,
                peerName: "push to talk"
            )
        )
    }

    func testExistingDictationPeerConflictMessageCanNameActiveTrigger() {
        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.existingConflictMessage(
                trigger: .fn,
                peer: .fn,
                peerName: "push to talk",
                disablesTrigger: false
            ),
            "Conflicts with push to talk (🌐 Fn)."
        )
    }

    func testExistingDictationPeerConflictMessageCanNameDisabledTrigger() {
        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.existingConflictMessage(
                trigger: .fn,
                peer: .fn,
                peerName: "hands-free mode",
                disablesTrigger: true
            ),
            "Disabled — conflicts with hands-free mode (🌐 Fn)."
        )
    }
}
