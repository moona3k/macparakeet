// Compile with the production VoiceControlTypes, JevDecisionClient,
// VoiceControlCommandRouter and NativeVoiceControlAdapter sources.
// This probe refuses all apps except the disposable qualification fixture.
import Foundation
@main struct NativeProbe {
    static func main() async {
        do { try await run() } catch { print("Qualification stopped: \(error.localizedDescription)") }
    }
    static func run() async throws {
        let adapter = NativeVoiceControlAdapter(includeMenus: false, includeApplications: false)
        let first = try await adapter.observe()
        guard first.applicationName == "VoiceControlFixture" else {
            print("Refusing to drive an app other than VoiceControlFixture."); return
        }
        print("Fixture candidates: " + first.targets.map { "\($0.role):\($0.label)" }.joined(separator: ", "))
        guard let key = ProcessInfo.processInfo.environment["JEV_API_KEY"], !key.isEmpty else {
            print("Observation only; no local credential supplied."); return
        }
        let engine = VoiceControlCommandRouter(fallback: JevDecisionClient(apiKey: key, consent: { true }))
        let goal = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard !goal.isEmpty else { return }
        var history: [VoiceControlAction] = []
        let start = ContinuousClock.now
        for step in 0..<8 {
            let snapshot = try await adapter.observe()
            guard snapshot.applicationName == "VoiceControlFixture" else {
                print("Fixture lost focus; stopped."); return
            }
            let decision = try await engine.decide(goal: goal, snapshot: snapshot, history: history)
            switch decision {
            case .information(let message): print(message); return
            case .directCompleted(let message): print(message); return
            case .finished:
                print(
                    "Model reports complete; independently inspect fixture values. elapsed=\(start.duration(to: .now))");
                return
            case .clarify(let question): print("Clarification: \(question)"); return
            case .pick(let prompt, _, _): print("Clarification: \(prompt)"); return
            case .action(let action):
                // Probe performs only synthetic text writes. No implicit confirmation
                // bypass for buttons, keystrokes or an external app switch.
                guard [.setValue, .insertText].contains(action.operation), !action.requiresConfirmation else {
                    print("Probe stops before non-text action: \(action.operation)"); return
                }
                let receipt = try await adapter.execute(
                    action: action, snapshot: snapshot, authority: ActionAuthority())
                print(
                    "step=\(step) target=\(snapshot.targets.first(where: {$0.id == action.targetID})?.label ?? "unknown") result=\(receipt.status) elapsed=\(start.duration(to: .now))"
                )
                guard receipt.status == .verified else { return }
                history.append(
                    VoiceControlAction(
                        operation: action.operation, targetID: action.targetID,
                        value: action.value,
                        targetLabel: snapshot.targets.first(where: { $0.id == action.targetID })?.label,
                        receiptStatus: receipt.status))
            }
        }
    }
}
