import Foundation
import XCTest

@testable import MacParakeetCore

/// Value candidates, wire history, retries and usage accounting for `JevDecisionClient`.
final class JevClientTransportTests: XCTestCase {
    private actor Calls {
        private(set) var bodies: [[String: Any]] = []
        private(set) var decisions: [VoiceControlDecisionTrace] = []
        func record(_ data: Data?) {
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodies.append(json)
            }
        }
        func note(_ decision: VoiceControlDecisionTrace) { decisions.append(decision) }
    }

    /// Replies with each status in `statuses` in turn (200 once they run out),
    /// answering every head with its first option.
    private func client(statuses: [Int], calls: Calls, usage: Int? = 1_234) -> JevDecisionClient {
        let script = Script(statuses)
        return JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                await calls.record(request.httpBody)
                let status = script.next()
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let questions = body?["questions"] as? [String: [String: Any]] ?? [:]
                var answers: [String: Any] = [:]
                for (name, question) in questions {
                    let keys = Array((question["criteria"] as? [String: String] ?? [:]).keys).sorted()
                    let choice = name == "outcome" ? keys.first { $0.hasPrefix("n:") } ?? keys[0] : keys[0]
                    var probabilities = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0.0) })
                    probabilities[choice] = 1
                    answers[name] = [
                        "type": "choice", "choice": choice, "confidence": 1, "probabilities": probabilities,
                    ]
                }
                var reply: [String: Any] = ["model": JevDecisionClient.model, "answers": answers]
                if let usage { reply["usage"] = ["input_tokens": usage, "output_tokens": 0] }
                let data = status == 200 ? try JSONSerialization.data(withJSONObject: reply) : Data()
                return (
                    data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            },
            onDecision: { await calls.note($0) })
    }

    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [Int]
        init(_ statuses: [Int]) { self.statuses = statuses }
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
    }

    private let snapshot = VoiceControlSnapshot(
        contextID: "ax:1", applicationName: "Chrome",
        targets: [
            VoiceControlTarget(id: "n:0", label: "Pick", role: "AXButton", operations: [.press]),
            VoiceControlTarget(id: "n:1", label: "Other", role: "AXButton", operations: [.press]),
        ])

    private var events: [VoiceControlEnabledEvent] {
        snapshot.targets.map {
            VoiceControlEnabledEvent(
                id: $0.id, criteria: $0.label,
                action: VoiceControlAction(operation: .press, targetID: $0.id, targetLabel: $0.label))
        }
    }

    func testLongValueIsOfferedWholeAndEverySpanIsLiteral() {
        let goal =
            "In the message field write Hi team, I will be about ten minutes late to the standup because of traffic on the bridge"
        let spans = JevDecisionClient.sourceSpans(goal)
        XCTAssertTrue(
            spans.contains("Hi team, I will be about ten minutes late to the standup because of traffic on the bridge"))
        XCTAssertTrue(spans.allSatisfy { goal.contains($0) })
        XCTAssertLessThanOrEqual(spans.count, 250)
        let long = (0..<60).map { "w\($0)" }.joined(separator: " ")
        let many = JevDecisionClient.sourceSpans(long)
        XCTAssertEqual(many.count, 250)
        XCTAssertTrue(many.contains((40..<60).map { "w\($0)" }.joined(separator: " ")), "tails survive the cap")
    }

    func testAmendedGoalOffersOnlyTheUsersWords() {
        let goal = [
            VoiceControlGoalText.header + "search flights to Paris",
            VoiceControlGoalText.correction + "make it Rome",
            VoiceControlGoalText.manualHeader,
            "Where from?: Secret Manual Value",
            VoiceControlGoalText.uncertainNote,
        ].joined(separator: "\n")
        let spans = JevDecisionClient.sourceSpans(goal)
        XCTAssertTrue(spans.contains("Rome"))
        XCTAssertTrue(spans.contains("Paris"))
        XCTAssertFalse(spans.contains { $0.contains("Continue") || $0.contains("corrections") })
        XCTAssertFalse(spans.contains { $0.contains("Secret") || $0.contains("effects") })
        XCTAssertLessThan(
            spans.firstIndex(of: "make it Rome") ?? .max, spans.firstIndex(of: "search flights to Paris") ?? .max,
            "the newest correction comes first")
        XCTAssertEqual(VoiceControlGoalText.userSegments("plain goal"), ["plain goal"])
    }

    func testRateLimitAndOverloadRetryThenSucceed() async throws {
        let calls = Calls()
        let decision = try await client(statuses: [429, 529], calls: calls).decide(
            goal: "pick", snapshot: snapshot, history: [], events: events)
        guard case .action = decision else { return XCTFail("expected an action, got \(decision)") }
        let bodies = await calls.bodies
        XCTAssertEqual(bodies.count, 3)
        let trace = await calls.decisions.last
        XCTAssertEqual(trace?.retries, 2)
        XCTAssertEqual(trace?.inputTokens, 1_234)
    }

    func testRetriesAreBoundedAndOtherErrorsDoNotRetry() async {
        let calls = Calls()
        do {
            _ = try await client(statuses: [529, 529, 529, 529], calls: calls).decide(
                goal: "pick", snapshot: snapshot, history: [], events: events)
            XCTFail("expected unavailable")
        } catch { XCTAssertEqual(error as? JevDecisionError, .unavailable) }
        let bounded = await calls.bodies.count
        XCTAssertEqual(bounded, 1 + JevDecisionClient.maxRetries)

        let auth = Calls()
        do {
            _ = try await client(statuses: [401], calls: auth).decide(
                goal: "pick", snapshot: snapshot, history: [], events: events)
            XCTFail("expected unavailable")
        } catch { XCTAssertEqual(error as? JevDecisionError, .unavailable) }
        let single = await auth.bodies.count
        XCTAssertEqual(single, 1)
    }

    /// History ids are walk positions from an older observation; `n:0` may be a
    /// different control now. The model reads labels and outcomes only.
    func testExecutedHistoryCarriesLabelsNotStaleIDs() async throws {
        let calls = Calls()
        let history = [
            VoiceControlAction(
                operation: .press, targetID: "n:0", targetLabel: "Search", receiptStatus: .transitionObserved,
                modelID: JevDecisionClient.model, decisionConfidence: 0.9)
        ]
        _ = try await client(statuses: [], calls: calls, usage: nil).decide(
            goal: "pick", snapshot: snapshot, history: history)
        let bodies = await calls.bodies
        let state = try XCTUnwrap(bodies.first?["state"] as? [String: Any])
        let executed = try XCTUnwrap(state["executed"] as? [[String: Any]])
        XCTAssertEqual(executed.first?["control"] as? String, "Search")
        XCTAssertEqual(executed.first?["outcome"] as? String, "transitionObserved")
        XCTAssertNil(executed.first?["targetID"])
        XCTAssertNil(executed.first?["decisionConfidence"])
        let trace = await calls.decisions.last
        XCTAssertNil(trace?.inputTokens, "no usage reported, none invented")
    }
}
