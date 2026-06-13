import XCTest
@testable import MacParakeetCore

final class KeyCodeNamesTests: XCTestCase {

    // MARK: - Function Keys

    func testFunctionKeys() {
        XCTAssertEqual(KeyCodeNames.name(for: 122).displayName, "F1")
        XCTAssertEqual(KeyCodeNames.name(for: 120).displayName, "F2")
        XCTAssertEqual(KeyCodeNames.name(for: 99).displayName, "F3")
        XCTAssertEqual(KeyCodeNames.name(for: 105).displayName, "F13")
        XCTAssertEqual(KeyCodeNames.name(for: 90).displayName, "F20")
    }

    func testFunctionKeySymbols() {
        XCTAssertEqual(KeyCodeNames.name(for: 122).shortSymbol, "F1")
        XCTAssertEqual(KeyCodeNames.name(for: 105).shortSymbol, "F13")
    }

    // MARK: - Navigation Keys

    func testNavigationKeys() {
        XCTAssertEqual(KeyCodeNames.name(for: 115).displayName, "Home")
        XCTAssertEqual(KeyCodeNames.name(for: 119).displayName, "End")
        XCTAssertEqual(KeyCodeNames.name(for: 116).displayName, "Page Up")
        XCTAssertEqual(KeyCodeNames.name(for: 121).displayName, "Page Down")
        XCTAssertEqual(KeyCodeNames.name(for: 117).displayName, "Forward Delete")
        XCTAssertEqual(KeyCodeNames.name(for: 117).shortSymbol, "⌦")
    }

    // MARK: - Arrow Keys

    func testArrowKeys() {
        XCTAssertEqual(KeyCodeNames.name(for: 126).displayName, "Up Arrow")
        XCTAssertEqual(KeyCodeNames.name(for: 126).shortSymbol, "↑")
        XCTAssertEqual(KeyCodeNames.name(for: 125).shortSymbol, "↓")
        XCTAssertEqual(KeyCodeNames.name(for: 123).shortSymbol, "←")
        XCTAssertEqual(KeyCodeNames.name(for: 124).shortSymbol, "→")
    }

    // MARK: - Special Keys

    func testSpecialKeys() {
        XCTAssertEqual(KeyCodeNames.name(for: 48).displayName, "Tab")
        XCTAssertEqual(KeyCodeNames.name(for: 49).displayName, "Space")
        XCTAssertEqual(KeyCodeNames.name(for: 36).displayName, "Return")
        XCTAssertEqual(KeyCodeNames.name(for: 53).displayName, "Escape")
        XCTAssertEqual(KeyCodeNames.name(for: 57).displayName, "Caps Lock")
    }

    // MARK: - Letters

    func testLetterKeys() {
        XCTAssertEqual(KeyCodeNames.name(for: 0).displayName, "A")
        XCTAssertEqual(KeyCodeNames.name(for: 32).displayName, "U")
        XCTAssertEqual(KeyCodeNames.name(for: 6).displayName, "Z")
        XCTAssertEqual(KeyCodeNames.name(for: 0).shortSymbol, "A")
    }

    // MARK: - Numbers

    func testNumberKeys() {
        XCTAssertEqual(KeyCodeNames.name(for: 18).displayName, "1")
        XCTAssertEqual(KeyCodeNames.name(for: 29).displayName, "0")
    }

    // MARK: - Punctuation

    func testPunctuationKeys() {
        XCTAssertEqual(KeyCodeNames.name(for: 27).displayName, "-")
        XCTAssertEqual(KeyCodeNames.name(for: 24).displayName, "=")
        XCTAssertEqual(KeyCodeNames.name(for: 47).displayName, ".")
    }

    // MARK: - Unknown Key Codes

    func testUnknownKeyCodeReturnsFallback() {
        let result = KeyCodeNames.name(for: 255)
        XCTAssertEqual(result.displayName, "Key 255")
        XCTAssertEqual(result.shortSymbol, "Key 255")
    }

    // MARK: - Function-Family Classification

    func testFunctionFamilyKeyCodesIncludeFKeysArrowsAndNavCluster() {
        for keyCode: UInt16 in [122, 64, 80, 90, 126, 123, 115, 119, 117, 114] {
            XCTAssertTrue(KeyCodeNames.isFunctionFamilyKeyCode(keyCode), "keyCode \(keyCode)")
        }
    }

    func testFunctionFamilyKeyCodesExcludeTypingAndModifierKeys() {
        for keyCode: UInt16 in [0, 49, 53, 36, 57, 55, 63] {
            XCTAssertFalse(KeyCodeNames.isFunctionFamilyKeyCode(keyCode), "keyCode \(keyCode)")
        }
    }
}
