import XCTest
@testable import MacParakeetCore

final class KeyActionTests: XCTestCase {
    func testKeyActionKeyCodes() {
        XCTAssertEqual(KeyAction.returnKey.keyCode, 0x24)
    }

    func testKeyActionCodable() throws {
        for action in KeyAction.allCases {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(KeyAction.self, from: data)
            XCTAssertEqual(decoded, action)
        }
    }

    func testKeyActionLabels() {
        XCTAssertFalse(KeyAction.returnKey.label.isEmpty)
    }

    func testKeyActionRawValues() {
        XCTAssertEqual(KeyAction.returnKey.rawValue, "return")
    }

    func testKeyActionAllCasesCount() {
        XCTAssertEqual(KeyAction.allCases.count, 1)
    }
}
