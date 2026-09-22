import Foundation
import XCTest
@testable import MacParakeetCore

final class VoiceControlCoreTests: XCTestCase {
    func testAuthorityPreventsEveryEffectAfterRevocation() throws {
        let authority = ActionAuthority()
        var effects = 0
        try authority.perform { effects += 1 }
        authority.revoke()
        XCTAssertThrowsError(try authority.perform { effects += 1 })
        XCTAssertEqual(effects, 1)
    }

    func testJevRejectsUnlistedTargetAndInvalidDistributions() throws {
        let valid = JevDecisionClient.Answer(
            type: "choice", choice: "a", probabilities: ["a": 0.8, "b": 0.2], confidence: 0.6)
        XCTAssertNoThrow(try JevDecisionClient.validate(valid, offered: ["a", "b"]))
        XCTAssertThrowsError(try JevDecisionClient.validate(valid, offered: ["a"]))
        let wrongMaximum = JevDecisionClient.Answer(
            type: "choice", choice: "b", probabilities: ["a": 0.8, "b": 0.2], confidence: 0.6)
        XCTAssertThrowsError(try JevDecisionClient.validate(wrongMaximum, offered: ["a", "b"]))
        let nonNormalized = JevDecisionClient.Answer(
            type: "choice", choice: "a", probabilities: ["a": 0.8, "b": 0.8], confidence: 0.6)
        XCTAssertThrowsError(try JevDecisionClient.validate(nonNormalized, offered: ["a", "b"]))
    }

    func testRoundedProbabilitySumAcceptsFloatingPointDrift() throws {
        let rounded = JevDecisionClient.Answer(
            type: "choice", choice: "a", probabilities: ["a": 0.74, "b": 0.25], confidence: 0.6)
        XCTAssertNoThrow(try JevDecisionClient.validate(rounded, offered: ["a", "b"]))
        let invalid = JevDecisionClient.Answer(
            type: "choice", choice: "a", probabilities: ["a": 0.73, "b": 0.25], confidence: 0.6)
        XCTAssertThrowsError(try JevDecisionClient.validate(invalid, offered: ["a", "b"]))
    }

