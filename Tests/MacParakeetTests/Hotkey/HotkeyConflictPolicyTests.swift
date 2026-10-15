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
        dictationAIPolish: HotkeyTrigger = .disabled,
        alternateHandsFree: HotkeyTrigger = .disabled,
        alternatePushToTalk: HotkeyTrigger = .disabled,
        transformHotkeys: [Prompt] = [],
        meetingRecordingEnabled: Bool = true
    ) -> HotkeyConflictPolicy.SettingsSnapshot {
        HotkeyConflictPolicy.SettingsSnapshot(
            handsFree: handsFree,
            pushToTalk: pushToTalk,
            meeting: meeting,
            fileTranscription: fileTranscription,
            youtubeTranscription: youtubeTranscription,
            dictationAIPolish: dictationAIPolish,
            alternateHandsFree: alternateHandsFree,
            alternatePushToTalk: alternatePushToTalk,
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

    func testAIPolishShortcutCannotClaimATransformHotkey() {
        let transform = Prompt(
            name: "Polish",
            content: "body",
            category: .transform,
            keyboardShortcut: opt1.encodedString()
        )

        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: opt1.hotkeyTrigger,
                surface: .dictationAIPolish,
                snapshot: snapshot(transformHotkeys: [transform])
            ),
            .blocked("Conflicts with Transform Polish (⌥1).")
        )
    }

    func testSettingsPolicyBlocksAIPolishConflictWithHandsFree() {
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: .control,
                surface: .dictationAIPolish,
                snapshot: snapshot(handsFree: .control)
            ),
            .blocked("Conflicts with hands-free mode (⌃ Control).")
        )
    }

    func testSettingsPolicyBlocksAIPolishChordSharingBareModifierHandsFree() {
        let commandP = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 35)
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: commandP,
                surface: .dictationAIPolish,
                snapshot: snapshot(handsFree: .command)
            ),
            .blocked("Conflicts with hands-free mode (⌘ Command).")
        )
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: .command,
                surface: .handsFreeDictation,
                snapshot: snapshot(dictationAIPolish: commandP)
            ),
            .blocked("Conflicts with AI-polished dictation (\(commandP.formattedLabel)).")
        )
    }

    func testSettingsPolicyAllowsBareAIPolishModifierWithAuxiliaryChords() {
        let controlF = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 3)
        let surfaces: [HotkeyConflictPolicy.Surface] = [
            .meetingRecording, .fileTranscription, .youtubeTranscription,
        ]

        for surface in surfaces {
            let configured = snapshot(
                handsFree: .disabled,
                pushToTalk: .disabled,
                meeting: surface == .meetingRecording ? controlF : .disabled,
                fileTranscription: surface == .fileTranscription ? controlF : .disabled,
                youtubeTranscription: surface == .youtubeTranscription ? controlF : .disabled,
                dictationAIPolish: .control
            )
            XCTAssertEqual(
                HotkeyConflictPolicy.settingsValidation(
                    candidate: controlF,
                    surface: surface,
                    snapshot: configured
                ),
                .allowed
            )
            XCTAssertEqual(
                HotkeyConflictPolicy.settingsValidation(
                    candidate: .control,
                    surface: .dictationAIPolish,
                    snapshot: configured
                ),
                .allowed
            )
        }
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
    func testAdditionalPairCanShareDeleteWithoutConflictingWithFn() {
        let key = HotkeyTrigger.fromKeyCode(117)
        let settings = snapshot(handsFree: .fn, pushToTalk: .fn, alternateHandsFree: key, alternatePushToTalk: key)
        for surface: HotkeyConflictPolicy.Surface in [.alternateHandsFree, .alternatePushToTalk] {
            XCTAssertEqual(
                HotkeyConflictPolicy.settingsValidation(candidate: key, surface: surface, snapshot: settings), .allowed)
        }
    }

    func testAdditionalShortcutsConflictInBothDirectionsWithEveryOtherSurface() {
        let key = HotkeyTrigger.chord(modifiers: ["control", "option"], keyCode: 20)
        let settings = snapshot(alternateHandsFree: key)
        for surface: HotkeyConflictPolicy.Surface in [
            .handsFreeDictation, .pushToTalk, .meetingRecording, .fileTranscription, .youtubeTranscription,
            .dictationAIPolish,
        ] {
            guard
                case .blocked = HotkeyConflictPolicy.settingsValidation(
                    candidate: key, surface: surface, snapshot: settings)
            else {
                return XCTFail("Expected conflict on \(surface)")
            }
        }
        for settings in [
            snapshot(handsFree: key), snapshot(pushToTalk: key), snapshot(meeting: key),
            snapshot(fileTranscription: key), snapshot(youtubeTranscription: key), snapshot(dictationAIPolish: key),
        ] {
            for surface: HotkeyConflictPolicy.Surface in [.alternateHandsFree, .alternatePushToTalk] {
                guard
                    case .blocked = HotkeyConflictPolicy.settingsValidation(
                        candidate: key, surface: surface, snapshot: settings)
                else {
                    return XCTFail("Expected reverse conflict on \(surface)")
                }
            }
        }
    }

    func testAdditionalPairBlocksNonidenticalOverlapsAndAllowsDisable() {
        let settings = snapshot(alternatePushToTalk: .command)
        let right = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        guard
            case .blocked = HotkeyConflictPolicy.settingsValidation(
                candidate: right, surface: .alternateHandsFree, snapshot: settings)
        else {
            return XCTFail("Generic and side-specific modifiers overlap")
        }
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: .disabled, surface: .alternateHandsFree, snapshot: settings), .allowed)
    }

    func testPersistedAdditionalPairConflictNamesCorrectRowAndPreservesHandsFree() {
        let right = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let settings = snapshot(alternateHandsFree: .command, alternatePushToTalk: right)
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsConflictMessage(
                for: .command, surface: .alternateHandsFree, snapshot: settings),
            SettingsHotkeyConflictMessage.blocked(conflictingWith: "additional push-to-talk shortcut", trigger: right))
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsConflictMessage(for: right, surface: .alternatePushToTalk, snapshot: settings),
            SettingsHotkeyConflictMessage.disabled(conflictingWith: "additional hands-free shortcut", trigger: .command)
        )
    }

    // MARK: - Chords on one terminal key

    private let commandK = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 40)
    private let optionK = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 40)

    /// Two keyboards can both send the key, and a held take cannot tell whose
    /// release it sees, so an additional chord may not share a key with another pair.
    func testAdditionalChordCannotShareATerminalKeyWithAnotherPairInEitherDirection() {
        XCTAssertFalse(commandK.overlaps(with: optionK), "Different modifiers do not overlap")
        let primaryRoles = [
            snapshot(handsFree: commandK), snapshot(pushToTalk: commandK), snapshot(dictationAIPolish: commandK),
        ]
        for settings in primaryRoles {
            for surface: HotkeyConflictPolicy.Surface in [.alternateHandsFree, .alternatePushToTalk] {
                guard
                    case .blocked = HotkeyConflictPolicy.settingsValidation(
                        candidate: optionK, surface: surface, snapshot: settings)
                else {
                    return XCTFail("Expected an additional \(surface) chord to collide on the shared key")
                }
            }
        }
        for settings in [snapshot(alternateHandsFree: commandK), snapshot(alternatePushToTalk: commandK)] {
            for surface: HotkeyConflictPolicy.Surface in [.handsFreeDictation, .pushToTalk, .dictationAIPolish] {
                guard
                    case .blocked = HotkeyConflictPolicy.settingsValidation(
                        candidate: optionK, surface: surface, snapshot: settings)
                else {
                    return XCTFail("Expected a \(surface) chord to collide with the additional chord's key")
                }
            }
        }
    }

    func testPersistedAdditionalChordOnAnotherPairsKeyIsReportedAsDisabled() {
        // The runtime plan keeps the primary shortcut and drops the additional one.
        let settings = snapshot(handsFree: commandK, alternateHandsFree: optionK)
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsConflictMessage(
                for: optionK, surface: .alternateHandsFree, snapshot: settings),
            SettingsHotkeyConflictMessage.disabled(conflictingWith: "hands-free mode", trigger: commandK))
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsConflictMessage(
                for: commandK, surface: .handsFreeDictation, snapshot: settings),
            SettingsHotkeyConflictMessage.blocked(conflictingWith: "additional hands-free shortcut", trigger: optionK))
    }

    func testChordsMayStillShareAKeyWithinOnePair() {
        // Primary pair and AI polish keep their long-standing rules.
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: optionK, surface: .pushToTalk, snapshot: snapshot(handsFree: commandK)),
            .allowed)
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: optionK, surface: .dictationAIPolish, snapshot: snapshot(handsFree: commandK)),
            .allowed)
        // The additional pair follows the same role policy as the primary pair.
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: optionK, surface: .alternatePushToTalk, snapshot: snapshot(alternateHandsFree: commandK)),
            .allowed)
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: commandK, surface: .alternatePushToTalk, snapshot: snapshot(alternateHandsFree: commandK)),
            .allowed)
    }

    func testAdditionalChordMayShareAKeyWithAKeyOrModifierShortcutThatDoesNotOverlap() {
        let settings = snapshot(handsFree: .fn, pushToTalk: .fn, alternateHandsFree: commandK)
        let otherKey = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 41)
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: otherKey, surface: .alternatePushToTalk, snapshot: settings),
            .allowed)
        XCTAssertEqual(
            HotkeyConflictPolicy.settingsValidation(
                candidate: optionK, surface: .meetingRecording, snapshot: settings),
            .allowed, "Only dictation takes can be ended by a peer's key release")
    }

}
