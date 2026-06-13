import AppKit
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class HotkeyRecorderViewTests: XCTestCase {
    func testStandardBareModifierCaptureRecordsPhysicalModifierSide() {
        let candidate = HotkeyRecorderView.bareModifierTrigger(
            for: "command",
            keyCode: 54,
            captureMode: .standard
        )

        XCTAssertEqual(
            candidate,
            HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
        )
    }

    func testStandardBareShiftCaptureRecordsPhysicalModifierSide() {
        let candidate = HotkeyRecorderView.bareModifierTrigger(
            for: "shift",
            keyCode: 60,
            captureMode: .standard
        )

        XCTAssertEqual(
            candidate,
            HotkeyTrigger(kind: .modifier, modifierName: "shift", keyCode: nil, modifierKeyCode: 60)
        )
    }

    func testStandardModifierKeyChordCapturePreservesGenericChordBehavior() {
        let candidate = HotkeyRecorderView.keyChordTrigger(
            modifiers: ["command"],
            keyCode: 8,
            captureMode: .standard
        )

        XCTAssertEqual(candidate, .chord(modifiers: ["command"], keyCode: 8))
    }

    func testStandardModifierChordCaptureRecordsPhysicalModifierSides() {
        let candidate = HotkeyRecorderView.modifierChordTrigger(
            components: [
                .init(modifierName: "option", keyCode: 58),
                .init(modifierName: "command", keyCode: 55),
            ],
            captureMode: .standard
        )

        XCTAssertEqual(
            candidate,
            .modifierChord(
                components: [
                    .init(modifierName: "option", keyCode: 58),
                    .init(modifierName: "command", keyCode: 55),
                ]
            )
        )
    }

    func testStandardSameModifierChordCaptureRecordsBothPhysicalSides() {
        let candidate = HotkeyRecorderView.modifierChordTrigger(
            components: [
                .init(modifierName: "shift", keyCode: 56),
                .init(modifierName: "shift", keyCode: 60),
            ],
            captureMode: .standard
        )

        XCTAssertEqual(
            candidate,
            .modifierChord(
                components: [
                    .init(modifierName: "shift", keyCode: 56),
                    .init(modifierName: "shift", keyCode: 60),
                ]
            )
        )
    }

    func testGenericBareModifierCapturePreservesEitherSideBehavior() {
        let candidate = HotkeyRecorderView.bareModifierTrigger(
            for: "option",
            keyCode: 61,
            captureMode: .generic
        )

        XCTAssertEqual(candidate, .option)
        XCTAssertNil(candidate?.modifierKeyCode)
    }

    func testSideSpecificBareModifierCaptureRecordsPhysicalModifierSide() {
        let candidate = HotkeyRecorderView.bareModifierTrigger(
            for: "option",
            keyCode: 61,
            captureMode: .sideSpecific
        )

        XCTAssertEqual(
            candidate,
            HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        )
    }

    func testGenericModifierChordCapturePreservesEitherSideBehavior() {
        let candidate = HotkeyRecorderView.modifierChordTrigger(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ],
            captureMode: .generic
        )

        XCTAssertEqual(candidate, .modifierChord(modifiers: ["option", "command"]))
        XCTAssertEqual(
            candidate?.normalizedModifierChordComponents,
            [
                .init(modifierName: "option"),
                .init(modifierName: "command"),
            ]
        )
    }

    func testSideSpecificModifierChordCaptureRecordsPhysicalModifierSides() {
        let candidate = HotkeyRecorderView.modifierChordTrigger(
            components: [
                .init(modifierName: "option", keyCode: 61),
                .init(modifierName: "command", keyCode: 54),
            ],
            captureMode: .sideSpecific
        )

        XCTAssertEqual(
            candidate,
            .modifierChord(
                components: [
                    .init(modifierName: "option", keyCode: 61),
                    .init(modifierName: "command", keyCode: 54),
                ]
            )
        )
    }

    func testSideSpecificRecordingRejectsModifierKeyChords() {
        let candidate = HotkeyRecorderView.keyChordTrigger(
            modifiers: ["option"],
            keyCode: 8,
            captureMode: .sideSpecific
        )

        XCTAssertNil(candidate)
    }

    func testGenericRecordingAllowsModifierKeyChords() {
        let candidate = HotkeyRecorderView.keyChordTrigger(
            modifiers: ["option"],
            keyCode: 8,
            captureMode: .generic
        )

        XCTAssertEqual(candidate, .chord(modifiers: ["option"], keyCode: 8))
    }

    func testGenericRecordingAllowsFnKeyChords() {
        let candidate = HotkeyRecorderView.keyChordTrigger(
            modifiers: ["fn"],
            keyCode: 49,
            captureMode: .generic
        )

        XCTAssertEqual(candidate, .fnSpace)
    }

    func testKeyChordCaptureUsesPendingFnWhenKeyDownFlagsOmitFunction() {
        let modifiers = HotkeyRecorderView.chordModifierNames(
            flags: [],
            keyCode: 49,
            pendingComponents: [.init(modifierName: "fn")]
        )
        let candidate = HotkeyRecorderView.keyChordTrigger(
            modifiers: modifiers,
            keyCode: 49,
            captureMode: .standard
        )

        XCTAssertEqual(candidate, .fnSpace)
    }

    func testChordCaptureIgnoresFunctionFlagForFunctionKeyChord() {
        let modifiers = HotkeyRecorderView.chordModifierNames(
            flags: [.control, .function],
            keyCode: 80,
            pendingComponents: []
        )

        XCTAssertEqual(modifiers, ["control"])

        let candidate = HotkeyRecorderView.keyChordTrigger(
            modifiers: modifiers,
            keyCode: 80,
            captureMode: .standard
        )

        XCTAssertEqual(candidate, .chord(modifiers: ["control"], keyCode: 80))
        XCTAssertEqual(candidate?.shortSymbol, "⌃F19")
        XCTAssertEqual(candidate?.formattedLabel, "⌃F19")
    }

    func testBareFunctionKeyCaptureIgnoresFunctionFlag() {
        let modifiers = HotkeyRecorderView.chordModifierNames(
            flags: [.function],
            keyCode: 80,
            pendingComponents: []
        )

        // Empty → the keyDown handler takes the bare-key path.
        XCTAssertTrue(modifiers.isEmpty)

        let candidate = HotkeyTrigger.fromKeyCode(80)
        XCTAssertEqual(candidate.formattedLabel, "F19")
        XCTAssertEqual(candidate.validation, .allowed)
    }

    func testChordCaptureIgnoresFunctionFlagForArrowAndNavKeys() {
        for keyCode: UInt16 in [126, 123, 115, 119, 116, 121, 117] {
            let modifiers = HotkeyRecorderView.chordModifierNames(
                flags: [.option, .function],
                keyCode: keyCode,
                pendingComponents: []
            )

            XCTAssertEqual(modifiers, ["option"], "keyCode \(keyCode)")
        }
    }

    func testPhysicalFnPendingComponentIsPreservedForFunctionKeyChord() {
        XCTAssertEqual(
            HotkeyRecorderView.chordModifierNames(
                flags: [.function],
                keyCode: 80,
                pendingComponents: [.init(modifierName: "fn")]
            ),
            ["fn"]
        )
        XCTAssertEqual(
            HotkeyRecorderView.chordModifierNames(
                flags: [.control, .function],
                keyCode: 80,
                pendingComponents: [.init(modifierName: "fn")]
            ),
            ["fn", "control"]
        )
    }

    func testFunctionFlagStillDerivesFnForNonFunctionFamilyKey() {
        let modifiers = HotkeyRecorderView.chordModifierNames(
            flags: [.function],
            keyCode: 7, // X
            pendingComponents: []
        )

        XCTAssertEqual(modifiers, ["fn"])
    }

    func testBareFnCaptureRemainsSupported() {
        let candidate = HotkeyRecorderView.bareModifierTrigger(
            for: "fn",
            keyCode: 63,
            captureMode: .generic
        )

        XCTAssertEqual(candidate, .fn)
    }

    func testSingleModifierDoesNotBecomeModifierChord() {
        let candidate = HotkeyRecorderView.modifierChordTrigger(
            components: [.init(modifierName: "option", keyCode: 61)],
            captureMode: .sideSpecific
        )

        XCTAssertNil(candidate)
    }

    func testSideSpecificModifierFallbackTracksBothSidesOfSameModifier() {
        let leftOption = HotkeyTrigger.ModifierComponent(modifierName: "option", keyCode: 58)
        let rightOption = HotkeyTrigger.ModifierComponent(modifierName: "option", keyCode: 61)

        var pending = HotkeyRecorderView.sideSpecificModifierComponentsAfterFlagsChanged(
            pending: [],
            eventKeyCode: 58,
            modifierName: "option",
            flags: [.option]
        )
        XCTAssertEqual(pending, [leftOption])

        pending = HotkeyRecorderView.sideSpecificModifierComponentsAfterFlagsChanged(
            pending: pending,
            eventKeyCode: 61,
            modifierName: "option",
            flags: [.option]
        )
        XCTAssertEqual(pending, [leftOption, rightOption])

        pending = HotkeyRecorderView.sideSpecificModifierComponentsAfterFlagsChanged(
            pending: pending,
            eventKeyCode: 58,
            modifierName: "option",
            flags: [.option]
        )
        XCTAssertEqual(pending, [rightOption])

        pending = HotkeyRecorderView.sideSpecificModifierComponentsAfterFlagsChanged(
            pending: pending,
            eventKeyCode: 61,
            modifierName: "option",
            flags: []
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testResetLabelUsesReadableFnName() {
        XCTAssertEqual(HotkeyRecorderView.resetLabel(for: .fn), "🌐 Fn")
    }

    func testResetLabelUsesReadableModifierName() {
        XCTAssertEqual(HotkeyRecorderView.resetLabel(for: .control), "Control")
    }

    func testResetLabelUsesChordSymbol() {
        XCTAssertEqual(
            HotkeyRecorderView.resetLabel(for: .defaultMeetingRecording),
            "⇧⌘M"
        )
    }
}
