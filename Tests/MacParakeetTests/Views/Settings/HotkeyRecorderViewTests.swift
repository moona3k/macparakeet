import AppKit
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class HotkeyRecorderViewTests: XCTestCase {
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

    func testTransformShortcutRecorderUsesEscapeToCancelRecording() throws {
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 0x35
        ))
        let one = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 0x12
        ))

        XCTAssertTrue(ShortcutRecorderField.shouldCancelRecording(escape))
        XCTAssertFalse(ShortcutRecorderField.shouldCancelRecording(one))
    }
}
