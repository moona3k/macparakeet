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
