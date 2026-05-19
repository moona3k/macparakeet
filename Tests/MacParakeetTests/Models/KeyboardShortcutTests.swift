import XCTest
@testable import MacParakeetCore

final class KeyboardShortcutTests: XCTestCase {

    // MARK: - Round-trip

    func testCodableRoundTrip() throws {
        let shortcut = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue,
            keyCode: 0x23,
            keyLabel: "P"
        )
        let encoded = try XCTUnwrap(shortcut.encodedString())
        let decoded = try XCTUnwrap(KeyboardShortcut.decoded(from: encoded))
        XCTAssertEqual(decoded, shortcut)
    }

    func testDecodedFromMalformedReturnsNil() {
        XCTAssertNil(KeyboardShortcut.decoded(from: nil))
        XCTAssertNil(KeyboardShortcut.decoded(from: "not json"))
        XCTAssertNil(KeyboardShortcut.decoded(from: "{}"))
    }

    // MARK: - Display

    func testDisplayStringUsesCanonicalMacOSOrder() {
        // Canonical order is ⌃ ⌥ ⇧ ⌘ regardless of which order the bits are
        // set in the underlying integer.
        let allFour = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.command.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue
                | KeyboardShortcut.ModifierFlag.option.rawValue
                | KeyboardShortcut.ModifierFlag.control.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        XCTAssertEqual(allFour.displayString, "⌃⌥⇧⌘1")
    }

    func testDisplayStringUppercasesKeyLabel() {
        let lowercase = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x23,
            keyLabel: "p"
        )
        XCTAssertEqual(lowercase.displayString, "⌥P")
    }

    func testDisplayStringNormalizesShiftedDigitLabel() {
        let shiftedDigit = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.command.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue,
            keyCode: 0x12,
            keyLabel: "!"
        )

        XCTAssertEqual(shiftedDigit.displayKeyLabel, "1")
        XCTAssertEqual(shiftedDigit.displayString, "⇧⌘1")
    }

    // MARK: - Modifier introspection

    func testHasModifierIsFalseWithoutAnyModifiers() {
        let bare = KeyboardShortcut(modifiers: 0, keyCode: 0x12, keyLabel: "1")
        XCTAssertFalse(bare.hasModifier)
        XCTAssertTrue(bare.modifierFlags.isEmpty)
    }

    func testHasModifierIsTrueWithSingleModifier() {
        let opt = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        XCTAssertTrue(opt.hasModifier)
        XCTAssertEqual(opt.modifierFlags, [.option])
    }

    // MARK: - Dead-key detection

    func testOptionPlusEIsRecognizedAsDeadKey() {
        let optE = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x0E,
            keyLabel: "E"
        )
        XCTAssertTrue(optE.isMacOSDeadKey)
    }

    func testOptionPlusOneIsNotDeadKey() {
        let optOne = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        XCTAssertFalse(optOne.isMacOSDeadKey)
    }

    func testOptionShiftEIsNotDeadKey() {
        // Adding shift takes us out of the dead-key territory.
        let optShiftE = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue,
            keyCode: 0x0E,
            keyLabel: "E"
        )
        XCTAssertFalse(optShiftE.isMacOSDeadKey)
    }

    // MARK: - CLI parsing

    func testParseOptDigit() {
        let parsed = try? XCTUnwrap(KeyboardShortcut.parse("opt+1"))
        XCTAssertEqual(parsed?.modifierFlags, [.option])
        XCTAssertEqual(parsed?.keyLabel, "1")
        XCTAssertEqual(parsed?.keyCode, 0x12)
    }

    func testParseIsCaseAndOrderInsensitive() {
        let parsed = try? XCTUnwrap(KeyboardShortcut.parse("SHIFT+cmd+P"))
        XCTAssertEqual(parsed?.modifierFlags, [.command, .shift])
        XCTAssertEqual(parsed?.keyLabel, "P")
    }

    func testParseAcceptsHyphenOrSpaceSeparators() {
        let plus = KeyboardShortcut.parse("opt+1")
        let dash = KeyboardShortcut.parse("opt-1")
        let spc  = KeyboardShortcut.parse("opt 1")
        XCTAssertEqual(plus, dash)
        XCTAssertEqual(plus, spc)
    }

    func testParseAcceptsGlyphAliases() {
        let parsed = try? XCTUnwrap(KeyboardShortcut.parse("⌥+⇧+P"))
        XCTAssertEqual(parsed?.modifierFlags, [.option, .shift])
        XCTAssertEqual(parsed?.keyLabel, "P")
    }

    func testParseRejectsTwoNonModifierTokens() {
        XCTAssertNil(KeyboardShortcut.parse("opt+1+2"))
        XCTAssertNil(KeyboardShortcut.parse("a+b"))
    }

    func testParseRejectsModifierOnly() {
        XCTAssertNil(KeyboardShortcut.parse("opt"))
        XCTAssertNil(KeyboardShortcut.parse("cmd+shift"))
    }

    func testParseRejectsUnknownKey() {
        XCTAssertNil(KeyboardShortcut.parse("opt+f24"))
    }

    func testParseRecognizesNamedKeys() {
        let space = try? XCTUnwrap(KeyboardShortcut.parse("ctrl+opt+space"))
        XCTAssertEqual(space?.keyCode, 0x31)
        XCTAssertEqual(space?.keyLabel, "Space")
    }
}
