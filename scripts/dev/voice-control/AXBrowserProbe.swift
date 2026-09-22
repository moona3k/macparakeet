// Exact-source production runner + native Accessibility qualification.
// Refuses context/effects outside the disposable single-tab loopback fixture.
import AppKit
import ApplicationServices
import Foundation

private enum FixtureError: Error { case wrongWindow, notChrome, missingFocusedWindow, wrongTitle, missingWebArea, wrongURL }
private func ax(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
}
private func fixtureGuard() throws {
    guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.google.Chrome" else { throw FixtureError.notChrome }
    guard let raw = ax(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw FixtureError.missingFocusedWindow }
    let window = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
    guard (ax(window, kAXTitleAttribute) as? String)?.contains("MacParakeet native AX flight fixture") == true else { throw FixtureError.wrongTitle }
    var nodes = [window]; var visited = Set<CFHashCode>(); var matchingWebArea = false
    while let node = nodes.popLast(), visited.count < 1500 {
        guard visited.insert(CFHash(node)).inserted else { continue }
        if ax(node, kAXRoleAttribute) as? String == "AXWebArea" {
            let value = ax(node, "AXURL")
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard url?.host == "127.0.0.1", url?.path == "/flight-fixture.html", url?.port == 56474 else { throw FixtureError.wrongURL }
            matchingWebArea = true
        }
        nodes += ax(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    guard matchingWebArea else { throw FixtureError.missingWebArea }
}
private actor FixtureAdapter: VoiceControlAdapter {
    let native = NativeVoiceControlAdapter(includeMenus: false, includeApplications: false)
    func observe() async throws -> VoiceControlSnapshot {
        try await MainActor.run { try fixtureGuard() }
        let snapshot = try await native.observe()
        print("OBS " + snapshot.targets.map { "\($0.role):\($0.label)=\($0.value ?? "nil")" }.joined(separator: "; "))
        return snapshot
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws -> VoiceControlReceipt {
        try await MainActor.run { try fixtureGuard() }
        return try await native.execute(action: action, snapshot: snapshot, authority: authority)
    }
}
@main struct AXBrowserProbe {
    static func main() async {
        do { try await run() } catch { print("Fixture qualification refused/stopped: \(error)"); exit(1) }
    }
    static func run() async throws {
        let adapter = FixtureAdapter()
        let first = try await adapter.observe()
        print("Native fixture targets: " + first.targets.map { "\($0.role):\($0.label) [\($0.operations)]" }.joined(separator: "; "))
        guard let key = ProcessInfo.processInfo.environment["JEV_API_KEY"], !key.isEmpty else { return }
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: VoiceControlCommandRouter(fallback: JevDecisionClient(apiKey: key, consent: { true }, transport: { request in
            let result = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any], let answers = json["answers"] as? [String: [String: Any]] {
                for (name, answer) in answers.sorted(by: { $0.key < $1.key }) where name == "operation" || name.hasPrefix("target_") {
                    print("MODEL \(name) choice=\(answer["choice"] ?? "missing") score=\(answer["confidence"] ?? "missing")")
                }
            }
            return result
        })))
        let start = ContinuousClock.now
        let monitor = Task {
            for await event in runner.events {
                print("\(start.duration(to: .now)) \(event)")
            }
        }
        let input = CommandLine.arguments.dropFirst().joined(separator: " ")
        await runner.submit(input.isEmpty ? "Find one way flights from Zürich to London on 20 September." : input)
        try await Task.sleep(for: .milliseconds(50))
        monitor.cancel()
        let result = try await adapter.observe()
        print("Final native summary: \(result.summary)")
        for target in result.targets where ["Origin", "Destination", "Trip type"].contains(target.label) {
            print("FINAL \(target.label)=\(target.value ?? "nil")")
        }
        print("TRACE " + String(data: try JSONEncoder().encode(await runner.traceSnapshot()), encoding: .utf8)!)
    }
}
