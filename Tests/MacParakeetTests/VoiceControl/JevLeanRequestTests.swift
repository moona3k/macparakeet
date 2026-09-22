import Foundation
import XCTest

@testable import MacParakeetCore

/// The open-ended decision as one small, disjoint question set:
/// `kind` / `target` / `value` (focused field only) / `consequence` (advisory) / `direction`.
final class JevLeanRequestTests: XCTestCase {
    private actor Requests {
        private(set) var bodies: [[String: Any]] = []
        func record(_ data: Data) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { bodies.append(json) }
        }
    }

    /// Answers every head with `choices[head] ?? first option`, at `confidence`.
    private func client(
        choices: [String: String], confidence: Double = 0.9, confidences: [String: Double] = [:],
        requests: Requests? = nil, onDecision: JevDecisionClient.DecisionObserver? = nil
    ) -> JevDecisionClient {
        JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                await requests?.record(request.httpBody ?? Data())
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let questions = body?["questions"] as? [String: [String: Any]] ?? [:]
                var answers: [String: Any] = [:]
                for (name, question) in questions {
                    let keys = Array((question["criteria"] as? [String: String] ?? [:]).keys).sorted()
                    let choice = choices[name] ?? keys[0]
                    let conf = confidences[name] ?? confidence
                    var probabilities = Dictionary(
                        uniqueKeysWithValues: keys.map { ($0, (1 - conf) / Double(max(1, keys.count - 1))) })
                    probabilities[choice] = conf
                    answers[name] = [
                        "type": "choice", "choice": choice, "confidence": conf, "probabilities": probabilities,
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "model": JevDecisionClient.model, "answers": answers,
                ])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            onDecision: onDecision)
    }

    private let form = VoiceControlSnapshot(
        contextID: "ax:1", applicationName: "Google Chrome",
        targets: [
            VoiceControlTarget(
                id: "n:1", label: "Where from?", role: "AXComboBox", value: "", operations: [.setValue, .press],
                isFocused: true),
            VoiceControlTarget(
                id: "n:2", label: "Where to?", role: "AXComboBox", value: "", operations: [.setValue, .press]),
            VoiceControlTarget(id: "n:3", label: "Search flights", role: "AXButton", operations: [.press]),
            VoiceControlTarget(id: "n:4", label: "Results", role: "AXScrollArea", operations: [.scroll]),
        ])

    func testRequestHasOneDisjointKindSetAndOneTargetHead() async throws {
        let requests = Requests()
        _ = try await client(choices: ["kind": "finished"], requests: requests).decide(
            goal: "fly to London", snapshot: form, history: [])
        let bodies = await requests.bodies
        let body = try XCTUnwrap(bodies.first)
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(questions.keys), ["kind", "target", "value", "consequence", "direction"])
        let kinds = try XCTUnwrap(questions["kind"]?["criteria"] as? [String: String])
        XCTAssertEqual(Set(kinds.keys), ["press", "fill", "scroll", "finished", "none"])
        let targets = try XCTUnwrap(questions["target"]?["criteria"] as? [String: String])
        XCTAssertEqual(targets["n:1"], "combo field 'Where from?' (focused, empty)")
        XCTAssertEqual(targets["n:3"], "button 'Search flights'")
        XCTAssertEqual(targets["n:4"], "scroll area 'Results'")
        XCTAssertNotNil(targets["none"])
        XCTAssertTrue(
            (questions["value"]?["instructions"] as? String)?.contains("Where from?") == true,
            "value head belongs to the focused field")
    }

    func testFillIntoFocusedFieldIsOneRequest() async throws {
        let requests = Requests()
        let goal = "search for flights from Zurich"
        let spans = JevDecisionClient.sourceSpans(goal)
        let zurich = "v\(spans.firstIndex(of: "Zurich")!)"
        let decision = try await client(
            choices: ["kind": "fill", "target": "n:1", "value": zurich], requests: requests
        )
        .decide(goal: goal, snapshot: form, history: [])
        let requestCount = await requests.bodies.count
        XCTAssertEqual(requestCount, 1)
        guard case .action(let action) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(action.operation, .setValue)
        XCTAssertEqual(action.targetID, "n:1")
        XCTAssertEqual(action.value, "Zurich")
        XCTAssertEqual(action.decisionConfidence, 0.9)
    }

    func testFillIntoUnfocusedFieldMakesOneFollowUpValueRequest() async throws {
        let requests = Requests()
        let observed = Observed()
        let goal = "search for flights to London"
        let spans = JevDecisionClient.sourceSpans(goal)
        let london = "v\(spans.firstIndex(of: "London")!)"
        let decision = try await client(
            choices: ["kind": "fill", "target": "n:2", "value": london], requests: requests,
            onDecision: { await observed.append($0) }
        ).decide(goal: goal, snapshot: form, history: [])
        let bodies = await requests.bodies
        XCTAssertEqual(bodies.count, 2)
        let followUp = try XCTUnwrap(bodies[1]["questions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(followUp.keys), ["value"], "the second request asks one thing")
        XCTAssertTrue((followUp["value"]?["instructions"] as? String)?.contains("Where to?") == true)
        guard case .action(let action) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(action.targetID, "n:2")
        XCTAssertEqual(action.value, "London")
        let traces = await observed.traces
        let trace = try XCTUnwrap(traces.first)
        XCTAssertNotNil(trace.heads["value_followup"], "the follow-up head is recorded alongside the first request")
    }

    func testConfidenceIsMinOfKindAndTargetOnlyWhenATargetIsNamed() async throws {
        let low = try await client(choices: ["kind": "press", "target": "n:3"], confidences: ["target": 0.3])
            .decide(goal: "search", snapshot: form, history: [])
        guard case .clarify = low else { return XCTFail("a low target confidence must not press: \(low)") }
        let finished = try await client(choices: ["kind": "finished", "target": "none"], confidences: ["target": 0.3])
            .decide(goal: "done", snapshot: form, history: [])
        XCTAssertEqual(finished, .finished, "finished is gated on kind alone; the unused target head cannot lower it")
    }

    func testConsequenceConfidenceNeverPromptsOnlyItsArgmaxIsPassedOn() async throws {
        let decision = try await client(
            choices: ["kind": "press", "target": "n:3", "consequence": "ordinary"], confidences: ["consequence": 0.21]
        ).decide(goal: "search", snapshot: form, history: [])
        guard case .action(let action) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(action.consequence, .ordinary)
        XCTAssertEqual(VoiceControlConsequencePolicy.consequence(of: action, target: form.targets[2]), .ordinary)
    }

    func testScrollCarriesDirectionAndPressPicksSelectWhenThatIsAllTheTargetHas() async throws {
        let scroll = try await client(choices: ["kind": "scroll", "target": "n:4", "direction": "up"])
            .decide(goal: "scroll up", snapshot: form, history: [])
        XCTAssertEqual(
            scroll,
            .action(
                VoiceControlAction(
                    operation: .scroll, targetID: "n:4", value: "up", targetLabel: "Results", consequence: .ordinary,
                    modelID: JevDecisionClient.model, decisionConfidence: 0.9)))
        let selectable = VoiceControlSnapshot(
            contextID: "ax:2", applicationName: "App",
            targets: [VoiceControlTarget(id: "o:1", label: "Economy", role: "AXMenuItem", operations: [.select])])
        let select = try await client(choices: ["kind": "press", "target": "o:1"]).decide(
            goal: "economy", snapshot: selectable, history: [])
        guard case .action(let action) = select else { return XCTFail("\(select)") }
        XCTAssertEqual(action.operation, .select)
    }

    func testTooManyTargetsAreTruncatedByPriorityInsteadOfFailing() async throws {
        var targets = (0..<260).map {
            VoiceControlTarget(id: "n:\($0)", label: "Link \($0)", role: "AXLink", operations: [.press])
        }
        targets.append(
            VoiceControlTarget(
                id: "focus", label: "Query", role: "AXTextField", value: "", operations: [.setValue], isFocused: true))
        targets.append(
            VoiceControlTarget(id: "field", label: "Email", role: "AXTextField", value: "", operations: [.setValue]))
        let crowded = VoiceControlSnapshot(contextID: "ax:3", applicationName: "Safari", targets: targets)
        let requests = Requests()
        let observed = Observed()
        _ = try await client(
            choices: ["kind": "finished"], requests: requests, onDecision: { await observed.append($0) }
        )
        .decide(goal: "done", snapshot: crowded, history: [])
        let bodies = await requests.bodies
        let body = try XCTUnwrap(bodies.first)
        let criteria = try XCTUnwrap(
            (body["questions"] as? [String: [String: Any]])?["target"]?["criteria"] as? [String: String])
        XCTAssertEqual(criteria.count, JevDecisionClient.maxTargets + 1)
        XCTAssertNotNil(criteria["focus"]); XCTAssertNotNil(criteria["field"])
        XCTAssertNotNil(criteria["n:0"]);
        XCTAssertNil(criteria["n:259"], "the tail of traversal order is what gets dropped")
        let traces = await observed.traces
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace.truncatedTargets, 62)
    }

    func testPrioritisedKeepsTraversalOrderAmongKeptTargets() {
        let targets = [
            VoiceControlTarget(id: "a", label: "A", role: "AXLink", operations: [.press]),
            VoiceControlTarget(id: "b", label: "B", role: "AXTextField", operations: [.setValue]),
            VoiceControlTarget(id: "c", label: "C", role: "AXLink", operations: [.press]),
            VoiceControlTarget(id: "d", label: "D", role: "AXLink", operations: [.press], isFocused: true),
        ]
        let kept = JevDecisionClient.prioritised(targets, limit: 3)
        XCTAssertEqual(kept.targets.map(\.id), ["a", "b", "d"])
        XCTAssertEqual(kept.dropped, 1)
        XCTAssertEqual(JevDecisionClient.prioritised(targets, limit: 10).dropped, 0)
    }

    func testPrioritisedDuplicateIDsDoNotTrap() {
        var targets = (0..<200).map {
            VoiceControlTarget(id: "n:\($0)", label: "L\($0)", role: "AXButton", operations: [.press])
        }
        targets.append(VoiceControlTarget(id: "n:0", label: "dup", role: "AXButton", operations: [.press]))
        let kept = JevDecisionClient.prioritised(targets, limit: 200)
        XCTAssertEqual(kept.targets.count, 200)
        XCTAssertEqual(Set(kept.targets.map(\.id)).count, 200)
    }

    func testDuplicateTargetIDsFailBeforeARequest() async {
        let requests = Requests()
        let snapshot = VoiceControlSnapshot(
            contextID: "ax:dup", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(id: "same", label: "One", role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "same", label: "Two", role: "AXButton", operations: [.press]),
            ])
        do {
            _ = try await client(choices: ["kind": "press", "target": "same"], requests: requests).decide(
                goal: "open it", snapshot: snapshot, history: [])
            XCTFail("duplicate ids must not reach Jev")
        } catch is JevDecisionError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        let requestCount = await requests.bodies.count
        XCTAssertEqual(requestCount, 0)
    }

    func testIndistinguishableControlsClarify() async throws {
        let twins = VoiceControlSnapshot(
            contextID: "ax:twins", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(
                    id: "a", label: "Details", role: "AXButton", operations: [.press], region: "top-left"),
                VoiceControlTarget(
                    id: "b", label: "Details", role: "AXButton", operations: [.press], region: "top-left"),
            ])
        let decision = try await client(choices: ["kind": "press", "target": "a", "consequence": "ordinary"]).decide(
            goal: "open details", snapshot: twins, history: [])
        guard case .clarify(let question) = decision else { return XCTFail("\(decision)") }
        XCTAssertTrue(question.contains("indistinguishable"))
    }

    func testDistinctRegionsStillSelectATwin() async throws {
        let twins = VoiceControlSnapshot(
            contextID: "ax:twins", applicationName: "Fixture",
            targets: [
                VoiceControlTarget(
                    id: "a", label: "Details", role: "AXButton", operations: [.press], region: "top-left"),
                VoiceControlTarget(
                    id: "b", label: "Details", role: "AXButton", operations: [.press], region: "bottom-right"),
            ])
        let decision = try await client(choices: ["kind": "press", "target": "b", "consequence": "ordinary"]).decide(
            goal: "open details", snapshot: twins, history: [])
        guard case .action(let action) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(action.targetID, "b")
    }

    func testNoOperableTargetsClarifiesWithoutARequest() async throws {
        let requests = Requests()
        let empty = VoiceControlSnapshot(
            contextID: "ax:4", applicationName: "Finder",
            targets: [VoiceControlTarget(id: "app:1", label: "Slack", role: "application", operations: [.activateApp])])
        let decision = try await client(choices: [:], requests: requests).decide(
            goal: "anything", snapshot: empty, history: [])
        guard case .clarify = decision else { return XCTFail("\(decision)") }
        let requestCount = await requests.bodies.count
        XCTAssertEqual(requestCount, 0)
    }

    func testRegionHintsNameTheGridCellAndTellTwinsApart() async throws {
        let window = CGRect(x: 100, y: 50, width: 900, height: 600)
        XCTAssertEqual(
            VoiceControlTarget.region(of: CGRect(x: 110, y: 60, width: 40, height: 20), in: window), "top-left")
        XCTAssertEqual(
            VoiceControlTarget.region(of: CGRect(x: 530, y: 330, width: 40, height: 20), in: window), "middle-center")
        XCTAssertEqual(
            VoiceControlTarget.region(of: CGRect(x: 950, y: 620, width: 40, height: 20), in: window), "bottom-right")
        XCTAssertNil(VoiceControlTarget.region(of: nil, in: window))
        XCTAssertNil(VoiceControlTarget.region(of: .zero, in: nil))
        let twins = VoiceControlSnapshot(
            contextID: "ax:9", applicationName: "Mail",
            targets: [
                VoiceControlTarget(
                    id: "n:1", label: "Delete", role: "AXButton", operations: [.press], region: "top-left"),
                VoiceControlTarget(
                    id: "n:2", label: "Delete", role: "AXButton", operations: [.press], region: "bottom-right"),
            ])
        let requests = Requests()
        _ = try await client(choices: ["kind": "finished"], requests: requests).decide(
            goal: "delete", snapshot: twins, history: [])
        let bodies = await requests.bodies
        let criteria = try XCTUnwrap(
            (bodies.first?["questions"] as? [String: [String: Any]])?["target"]?["criteria"] as? [String: String])
        XCTAssertEqual(criteria["n:1"], "button 'Delete' (top-left)")
        XCTAssertEqual(criteria["n:2"], "button 'Delete' (bottom-right)")
        let wire = try XCTUnwrap(
            ((bodies.first?["state"] as? [String: Any])?["observation"] as? [String: Any])?["targets"]
                as? [[String: Any]])
        XCTAssertEqual(wire.first?["region"] as? String, "top-left")
    }

    private actor Observed {
        private(set) var traces: [VoiceControlDecisionTrace] = []
        func append(_ trace: VoiceControlDecisionTrace) { traces.append(trace) }
    }
}