    func testObservedTransitionReplansFromFreshObservation() async {
        let adapter = CoreTransitionAdapter(changesState: true)
        let engine = CoreTransitionEngine()
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Open the next page")
        let observations = await adapter.observations
        let history = await engine.lastHistory
        XCTAssertEqual(observations, 2)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.receiptStatus, .transitionObserved)
    }

    func testRefreshedIDsCannotReplayActionAgainstSamePrestate() async {
        let adapter = CoreTransitionAdapter(changesState: false)
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: CoreRepeatingEngine())
        await runner.submit("Open the next page")
        await runner.resume()
        let executed = await adapter.executed
        XCTAssertEqual(executed, 1)
    }

    func testWireRedactsSelectionAndOffersOnlySupportedDirectionsAndKeys() async throws {
        let capture = CoreRequestCapture()
        let selected = "selection-only-private-content"
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(
                    id: "text", label: "Message", role: "textbox", value: "visible",
                    operations: [.setValue, .insertText], selectedText: selected)
            ])
        let client = JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                await capture.record(request.httpBody ?? Data())
                return (
                    Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                )
            })
        do { _ = try await client.decide(goal: "fill message", snapshot: snapshot, history: []) } catch {}
        let body = await capture.body
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        let observation = try XCTUnwrap(state["observation"] as? [String: Any])
        let targets = try XCTUnwrap(observation["targets"] as? [[String: Any]])
        XCTAssertNil(targets.first?["selectedText"])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(selected))
        XCTAssertEqual(snapshot.targets[0].selectedText, selected)
        let questions = try XCTUnwrap(json["questions"] as? [String: [String: Any]])
        XCTAssertNil(questions["key"])
        XCTAssertNil(questions["direction"], "no scrollable target, so no direction head")
        let kinds = try XCTUnwrap(questions["kind"]?["criteria"] as? [String: String])
        XCTAssertEqual(Set(kinds.keys), ["fill", "finished", "none"], "one disjoint kind set; keys and consequence never join it")
        XCTAssertEqual(Set(questions.keys), ["kind", "target", "consequence"], "the field is not focused, so there is no value head")
    }

    func testJevRequestOmitsAppSwitchingWhenPageControlsExist() async throws {
        let capture = CoreRequestCapture()
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "from", label: "Where from?", role: "AXComboBox", operations: [.setValue, .press]),
                VoiceControlTarget(
                    id: "app:1", label: "Slack", role: "application", operations: [.activateApp]),
                VoiceControlTarget(
                    id: "web:google-flights", label: "Google Flights", role: "url", operations: [.press],
                    isNavigation: true),
            ])
        let client = JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                await capture.record(request.httpBody ?? Data())
                return (
                    Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                )
            })
        do { _ = try await client.decide(goal: "Find flights to London", snapshot: snapshot, history: []) } catch {}
        let body = await capture.body
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let encoded = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(encoded.contains("Slack"))
        XCTAssertFalse(encoded.contains("activateApp"))
        XCTAssertFalse(encoded.contains("Google Flights"))
        XCTAssertFalse(encoded.contains("web:google-flights"))
        let questions = try XCTUnwrap(json["questions"] as? [String: [String: Any]])
        let targetCriteria = try XCTUnwrap(questions["target"]?["criteria"] as? [String: String])
        XCTAssertEqual(Set(targetCriteria.keys), ["from", "none"])
        XCTAssertEqual(targetCriteria["from"], "combo field 'Where from?' (empty)")
        let observation = try XCTUnwrap((json["state"] as? [String: Any])?["observation"] as? [String: Any])
        let targets = try XCTUnwrap(observation["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.map { $0["id"] as? String }, ["from"])
    }

    func testJevRequestOmitsURLDestinationsEvenWhenThePageHasNoControls() async throws {
        let capture = CoreRequestCapture()
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "web:gmail", label: "Gmail", role: "url", operations: [.press], isNavigation: true),
            ])
        let client = JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                await capture.record(request.httpBody ?? Data())
                return (
                    Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                )
            })
        do { _ = try await client.decide(goal: "open gmail", snapshot: snapshot, history: []) } catch {}
        let body = await capture.body
        let encoded = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(encoded.contains("web:gmail"))
        XCTAssertFalse(encoded.contains("Gmail"))
    }

    func testInformationNeedsNoEffectAndDoesNotRequireCompleteObservation() async {
        let runner = VoiceControlTurnRunner(adapter: CoreDirectAdapter(), engine: CoreInformationEngine())
        await runner.submit("help")
        var iterator = runner.events.makeAsyncIterator()
        var final: VoiceControlEvent?
        for _ in 0..<3 { final = await iterator.next() }
        XCTAssertEqual(final, .completed("Available commands."))
    }

    func testVerifiedDirectCompletionIgnoresUnrelatedObservationTruncation() async {
        let adapter = CoreDirectAdapter()
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: CoreDirectEngine())
        await runner.submit("type hello")
        var iterator = runner.events.makeAsyncIterator()
        var final: VoiceControlEvent?
        // Exactly observing/deciding/acting, then observing/deciding/completed.
        for _ in 0..<7 { final = await iterator.next() }
        XCTAssertEqual(final, .completed("Text entered."))
    }

    func testSourceSpansPreserveLiteralText() {
        let text = "type Please, keep  BOTH spaces and punctuation!"
        XCTAssertTrue(JevDecisionClient.sourceSpans(text).contains("Please, keep  BOTH spaces and punctuation!"))
        XCTAssertTrue(JevDecisionClient.sourceSpans(text).allSatisfy { text.contains($0) })
        XCTAssertEqual(JevDecisionClient.sourceSpans(""), [])
        XCTAssertTrue(JevDecisionClient.sourceSpans("Set destination to London.").contains("London"))
        XCTAssertTrue(JevDecisionClient.sourceSpans("type Hello!").contains("Hello!"))
        XCTAssertTrue(JevDecisionClient.sourceSpans("Set city to St. Louis.").contains("St. Louis"))
    }

    func testNoNetworkWithoutConsentAndErrorsNeverEchoResponse() async throws {
        let calls = CoreTransportCounter()
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Fixture",
            targets: [VoiceControlTarget(id: "n:0", label: "Save", role: "AXButton", operations: [.press])])
        let denied = JevDecisionClient(
            apiKey: "test-secret", consent: { false },
            transport: { request in
                await calls.increment()
                return (
                    Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        do {
            _ = try await denied.decide(goal: "test", snapshot: snapshot, history: []);
            XCTFail("Expected consent rejection")
        } catch { XCTAssertFalse(error.localizedDescription.contains("test-secret")) }
        let count = await calls.count
        XCTAssertEqual(count, 0)
        let rejected = JevDecisionClient(
            apiKey: "test-secret", consent: { true },
            transport: { request in
                (
                    Data("test-secret private document".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                )
            })
        do {
            _ = try await rejected.decide(goal: "test", snapshot: snapshot, history: []); XCTFail("Expected rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("test-secret"));
            XCTAssertFalse(error.localizedDescription.contains("private document"))
        }
    }

    func testUnknownPressRequiresConfirmationAndStopRevokesIt() async {
        let adapter = CoreTestAdapter()
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: CoreTestEngine())
        await runner.submit("Click send")
        let initial = await adapter.executed
        XCTAssertEqual(initial, 0)
        runner.stop()
        await runner.confirm()
        let stopped = await adapter.executed
        XCTAssertEqual(stopped, 0)
    }

    func testUnknownReceiptIsNeverAutomaticallyRetried() async {
        let adapter = CoreTestAdapter(navigation: true)
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: CoreTestEngine())
        await runner.submit("Open item")
        await runner.resume()
        let executed = await adapter.executed
        XCTAssertEqual(executed, 1)
    }

    func testStaleSnapshotIDsRematchByUniqueLabel() async {
        let adapter = CoreTransitionAdapter(changesState: false)
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: CoreStaleIDEngine())
        await runner.submit("Open the next page")
        let executed = await adapter.executed
        XCTAssertEqual(executed, 1)
    }

    func testSelectedLabelPostconditionPromotesTransitionToVerified() async {
        let adapter = CoreLandingAdapter()
        let engine = CoreLandingEngine()
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        await runner.submit("Choose Zurich")
        let history = await engine.lastHistory
        XCTAssertEqual(history.last?.receiptStatus, .verified)
        let records = await runner.traceSnapshot()
        XCTAssertTrue(records.contains { $0.outcome == "postcondition_holds" })
    }
}

