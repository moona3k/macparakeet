import Foundation
import XCTest

@testable import MacParakeetCore

/// Probabilities, replayable observations, dry run and timing: the parts that
/// make a stalled turn reproducible offline instead of on a live app.
final class VoiceControlObservabilityTests: XCTestCase {
    private func temporaryRoot() -> (root: URL, pointer: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-control-obs-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("pointer", isDirectory: true))
    }

    // MARK: Decision traces

    func testOutcomeChoiceEmitsHeadProbabilitiesToTheObserver() async throws {
        let observed = DecisionCapture()
        let events = [
            VoiceControlEnabledEvent(
                id: "c0", criteria: "After the host acts, London, United Kingdom is the selected result.",
                action: VoiceControlAction(operation: .press, targetID: "c0", targetLabel: "London, United Kingdom")),
            VoiceControlEnabledEvent(
                id: "c1", criteria: "After the host acts, London, Ontario is the selected result.",
                action: VoiceControlAction(operation: .press, targetID: "c1", targetLabel: "London, Ontario")),
        ]
        let client = JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                let answers: [String: Any] = [
                    "outcome": [
                        "type": "choice", "choice": "c0", "confidence": 0.81,
                        "probabilities": ["c0": 0.7, "c1": 0.2, "insufficient_evidence": 0.06, "clarify": 0.04],
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: [
                    "model": JevDecisionClient.model, "answers": answers,
                ])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            onDecision: { await observed.append($0) })
        let snapshot = VoiceControlSnapshot(
            contextID: "chrome", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "c0", label: "London, United Kingdom", role: "AXStaticText", operations: [.press]),
                VoiceControlTarget(
                    id: "c1", label: "London, Ontario", role: "AXStaticText", operations: [.press], isFocused: true),
                VoiceControlTarget(id: "else", label: "Where else?", role: "AXComboBox", operations: [.setValue, .press]),
            ])
        _ = try await client.decide(goal: "fly to London", snapshot: snapshot, history: [], events: events)
        let traces = await observed.traces
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace.kind, "outcome")
        XCTAssertEqual(trace.resolution, "action")
        XCTAssertEqual(trace.situation, "suggestionPicker")
        XCTAssertEqual(trace.model, JevDecisionClient.model)
        XCTAssertGreaterThan(trace.requestBytes, 0)
        let head = try XCTUnwrap(trace.heads["outcome"])
        XCTAssertEqual(head.choice, "c0")
        XCTAssertEqual(head.top(2).map(\.option), ["c0", "c1"])
        // Only ids and closed tokens cross the observer boundary.
        let encoded = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        XCTAssertFalse(encoded.contains("London"))
        XCTAssertFalse(encoded.contains("fly to"))
    }

    func testUnconstrainedRequestEmitsEveryHeadAndResolutionToken() async throws {
        let observed = DecisionCapture()
        let client = JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let questions = body?["questions"] as? [String: [String: Any]] ?? [:]
                var answers: [String: Any] = [:]
                for (name, question) in questions {
                    let keys = Array((question["criteria"] as? [String: String] ?? [:]).keys).sorted()
                    // Pick a low-confidence "none"/first option so the client clarifies.
                    let choice = keys.contains("none") ? "none" : keys[0]
                    let share = 1.0 / Double(keys.count)
                    answers[name] = [
                        "type": "choice", "choice": choice, "confidence": 0.2,
                        "probabilities": Dictionary(uniqueKeysWithValues: keys.map { ($0, share) }),
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "model": JevDecisionClient.model, "answers": answers,
                ])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            onDecision: { await observed.append($0) })
        let snapshot = VoiceControlSnapshot(
            contextID: "notes", applicationName: "Notes",
            targets: [VoiceControlTarget(id: "n:0", label: "New Note", role: "AXButton", operations: [.press])])
        let decision = try await client.decide(goal: "make a note", snapshot: snapshot, history: [])
        guard case .clarify = decision else { return XCTFail("expected clarify, got \(decision)") }
        let unconstrainedTraces = await observed.traces
        let trace = try XCTUnwrap(unconstrainedTraces.first)
        XCTAssertEqual(trace.kind, "unconstrained")
        XCTAssertEqual(trace.resolution, "clarify")
        XCTAssertEqual(trace.situation, "plain")
        XCTAssertEqual(Set(trace.heads.keys), ["kind", "target", "consequence"])
    }

    // MARK: Trace store

    func testStorePersistsDecisionsReplayableObservationsAndTimingLine() async throws {
        let (root, pointer) = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceControlTraceStore(directory: root, pointerDirectory: pointer, retention: 5)
        let taskID = UUID()
        await store.beginTask(id: taskID, instruction: "Find flights to London")
        let snapshot = VoiceControlSnapshot(
            contextID: "ax:42:7", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "n:3", label: "Where from?", role: "AXComboBox", value: "SECRET_VALUE",
                    operations: [.setValue, .press, .key], isFocused: true),
                VoiceControlTarget(id: "n:9", label: "Search flights", role: "AXButton", operations: [.press]),
            ],
            summary: "Google Flights\nZürich ZRH\nFlight results")
        await store.noteObservation(snapshot)
        await store.record(
            VoiceControlTraceRecord(
                id: UUID(), taskID: taskID, revision: 0, timestamp: Date(), stage: "observation", operation: nil,
                outcome: "complete", durationMilliseconds: 400, candidateCount: 2, observationComplete: true,
                modelID: nil, decisionScore: nil, detail: nil))
        await store.record(
            VoiceControlTraceRecord(
                id: UUID(), taskID: taskID, revision: 0, timestamp: Date(), stage: "observation", operation: nil,
                outcome: "complete", durationMilliseconds: 600, candidateCount: 2, observationComplete: true,
                modelID: nil, decisionScore: nil, detail: nil))
        await store.record(
            VoiceControlTraceRecord(
                id: UUID(), taskID: taskID, revision: 0, timestamp: Date(), stage: "decision", operation: .press,
                outcome: "received", durationMilliseconds: 240, candidateCount: nil, observationComplete: nil,
                modelID: JevDecisionClient.model, decisionScore: 0.81, detail: nil, actor: "jev", route: "jev",
                targetID: "n:9", targetLabel: "Search flights"))
        await store.noteDecision(
            VoiceControlDecisionTrace(
                model: JevDecisionClient.model, kind: "outcome", situation: "plain",
                heads: [
                    "outcome": .init(
                        choice: "n:9", confidence: 0.81,
                        probabilities: ["n:9": 0.7, "n:3": 0.2, "insufficient_evidence": 0.06, "clarify": 0.04])
                ],
                requestBytes: 1_234, latencyMilliseconds: 240, resolution: "action"))

        let loaded = await store.loadLatest()
        let session = try XCTUnwrap(loaded)
        let observation = try XCTUnwrap(session.observations.last)
        XCTAssertEqual(observation.snapshotID, snapshot.id)
        XCTAssertEqual(observation.contextID, "ax:42:7")
        XCTAssertEqual(observation.summary, snapshot.summary)
        let rebuilt = observation.snapshot()
        XCTAssertEqual(rebuilt.id, snapshot.id)
        XCTAssertEqual(rebuilt.contextID, snapshot.contextID)
        XCTAssertEqual(rebuilt.targets.map(\.id), ["n:3", "n:9"])
        XCTAssertEqual(rebuilt.targets[0].operations, [.setValue, .press, .key])
        XCTAssertTrue(rebuilt.targets[0].isFocused)
        XCTAssertEqual(rebuilt.targets[0].value, "", "values are not persisted; a replay sees an empty field")
        XCTAssertNil(rebuilt.targets[1].value)
        XCTAssertEqual(VoiceControlSituation.classify(rebuilt), VoiceControlSituation.classify(snapshot))

        XCTAssertEqual(session.decisions?.count, 1)
        XCTAssertEqual(session.decisions?.first?.heads["outcome"]?.probabilities["n:3"], 0.2)
        let timing = try XCTUnwrap(session.summary?.timing)
        XCTAssertEqual(
            timing["observation"], VoiceControlStageTiming(count: 2, meanMilliseconds: 500, maxMilliseconds: 600))
        XCTAssertEqual(timing["decision"]?.meanMilliseconds, 240)

        let disk = String(decoding: try Data(contentsOf: store.latestURL), as: UTF8.self)
        XCTAssertFalse(disk.contains("SECRET_VALUE"), "field values never reach disk")
        let markdown = String(decoding: try Data(contentsOf: store.latestMarkdownURL), as: UTF8.self)
        XCTAssertTrue(
            markdown.contains("timing: observation 500ms (max 600, n=2)  decision 240ms (max 240, n=1)"), markdown)
        XCTAssertTrue(markdown.contains("jev: outcome action 240ms 1234B situation=plain"), markdown)
        XCTAssertTrue(
            markdown.contains("outcome: n:9 (0.81) n:9 \"Search flights\"=0.70 n:3 \"Where from?\"=0.20"), markdown)
        let events = String(decoding: try Data(contentsOf: store.eventsURL), as: UTF8.self)
        XCTAssertTrue(events.contains("\"type\":\"decision\""))
        XCTAssertTrue(events.contains("\"kind\":\"outcome\""))
    }

    func testShareableDiagnosticsShapeIsUnchangedByDecisionTraces() throws {
        let record = VoiceControlTraceRecord(
            id: UUID(), taskID: UUID(), revision: 0, timestamp: Date(), stage: "decision", operation: .press,
            outcome: "received", durationMilliseconds: 240, candidateCount: nil, observationComplete: nil,
            modelID: JevDecisionClient.model, decisionScore: 0.81, detail: nil, actor: "jev", route: "jev",
            targetID: "n:9", targetLabel: "Search flights")
        let export = VoiceControlShareableDiagnostics.make(
            schema: VoiceControlTraceStore.schema, taskID: record.taskID, summary: nil, records: [record])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(export)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["schema", "taskID", "records"])
        let encoded = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Search flights"))
        XCTAssertFalse(encoded.contains("decisions"))
    }

    // MARK: Dry run

    func testDryRunReportsTheCompiledActionAndExecutesNothing() async throws {
        let adapter = CountingAdapter()
        let engine = FixedEngine(.action(VoiceControlAction(operation: .press, targetID: "save")))
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        var received: [VoiceControlEvent] = []
        let collector = Task {
            for await event in runner.events { received.append(event); if case .completed = event { break } }
        }
        await runner.submit("click Save", dryRun: true)
        await collector.value
        let executions = await adapter.executions
        XCTAssertEqual(executions, 0)
        guard case .completed(let message)? = received.last else {
            return XCTFail("expected completed, got \(received)")
        }
        XCTAssertTrue(message.hasPrefix("Dry run: would press Save"), message)
        XCTAssertTrue(message.contains("Nothing was executed"))
        let traces = await runner.traceSnapshot()
        XCTAssertTrue(traces.contains { $0.stage == "dispatch" && $0.outcome == "dry_run" && $0.detail == "ordinary" })
        XCTAssertFalse(traces.contains { $0.stage == "dispatch" && $0.outcome == "started" })
    }

    func testDryRunNamesTheConfirmationItWouldHaveAsked() async throws {
        let adapter = CountingAdapter(label: "Pay now")
        let engine = FixedEngine(.action(VoiceControlAction(operation: .press, targetID: "save")))
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        var received: [VoiceControlEvent] = []
        let collector = Task {
            for await event in runner.events { received.append(event); if case .completed = event { break } }
        }
        await runner.submit("pay", dryRun: true)
        await collector.value
        let executions = await adapter.executions
        XCTAssertEqual(executions, 0)
        guard case .completed(let message)? = received.last else { return XCTFail("expected completed") }
        XCTAssertTrue(message.contains("(would confirm: payment)"), message)
        XCTAssertFalse(received.contains { if case .confirmation = $0 { return true } else { return false } })
    }

    func testInboxParsesDryRun() {
        XCTAssertEqual(
            VoiceControlInboxCommand.parse(#"{"action":"submit","text":"click Save","dryRun":true}"#),
            VoiceControlInboxCommand(action: .submit, text: "click Save", dryRun: true))
        XCTAssertEqual(VoiceControlInboxCommand.parse("click Save")?.dryRun, false)
    }

    func testDecisionTraceTopOrdersByProbabilityThenKey() {
        let head = VoiceControlDecisionTrace.Head(
            choice: "b", confidence: 0.5, probabilities: ["a": 0.25, "b": 0.5, "c": 0.25])
        XCTAssertEqual(head.top(3).map(\.option), ["b", "a", "c"])
        XCTAssertEqual(head.top(1).map(\.option), ["b"])
    }
}

private actor DecisionCapture {
    private(set) var traces: [VoiceControlDecisionTrace] = []
    func append(_ trace: VoiceControlDecisionTrace) { traces.append(trace) }
}

private actor CountingAdapter: VoiceControlAdapter {
    private(set) var executions = 0
    private let label: String
    init(label: String = "Save") { self.label = label }
    func observe() async throws -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            contextID: "app", applicationName: "TextEdit",
            targets: [VoiceControlTarget(id: "save", label: label, role: "AXButton", operations: [.press])])
    }
    func execute(
        action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority
    ) async throws -> VoiceControlReceipt {
        executions += 1
        return VoiceControlReceipt(status: .verified)
    }
}

private struct FixedEngine: VoiceControlDecisionEngine {
    let decision: VoiceControlDecision
    init(_ decision: VoiceControlDecision) { self.decision = decision }
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    { decision }
}
