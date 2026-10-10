import Foundation
import XCTest

@testable import MacParakeetCore

/// Wire order, the offered set, the scope head, numbered picks and error
/// mapping for `JevDecisionClient` (replay-corpus findings, 2026-10-09).
final class JevRequestShapeTests: XCTestCase {
    private actor Bodies {
        private(set) var raw: [Data] = []
        func record(_ data: Data?) { raw.append(data ?? Data()) }
        var json: [[String: Any]] { raw.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    /// Answers each head from `answer(head, options)`, or its first option at 0.9.
    private func client(
        bodies: Bodies? = nil, status: Int = 200, responseBody: Data? = nil,
        answer: (@Sendable (String, [String]) -> (choice: String, probabilities: [String: Double])?)? = nil
    ) -> JevDecisionClient {
        JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                await bodies?.record(request.httpBody)
                let url = request.url!
                guard status == 200 else {
                    return (
                        responseBody ?? Data(),
                        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                    )
                }
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let questions = body?["questions"] as? [String: [String: Any]] ?? [:]
                var answers: [String: Any] = [:]
                for (name, question) in questions {
                    let keys = Array((question["criteria"] as? [String: Any] ?? [:]).keys).sorted()
                    if let scripted = answer?(name, keys) {
                        let top = scripted.probabilities.values.max() ?? 1
                        let confidence = keys.count > 1 ? (Double(keys.count) * top - 1) / Double(keys.count - 1) : 1
                        // The rest of the mass is spread over unscripted options.
                        let rest = keys.filter { scripted.probabilities[$0] == nil }
                        let left = max(0, 1 - scripted.probabilities.values.reduce(0, +))
                        var probabilities = Dictionary(
                            uniqueKeysWithValues: rest.map { ($0, left / Double(max(1, rest.count))) })
                        for (key, value) in scripted.probabilities { probabilities[key] = value }
                        answers[name] = [
                            "type": "choice", "choice": scripted.choice, "confidence": confidence,
                            "probabilities": probabilities,
                        ]
                    } else {
                        var probabilities = Dictionary(
                            uniqueKeysWithValues: keys.map { ($0, 0.1 / Double(max(1, keys.count - 1))) })
                        probabilities[keys[0]] = 0.9
                        answers[name] = [
                            "type": "choice", "choice": keys[0], "confidence": 0.9, "probabilities": probabilities,
                        ]
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "model": JevDecisionClient.model, "answers": answers,
                ])
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
    }

    private let page = VoiceControlSnapshot(
        contextID: "ax:1", applicationName: "Google Chrome",
        targets: [
            VoiceControlTarget(
                id: "n:0", label: "Search mail", role: "AXTextField", value: "", operations: [.setValue]),
            VoiceControlTarget(id: "n:1", label: "Compose", role: "AXButton", operations: [.press]),
            VoiceControlTarget(id: "n:2", label: "Sent", role: "AXLink", operations: [.press]),
            VoiceControlTarget(id: "n:3", label: "Sent", role: "AXStaticText", operations: [.press]),
            VoiceControlTarget(id: "n:4", label: "Drafts 131 unread", role: "AXLink", operations: [.press]),
            VoiceControlTarget(id: "n:5", label: "Drafts", role: "AXStaticText", operations: [.press]),
            VoiceControlTarget(id: "n:6", label: "Inbox", role: "AXLink", operations: [.press]),
        ])

    /// The criteria keys of one question, in the order they appear on the wire.
    private func wireOrder(_ body: Data, question: String) throws -> [String] {
        let text = String(decoding: body, as: UTF8.self)
        let marker = "\"\(question)\":{\"type\":\"choice\""
        let start = try XCTUnwrap(text.range(of: marker), "question \(question) missing")
        let criteria = try XCTUnwrap(text.range(of: "\"criteria\":{", range: start.upperBound..<text.endIndex))
        var keys: [String] = []
        var index = criteria.upperBound
        var depth = 1
        var expectingKey = true
        while index < text.endIndex, depth > 0 {
            let character = text[index]
            if character == "\"" {
                var end = text.index(after: index)
                while text[end] != "\"" { end = text.index(after: text[end] == "\\" ? text.index(after: end) : end) }
                if expectingKey && depth == 1 { keys.append(String(text[text.index(after: index)..<end])) }
                index = text.index(after: end); continue
            }
            if character == ":" { expectingKey = false }
            if character == "," && depth == 1 { expectingKey = true }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            index = text.index(after: index)
        }
        return keys
    }

    func testSameRequestEncodesToIdenticalBytesWithDeliberateOptionOrder() async throws {
        let bodies = Bodies()
        let client = client(bodies: bodies, answer: { name, _ in name == "kind" ? ("finished", ["finished": 1]) : nil })
        _ = try await client.decide(goal: "show my sent mail", snapshot: page, history: [])
        _ = try await client.decide(goal: "show my sent mail", snapshot: page, history: [])
        let raw = await bodies.raw
        XCTAssertEqual(raw.count, 2)
        XCTAssertEqual(raw[0], raw[1], "one observation and goal always serialize to the same bytes")
        XCTAssertEqual(try wireOrder(raw[0], question: "kind"), ["press", "fill", "finished", "none"])
        XCTAssertEqual(try wireOrder(raw[0], question: "target"), ["n:0", "n:1", "n:2", "n:4", "n:6", "none"])
        XCTAssertEqual(try wireOrder(raw[0], question: "scope"), ["multi", "single"])
        XCTAssertEqual(
            try wireOrder(raw[0], question: "consequence"),
            ["ordinary", "payment", "destructive", "externalCommitment", "unknown"])
    }

    func testValueSpansKeepTheirPriorityOrderOnTheWire() async throws {
        let bodies = Bodies()
        let focused = VoiceControlSnapshot(
            contextID: "ax:2", applicationName: "Mail",
            targets: [
                VoiceControlTarget(
                    id: "n:0", label: "Message", role: "AXTextArea", value: "", operations: [.setValue],
                    isFocused: true)
            ])
        let goal = "reply saying I'll be ten minutes late"
        _ = try await client(
            bodies: bodies, answer: { name, _ in name == "kind" ? ("finished", ["finished": 1]) : nil }
        )
        .decide(goal: goal, snapshot: focused, history: [])
        let all = await bodies.raw
        let raw = try XCTUnwrap(all.first)
        let order = try wireOrder(raw, question: "value")
        let spans = JevDecisionClient.sourceSpans(goal)
        XCTAssertEqual(order, spans.indices.map { "v\($0)" } + ["none"])
        XCTAssertEqual(spans.first, "I'll be ten minutes late", "the cue tail is offered first")
    }

    func testOutcomeEventsKeepHostOrderWithEscapesLast() async throws {
        let bodies = Bodies()
        let events = ["c2", "c0", "c1"].map {
            VoiceControlEnabledEvent(
                id: $0, criteria: "After the host acts, \($0) is selected.",
                action: VoiceControlAction(operation: .press, targetID: $0, targetLabel: $0))
        }
        _ = try await client(bodies: bodies).decide(goal: "London", snapshot: page, history: [], events: events)
        let all = await bodies.raw
        let raw = try XCTUnwrap(all.first)
        XCTAssertEqual(try wireOrder(raw, question: "outcome"), ["c2", "c0", "c1", "insufficient_evidence", "clarify"])
    }

    func testTargetsAreDescribedOnceInStateWithNullCriteria() async throws {
        let bodies = Bodies()
        _ = try await client(
            bodies: bodies, answer: { name, _ in name == "kind" ? ("finished", ["finished": 1]) : nil }
        )
        .decide(goal: "show my sent mail", snapshot: page, history: [])
        let all = await bodies.json
        let body = try XCTUnwrap(all.first)
        let criteria = try XCTUnwrap(
            ((body["questions"] as? [String: [String: Any]])?["target"])?["criteria"] as? [String: Any])
        XCTAssertTrue(criteria["n:1"] is NSNull)
        XCTAssertNotNil(criteria["none"] as? String)
        let lines = try XCTUnwrap(
            ((body["state"] as? [String: Any])?["observation"] as? [String: Any])?["targets"] as? [String])
        XCTAssertEqual(
            lines,
            [
                "n:0: field 'Search mail' (empty)", "n:1: button 'Compose'", "n:2: link 'Sent'",
                "n:4: link 'Drafts 131 unread'", "n:6: link 'Inbox'",
            ])
    }

    func testTextTwinsOfNamedControlsAreNotOffered() {
        let kept = JevDecisionClient.withoutTextTwins(page.targets).map(\.id)
        XCTAssertEqual(kept, ["n:0", "n:1", "n:2", "n:4", "n:6"])
        let ocrOnly = [
            VoiceControlTarget(id: "t:0", label: "Save", role: "text", operations: [.press]),
            VoiceControlTarget(id: "n:0", label: "Save as PDF", role: "AXButton", operations: [.press]),
        ]
        XCTAssertEqual(
            JevDecisionClient.withoutTextTwins(ocrOnly).map(\.id), ["t:0", "n:0"],
            "only Chromium static text uses the prefix rule; OCR text is already merged against Accessibility")
        let textOnly = [VoiceControlTarget(id: "n:0", label: "Sent", role: "AXStaticText", operations: [.press])]
        XCTAssertEqual(JevDecisionClient.withoutTextTwins(textOnly).map(\.id), ["n:0"])
    }

    func testSingleActionScopeMarksTheActionAndTheRouterFinishesAfterIt() async throws {
        let decision = try await client(answer: { name, _ in
            switch name {
            case "kind": return ("press", ["press": 0.95])
            case "target": return ("n:2", ["n:2": 0.95])
            case "scope": return ("single", ["single": 0.9])
            default: return nil
            }
        }).decide(goal: "show my sent mail", snapshot: page, history: [])
        guard case .action(let action) = decision else { return XCTFail("expected an action, got \(decision)") }
        XCTAssertEqual(action.targetID, "n:2")
        XCTAssertEqual(action.completesRequest, true)

        let router = VoiceControlCommandRouter(fallback: FailingEngine())
        let landed = VoiceControlAction(
            operation: .press, targetID: "n:2", targetLabel: "Sent", receiptStatus: .transitionObserved,
            completesRequest: true)
        let next = try await router.decide(goal: "show my sent mail", snapshot: page, history: [landed])
        XCTAssertEqual(next, .finished, "no second Jev call after the one action landed")
        let verified = VoiceControlAction(
            operation: .press, targetID: "n:2", targetLabel: "Sent", receiptStatus: .verified, completesRequest: true)
        let done = try await router.decide(goal: "show my sent mail", snapshot: page, history: [verified])
        XCTAssertEqual(done, .directCompleted("Done. The requested change was verified."))
    }

    func testMultiStepOrUnsureScopeKeepsTheLoopAndAmendedGoalsNeverInherit() async throws {
        let multi = try await client(answer: { name, _ in
            switch name {
            case "kind": return ("press", ["press": 0.95])
            case "target": return ("n:1", ["n:1": 0.95])
            case "scope": return ("multi", ["multi": 0.9])
            default: return nil
            }
        }).decide(goal: "write an email to Sam", snapshot: page, history: [])
        guard case .action(let action) = multi else { return XCTFail("expected an action") }
        XCTAssertNil(action.completesRequest)

        let bodies = Bodies()
        let pressed = VoiceControlAction(
            operation: .press, targetID: "n:1", targetLabel: "Compose", receiptStatus: .verified)
        _ = try await client(
            bodies: bodies, answer: { name, _ in name == "kind" ? ("finished", ["finished": 1]) : nil }
        )
        .decide(goal: "write an email to Sam", snapshot: page, history: [pressed])
        let sent = await bodies.json
        let later = try XCTUnwrap(sent.first?["questions"] as? [String: Any])
        XCTAssertNil(later["scope"], "scope is judged once, on the first decision")

        let amended = VoiceControlGoalText.header + "show my sent mail\n" + VoiceControlGoalText.correction + "drafts"
        let landed = VoiceControlAction(
            operation: .press, targetID: "n:2", targetLabel: "Sent", receiptStatus: .verified, completesRequest: true)
        let fallback = RecordingEngine()
        _ = try await VoiceControlCommandRouter(fallback: fallback).decide(
            goal: amended, snapshot: page, history: [landed])
        let calls = await fallback.calls
        XCTAssertEqual(calls, 1, "a corrected request is a different request and asks again")
    }

    func testSplitTargetBecomesANumberedPick() async throws {
        let decision = try await client(answer: { name, _ in
            switch name {
            case "kind": return ("press", ["press": 0.95])
            case "target": return ("n:2", ["n:2": 0.46, "n:4": 0.42, "none": 0.02])
            default: return nil
            }
        }).decide(goal: "open that one", snapshot: page, history: [])
        guard case .pick(let prompt, let labels, let ids) = decision else {
            return XCTFail("expected a numbered pick, got \(decision)")
        }
        XCTAssertEqual(ids, ["n:2", "n:4"])
        XCTAssertEqual(labels, ["Sent", "Drafts 131 unread"])
        XCTAssertTrue(prompt.hasPrefix("Which one? Say the number."))
    }

    func testSpreadTargetStillAsksForTheLabel() async throws {
        let decision = try await client(answer: { name, _ in
            switch name {
            case "kind": return ("press", ["press": 0.95])
            case "target": return ("n:2", ["n:2": 0.3, "n:4": 0.25, "n:6": 0.2, "n:1": 0.15, "none": 0.1])
            default: return nil
            }
        }).decide(goal: "open that one", snapshot: page, history: [])
        XCTAssertEqual(decision, .clarify("Which control should I use? Please say its full label."))
    }

    func testBoundaryPunctuationVariantsShareTheirSupport() {
        let values = ["v0": "London.", "v1": "London", "v2": "to London"]
        let answer = JevDecisionClient.Answer(
            type: "choice", choice: "v1", probabilities: ["v0": 0.4, "v1": 0.45, "v2": 0.1, "none": 0.05],
            confidence: 0.27)
        XCTAssertEqual(JevDecisionClient.valueSupport(answer, values: values), 0.85, accuracy: 0.0001)
    }

    func testStopDuringARequestIsCancellationNotUnavailable() async {
        let client = JevDecisionClient(
            apiKey: "test", consent: { true }, transport: { _ in throw URLError(.cancelled) })
        do {
            _ = try await client.decide(goal: "show my sent mail", snapshot: page, history: [])
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("expected CancellationError, got \(error)") }
    }

    func testRejectedKeyAndTokenLimitHaveTheirOwnErrors() async {
        do {
            _ = try await client(status: 401).decide(goal: "show my sent mail", snapshot: page, history: [])
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? JevDecisionError, .unauthorized) }
        do {
            _ = try await client(
                status: 400, responseBody: Data(#"{"detail":{"error_type":"max_tokens_exceeded"}}"#.utf8)
            )
            .decide(goal: "show my sent mail", snapshot: page, history: [])
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? JevDecisionError, .contextTooLarge) }
        do {
            _ = try await client(status: 400, responseBody: Data(#"{"detail":"Too many choices."}"#.utf8))
                .decide(goal: "show my sent mail", snapshot: page, history: [])
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? JevDecisionError, .unavailable) }
    }

    private struct FailingEngine: VoiceControlDecisionEngine {
        func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
            -> VoiceControlDecision
        {
            XCTFail("the router should not ask the engine"); return .finished
        }
        func decide(
            goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
            events: [VoiceControlEnabledEvent]
        ) async throws -> VoiceControlDecision {
            XCTFail("the router should not ask the engine"); return .finished
        }
    }

    private actor RecordingEngine: VoiceControlDecisionEngine {
        private(set) var calls = 0
        func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
            -> VoiceControlDecision
        {
            calls += 1; return .finished
        }
        func decide(
            goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
            events: [VoiceControlEnabledEvent]
        ) async throws -> VoiceControlDecision {
            calls += 1; return .finished
        }
    }
}

final class JevWarmTests: XCTestCase {
    private actor Requests {
        private(set) var urls: [String] = []
        func record(_ request: URLRequest) {
            urls.append((request.httpMethod ?? "GET") + " " + (request.url?.path ?? ""))
        }
    }

    func testWarmSendsNoContentAndOnlyWithConsentAtMostOncePerMinute() async {
        let requests = Requests()
        let consent = ConsentFlag()
        let client = JevDecisionClient(
            apiKey: "test", consent: { consent.value },
            transport: { request in
                await requests.record(request)
                XCTAssertNil(request.httpBody, "warm-up carries no command or screen content")
                return (
                    Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        await client.warm()
        let none = await requests.urls
        XCTAssertEqual(none, [], "no consent, no request")
        consent.value = true
        await client.warm()
        await client.warm()
        let urls = await requests.urls
        XCTAssertEqual(urls, ["GET /v1/models"])
    }

    private final class ConsentFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}

final class VoiceControlScrollAreaTests: XCTestCase {
    private func area(_ id: String, _ frame: CGRect?) -> VoiceControlTarget {
        VoiceControlTarget(id: id, label: "", role: "AXScrollArea", operations: [.scroll], frame: frame)
    }

    func testScrollPrefersTheAreaHoldingFocusThenTheClearlyLargest() async throws {
        let sidebar = area("n:0", CGRect(x: 0, y: 0, width: 200, height: 800))
        let content = area("n:1", CGRect(x: 200, y: 0, width: 1000, height: 800))
        let focusedRow = VoiceControlTarget(
            id: "n:2", label: "Inbox", role: "AXRow", operations: [.press], isFocused: true,
            frame: CGRect(x: 10, y: 100, width: 180, height: 20))
        let router = VoiceControlCommandRouter(fallback: Unused())
        let inSidebar = VoiceControlSnapshot(
            contextID: "a", applicationName: "Mail", targets: [sidebar, content, focusedRow])
        let first = try await router.decide(goal: "scroll down", snapshot: inSidebar, history: [])
        guard case .action(let a) = first else { return XCTFail("expected an action, got \(first)") }
        XCTAssertEqual(a.targetID, "n:0", "the list you are in")
        let noFocus = VoiceControlSnapshot(contextID: "b", applicationName: "Mail", targets: [sidebar, content])
        let second = try await router.decide(goal: "scroll up", snapshot: noFocus, history: [])
        guard case .action(let b) = second else { return XCTFail("expected an action, got \(second)") }
        XCTAssertEqual(b.targetID, "n:1"); XCTAssertEqual(b.value, "up")
        let twins = VoiceControlSnapshot(
            contextID: "c", applicationName: "Finder",
            targets: [
                area("n:0", CGRect(x: 0, y: 0, width: 500, height: 800)),
                area("n:1", CGRect(x: 500, y: 0, width: 600, height: 800)),
            ])
        let third = try await router.decide(goal: "scroll down", snapshot: twins, history: [])
        XCTAssertEqual(third, .clarify("Which part of the window should I scroll?"))
    }

    private struct Unused: VoiceControlDecisionEngine {
        func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
            -> VoiceControlDecision
        { .finished }
        func decide(
            goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
            events: [VoiceControlEnabledEvent]
        ) async throws -> VoiceControlDecision { .finished }
    }
}
