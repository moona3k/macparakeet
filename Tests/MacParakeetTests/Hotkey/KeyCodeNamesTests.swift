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

    // MARK: - Unknown Key Codes

    func testUnknownKeyCodeReturnsFallback() {
        let result = KeyCodeNames.name(for: 255)
        XCTAssertEqual(result.displayName, "Key 255")
        XCTAssertEqual(result.shortSymbol, "Key 255")
    }

    func testUnknownKeyCodeZero() {
        let result = KeyCodeNames.name(for: 0)
        XCTAssertEqual(result.displayName, "Key 0")
        XCTAssertEqual(result.shortSymbol, "Key 0")
    }
}
