import Foundation
import XCTest
@testable import MacParakeetCore

final class VoiceControlRecoveryTests: XCTestCase {
    func testCorrectionRetainsVerifiedHistoryAndOriginalGoal() async {
        let adapter = RecoveryAdapter()
        let engine = RecoveryEngine([
            .action(.init(operation: .setValue, targetID: "destination", value: "Paris")), .finished,
            .action(.init(operation: .setValue, targetID: "destination", value: "London")), .finished
        ])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Find flights from Zurich to Paris")
        await runner.revise("Actually London")
        let histories = await engine.histories
        let goals = await engine.goals
        XCTAssertEqual(histories[2].first?.value, "Paris")
        XCTAssertEqual(histories[2].first?.receiptStatus, .verified)
        XCTAssertTrue(goals[2].contains("Zurich"))
        XCTAssertTrue(goals[2].contains("Actually London"))
        let value = await adapter.value
        XCTAssertEqual(value, "London")
    }

    func testManualContinuePreservesChangedFieldAndNeverRestartsOriginalTask() async {
        let adapter = RecoveryAdapter()
        let engine = RecoveryEngine([.action(.init(operation: .setValue, targetID: "destination", value: "Paris")), .finished, .finished])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Find flights to Paris")
        runner.pauseForManualInput()
        await adapter.manuallySet("London")
        await runner.continueTask()
        let goals = await engine.goals
        XCTAssertTrue(goals.last?.contains("destination: London") == true)
        XCTAssertTrue(goals.last?.contains("override earlier") == true)
        let effects = await adapter.effects
        XCTAssertEqual(effects.count, 1)
    }

    func testManualContextSwitchCannotBeAuthorizedByRepeatedContinue() async {
        let adapter = RecoveryAdapter()
        let engine = RecoveryEngine([.finished, .action(.init(operation: .setValue, targetID: "destination", value: "Wrong"))])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Find flights")
        runner.pauseForManualInput()
        await adapter.changeContext()
        await runner.continueTask()
        await runner.continueTask()
        let effects = await adapter.effects
        let goals = await engine.goals
        XCTAssertEqual(effects.count, 0)
        XCTAssertEqual(goals.count, 1)
    }

    func testOtherOneAsksWhenTwoAlternativesRemainAndExcludesRejectedControl() async {
        let adapter = RecoveryAdapter()
        let engine = RecoveryEngine([.action(.init(operation: .press, targetID: "alpha")), .finished, .finished])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Open Alpha")
        await runner.revise("No, the other one")
        var effects = await adapter.effects
        XCTAssertEqual(effects.map(\.targetID), ["alpha"])
        await runner.clarify("Beta")
        effects = await adapter.effects
        XCTAssertEqual(effects.map(\.targetID), ["alpha", "beta"])
    }

    func testNumberedPickResolvesTheOtherOneWithoutRepeatingTheLabel() async {
        let adapter = RecoveryAdapter()
        let engine = RecoveryEngine([.action(.init(operation: .press, targetID: "alpha")), .finished, .finished])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Open Alpha")
        await runner.revise("No, the other one")
        await runner.clarify("2")
        let effects = await adapter.effects
        XCTAssertEqual(effects.map(\.targetID), ["alpha", "gamma"])
    }

