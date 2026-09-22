// Compile alongside the exact production VoiceControl files (see README).
// This harness authorizes fixture-only confirmations; never point it at a real site.
import Foundation

private actor FixtureEngine: VoiceControlDecisionEngine {
    let client: JevDecisionClient
    init(key: String) {
        client = JevDecisionClient(
            apiKey: key, consent: { true },
            transport: { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let answers = object["answers"] as? [String: [String: Any]]
                {
                    for key in answers.keys.sorted() where key == "operation" || key.hasPrefix("target_") {
                        let answer = answers[key]!
                        print("CHOICE \(key) \(answer["choice"] ?? "?") \(answer["confidence"] ?? "?")")
                    }
                    fflush(stdout)
                }
                return (data, response)
            })
    }
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        guard snapshot.applicationName.contains("MacParakeet synthetic flight search") else {
            throw NSError(domain: "Wrong fixture", code: 9)
        }
        let start = Date()
        let decision = try await client.decide(goal: goal, snapshot: snapshot, history: history)
        print("JEV_MS \(Int(Date().timeIntervalSince(start) * 1000))"); fflush(stdout)
        if case .action(let action) = decision {
            return .action(
                VoiceControlAction(
                    operation: action.operation, targetID: action.targetID, value: action.value,
                    targetLabel: snapshot.targets.first { $0.id == action.targetID }?.label,
                    requiresConfirmation: action.requiresConfirmation))
        }
        return decision
    }
}

@main struct BrowserQualification {
    static func main() async throws {
        guard ProcessInfo.processInfo.environment["MACPARAKEET_BROWSER_FIXTURE_QUALIFICATION"] == "1",
            let key = ProcessInfo.processInfo.environment["JEV_API_KEY"], !key.isEmpty
        else {
            throw NSError(domain: "Fixture opt-in and API key required", code: 1)
        }
        let adapter = VoiceControlBrowserAdapter()
        try await adapter.start()
        print("BRIDGE_READY"); fflush(stdout)
        for _ in 0..<600 {
            if await adapter.isConnected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard await adapter.isConnected else {
            await adapter.stop(); throw NSError(domain: "No browser connected", code: 2)
        }
        let initial = try await adapter.observe()
        guard initial.applicationName.contains("MacParakeet synthetic flight search") else {
            await adapter.stop(); throw NSError(domain: "Fixture identity required", code: 3)
        }
        print("PRE_NAV_READY"); fflush(stdout)
        var rebound: VoiceControlSnapshot?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if let fresh = try? await adapter.observe(), fresh.contextID != initial.contextID {
                rebound = fresh; break
            }
        }
        guard rebound != nil else { await adapter.stop(); throw NSError(domain: "Same-origin rebind failed", code: 5) }
        if let target = initial.targets.first(where: { $0.operations.contains(.setValue) }) {
            do {
                _ = try await adapter.execute(
                    action: VoiceControlAction(operation: .setValue, targetID: target.id, value: "STALE MUST NOT LAND"),
                    snapshot: initial, authority: ActionAuthority())
                await adapter.stop(); throw NSError(domain: "Stale observation accepted", code: 6)
            } catch VoiceControlBrowserAdapter.BridgeError.remoteFailure { /* Expected pre-dispatch rejection. */  }
        }
        print("NAVIGATION_VERIFIED"); fflush(stdout)
        try await Task.sleep(for: .seconds(2))  // Establish the fixture in the unedited recording before timing the goal.
        let engine = FixtureEngine(key: key)
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: engine)
        let goalStart = Date()
        let events = Task {
            for await event in runner.events {
                switch event {
                case .confirmation(let action, _):
                    // Test consent is limited to the synthetic fixture's known buttons.
                    guard let label = action.targetLabel,
                        ["Choose departure date", "20 September", "Search flights"].contains(label)
                    else {
                        print("UNEXPECTED_CONFIRMATION"); fflush(stdout); await runner.cancel(); continue
                    }
                    print("FIXTURE_CONFIRM \(label)"); fflush(stdout)
                    await runner.confirm()
                case .acting(let action): print("ACTION \(action.operation.rawValue)"); fflush(stdout)
                case .completed:
                    print("GOAL_MS \(Int(Date().timeIntervalSince(goalStart) * 1000))"); print("RUNNER_COMPLETED");
                    fflush(stdout)
                    await adapter.stop(); exit(0)
                case .paused(let message), .failed(let message), .clarification(let message):
                    print("RUNNER_STOPPED \(message)"); fflush(stdout)
                    await adapter.stop(); exit(2)
                default: break
                }
            }
        }
        await runner.submit("Find one way flights from Zürich to London on 20 September.")
        try await Task.sleep(for: .seconds(70))
        events.cancel(); await adapter.stop()
        throw NSError(domain: "Qualification timed out", code: 4)
    }
}
