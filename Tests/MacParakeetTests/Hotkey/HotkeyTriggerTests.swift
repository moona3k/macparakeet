import XCTest
@testable import MacParakeetCore

final class HotkeyTriggerTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.macparakeet.tests.hotkeytrigger.\(UUID().uuidString)"
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

    // MARK: - Modifier Presets

    func testModifierPresetsHaveCorrectKind() {
        for preset in HotkeyTrigger.modifierPresets {
            XCTAssertEqual(preset.kind, .modifier, "\(preset.displayName) should be .modifier")
            XCTAssertNotNil(preset.modifierName)
            XCTAssertNil(preset.keyCode)
        }
    }

    func testModifierPresetDisplayNames() {
        XCTAssertEqual(HotkeyTrigger.fn.displayName, "Fn")
        XCTAssertEqual(HotkeyTrigger.control.displayName, "Control")
        XCTAssertEqual(HotkeyTrigger.option.displayName, "Option")
        XCTAssertEqual(HotkeyTrigger.shift.displayName, "Shift")
        XCTAssertEqual(HotkeyTrigger.command.displayName, "Command")
    }

    func testModifierPresetShortSymbols() {
        XCTAssertEqual(HotkeyTrigger.fn.shortSymbol, "fn")
        XCTAssertEqual(HotkeyTrigger.control.shortSymbol, "⌃")
        XCTAssertEqual(HotkeyTrigger.option.shortSymbol, "⌥")
        XCTAssertEqual(HotkeyTrigger.shift.shortSymbol, "⇧")
        XCTAssertEqual(HotkeyTrigger.command.shortSymbol, "⌘")
    }

    func testModifierPresetsCount() {
        XCTAssertEqual(HotkeyTrigger.modifierPresets.count, 5)
    }

    // MARK: - Factory: fromKeyCode

    func testFromKeyCodeEnd() {
        let trigger = HotkeyTrigger.fromKeyCode(119)
        XCTAssertEqual(trigger.kind, .keyCode)
        XCTAssertEqual(trigger.keyCode, 119)
        XCTAssertNil(trigger.modifierName)
        XCTAssertEqual(trigger.displayName, "End")
        XCTAssertEqual(trigger.shortSymbol, "End")
    }

    func testFromKeyCodeF13() {
        let trigger = HotkeyTrigger.fromKeyCode(105)
        XCTAssertEqual(trigger.displayName, "F13")
        XCTAssertEqual(trigger.shortSymbol, "F13")
    }

    func testFromKeyCodeUnknown() {
        let trigger = HotkeyTrigger.fromKeyCode(200)
        XCTAssertEqual(trigger.displayName, "Key 200")
        XCTAssertEqual(trigger.shortSymbol, "Key 200")
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtripModifier() throws {
        for preset in HotkeyTrigger.modifierPresets {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
            XCTAssertEqual(decoded, preset, "Roundtrip failed for \(preset.displayName)")
        }
    }

    func testCodableRoundtripKeyCode() throws {
        let trigger = HotkeyTrigger.fromKeyCode(119)
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        XCTAssertEqual(decoded, trigger)
    }

    // MARK: - Persistence

    func testCurrentDefaultsToFn() {
        testDefaults.removeObject(forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .fn)
    }

    func testSaveAndLoad() throws {
        let trigger = HotkeyTrigger.fromKeyCode(119)
        trigger.save(to: testDefaults)

        let loaded = HotkeyTrigger.current(defaults: testDefaults)
        XCTAssertEqual(loaded, trigger)
        XCTAssertEqual(loaded.displayName, "End")
    }

    func testSaveModifierAndLoad() throws {
        HotkeyTrigger.control.save(to: testDefaults)

        let loaded = HotkeyTrigger.current(defaults: testDefaults)
        XCTAssertEqual(loaded, .control)
    }

    // MARK: - Legacy String Parsing

    func testLegacyStringFn() {
        testDefaults.set("fn", forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .fn)
    }

    func testLegacyStringControl() {
        testDefaults.set("control", forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .control)
    }

    func testLegacyStringOption() {
        testDefaults.set("option", forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .option)
    }

    func testLegacyStringShift() {
        testDefaults.set("shift", forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .shift)
    }

    func testLegacyStringCommand() {
        testDefaults.set("command", forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .command)
    }

    func testLegacyStringInvalidFallsBackToFn() {
        testDefaults.set("invalid_key", forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .fn)
    }

    // MARK: - Validation

    func testEscapeIsBlocked() {
        let trigger = HotkeyTrigger.fromKeyCode(53)
        if case .blocked(let msg) = trigger.validation {
            XCTAssertTrue(msg.contains("reserved"))
        } else {
            XCTFail("Escape should be blocked")
        }
    }

    func testSpaceIsWarned() {
        let trigger = HotkeyTrigger.fromKeyCode(49)
        if case .warned(let msg) = trigger.validation {
            XCTAssertTrue(msg.contains("typing"))
        } else {
            XCTFail("Space should produce a warning")
        }
    }

    func testReturnIsWarned() {
        let trigger = HotkeyTrigger.fromKeyCode(36)
        if case .warned = trigger.validation {} else {
            XCTFail("Return should produce a warning")
        }
    }

    func testTabIsWarned() {
        let trigger = HotkeyTrigger.fromKeyCode(48)
        if case .warned = trigger.validation {} else {
            XCTFail("Tab should produce a warning")
        }
    }

    func testArrowKeysAreWarned() {
        for code: UInt16 in [126, 125, 123, 124] {
            let trigger = HotkeyTrigger.fromKeyCode(code)
            if case .warned(let msg) = trigger.validation {
                XCTAssertTrue(msg.contains("editing"), "Arrow key \(code) warning should mention editing")
            } else {
                XCTFail("Arrow key \(code) should produce a warning")
            }
        }
    }

    func testF13IsAllowed() {
        let trigger = HotkeyTrigger.fromKeyCode(105)
        XCTAssertEqual(trigger.validation, .allowed)
    }

    func testEndIsAllowed() {
        let trigger = HotkeyTrigger.fromKeyCode(119)
        XCTAssertEqual(trigger.validation, .allowed)
    }

    func testHomeIsAllowed() {
        let trigger = HotkeyTrigger.fromKeyCode(115)
        XCTAssertEqual(trigger.validation, .allowed)
    }

    func testModifierValidationIsAlwaysAllowed() {
        for preset in HotkeyTrigger.modifierPresets {
            XCTAssertEqual(preset.validation, .allowed, "\(preset.displayName) should always be allowed")
        }
    }

    // MARK: - Equatable

    func testEquality() {
        let a = HotkeyTrigger.fromKeyCode(119)
        let b = HotkeyTrigger.fromKeyCode(119)
        XCTAssertEqual(a, b)
    }

    func testInequalityDifferentKeyCodes() {
        let a = HotkeyTrigger.fromKeyCode(119)
        let b = HotkeyTrigger.fromKeyCode(115)
        XCTAssertNotEqual(a, b)
    }

    func testInequalityDifferentKinds() {
        let keyTrigger = HotkeyTrigger.fromKeyCode(119)
        XCTAssertNotEqual(keyTrigger, .fn)
    }
}
