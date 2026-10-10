import CoreGraphics
import XCTest

@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// The panel names the effect and the choices; it never says "the next step".
@MainActor
final class VoiceControlPresentationTests: XCTestCase {
    func testActingNamesTheControlFromTheHighlight() {
        let model = VoiceControlViewModel()
        model.apply(.highlight(VoiceControlHighlight(style: .acting, marks: [.init(label: "Sent", frame: nil)])))
        model.apply(.acting(VoiceControlAction(operation: .press, targetID: "n:2")))
        XCTAssertEqual(model.message, "Clicking ‘Sent’…")
        XCTAssertEqual(model.steps.last, "Clicking ‘Sent’")
    }

    func testEveryOperationReadsAsAnEffect() {
        func say(_ operation: VoiceControlOperation, _ label: String?, value: String? = nil) -> String {
            VoiceControlViewModel.describe(
                VoiceControlAction(operation: operation, targetID: "n:0", value: value), label: label)
        }
        XCTAssertEqual(say(.setValue, "Search mail"), "Typing into ‘Search mail’")
        XCTAssertEqual(say(.insertText, nil), "Typing")
        XCTAssertEqual(say(.key, nil, value: "return"), "Pressing Return")
        XCTAssertEqual(say(.scroll, "Results", value: "up"), "Scrolling up in ‘Results’")
        XCTAssertEqual(say(.activateApp, "Safari"), "Switching to ‘Safari’")
        XCTAssertEqual(say(.select, "One way"), "Selecting ‘One way’")
    }

    func testNumberedHighlightBecomesChoicesUntilTheNextStep() {
        let model = VoiceControlViewModel()
        let marks: [VoiceControlHighlight.Mark] = [
            .init(label: "Sent", frame: CGRect(x: 10, y: 10, width: 40, height: 20), number: 1),
            .init(label: "Drafts", frame: nil, number: 2),
        ]
        model.apply(.highlight(VoiceControlHighlight(style: .numbered, marks: marks)))
        model.apply(.clarification("Which one? Say the number.\n1. Sent\n2. Drafts"))
        XCTAssertEqual(model.choices.map(\.label), ["Sent", "Drafts"])
        XCTAssertEqual(model.phase, .clarification)
        model.apply(.observing)
        XCTAssertTrue(model.choices.isEmpty, "an answered pick does not linger")
    }
}
