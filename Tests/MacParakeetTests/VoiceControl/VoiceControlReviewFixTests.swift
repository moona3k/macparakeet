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

    func testCapCountsTheLabelsOwnWords() {
        XCTAssertEqual(floor("Place order & pay $24.99"), .payment)
    }

    func testGestureInfinitivesModifiersAndSharedObjectsConfirm() {
        for label in ["Pre-order now", "Quick buy", "1-Click Buy"] { XCTAssertEqual(floor(label), .payment, label) }
        XCTAssertEqual(floor("Click to delete"), .destructive)
        XCTAssertEqual(floor("Tap to send"), .externalCommitment)
        XCTAssertEqual(floor("Share file with Alice"), .externalCommitment)
        for label in ["Proceed to checkout", "Share", "Share options", "Sort order"] { XCTAssertNil(floor(label), label) }
    }

    func testShareFollowsTheSameRulesAsOtherFloorWords() {
        for label in ["Yes, share my location", "Save & Share", "Confirm and share", "Schedule share", "Share now"] {
            XCTAssertEqual(floor(label), .externalCommitment, label)
        }
        for label in ["Share", "Share options", "Share menu", "Share sheet"] { XCTAssertNil(floor(label), label) }
    }

    func testACorrectionIsNotDoneByAPrefixOfThePressedLabel() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "s", applicationName: "Editor",
            targets: [
                VoiceControlTarget(id: "t1", label: "Save", role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "t2", label: "Save As", role: "AXButton", operations: [.press]),
            ])
        let pressed = VoiceControlAction(operation: .press, targetID: "t2", targetLabel: "Save As", receiptStatus: .verified)
        let goal = VoiceControlGoalText.header + "click Save As\n" + VoiceControlGoalText.correction + "actually click Save"
        let decision = try await VoiceControlCommandRouter(fallback: Unused()).decide(
            goal: goal, snapshot: snapshot, history: [pressed])
        guard case .action(let action) = decision else { return XCTFail("expected the Save press, got \(decision)") }
        XCTAssertEqual(action.targetID, "t1")
    }

    func testSayingAnOfferedLabelThatStartsWithAVerbAnswers() {
        let state = VoiceControlUtteranceIntent.State(
            awaitingClarification: true, hasOpenTask: true, offeredLabels: ["Select All", "Select None"])
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("Select All", state: state), .answer)
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("click Select None", state: state), .answer)
    }

    func testIntermediateNameIsTriedBeforeTheBareWord() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "b", applicationName: "Safari",
            targets: ["New Tab", "New Window", "New Private Window"].enumerated().map {
                VoiceControlTarget(id: "n:\($0.offset)", label: $0.element, role: "AXMenuItem", operations: [.press])
            })
        let decision = try await VoiceControlCommandRouter(fallback: Unused()).decide(
            goal: "click the new tab button", snapshot: snapshot, history: [])
        guard case .action(let action) = decision else { return XCTFail("expected New Tab, got \(decision)") }
        XCTAssertEqual(action.targetID, "n:0")
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
