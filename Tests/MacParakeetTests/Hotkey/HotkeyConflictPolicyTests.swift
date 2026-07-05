import XCTest
@testable import MacParakeetCore

final class HotkeyConflictPolicyTests: XCTestCase {
    private let checker = TransformsHotkeyCollisionChecker()

    private let opt1 = KeyboardShortcut(
        modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
        keyCode: 0x12,
        keyLabel: "1"
    )

    private let opt2 = KeyboardShortcut(
        modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
        keyCode: 0x13,
        keyLabel: "2"
    )

    private func snapshot(
        handsFree: HotkeyTrigger = .disabled,
        pushToTalk: HotkeyTrigger = .disabled,
        meeting: HotkeyTrigger = .disabled,
        fileTranscription: HotkeyTrigger = .disabled,
        youtubeTranscription: HotkeyTrigger = .disabled,
        transformHotkeys: [Prompt] = [],
        meetingRecordingEnabled: Bool = true
    ) -> HotkeyConflictPolicy.SettingsSnapshot {
        HotkeyConflictPolicy.SettingsSnapshot(
            handsFree: handsFree,
            pushToTalk: pushToTalk,
            meeting: meeting,
            fileTranscription: fileTranscription,
            youtubeTranscription: youtubeTranscription,
            transformHotkeys: transformHotkeys,
            meetingRecordingEnabled: meetingRecordingEnabled
        )
    }

    func testTransformShortcutCollisionMessagesAreSnapshotted() {
        XCTAssertEqual(
            TransformShortcutCollision.missingModifier.message,
            "Shortcut must include a modifier key (\u{2303}, \u{2325}, \u{21E7}, or \u{2318})."
        )
        XCTAssertEqual(
            TransformShortcutCollision.macOSDeadKey.message,
            "This shortcut produces a special character on Mac. Pick another combo."
        )
        XCTAssertEqual(
            TransformShortcutCollision.duplicateTransform(otherPromptID: UUID()).message,
            "Another Transform already uses this shortcut."
        )
        XCTAssertEqual(
            TransformShortcutCollision.reservedHotkey(name: "push to talk").message,
            "This shortcut conflicts with push to talk."
        )
    }

