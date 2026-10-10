import XCTest

@testable import MacParakeetCore

/// Review findings on the routing PR: the label floor, the trailing type
/// clause, and a stale id finishing an amended request.
final class VoiceControlReviewFixTests: XCTestCase {
    private func floor(_ label: String) -> VoiceControlConsequence? {
        VoiceControlConsequencePolicy.floorConsequence(label: label)
    }

    func testAmpersandAndPlusReadAsAnd() {
        XCTAssertEqual(floor("Save & Send"), .externalCommitment)
        XCTAssertEqual(floor("Save + Publish"), .externalCommitment)
        XCTAssertEqual(floor("Archive & Delete"), .destructive)
    }

    func testImperativeLedCommitsConfirmWhileNounsStayOrdinary() {
        for label in ["Purchase for $9.99", "Purchase subscription", "Order tickets", "Order $24.99", "Order now"] {
            XCTAssertEqual(floor(label), .payment, label)
        }
        for label in ["Permanently delete", "Yes, delete"] { XCTAssertEqual(floor(label), .destructive, label) }
        XCTAssertEqual(floor("Schedule send"), .externalCommitment)
        for label in ["Sort order", "Order history", "Booking details", "Payment methods", "Share", "Order status"] {
            XCTAssertNil(floor(label), label)
        }
    }

    func testTrailingTypeClauseNeedsACommaPeriodOrJoiningWord() {
        XCTAssertEqual(VoiceControlCommandRouter.typePayload(in: "ok, type hello"), "hello")
        XCTAssertEqual(VoiceControlCommandRouter.typePayload(in: "then type hello"), "hello")
        XCTAssertEqual(VoiceControlCommandRouter.typePayload(in: "open notes and type hi"), "hi")
        XCTAssertNil(VoiceControlCommandRouter.typePayload(in: "fill the form just type x"))
        XCTAssertNil(VoiceControlCommandRouter.typePayload(in: "ok? type hello"))
        XCTAssertNil(VoiceControlCommandRouter.typePayload(in: "what type of file is this"))
    }

    func testAReusedIDDoesNotFinishACorrectionThatNamesAnotherControl() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "c", applicationName: "Editor",
            targets: [VoiceControlTarget(id: "t7", label: "Revert", role: "AXButton", operations: [.press])])
        let pressedSave = VoiceControlAction(
            operation: .press, targetID: "t7", targetLabel: "Save", receiptStatus: .verified)
        let goal = VoiceControlGoalText.header + "click Save\n" + VoiceControlGoalText.correction + "click Revert"
        let decision = try await VoiceControlCommandRouter(fallback: Unused()).decide(
            goal: goal, snapshot: snapshot, history: [pressedSave])
        guard case .action(let action) = decision else {
            return XCTFail("expected the Revert press, got \(decision)")
        }
        XCTAssertEqual(action.targetID, "t7")
    }

    private struct Unused: VoiceControlDecisionEngine {
        func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
            -> VoiceControlDecision
        { .clarify("fallback") }
        func decide(
            goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
            events: [VoiceControlEnabledEvent]
        ) async throws -> VoiceControlDecision { .clarify("fallback") }
    }
}
