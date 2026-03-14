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

    // MARK: - Chord Factory

    func testChordFactoryProducesCorrectProperties() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        XCTAssertEqual(trigger.kind, .chord)
        XCTAssertEqual(trigger.keyCode, 25)
        XCTAssertEqual(trigger.chordModifiers, ["command"])
        XCTAssertNil(trigger.modifierName)
    }

    func testChordDisplayNameSingleModifier() {
        // keyCode 25 = "9" on US keyboard
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        XCTAssertEqual(trigger.displayName, "Command+9")
    }

    func testChordShortSymbolSingleModifier() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        XCTAssertEqual(trigger.shortSymbol, "⌘9")
    }

    func testChordDisplayNameMultiModifier() {
        // keyCode 40 = "K" on US keyboard
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 40)
        XCTAssertEqual(trigger.displayName, "Shift+Command+K")
    }

    func testChordShortSymbolMultiModifier() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 40)
        XCTAssertEqual(trigger.shortSymbol, "⇧⌘K")
    }

    func testChordModifierOrderingIsCanonical() {
        // Input in wrong order — output should always be ⌃⌥⇧⌘
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "control", "shift", "option"], keyCode: 25)
        XCTAssertEqual(trigger.shortSymbol, "⌃⌥⇧⌘9")
        XCTAssertEqual(trigger.displayName, "Control+Option+Shift+Command+9")
    }

    func testChordWithFunctionKey() {
        // keyCode 96 = F5
        let trigger = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 96)
        XCTAssertEqual(trigger.displayName, "Option+F5")
        XCTAssertEqual(trigger.shortSymbol, "⌥F5")
    }

    // MARK: - Chord Validation

    func testChordValidationDefaultAllowed() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        XCTAssertEqual(trigger.validation, .allowed)
    }

    func testChordEscapeBlocked() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 53)
        if case .blocked = trigger.validation {} else {
            XCTFail("Escape in chord should be blocked")
        }
    }

    func testChordCmdTabWarned() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 48)
        if case .warned(let msg) = trigger.validation {
            XCTAssertTrue(msg.contains("system shortcut"))
        } else {
            XCTFail("Cmd+Tab should produce a warning")
        }
    }

    func testChordCmdSpaceWarned() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 49)
        if case .warned(let msg) = trigger.validation {
            XCTAssertTrue(msg.contains("system shortcut"))
        } else {
            XCTFail("Cmd+Space should produce a warning")
        }
    }

    func testChordLetterKeyAllowed() {
        // Regular letter key with modifier — chords disambiguate from typing
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 0) // 'A'
        XCTAssertEqual(trigger.validation, .allowed)
    }

    // MARK: - Chord Codable

    func testCodableRoundtripChord() throws {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 25)
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        XCTAssertEqual(decoded, trigger)
        // Factory normalizes to canonical order: ⌃⌥⇧⌘
        XCTAssertEqual(decoded.chordModifiers, ["shift", "command"])
    }

    func testBackwardCompatOldJSONWithoutChordModifiers() throws {
        // Old JSON that doesn't have chordModifiers — should decode fine
        let json = #"{"kind":"keyCode","keyCode":119}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        XCTAssertEqual(decoded.kind, .keyCode)
        XCTAssertEqual(decoded.keyCode, 119)
        XCTAssertNil(decoded.chordModifiers)
    }

    func testBackwardCompatOldModifierJSON() throws {
        let json = #"{"kind":"modifier","modifierName":"fn"}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        XCTAssertEqual(decoded, .fn)
        XCTAssertNil(decoded.chordModifiers)
    }

    // MARK: - Chord Equatable

    func testChordEquality() {
        let a = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        let b = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        XCTAssertEqual(a, b)
    }

    func testChordInequalityDifferentModifiers() {
        let a = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        let b = HotkeyTrigger.chord(modifiers: ["shift"], keyCode: 25)
        XCTAssertNotEqual(a, b)
    }

    func testChordInequalityDifferentKey() {
        let a = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        let b = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 26)
        XCTAssertNotEqual(a, b)
    }

    func testChordNotEqualToKeyCode() {
        let chord = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        let keyCode = HotkeyTrigger.fromKeyCode(25)
        XCTAssertNotEqual(chord, keyCode)
    }

    // MARK: - Chord Event Flags

    func testChordEventFlagsCommand() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        // maskCommand = 0x00100000
        XCTAssertEqual(trigger.chordEventFlags, 0x00100000)
    }

    func testChordEventFlagsMultiple() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 25)
        // maskCommand | maskShift = 0x00100000 | 0x00020000
        let expected: UInt64 = 0x00100000 | 0x00020000
        XCTAssertEqual(trigger.chordEventFlags, expected)
    }

    func testChordEventFlagsNilModifiers() {
        let trigger = HotkeyTrigger.fromKeyCode(25)
        XCTAssertEqual(trigger.chordEventFlags, 0)
    }

    // MARK: - Chord Persistence

    func testSaveAndLoadChord() throws {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        trigger.save(to: testDefaults)

        let loaded = HotkeyTrigger.current(defaults: testDefaults)
        XCTAssertEqual(loaded, trigger)
        XCTAssertEqual(loaded.displayName, "Command+9")
    }
}