    func testSettingsConflictMessagesAreSnapshotted() {
        let rightCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )
        XCTAssertEqual(
            SettingsHotkeyConflictMessage.disabled(conflictingWith: "push to talk", trigger: rightCommand),
            "Disabled — conflicts with push to talk (R⌘ Right Command)."
        )
        XCTAssertEqual(
            SettingsHotkeyConflictMessage.blocked(
                conflictingWith: "meeting recording",
                trigger: .defaultMeetingRecording
            ),
            "Conflicts with meeting recording (⇧⌘M)."
        )
    }

    func testTransformCollisionMissingModifierIsRejected() {
        let bareKey = KeyboardShortcut(modifiers: 0, keyCode: 0x12, keyLabel: "1")
        XCTAssertEqual(
            checker.check(
                candidate: bareKey,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: []
            ),
            .missingModifier
        )
    }

    func testTransformCollisionMacOSDeadKeyIsRejected() {
        let optE = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x0E,
            keyLabel: "E"
        )
        XCTAssertEqual(
            checker.check(
                candidate: optE,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: []
            ),
            .macOSDeadKey
        )
    }

    func testTransformCollisionDuplicateTransformReturnsOtherID() {
        let otherID = UUID()
        let result = checker.check(
            candidate: opt1,
            existing: [otherID: opt1],
            excludingPromptID: nil,
            reservedHotkeys: []
        )
        XCTAssertEqual(result, .duplicateTransform(otherPromptID: otherID))
    }

    func testTransformCollisionDuplicateIgnoresExcludedPromptID() {
        let selfID = UUID()
        XCTAssertNil(
            checker.check(
                candidate: opt1,
                existing: [selfID: opt1],
                excludingPromptID: selfID,
                reservedHotkeys: []
            )
        )
    }

    func testTransformCollisionReservedHotkeyConflictReturnsName() {
        XCTAssertEqual(
            checker.check(
                candidate: opt1,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [
                    TransformShortcutReservedHotkey(name: "push to talk", trigger: opt1.hotkeyTrigger)
                ]
            ),
            .reservedHotkey(name: "push to talk")
        )
    }

    func testTransformCollisionModifierOnlyReservedHotkeyConflictsWithChordUsingThatModifier() {
        XCTAssertEqual(
            checker.check(
                candidate: opt1,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [
                    TransformShortcutReservedHotkey(name: "hands-free dictation", trigger: .option)
                ]
            ),
            .reservedHotkey(name: "hands-free dictation")
        )
    }

    func testTransformCollisionModifierChordReservedHotkeyDoesNotConflictWithSubsetTransformChord() {
        let opt4 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x15,
            keyLabel: "4"
        )
        XCTAssertNil(
            checker.check(
                candidate: opt4,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [
                    TransformShortcutReservedHotkey(name: "hands-free dictation", trigger: .fn),
                    TransformShortcutReservedHotkey(
                        name: "meeting recording",
                        trigger: .modifierChord(modifiers: ["option", "command"])
                    ),
                ]
            )
        )
    }

    func testTransformCollisionDisabledReservedHotkeyIsIgnored() {
        XCTAssertNil(
            checker.check(
                candidate: opt1,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [
                    TransformShortcutReservedHotkey(name: "file transcription", trigger: .disabled)
                ]
            )
        )
    }

    func testTransformCollisionBareModifierDictationReservedHotkeyAllowsChordUsingThatModifier() {
        XCTAssertNil(
            checker.check(
                candidate: opt1,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [
                    TransformShortcutReservedHotkey(
                        name: "push to talk",
                        trigger: .option,
                        conflictMode: .bareModifierDictation
                    )
                ]
            )
        )
    }

    func testTransformCollisionPriorityModifierBeatsDuplicate() {
        let bare = KeyboardShortcut(modifiers: 0, keyCode: 0x12, keyLabel: "1")
        let result = checker.check(
            candidate: bare,
            existing: [UUID(): bare],
            excludingPromptID: nil,
            reservedHotkeys: []
        )
        XCTAssertEqual(result, .missingModifier)
    }

    func testTransformCollisionAcceptsValidCandidate() {
        XCTAssertNil(
            checker.check(
                candidate: opt2,
                existing: [UUID(): opt1],
                excludingPromptID: nil,
                reservedHotkeys: []
            )
        )
    }

    func testSettingsPolicyAllowsTranscriptionChordSharingWithBareModifierDictation() {
        let commandOne = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 0x12)

        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: commandOne,
                surface: .fileTranscription,
                snapshot: snapshot(handsFree: .command)
            ),
            .allowed
        )
    }

    func testSettingsPolicyBlocksAppSurfaceConflictInOrder() {
        let result = HotkeyConflictPolicy.settingsValidation(
            candidate: .defaultMeetingRecording,
            surface: .fileTranscription,
            snapshot: snapshot(meeting: .defaultMeetingRecording)
        )

        XCTAssertEqual(result, .blocked("Conflicts with meeting recording (⇧⌘M)."))
    }

    func testSettingsPolicyBlocksTransformHotkeyConflict() {
        let transform = Prompt(
            name: "Polish",
            content: "body",
            category: .transform,
            keyboardShortcut: opt1.encodedString()
        )

        let result = HotkeyConflictPolicy.settingsValidation(
            candidate: opt1.hotkeyTrigger,
            surface: .fileTranscription,
            snapshot: snapshot(transformHotkeys: [transform])
        )

        XCTAssertEqual(result, .blocked("Conflicts with Transform Polish (⌥1)."))
    }

    func testSettingsPolicyExistingDictationPeerMessagePreservesBlockedVsDisabled() {
        let rightCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )

        XCTAssertEqual(
            HotkeyConflictPolicy.settingsConflictMessage(
                for: rightCommand,
                surface: .handsFreeDictation,
                snapshot: snapshot(pushToTalk: .command)
            ),
            "Conflicts with push to talk (⌘ Command)."
        )
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsConflictMessage(
                for: rightCommand,
                surface: .pushToTalk,
                snapshot: snapshot(handsFree: .command)
            ),
            "Disabled — conflicts with hands-free mode (⌘ Command)."
        )
    }

    func testSettingsPolicyIgnoresDisabledTriggers() {
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: opt2.hotkeyTrigger,
                surface: .youtubeTranscription,
                snapshot: snapshot(
                    handsFree: .disabled,
                    pushToTalk: .disabled,
                    meeting: .disabled,
                    fileTranscription: .disabled
                )
            ),
            .allowed
        )
    }

    func testRuntimeRegistrationPolicyReturnsOnlyConflictingEnabledTriggers() {
        let conflicts = HotkeyConflictPolicy.conflictingTriggers(
            for: opt1.hotkeyTrigger,
            among: [
                .init(.disabled),
                .init(.option, mode: .bareModifierDictation),
                .init(opt1.hotkeyTrigger),
            ]
        )

        XCTAssertEqual(conflicts, [opt1.hotkeyTrigger])
    }
}
