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

    func testDictationPeerValidationAllowsDefaultFnGesturePreset() {
        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.validation(
                candidate: .fn,
                peer: .fn,
                peerName: "push to talk"
            ),
            nil
        )
    }

    func testDictationPeerValidationAllowsNonDefaultExactDuplicate() {
        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.validation(
                candidate: .control,
                peer: .control,
                peerName: "push to talk"
            ),
            nil
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

    func testDictationPeerValidationAllowsDuplicateSideSpecificShiftChord() {
        let bothShifts = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "shift", keyCode: 56),
                .init(modifierName: "shift", keyCode: 60),
            ]
        )

        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.validation(
                candidate: bothShifts,
                peer: bothShifts,
                peerName: "push to talk"
            ),
            nil
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

    func testExistingDictationPeerConflictMessageAllowsDefaultFnGesturePreset() {
        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.existingConflictMessage(
                trigger: .fn,
                peer: .fn,
                peerName: "push to talk",
                disablesTrigger: false
            ),
            nil
        )
    }

    func testExistingDictationPeerConflictMessageAllowsExactSharedTrigger() {
        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.existingConflictMessage(
                trigger: .control,
                peer: .control,
                peerName: "push to talk",
                disablesTrigger: false
            ),
            nil
        )
    }

    func testExistingDictationPeerConflictMessageCanNameDisabledTrigger() {
        let rightCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )

        XCTAssertEqual(
            SettingsDictationHotkeyConflictPolicy.existingConflictMessage(
                trigger: rightCommand,
                peer: .command,
                peerName: "hands-free mode",
                disablesTrigger: true
            ),
            "Disabled — conflicts with hands-free mode (⌘ Command)."
        )
    }
}