private actor CoreTestAdapter: VoiceControlAdapter {
    var executed = 0
    let navigation: Bool
    init(navigation: Bool = false) { self.navigation = navigation }
    func observe() async throws -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            contextID: "test", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(
                    id: "t1", label: navigation ? "Next" : "Send", role: "button", operations: [.press], isNavigation: navigation)
            ])
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws
        -> VoiceControlReceipt
    {
        try authority.check(); executed += 1
        return VoiceControlReceipt(status: .unknown)
    }
}
private struct CoreTestEngine: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        .action(VoiceControlAction(operation: .press, targetID: "t1"))
    }
}

private actor CoreTransportCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor CoreTransitionAdapter: VoiceControlAdapter {
    let changesState: Bool
    var observations = 0
    var executed = 0
    init(changesState: Bool) { self.changesState = changesState }
    func observe() async throws -> VoiceControlSnapshot {
        observations += 1
        return VoiceControlSnapshot(
            contextID: "test", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(
                    id: UUID().uuidString, label: "Next", role: "button", operations: [.press], isNavigation: true)
            ], summary: changesState && executed > 0 ? "New page" : "Original page")
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws
        -> VoiceControlReceipt
    {
        try authority.check(); executed += 1
        return VoiceControlReceipt(status: .transitionObserved)
    }
}
private actor CoreTransitionEngine: VoiceControlDecisionEngine {
    var lastHistory: [VoiceControlAction] = []
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        lastHistory = history
        if snapshot.summary == "New page" { return .finished }
        return .action(VoiceControlAction(operation: .press, targetID: snapshot.targets[0].id))
    }
}
private struct CoreRepeatingEngine: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        .action(VoiceControlAction(operation: .press, targetID: snapshot.targets[0].id))
    }
}

private struct CoreStaleIDEngine: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        .action(VoiceControlAction(operation: .press, targetID: "stale", targetLabel: "Next"))
    }
}

private actor CoreLandingAdapter: VoiceControlAdapter {
    var executed = 0
    func observe() async throws -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            contextID: "test", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(
                    id: "city", label: "Zürich, Switzerland", role: "AXStaticText", operations: [.press],
                    isFocused: executed > 0)
            ])
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws
        -> VoiceControlReceipt
    {
        try authority.check(); executed += 1
        return VoiceControlReceipt(status: .transitionObserved)
    }
}

private actor CoreLandingEngine: VoiceControlDecisionEngine {
    var lastHistory: [VoiceControlAction] = []
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        lastHistory = history
        if history.last?.receiptStatus == .verified { return .finished }
        return .action(
            VoiceControlAction(
                operation: .press, targetID: "city", targetLabel: "Zürich, Switzerland",
                postcondition: .selectedLabel("Zürich, Switzerland")))
    }
}

private actor CoreRequestCapture {
    var body = Data()
    func record(_ value: Data) { body = value }
}
private actor CoreDirectAdapter: VoiceControlAdapter {
    var edited = false
    func observe() async throws -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            contextID: "test", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(
                    id: "text", label: "Message", role: "textbox", value: edited ? "hello" : "", operations: [.setValue]
                )
            ], isComplete: false)
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws
        -> VoiceControlReceipt
    {
        try authority.check(); edited = true
        return VoiceControlReceipt(status: .verified)
    }
}
private struct CoreDirectEngine: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        history.isEmpty
            ? .action(VoiceControlAction(operation: .setValue, targetID: "text", value: "hello"))
            : .directCompleted("Text entered.")
    }
}

private struct CoreInformationEngine: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        .information("Available commands.")
    }
}
