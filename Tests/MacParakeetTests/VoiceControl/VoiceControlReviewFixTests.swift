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

    func testConsentLeadInsAndRequestsConfirmWhileStepsTowardCheckoutDoNot() {
        XCTAssertEqual(floor("OK, delete"), .destructive)
        XCTAssertEqual(floor("Request payment"), .payment)
        // These open the checkout or payment page; the pay control there confirms.
        for label in ["Secure checkout", "Continue to payment", "Proceed to checkout"] { XCTAssertNil(floor(label), label) }
    }

    func testVSCodeAnswersToItsProcessName() {
        XCTAssertTrue(VoiceControlCommandRouter.application(named: "Code", matches: "vs code"))
        XCTAssertTrue(VoiceControlCommandRouter.application(named: "Code", matches: "vscode"))
    }

    func testUncertainAnswersAreNotCorrections() {
        let state = VoiceControlUtteranceIntent.State(awaitingClarification: true, hasOpenTask: true)
        for text in ["not sure", "no preference", "no idea"] {
            XCTAssertEqual(VoiceControlUtteranceIntent.classify(text, state: state), .answer, text)
        }
    }

    func testTheFloorFailsClosedOnUnlistedModifiersAndConjunctions() {
        for label in ["Bulk delete", "Force Delete", "Batch delete", "Archive and permanently delete"] {
            XCTAssertEqual(floor(label), .destructive, label)
        }
        for label in ["Save & Purchase", "Save and order", "Process payment"] { XCTAssertEqual(floor(label), .payment, label) }
        XCTAssertEqual(floor("Click to share"), .externalCommitment)
        for label in ["Checkout page", "Payment page", "Order view"] { XCTAssertNil(floor(label), label) }
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

    func testAMissingNamedControlIsNotReplacedByAShorterOne() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "m", applicationName: "Safari",
            targets: [VoiceControlTarget(id: "n:0", label: "New", role: "AXButton", operations: [.press])])
        let decision = try await VoiceControlCommandRouter(fallback: Unused()).decide(
            goal: "click the new tab button", snapshot: snapshot, history: [])
        XCTAssertEqual(decision, .clarify("fallback"), "no New Tab on screen: ask, never press New")
    }

    func testACorrectionIsDoneOnlyByItsFullNameOnAVerifiedPress() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "e", applicationName: "Safari",
            targets: [
                VoiceControlTarget(id: "n:0", label: "New", role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "n:1", label: "New Tab", role: "AXButton", operations: [.press]),
            ])
        let router = VoiceControlCommandRouter(fallback: Unused())
        let pressedNew = VoiceControlAction(operation: .press, targetID: "n:0", targetLabel: "New", receiptStatus: .verified)
        let goal = VoiceControlGoalText.header + "click New\n" + VoiceControlGoalText.correction + "actually click New Tab"
        let decision = try await router.decide(goal: goal, snapshot: snapshot, history: [pressedNew])
        guard case .action(let action) = decision else { return XCTFail("expected New Tab, got \(decision)") }
        XCTAssertEqual(action.targetID, "n:1")
    }

    func testPleaseAndFailuresDoNotBlockACorrectionsLocalRoute() async throws {
        let snapshot = VoiceControlSnapshot(
            contextID: "p", applicationName: "Editor",
            targets: [VoiceControlTarget(id: "n:0", label: "Save", role: "AXButton", operations: [.press])])
        let router = VoiceControlCommandRouter(fallback: Unused())
        let polite = VoiceControlGoalText.header + "open the file\n" + VoiceControlGoalText.correction + "please click Save"
        let first = try await router.decide(goal: polite, snapshot: snapshot, history: [])
        guard case .action(let action) = first else { return XCTFail("expected Save, got \(first)") }
        XCTAssertEqual(action.targetID, "n:0")
        let failed = VoiceControlAction(operation: .press, targetID: "n:0", targetLabel: "Save", receiptStatus: .failed)
        let retry = VoiceControlGoalText.header + "click Save\n" + VoiceControlGoalText.correction + "actually click Save"
        let again = try await router.decide(goal: retry, snapshot: snapshot, history: [failed])
        guard case .action = again else { return XCTFail("a failed press is retried, got \(again)") }
    }

    func testAPriceCountsAsOneWordAndNewTabIsNeverNew() async throws {
        XCTAssertEqual(floor("Buy now for $1,200.00"), .payment)
        let snapshot = VoiceControlSnapshot(
            contextID: "t", applicationName: "Safari",
            targets: [VoiceControlTarget(id: "n:0", label: "New", role: "AXButton", operations: [.press])])
        let decision = try await VoiceControlCommandRouter(fallback: Unused()).decide(
            goal: "click new tab", snapshot: snapshot, history: [])
        XCTAssertEqual(decision, .clarify("fallback"), "no New Tab on screen: never press New")
    }

    func testTheFirstFloorWordDecidesAMixedLabel() {
        XCTAssertEqual(floor("Delete order"), .destructive)
        XCTAssertEqual(floor("Send payment"), .externalCommitment)
        XCTAssertEqual(floor("Pay and send"), .payment)
    }

    func testPoliteAndClosePhrasesReadTheSameInTheClassifier() {
        let state = VoiceControlUtteranceIntent.State(
            awaitingClarification: true, hasOpenTask: true, offeredLabels: ["Please Save", "Save"])
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("please select 2", state: state), .answer)
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("Please Save", state: state), .answer)
        let open = VoiceControlUtteranceIntent.State(awaitingClarification: true, hasOpenTask: true)
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("close the tab", state: open), .newInstruction)
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
