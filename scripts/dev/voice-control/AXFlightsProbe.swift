// Content-minimized native qualification against the real Google Flights page.
// Uses production Types, Diagnostics, TurnRunner, CommandRouter, Jev client,
// and NativeVoiceControlAdapter. Refuses any window that is not the dedicated
// Google Flights tab. Never prints page summaries, account labels, URLs with
// query strings, or non-allowlisted field values.
import AppKit
import ApplicationServices
import Foundation

private enum FlightsError: Error { case notChrome, missingFocusedWindow, wrongTitle, missingWebArea, wrongURL }
private func ax(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
}
private let allowedLabels = [
    "where from", "where to", "ticket type", "one way", "round trip", "multi-city",
    "departure", "return", "explore destinations", "search", "calendar", "done",
    "zurich", "zürich", "london", "paris", "september", "20",
]
private func isAllowed(_ label: String) -> Bool {
    let lower = label.lowercased()
    if lower.contains("google account") || lower.contains("profile:") || lower.contains("@") { return false }
    return allowedLabels.contains { lower.contains($0) }
}
private func webURL(_ node: AXUIElement) -> URL? {
    let value = ax(node, "AXURL")
    return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
}
private func isFlightsURL(_ url: URL) -> Bool {
    let host = url.host ?? ""
    return url.scheme == "https"
        && (host == "www.google.com" || host == "google.com")
        && url.path.hasPrefix("/travel/flights")
}
private func flightsGuard() throws {
    guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.google.Chrome" else {
        throw FlightsError.notChrome
    }
    guard let raw = ax(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw FlightsError.missingFocusedWindow }
    let window = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
    guard (ax(window, kAXTitleAttribute) as? String)?.localizedCaseInsensitiveContains("flight") == true else {
        throw FlightsError.wrongTitle
    }
    var nodes = [window]; var visited = Set<CFHashCode>(); var matchingWebArea = false
    while let node = nodes.popLast(), visited.count < 2000 {
        guard visited.insert(CFHash(node)).inserted else { continue }
        if ax(node, kAXRoleAttribute) as? String == "AXWebArea", let url = webURL(node) {
            if isFlightsURL(url) { matchingWebArea = true }
        }
        nodes += ax(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    guard matchingWebArea else { throw FlightsError.missingWebArea }
}
private func waitForFlightsContext() async throws {
    var last: Error = FlightsError.missingWebArea
    for _ in 0..<8 {
        do {
            try await MainActor.run { try flightsGuard() }
            return
        } catch {
            last = error
            try await Task.sleep(for: .milliseconds(200))
        }
    }
    throw last
}
private func describe(_ snapshot: VoiceControlSnapshot) -> String {
    let offered = snapshot.targets.filter { isAllowed($0.label) }.map { target in
        let value = isAllowed(target.value ?? "") ? (target.value ?? "") : (target.value == nil ? "" : "present")
        return "\(target.role):\(target.label)=\(value)[\(target.operations.map(\.rawValue).sorted().joined(separator: ","))]nav=\(target.isNavigation)"
    }
    return "complete=\(snapshot.isComplete) count=\(snapshot.targets.count) offered=\(offered.joined(separator: "; "))"
}
private actor FlightsAdapter: VoiceControlAdapter {
    let native = NativeVoiceControlAdapter(includeMenus: false, includeApplications: false)
    func observe() async throws -> VoiceControlSnapshot {
        try await MainActor.run { try flightsGuard() }
        let snapshot = try await native.observe()
        print("OBS " + describe(snapshot))
        return snapshot
    }
    func execute(action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws -> VoiceControlReceipt {
        try await MainActor.run { try flightsGuard() }
        let receipt = try await native.execute(action: action, snapshot: snapshot, authority: authority)
        let label = snapshot.targets.first(where: { $0.id == action.targetID }).map(\.label) ?? action.targetID
        print("EFFECT op=\(action.operation.rawValue) label=\(isAllowed(label) ? label : "control") status=\(receipt.status.rawValue)")
        return receipt
    }
}
@main struct AXFlightsProbe {
    static func main() async {
        do { try await run() } catch { print("Flights qualification refused/stopped: \(error)"); exit(1) }
    }
    static func run() async throws {
        try await becomeFlightsForeground()
        let adapter = FlightsAdapter()
        let first = try await adapter.observe()
        print("Native flights " + describe(first))
        guard let key = ProcessInfo.processInfo.environment["JEV_API_KEY"], !key.isEmpty else { return }
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: VoiceControlCommandRouter(fallback: JevDecisionClient(apiKey: key, consent: { true }, transport: { request in
            let result = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
               let answers = json["answers"] as? [String: [String: Any]] {
                for (name, answer) in answers.sorted(by: { $0.key < $1.key })
                where name == "operation" || name == "consequence" || name.hasPrefix("target_") {
                    print("MODEL \(name) choice=\(answer["choice"] ?? "missing") score=\(answer["confidence"] ?? "missing")")
                }
            }
            return result
        })))
        let start = ContinuousClock.now
        let monitor = Task {
            for await event in runner.events {
                print("\(start.duration(to: .now)) \(summarize(event))")
            }
        }
        let input = CommandLine.arguments.dropFirst().joined(separator: " ")
        await runner.submit(input.isEmpty ? "Find one-way flights from Zürich to London on September 20." : input)
        try await Task.sleep(for: .milliseconds(50))
        monitor.cancel()
        let result = try await adapter.observe()
        print("FINAL " + describe(result))
        print("TRACE " + String(data: try JSONEncoder().encode(await runner.traceSnapshot()), encoding: .utf8)!)
    }
    /// Tester intervention only: bring the already-open dedicated window forward
    /// after compilation. This is not a product activation effect.
    static func becomeFlightsForeground() async throws {
        var last: Error = FlightsError.notChrome
        for attempt in 0..<20 {
            await MainActor.run {
                NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.google.Chrome" }?.activate()
            }
            try await Task.sleep(for: .milliseconds(250))
            do {
                try await MainActor.run { try flightsGuard() }
                print("FOCUS_READY attempt=\(attempt)")
                return
            } catch {
                last = error
            }
        }
        throw last
    }
    static func summarize(_ event: VoiceControlEvent) -> String {
        switch event {
        case .observing: return "observing"
        case .deciding: return "deciding"
        case .acting(let action): return "acting \(action.operation.rawValue)"
        case .confirmation(_, let message): return "confirmation \(message)"
        case .clarification(let question): return "clarification \(question)"
        case .paused(let message): return "paused \(message)"
        case .completed(let message): return "completed \(message)"
        case .failed(let message): return "failed \(message)"
        case .cancelled: return "cancelled"
        case .activity(let message): return "activity \(message)"
        }
    }
}
