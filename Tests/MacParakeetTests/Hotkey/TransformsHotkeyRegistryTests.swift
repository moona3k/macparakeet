import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

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
            )
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

    func testHandleCommandShiftOneShortcutTriggers() throws {
        let registry = TransformsHotkeyRegistry()
        let id = UUID()
        registry.register(
            promptID: id,
            shortcut: KeyboardShortcut(
                modifiers: KeyboardShortcut.ModifierFlag.command.rawValue
                    | KeyboardShortcut.ModifierFlag.shift.rawValue,
                keyCode: 0x12,
                keyLabel: "1"
            )
        )

        var triggeredIDs: [UUID] = []
        registry.onTrigger = { triggeredIDs.append($0) }

        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x12, keyDown: true))
        keyDown.flags = [.maskCommand, .maskShift]

        XCTAssertNil(registry.handleEvent(type: .keyDown, event: keyDown))
        XCTAssertEqual(triggeredIDs, [id])
    }

    func testTapDisabledRecoveryClearsPressedKeyState() throws {
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

        var triggerCount = 0
        registry.onTrigger = { _ in triggerCount += 1 }

        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x12, keyDown: true))
        keyDown.flags = .maskAlternate

        XCTAssertNil(registry.handleEvent(type: .keyDown, event: keyDown))
        XCTAssertEqual(triggerCount, 1)

        let disabled = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x12, keyDown: true))
        XCTAssertNotNil(registry.handleEvent(type: .tapDisabledByTimeout, event: disabled))

        XCTAssertNil(registry.handleEvent(type: .keyDown, event: keyDown))
        XCTAssertEqual(triggerCount, 2)
    }

}
