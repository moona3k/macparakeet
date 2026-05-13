import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class TransformsHotkeyRegistryTests: XCTestCase {

    // MARK: - Dispatch table

    func testRegisterReplacesPriorBindingForSamePromptID() {
        let registry = TransformsHotkeyRegistry()
        let id = UUID()

        let opt1 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        let opt2 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x13,
            keyLabel: "2"
        )

        registry.register(promptID: id, shortcut: opt1)
        XCTAssertFalse(registry.isEmpty)

        // Rebinding the same prompt to a new shortcut drops the old binding.
        registry.register(promptID: id, shortcut: opt2)

        // Re-binding twice means the only mapping should still be one entry,
        // and the old opt1 slot is free.
        registry.unregister(promptID: id)
        XCTAssertTrue(registry.isEmpty)
    }

    func testUnregisterDropsBinding() {
        let registry = TransformsHotkeyRegistry()
        let id = UUID()
        registry.register(
            promptID: id,
            shortcut: KeyboardShortcut(
                modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                keyCode: 0x12,
                keyLabel: "1"
            )
        )
        XCTAssertFalse(registry.isEmpty)
        registry.unregister(promptID: id)
        XCTAssertTrue(registry.isEmpty)
    }

    func testRegisterNilShortcutIsUnbind() {
        let registry = TransformsHotkeyRegistry()
        let id = UUID()
        registry.register(
            promptID: id,
            shortcut: KeyboardShortcut(
                modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                keyCode: 0x12,
                keyLabel: "1"
            )
        )
        registry.register(promptID: id, shortcut: nil)
        XCTAssertTrue(registry.isEmpty)
    }

    func testReplaceBindingsRebuildsTableFromScratch() {
        let registry = TransformsHotkeyRegistry()
        let a = UUID()
        let b = UUID()
        registry.register(
            promptID: a,
            shortcut: KeyboardShortcut(
                modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                keyCode: 0x12,
                keyLabel: "1"
            )
        )

        registry.replaceBindings([
            b: KeyboardShortcut(
                modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                keyCode: 0x13,
                keyLabel: "2"
            ),
        ])

        // The previous binding for `a` is gone, only `b` remains.
        XCTAssertFalse(registry.isEmpty)
        // (We can't introspect the dispatch table directly, but the empty
        // check + the unbind below confirms the reset.)
        registry.unregister(promptID: a)
        XCTAssertFalse(registry.isEmpty)
        registry.unregister(promptID: b)
        XCTAssertTrue(registry.isEmpty)
    }

    func testHandleKeyUpSwallowsOwnedShortcutEvenAfterModifiersClear() throws {
        let registry = TransformsHotkeyRegistry()
        let id = UUID()
        registry.register(
            promptID: id,
            shortcut: KeyboardShortcut(
                modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
                keyCode: 0x12,
                keyLabel: "1"
            )
        )

        var triggeredIDs: [UUID] = []
        registry.onTrigger = { triggeredIDs.append($0) }

        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x12, keyDown: true))
        keyDown.flags = .maskAlternate

        XCTAssertNil(registry.handleEvent(type: .keyDown, event: keyDown))
        XCTAssertEqual(triggeredIDs, [id])

        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x12, keyDown: false))
        keyUp.flags = []

        XCTAssertNil(registry.handleEvent(type: .keyUp, event: keyUp))

        let unrelatedKeyUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x13, keyDown: false))
        XCTAssertNotNil(registry.handleEvent(type: .keyUp, event: unrelatedKeyUp))
    }

    // MARK: - Collision detection

    private let checker = TransformsHotkeyCollisionChecker()

    private func reserved(_ name: String, _ trigger: HotkeyTrigger) -> TransformShortcutReservedHotkey {
        TransformShortcutReservedHotkey(name: name, trigger: trigger)
    }

    func testCollisionMissingModifierIsRejected() {
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

    func testCollisionMacOSDeadKeyIsRejected() {
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

    func testCollisionDuplicateTransformReturnsOtherID() {
        let opt1 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        let otherID = UUID()
        let result = checker.check(
            candidate: opt1,
            existing: [otherID: opt1],
            excludingPromptID: nil,
                reservedHotkeys: []
        )
        XCTAssertEqual(result, .duplicateTransform(otherPromptID: otherID))
    }

    func testCollisionDuplicateIgnoresExcludedPromptID() {
        let opt1 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        let selfID = UUID()
        // The user is re-saving their own Transform without changing its
        // shortcut; the existing binding shouldn't read as a duplicate.
        XCTAssertNil(
            checker.check(
                candidate: opt1,
                existing: [selfID: opt1],
                excludingPromptID: selfID,
                reservedHotkeys: []
            )
        )
    }

    func testCollisionDictationHotkeyConflictReturnsDictation() {
        let opt1 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        XCTAssertEqual(
            checker.check(
                candidate: opt1,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [reserved("Dictation", opt1.hotkeyTrigger)]
            ),
            .reservedHotkey(name: "Dictation", shortcut: opt1.hotkeyTrigger.formattedLabel)
        )
    }

    func testCollisionModifierOnlyDictationHotkeyConflictsWithChordUsingThatModifier() {
        let opt1 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        XCTAssertEqual(
            checker.check(
                candidate: opt1,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [reserved("Dictation", .option)]
            ),
            .reservedHotkey(name: "Dictation", shortcut: HotkeyTrigger.option.formattedLabel)
        )
    }

    func testCollisionModifierChordDictationHotkeyDoesNotConflictWithSubsetTransformChord() {
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
                    reserved("Dictation", .fn),
                    reserved("Push-to-talk", .modifierChord(modifiers: ["option", "command"])),
                ]
            )
        )
    }

    func testCollisionMeetingHotkeyConflictReturnsMeeting() {
        let opt1 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        XCTAssertEqual(
            checker.check(
                candidate: opt1,
                existing: [:],
                excludingPromptID: nil,
                reservedHotkeys: [reserved("Meeting recording", opt1.hotkeyTrigger)]
            ),
            .reservedHotkey(name: "Meeting recording", shortcut: opt1.hotkeyTrigger.formattedLabel)
        )
    }

    func testCollisionAcceptsValidCandidate() {
        let opt1 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        let opt2 = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x13,
            keyLabel: "2"
        )
        XCTAssertNil(
            checker.check(
                candidate: opt2,
                existing: [UUID(): opt1],
                excludingPromptID: nil,
                reservedHotkeys: []
            )
        )
    }

    func testCollisionPriorityModifierBeatsDuplicate() {
        // A bare-key candidate is rejected for missing-modifier even if
        // it would also be a duplicate. Modifier check runs first because
        // it's the more actionable user-facing error.
        let bare = KeyboardShortcut(modifiers: 0, keyCode: 0x12, keyLabel: "1")
        let result = checker.check(
            candidate: bare,
            existing: [UUID(): bare],
            excludingPromptID: nil,
                reservedHotkeys: []
        )
        XCTAssertEqual(result, .missingModifier)
    }
}
