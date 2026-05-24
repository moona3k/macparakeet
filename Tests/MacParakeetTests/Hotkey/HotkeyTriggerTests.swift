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

    // MARK: - Disabled

    func testDisabledKind() {
        let trigger = HotkeyTrigger.disabled
        XCTAssertEqual(trigger.kind, .disabled)
        XCTAssertTrue(trigger.isDisabled)
        XCTAssertNil(trigger.modifierName)
        XCTAssertNil(trigger.keyCode)
    }

    func testDisabledDisplayName() {
        XCTAssertEqual(HotkeyTrigger.disabled.displayName, "Disabled")
    }

    func testDisabledShortSymbol() {
        XCTAssertEqual(HotkeyTrigger.disabled.shortSymbol, "—")
    }

    func testDisabledValidationIsAllowed() {
        XCTAssertEqual(HotkeyTrigger.disabled.validation, .allowed)
    }

    func testDisabledIsNotEqualToFn() {
        XCTAssertNotEqual(HotkeyTrigger.disabled, HotkeyTrigger.fn)
    }

    func testDisabledCodableRoundtrip() throws {
        let data = try JSONEncoder().encode(HotkeyTrigger.disabled)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        XCTAssertEqual(decoded, .disabled)
        XCTAssertTrue(decoded.isDisabled)
    }

    func testDisabledPersistence() {
        HotkeyTrigger.disabled.save(to: testDefaults)
        let loaded = HotkeyTrigger.current(defaults: testDefaults)
        XCTAssertEqual(loaded, .disabled)
        XCTAssertTrue(loaded.isDisabled)
    }

    func testNonDisabledTriggersAreNotDisabled() {
        XCTAssertFalse(HotkeyTrigger.fn.isDisabled)
        XCTAssertFalse(HotkeyTrigger.fromKeyCode(105).isDisabled)
        XCTAssertFalse(HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25).isDisabled)
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

    // MARK: - formattedLabel

    func testFormattedLabelDisabled() {
        XCTAssertEqual(HotkeyTrigger.disabled.formattedLabel, "Disabled")
    }

    func testFormattedLabelFnUsesGlobeGlyph() {
        // The Fn key's shortSymbol "fn" is visually redundant with its displayName "Fn".
        // Modern Macs ship the globe glyph instead.
        XCTAssertEqual(HotkeyTrigger.fn.formattedLabel, "🌐 Fn")
    }

    func testFormattedLabelGenericModifiersCombineGlyphAndName() {
        XCTAssertEqual(HotkeyTrigger.control.formattedLabel, "⌃ Control")
        XCTAssertEqual(HotkeyTrigger.option.formattedLabel, "⌥ Option")
        XCTAssertEqual(HotkeyTrigger.shift.formattedLabel, "⇧ Shift")
        XCTAssertEqual(HotkeyTrigger.command.formattedLabel, "⌘ Command")
    }

    func testFormattedLabelSideSpecificModifier() {
        let trigger = HotkeyTrigger(
            kind: .modifier,
            modifierName: "option",
            keyCode: nil,
            modifierKeyCode: 61 // right option
        )
        XCTAssertEqual(trigger.formattedLabel, "R⌥ Right Option")
    }

    func testFormattedLabelKeyCodeDigitDoesNotDuplicate() {
        // Regression: digit "1" used to render as "1 1".
        XCTAssertEqual(HotkeyTrigger.fromKeyCode(18).formattedLabel, "1")
    }

    func testFormattedLabelKeyCodeFunctionKey() {
        // Regression: "F13" used to render as "F13 F13".
        XCTAssertEqual(HotkeyTrigger.fromKeyCode(105).formattedLabel, "F13")
    }

    func testFormattedLabelKeyCodeArrow() {
        // Arrows have distinct displayName ("Up Arrow") vs shortSymbol ("↑").
        // We pick the compact glyph to match macOS menu conventions.
        XCTAssertEqual(HotkeyTrigger.fromKeyCode(126).formattedLabel, "↑")
    }

    func testFormattedLabelChordUsesGlyphForm() {
        // Regression: Cmd+Shift+N used to render as "⇧⌘N Shift+Command+N".
        let trigger = HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 45) // N
        XCTAssertEqual(trigger.formattedLabel, "⇧⌘N")
    }

    func testFormattedLabelModifierChord() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["option", "shift"])
        XCTAssertEqual(trigger.formattedLabel, "⌥⇧")
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

    func testCurrentDefaultsToHandsFreeShortcut() {
        testDefaults.removeObject(forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .defaultDictation)
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

    func testLegacyStringRightOptionPreservesSideSpecificModifier() {
        testDefaults.set("right_option", forKey: "hotkeyTrigger")
        XCTAssertEqual(
            HotkeyTrigger.current(defaults: testDefaults),
            HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        )
    }

    func testLegacyStringInvalidFallsBackToHandsFreeDefault() {
        testDefaults.set("invalid_key", forKey: "hotkeyTrigger")
        XCTAssertEqual(HotkeyTrigger.current(defaults: testDefaults), .defaultDictation)
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

    func testFnSpaceChordDisplayAndFlags() {
        let trigger = HotkeyTrigger.fnSpace

        XCTAssertEqual(trigger.displayName, "Fn+Space")
        XCTAssertEqual(trigger.shortSymbol, "fn+Space")
        XCTAssertEqual(trigger.chordEventFlags, 0x00800000)
        XCTAssertEqual(trigger.validation, .allowed)
    }

    func testDefaultHandsFreeAndPushToTalkUseCombinedFnGesturePreset() {
        XCTAssertEqual(HotkeyTrigger.defaultDictation, .fn)
        XCTAssertEqual(HotkeyTrigger.defaultPushToTalk, .fn)
        XCTAssertTrue(HotkeyTrigger.defaultDictation.overlaps(with: .defaultPushToTalk))
        XCTAssertTrue(HotkeyTrigger.isDefaultDictationGesturePreset(
            handsFree: .defaultDictation,
            pushToTalk: .defaultPushToTalk
        ))
        XCTAssertTrue(HotkeyTrigger.isSharedDictationGesture(
            handsFree: .defaultDictation,
            pushToTalk: .defaultPushToTalk
        ))
    }

    func testSharedDictationGestureAllowsExactCustomTrigger() {
        let rightCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )

        XCTAssertTrue(HotkeyTrigger.isSharedDictationGesture(
            handsFree: rightCommand,
            pushToTalk: rightCommand
        ))
    }

    func testSharedDictationGestureRejectsDisabledTriggers() {
        XCTAssertFalse(HotkeyTrigger.isSharedDictationGesture(
            handsFree: .disabled,
            pushToTalk: .disabled
        ))
    }

    func testSharedDictationGestureRejectsNonExactOverlap() {
        let rightCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )

        XCTAssertTrue(rightCommand.overlaps(with: .command))
        XCTAssertFalse(HotkeyTrigger.isSharedDictationGesture(
            handsFree: rightCommand,
            pushToTalk: .command
        ))
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

    // MARK: - Chord Validation (Destructive Shortcuts)

    func testChordCmdQWarned() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 12)
        if case .warned(let msg) = trigger.validation {
            XCTAssertTrue(msg.contains("system shortcut"))
        } else {
            XCTFail("Cmd+Q should produce a warning")
        }
    }

    func testChordCmdWWarned() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 13)
        if case .warned = trigger.validation {} else {
            XCTFail("Cmd+W should produce a warning")
        }
    }

    func testChordCmdHWarned() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 4)
        if case .warned = trigger.validation {} else {
            XCTFail("Cmd+H should produce a warning")
        }
    }

    func testChordCmdMWarned() {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 46)
        if case .warned = trigger.validation {} else {
            XCTFail("Cmd+M should produce a warning")
        }
    }

    func testDefaultMeetingChordIsAllowed() {
        XCTAssertEqual(HotkeyTrigger.defaultMeetingRecording.validation, .allowed)
    }

    func testChordCmdQWithoutCommandIsAllowed() {
        // Q with Shift only (no Cmd) — should not trigger the Cmd+Q warning
        let trigger = HotkeyTrigger.chord(modifiers: ["shift"], keyCode: 12)
        XCTAssertEqual(trigger.validation, .allowed)
    }

    // MARK: - Chord Display (Control/Shift Single Modifiers)

    func testChordControlSingleModifier() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 25)
        XCTAssertEqual(trigger.displayName, "Control+9")
        XCTAssertEqual(trigger.shortSymbol, "⌃9")
    }

    func testChordShiftSingleModifier() {
        let trigger = HotkeyTrigger.chord(modifiers: ["shift"], keyCode: 25)
        XCTAssertEqual(trigger.displayName, "Shift+9")
        XCTAssertEqual(trigger.shortSymbol, "⇧9")
    }

    // MARK: - Chord Event Flags (All Modifiers)

    func testChordEventFlagsControl() {
        let trigger = HotkeyTrigger.chord(modifiers: ["control"], keyCode: 25)
        XCTAssertEqual(trigger.chordEventFlags, 0x00040000) // maskControl
    }

    func testChordEventFlagsOption() {
        let trigger = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 25)
        XCTAssertEqual(trigger.chordEventFlags, 0x00080000) // maskAlternate
    }

    func testChordEventFlagsAllFour() {
        let trigger = HotkeyTrigger.chord(
            modifiers: ["control", "option", "shift", "command"], keyCode: 25
        )
        let expected: UInt64 = 0x00040000 | 0x00080000 | 0x00020000 | 0x00100000
        XCTAssertEqual(trigger.chordEventFlags, expected)
    }

    // MARK: - Chord Edge Cases

    func testChordEmptyModifiersDisplayName() {
        // Edge case: chord with no valid modifiers degrades gracefully
        let trigger = HotkeyTrigger(kind: .chord, modifierName: nil, keyCode: 25, chordModifiers: [])
        XCTAssertEqual(trigger.displayName, "9")
        XCTAssertEqual(trigger.shortSymbol, "9")
    }

    func testChordNilModifiersDisplayName() {
        let trigger = HotkeyTrigger(kind: .chord, modifierName: nil, keyCode: 25, chordModifiers: nil)
        XCTAssertEqual(trigger.displayName, "9")
        XCTAssertEqual(trigger.shortSymbol, "9")
    }

    // MARK: - Chord Persistence

    func testSaveAndLoadChord() throws {
        let trigger = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 25)
        trigger.save(to: testDefaults)

        let loaded = HotkeyTrigger.current(defaults: testDefaults)
        XCTAssertEqual(loaded, trigger)
        XCTAssertEqual(loaded.displayName, "Command+9")
    }

    // MARK: - Side-Specific Modifiers

    func testSideSpecificOptionDisplayNames() {
        let right = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        XCTAssertEqual(right.displayName, "Right Option")
        XCTAssertEqual(right.shortSymbol, "R⌥")

        let left = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 58)
        XCTAssertEqual(left.displayName, "Left Option")
        XCTAssertEqual(left.shortSymbol, "L⌥")
    }

    func testSideSpecificControlDisplayNames() {
        let right = HotkeyTrigger(kind: .modifier, modifierName: "control", keyCode: nil, modifierKeyCode: 62)
        XCTAssertEqual(right.displayName, "Right Control")
        XCTAssertEqual(right.shortSymbol, "R⌃")

        let left = HotkeyTrigger(kind: .modifier, modifierName: "control", keyCode: nil, modifierKeyCode: 59)
        XCTAssertEqual(left.displayName, "Left Control")
        XCTAssertEqual(left.shortSymbol, "L⌃")
    }

    func testSideSpecificShiftDisplayNames() {
        let right = HotkeyTrigger(kind: .modifier, modifierName: "shift", keyCode: nil, modifierKeyCode: 60)
        XCTAssertEqual(right.displayName, "Right Shift")
        XCTAssertEqual(right.shortSymbol, "R⇧")

        let left = HotkeyTrigger(kind: .modifier, modifierName: "shift", keyCode: nil, modifierKeyCode: 56)
        XCTAssertEqual(left.displayName, "Left Shift")
        XCTAssertEqual(left.shortSymbol, "L⇧")
    }

    func testSideSpecificCommandDisplayNames() {
        let right = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        XCTAssertEqual(right.displayName, "Right Command")
        XCTAssertEqual(right.shortSymbol, "R⌘")

        let left = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 55)
        XCTAssertEqual(left.displayName, "Left Command")
        XCTAssertEqual(left.shortSymbol, "L⌘")
    }

    func testGenericModifierHasNoSidePrefix() {
        // Generic triggers (no modifierKeyCode) should display without side prefix
        XCTAssertEqual(HotkeyTrigger.option.displayName, "Option")
        XCTAssertEqual(HotkeyTrigger.option.shortSymbol, "⌥")
        XCTAssertNil(HotkeyTrigger.option.modifierKeyCode)
    }

    func testSideSpecificCodableRoundtrip() throws {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        XCTAssertEqual(decoded, trigger)
        XCTAssertEqual(decoded.modifierKeyCode, 61)
        XCTAssertEqual(decoded.displayName, "Right Option")
    }

    func testSideSpecificPersistence() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        trigger.save(to: testDefaults)

        let loaded = HotkeyTrigger.current(defaults: testDefaults)
        XCTAssertEqual(loaded, trigger)
        XCTAssertEqual(loaded.modifierKeyCode, 61)
        XCTAssertEqual(loaded.displayName, "Right Option")
    }

    func testBackwardCompatOldJSONWithoutModifierKeyCode() throws {
        // Old JSON that doesn't have modifierKeyCode — should decode with nil (generic behavior)
        let json = #"{"kind":"modifier","modifierName":"option"}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)
        XCTAssertEqual(decoded.modifierName, "option")
        XCTAssertNil(decoded.modifierKeyCode)
        XCTAssertEqual(decoded.displayName, "Option")
    }

    func testSideSpecificNotEqualToGeneric() {
        let generic = HotkeyTrigger.option
        let sideSpecific = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        XCTAssertNotEqual(generic, sideSpecific)
    }

    func testLeftNotEqualToRight() {
        let left = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 58)
        let right = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        XCTAssertNotEqual(left, right)
    }

    // MARK: - Modifier-Only Chords

    func testModifierChordFactoryNormalizesOrdering() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "control", "option"])

        XCTAssertEqual(trigger.kind, .modifierChord)
        XCTAssertNil(trigger.keyCode)
        XCTAssertNil(trigger.modifierName)
        XCTAssertEqual(
            trigger.normalizedModifierChordComponents,
            [
                .init(modifierName: "control"),
                .init(modifierName: "option"),
                .init(modifierName: "command"),
            ]
        )
    }

    func testModifierChordInitNormalizesStoredComponents() {
        let trigger = HotkeyTrigger(
            kind: .modifierChord,
            modifierName: nil,
            keyCode: nil,
            modifierChordComponents: [
                .init(modifierName: "command", keyCode: 54),
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "option", keyCode: 61),
            ]
        )

        XCTAssertEqual(
            trigger.modifierChordComponents,
            [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
        XCTAssertEqual(trigger.normalizedModifierChordComponents, trigger.modifierChordComponents)
    }

    func testModifierChordDecodingNormalizesStoredComponents() throws {
        let data = """
        {
          "kind": "modifierChord",
          "modifierChordComponents": [
            { "modifierName": "command", "keyCode": 54 },
            { "modifierName": "option", "keyCode": 61 },
            { "modifierName": "fn", "keyCode": 63 }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)

        XCTAssertEqual(
            decoded.modifierChordComponents,
            [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ]
        )
    }

    func testModifierNameMapsFnKeyCodesButExcludesFnComponents() {
        XCTAssertEqual(HotkeyTrigger.modifierName(forKeyCode: 63), "fn")
        XCTAssertEqual(HotkeyTrigger.modifierName(forKeyCode: 179), "fn")
        XCTAssertTrue(HotkeyTrigger.isFnKeyCode(63))
        XCTAssertTrue(HotkeyTrigger.isFnKeyCode(179))
        XCTAssertNil(HotkeyTrigger.modifierComponent(forKeyCode: 63))
    }

    func testModifierChordDisplayNames() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])

        XCTAssertEqual(trigger.displayName, "Option+Command")
        XCTAssertEqual(trigger.shortSymbol, "⌥⌘")
    }

    func testSideSpecificModifierChordDisplayNames() {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "command", keyCode: 54),
                .init(modifierName: "option", keyCode: 61),
            ]
        )

        XCTAssertEqual(trigger.displayName, "Right Option+Right Command")
        XCTAssertEqual(trigger.shortSymbol, "R⌥R⌘")
    }

    func testModifierChordCodableRoundtrip() throws {
        let trigger = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "command", keyCode: 54),
                .init(modifierName: "option", keyCode: 61),
            ]
        )

        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)

        XCTAssertEqual(decoded, trigger)
        XCTAssertEqual(decoded.displayName, "Right Option+Right Command")
    }

    func testModifierChordPersistence() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        trigger.save(to: testDefaults)

        let loaded = HotkeyTrigger.current(defaults: testDefaults)

        XCTAssertEqual(loaded, trigger)
        XCTAssertEqual(loaded.displayName, "Option+Command")
    }

    func testModifierChordEventFlags() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let expected: UInt64 = 0x00100000 | 0x00080000

        XCTAssertEqual(trigger.modifierChordEventFlags, expected)
    }

    func testModifierChordRequiresAtLeastTwoModifiers() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command"])

        if case .blocked(let message) = trigger.validation {
            XCTAssertTrue(message.contains("at least two"))
        } else {
            XCTFail("Single modifier chord should be blocked")
        }
    }

    func testModifierChordOverlapsGenericSingleModifier() {
        let trigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])

        XCTAssertTrue(trigger.overlaps(with: .option))
        XCTAssertTrue(HotkeyTrigger.command.overlaps(with: trigger))
        XCTAssertFalse(trigger.overlaps(with: .shift))
    }

    func testSideSpecificModifierChordOverlapsCompatibleGenericChord() {
        let sideSpecific = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "command", keyCode: 54),
                .init(modifierName: "option", keyCode: 61),
            ]
        )
        let generic = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])

        XCTAssertTrue(sideSpecific.overlaps(with: generic))
        XCTAssertTrue(generic.overlaps(with: sideSpecific))
    }

    func testModifierChordOverlapsModifierChordSuperset() {
        let double = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let triple = HotkeyTrigger.modifierChord(modifiers: ["command", "option", "shift"])

        XCTAssertTrue(double.overlaps(with: triple))
        XCTAssertTrue(triple.overlaps(with: double))
    }

    func testSideSpecificModifierChordDoesNotOverlapOppositeSides() {
        let right = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "command", keyCode: 54),
                .init(modifierName: "option", keyCode: 61),
            ]
        )
        let left = HotkeyTrigger.modifierChord(
            components: [
                .init(modifierName: "command", keyCode: 55),
                .init(modifierName: "option", keyCode: 58),
            ]
        )

        XCTAssertFalse(right.overlaps(with: left))
    }

    func testModifierChordOverlapsModifierPlusKeyChordWithSameModifiers() {
        let modifierOnly = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let keyChord = HotkeyTrigger.chord(modifiers: ["command", "option"], keyCode: 46)

        XCTAssertTrue(modifierOnly.overlaps(with: keyChord))
        XCTAssertTrue(keyChord.overlaps(with: modifierOnly))
    }

    func testModifierChordDoesNotOverlapModifierPlusKeyChordWithSubsetModifiers() {
        let modifierOnly = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let keyChord = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 46)

        XCTAssertFalse(modifierOnly.overlaps(with: keyChord))
        XCTAssertFalse(keyChord.overlaps(with: modifierOnly))
    }

    func testModifierChordOverlapsModifierPlusKeyChordWithSupersetModifiers() {
        let modifierOnly = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        let keyChord = HotkeyTrigger.chord(modifiers: ["command", "option", "shift"], keyCode: 46)

        XCTAssertTrue(modifierOnly.overlaps(with: keyChord))
        XCTAssertTrue(keyChord.overlaps(with: modifierOnly))
    }

    func testKeyCodeOverlapsModifierPlusSameKeyChord() {
        let bareM = HotkeyTrigger.fromKeyCode(46)
        let commandM = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 46)

        XCTAssertTrue(bareM.overlaps(with: commandM))
        XCTAssertTrue(commandM.overlaps(with: bareM))
    }

    func testBareModifierDictationCanShareModifierPlusKeyChord() {
        let rightCommand = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        let meeting = HotkeyTrigger.defaultMeetingRecording

        XCTAssertTrue(rightCommand.overlaps(with: meeting))
        XCTAssertFalse(rightCommand.conflicts(with: meeting, selfMode: .bareModifierDictation))
        XCTAssertFalse(meeting.conflicts(with: rightCommand, otherMode: .bareModifierDictation))
    }

    func testBareModifierDictationCanShareTransformOptionChord() {
        let optionOne = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 0x12)

        XCTAssertTrue(HotkeyTrigger.option.overlaps(with: optionOne))
        XCTAssertFalse(HotkeyTrigger.option.conflicts(with: optionOne, selfMode: .bareModifierDictation))
    }

    func testBareModifierDictationStillConflictsWithBareModifier() {
        let rightCommand = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)

        XCTAssertTrue(rightCommand.conflicts(with: .command, selfMode: .bareModifierDictation))
        XCTAssertTrue(rightCommand.conflicts(with: .command, otherMode: .bareModifierDictation))
    }

    // MARK: - Telemetry

    func testTelemetryKindMapsOnlyStructuralTriggerKind() {
        XCTAssertEqual(HotkeyTrigger.disabled.telemetryKind, .disabled)
        XCTAssertEqual(HotkeyTrigger.option.telemetryKind, .modifier)
        XCTAssertEqual(HotkeyTrigger.fromKeyCode(119).telemetryKind, .keyCode)
        XCTAssertEqual(HotkeyTrigger.chord(modifiers: ["command", "shift"], keyCode: 25).telemetryKind, .chord)
        XCTAssertEqual(HotkeyTrigger.modifierChord(modifiers: ["command", "option"]).telemetryKind, .chord)
    }

    func testCustomizedEventDoesNotExposeSpecificKeySelection() {
        let event = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
            .customizedEvent(surface: .meeting)
        let payload = TelemetryEvent(
            spec: event,
            appVer: "0.6.3",
            osVer: "15.4",
            locale: "en-US",
            chip: "Apple M4",
            session: "session"
        )

        XCTAssertEqual(payload.event, TelemetryEventName.hotkeyCustomized.rawValue)
        XCTAssertEqual(payload.props?["surface"], "meeting")
        XCTAssertEqual(payload.props?["kind"], "chord")
        XCTAssertNil(payload.props?["modifier"])
        XCTAssertNil(payload.props?["key_code"])
        XCTAssertNil(payload.props?["chord_modifiers"])
    }
}