    func testRevisingLiteralTaskCannotTriggerOldLocalCompletion() async {
        let adapter = RecoveryAdapter()
        let fallback = RecoveryEngine([.action(.init(operation: .setValue, targetID: "destination", value: "London")), .finished])
        let router = VoiceControlCommandRouter(fallback: fallback)
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: router)
        await runner.submit("type Paris")
        await runner.revise("Actually London")
        let goals = await fallback.goals
        XCTAssertTrue(goals.first?.hasPrefix("Continue this task") == true)
        let value = await adapter.value
        XCTAssertEqual(value, "London")
    }

    func testUnknownEffectCannotReplayAfterGoalRevision() async {
        let adapter = RecoveryAdapter(unknownPress: true)
        let engine = RecoveryEngine([.action(.init(operation: .press, targetID: "alpha")), .action(.init(operation: .press, targetID: "alpha"))])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Open Alpha")
        await runner.revise("Try Alpha again")
        let effects = await adapter.effects
        XCTAssertEqual(effects.count, 1)
    }

    func testStopCancelsDecisionTaskRatherThanWaitingForNetworkTimeout() async {
        let engine = CancellableRecoveryEngine()
        let runner = VoiceControlTurnRunner(adapter: RecoveryAdapter(), engine: engine)
        let operation = Task { await runner.submit("Find flights") }
        await engine.waitUntilStarted()
        runner.stop()
        await operation.value
        let cancelled = await engine.wasCancelled
        XCTAssertTrue(cancelled)
    }

    func testTraceContainsStageEvidenceButNoTaskContent() async throws {
        let runner = VoiceControlTurnRunner(adapter: RecoveryAdapter(), engine: RecoveryEngine([
            .action(.init(operation: .setValue, targetID: "destination", value: "PRIVATE_PAYLOAD_123")), .finished
        ]))
        await runner.submit("PRIVATE_COMMAND_456")
        let records = await runner.traceSnapshot()
        let json = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_PAYLOAD"))
        XCTAssertFalse(json.contains("PRIVATE_COMMAND"))
        XCTAssertTrue(records.contains { $0.targetID == "destination" && $0.actor == "local" })
        XCTAssertTrue(records.contains { $0.stage == "verification" && $0.outcome == "verified" })
        XCTAssertTrue(records.contains { $0.stage == "observation" && $0.candidateCount != nil })
        let shareable = records.map { $0.shareable() }
        XCTAssertTrue(shareable.contains { $0.targetID == "destination" && $0.targetLabel == nil })
    }

    func testConsequentialTransitionPausesAndCannotReplayAfterChangedState() async {
        let adapter = CommitmentTransitionAdapter()
        let action = VoiceControlAction(operation: .press, targetID: "pay", consequence: .payment)
        let engine = RecoveryEngine([.action(action), .action(action)])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Pay for the order")
        await runner.confirm()
        let initialCalls = await engine.goals.count
        XCTAssertEqual(initialCalls, 1, "A visual transition must not automatically advance a payment task")
        await runner.continueTask()
        await runner.confirm()
        let effects = await adapter.effects
        XCTAssertEqual(effects, 1, "Changed surrounding UI does not authorize repeating uncertain payment")
        let records = await runner.traceSnapshot()
        XCTAssertTrue(records.contains { $0.outcome == "commitment_outcome_unverified" })
        XCTAssertTrue(records.contains { $0.outcome == "uncertain_replay_blocked" })
    }

    func testJevClarifyOperationDoesNotMasqueradeAsTargetAmbiguity() async throws {
        let client = JevDecisionClient(apiKey: "fixture", consent: { true }, transport: { request in
            let root = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let questions = root["questions"] as! [String: [String: Any]]
            var answers: [String: Any] = [:]
            for (id, question) in questions {
                let options = question["criteria"] as! [String: String]
                let choice = id == "kind" ? "none" : options.keys.sorted()[0]
                let probabilities = Dictionary(uniqueKeysWithValues: options.keys.map { ($0, $0 == choice ? 1.0 : 0.0) })
                answers[id] = ["type": "choice", "choice": choice, "probabilities": probabilities, "confidence": 1.0]
            }
            let data = try JSONSerialization.data(withJSONObject: ["model": JevDecisionClient.model, "answers": answers])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let snapshot = VoiceControlSnapshot(
            contextID: "fixture", applicationName: "Fixture",
            targets: [VoiceControlTarget(id: "n:0", label: "Save", role: "AXButton", operations: [.press])])
        let result = try await client.decide(goal: "Do that", snapshot: snapshot, history: [])
        XCTAssertEqual(result, .clarify("I need more detail about the next step or requested outcome. What should happen next?"))
    }

    func testDeletionKeysRequireConfirmationOutsideFocusedTextEvenWithOrdinaryModelAssessment() {
        for key in ["delete", "backspace"] {
            let action = VoiceControlAction(operation: .key, targetID: "focused", value: key, consequence: .ordinary)
            let collection = VoiceControlTarget(id: "focused", label: "Messages", role: "AXTable", operations: [.key], isFocused: true, consequence: .ordinary)
            XCTAssertEqual(VoiceControlConsequencePolicy.consequence(of: action, target: collection), .destructive)
            let text = VoiceControlTarget(id: "focused", label: "Message", role: "AXTextArea", operations: [.key, .insertText], isFocused: true)
            XCTAssertEqual(VoiceControlConsequencePolicy.consequence(of: action, target: text), .ordinary)
            let unfocusedText = VoiceControlTarget(id: "focused", label: "Message", role: "AXTextArea", operations: [.key, .insertText])
            XCTAssertEqual(VoiceControlConsequencePolicy.consequence(of: action, target: unfocusedText), .destructive)
        }
    }

    func testNewSpokenRevisionSupersedesEarlierManualOverride() async {
        let adapter = RecoveryAdapter()
        let engine = RecoveryEngine([
            .action(.init(operation: .setValue, targetID: "destination", value: "Rome")), .finished,
            .finished, .action(.init(operation: .setValue, targetID: "destination", value: "London")), .finished
        ])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Find flights to Rome")
        runner.pauseForManualInput()
        await adapter.manuallySet("Paris")
        await runner.continueTask()
        await runner.revise("No, London")
        let goals = await engine.goals
        XCTAssertTrue(goals[2].contains("destination: Paris"))
        XCTAssertFalse(goals[3].contains("destination: Paris"))
        XCTAssertTrue(goals[3].contains("No, London"))
        let value = await adapter.value
        XCTAssertEqual(value, "London")
    }

    func testRevokedIngressCannotRenewAuthorityAfterWaitingForPriorWork() async {
        let adapter = RecoveryAdapter()
        let engine = SuspendedIngressEngine()
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        let firstIngress = ActionAuthority()
        let first = Task { await runner.submit("First", submissionAuthority: firstIngress) }
        await engine.waitUntilStarted()
        let nextIngress = ActionAuthority()
        let next = Task { await runner.submit("Late instruction", submissionAuthority: nextIngress) }
        while firstIngress.isValid { await Task.yield() }
        nextIngress.revoke()
        await engine.release()
        await first.value
        await next.value
        let effects = await adapter.effects
        let calls = await engine.calls
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(calls, 1)
    }

    func testRevokedQueuedCancelCannotCancelNewTask() async {
        let runner = VoiceControlTurnRunner(adapter: RecoveryAdapter(), engine: RecoveryEngine([.finished]))
        await runner.submit("Current task")
        let obsolete = ActionAuthority()
        obsolete.revoke()
        await runner.cancel(submissionAuthority: obsolete)
        let hasTask = await runner.hasTask
        XCTAssertTrue(hasTask)
    }

    func testConfirmationMayReuseItsStillValidIngressAuthority() async {
        let adapter = RecoveryAdapter()
        let engine = RecoveryEngine([.action(.init(operation: .press, targetID: "alpha", consequence: .payment)), .finished])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        let ingress = ActionAuthority()
        await runner.submit("Commit this payment", submissionAuthority: ingress)
        await runner.confirm(submissionAuthority: ingress)
        let effects = await adapter.effects
        XCTAssertEqual(effects.count, 1)
        XCTAssertTrue(ingress.isValid)
    }

    func testStaleConfirmationDoesNotDispatchAReboundControl() async {
        let adapter = RecoveryAdapter()
        await adapter.expireNextExecute()
        let engine = RecoveryEngine([.action(.init(operation: .press, targetID: "alpha", targetLabel: "Alpha", consequence: .payment)), .finished])
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Commit this payment")
        await runner.confirm()
        let effects = await adapter.effects
        XCTAssertTrue(effects.isEmpty)
        let records = await runner.traceSnapshot()
        XCTAssertTrue(records.contains { $0.outcome == "confirmation_stale" })
    }

    func testConsequencePolicyAllowsOrdinaryTaskStepsAndProtectsCommitments() {
        func policy(_ label: String, operation: VoiceControlOperation = .press, assessment: VoiceControlConsequence = .ordinary) -> VoiceControlConsequence {
            VoiceControlConsequencePolicy.consequence(of: .init(operation: operation, targetID: "t", consequence: assessment), target: .init(id: "t", label: label, role: "control", operations: [operation]))
        }
        XCTAssertEqual(policy("Search flights"), .ordinary)
        XCTAssertEqual(policy("20 September"), .ordinary)
        XCTAssertEqual(policy("Remove filter"), .ordinary)
        XCTAssertEqual(policy("Submit search"), .ordinary)
        XCTAssertEqual(policy("Globe", assessment: .unknown), .ordinary)
        XCTAssertEqual(policy("Pay now"), .payment)
        XCTAssertEqual(policy("Place your order"), .payment)
        XCTAssertEqual(policy("Complete booking"), .payment)
        XCTAssertEqual(policy("Address book"), .ordinary)
        XCTAssertEqual(policy("Delete file"), .destructive)
        XCTAssertEqual(policy("Send message"), .externalCommitment)
        let continued = VoiceControlTarget(
            id: "t", label: "Continue", role: "button", operations: [.press], consequence: .payment)
        XCTAssertEqual(
            VoiceControlConsequencePolicy.consequence(
                of: .init(operation: .press, targetID: "t", consequence: .ordinary), target: continued),
            .payment)
        let unmarked = VoiceControlTarget(
            id: "t", label: "Continue", role: "button", operations: [.press], consequence: .unknown)
        XCTAssertEqual(
            VoiceControlConsequencePolicy.consequence(
                of: .init(operation: .press, targetID: "t", consequence: .ordinary), target: unmarked),
            .unknown)
        XCTAssertEqual(policy("Payment amount", operation: .setValue), .ordinary)
        let returnKey = VoiceControlAction(operation: .key, targetID: "t", value: "return")
        let body = VoiceControlTarget(
            id: "t", label: "Body", role: "text", operations: [.insertText, .key], isFocused: true)
        XCTAssertEqual(VoiceControlConsequencePolicy.consequence(of: returnKey, target: body), .ordinary)
        let listOption = VoiceControlTarget(
            id: "t", label: "One way", role: "AXStaticText", operations: [.press], isNavigation: true)
        XCTAssertEqual(
            VoiceControlConsequencePolicy.consequence(
                of: .init(operation: .press, targetID: "t", consequence: .unknown), target: listOption),
            .ordinary)
    }

    func testRevokedSubmissionAuthorityDoesNotStartTask() async {
        let engine = RecoveryEngine([.finished])
        let runner = VoiceControlTurnRunner(adapter: RecoveryAdapter(), engine: engine)
        let token = ActionAuthority()
        token.revoke()
        await runner.submit("Find flights", submissionAuthority: token)
        let goals = await engine.goals
        XCTAssertEqual(goals, [])
    }
}

private actor RecoveryAdapter: VoiceControlAdapter {
    var value = ""
    var effects: [VoiceControlAction] = []
    var context = "original"
    var expireNext = false
    let unknownPress: Bool
    init(unknownPress: Bool = false) { self.unknownPress = unknownPress }
    func manuallySet(_ value: String) { self.value = value }
    func changeContext() { context = "other-window" }
    func expireNextExecute() { expireNext = true }
    func observe() async throws -> VoiceControlSnapshot {
        VoiceControlSnapshot(contextID: context, applicationName: "Fixture", targets: [
            .init(id: "destination", label: "destination", role: "text", value: value, operations: [.setValue, .insertText], isFocused: true),
            .init(id: "alpha", label: "Alpha", role: "button", operations: [.press], isNavigation: true),
            .init(id: "beta", label: "Beta", role: "button", operations: [.press], isNavigation: true),
            .init(id: "gamma", label: "Gamma", role: "button", operations: [.press], isNavigation: true)
        ])
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws -> VoiceControlReceipt {
        try authority.check()
        if expireNext {
            expireNext = false
            throw NativeVoiceControlError.observationExpired
        }
        effects.append(action)
        if [.setValue, .insertText].contains(action.operation) { value = action.value ?? "" }
        return .init(status: action.operation == .press && unknownPress ? .unknown : .verified)
    }
}
private actor RecoveryEngine: VoiceControlDecisionEngine {
    var decisions: [VoiceControlDecision]
    var goals: [String] = []
    var histories: [[VoiceControlAction]] = []
    init(_ decisions: [VoiceControlDecision]) { self.decisions = decisions }
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws -> VoiceControlDecision {
        goals.append(goal); histories.append(history)
        return decisions.isEmpty ? .finished : decisions.removeFirst()
    }
}
private actor CancellableRecoveryEngine: VoiceControlDecisionEngine {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var wasCancelled = false
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws -> VoiceControlDecision {
        started = true; waiter?.resume(); waiter = nil
        do { try await Task.sleep(for: .seconds(60)); return .finished }
        catch { wasCancelled = true; throw error }
    }
}

private actor CommitmentTransitionAdapter: VoiceControlAdapter {
    var effects = 0
    func observe() async throws -> VoiceControlSnapshot {
        .init(contextID: "fixture", applicationName: "Fixture", targets: [
            .init(id: "pay", label: "Pay now", role: "button", operations: [.press])
        ], summary: "Surrounding interface revision \(effects)")
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws -> VoiceControlReceipt {
        try authority.check(); effects += 1
        return .init(status: .transitionObserved)
    }
}

private actor SuspendedIngressEngine: VoiceControlDecisionEngine {
    var calls = 0
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async { if !started { await withCheckedContinuation { startWaiter = $0 } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws -> VoiceControlDecision {
        calls += 1; started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return .action(.init(operation: .setValue, targetID: "destination", value: "Must not enter"))
    }
}
