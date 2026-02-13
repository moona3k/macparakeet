import XCTest
@testable import MacParakeetCore

final class TriggerKeyTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.macparakeet.tests.triggerkey.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Raw Value Roundtrip

    func testRawValueRoundtripForAllCases() {
        for key in TriggerKey.allCases {
            let restored = TriggerKey(rawValue: key.rawValue)
            XCTAssertEqual(restored, key, "Roundtrip failed for \(key)")
        }
    }

    // MARK: - Display Name

    func testDisplayNames() {
        XCTAssertEqual(TriggerKey.fn.displayName, "Fn")
        XCTAssertEqual(TriggerKey.control.displayName, "Control")
        XCTAssertEqual(TriggerKey.option.displayName, "Option")
        XCTAssertEqual(TriggerKey.shift.displayName, "Shift")
        XCTAssertEqual(TriggerKey.command.displayName, "Command")
    }

    // MARK: - Short Symbol

    func testShortSymbols() {
        XCTAssertEqual(TriggerKey.fn.shortSymbol, "fn")
        XCTAssertEqual(TriggerKey.control.shortSymbol, "⌃")
        XCTAssertEqual(TriggerKey.option.shortSymbol, "⌥")
        XCTAssertEqual(TriggerKey.shift.shortSymbol, "⇧")
        XCTAssertEqual(TriggerKey.command.shortSymbol, "⌘")
    }

    // MARK: - Default Value

    func testCurrentDefaultsToFn() {
        // With no UserDefaults entry, .current should be .fn
        testDefaults.removeObject(forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current(defaults: testDefaults), .fn)
    }

    func testCurrentReadsFromUserDefaults() {
        testDefaults.set("control", forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current(defaults: testDefaults), .control)

        testDefaults.set("option", forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current(defaults: testDefaults), .option)

        // Clean up
        testDefaults.removeObject(forKey: "hotkeyTrigger")
    }

    func testCurrentFallsBackToFnForInvalidValue() {
        testDefaults.set("invalid_key", forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current(defaults: testDefaults), .fn)

        // Clean up
        testDefaults.removeObject(forKey: "hotkeyTrigger")
    }

    // MARK: - Codable

    func testCodableRoundtrip() throws {
        for key in TriggerKey.allCases {
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(TriggerKey.self, from: data)
            XCTAssertEqual(decoded, key, "Codable roundtrip failed for \(key)")
        }
    }

    // MARK: - All Cases

    func testAllCasesCount() {
        XCTAssertEqual(TriggerKey.allCases.count, 5)
    }
}
