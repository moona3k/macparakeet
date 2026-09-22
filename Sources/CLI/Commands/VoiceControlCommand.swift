import ArgumentParser
import Foundation
import MacParakeetCore

struct VoiceControlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice-control",
        abstract: "Experimental: replay Voice Control observations offline.",
        subcommands: [VoiceControlReplayCommand.self]
    )
}

/// Runs the command router (and optionally Jev) against a persisted
/// observation without touching the screen. This is how a stalled turn is
/// reproduced from `latest.json` instead of a live app.
struct VoiceControlReplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Route a goal against a saved Voice Control observation. Executes nothing."
    )

    @Argument(help: "Path to a Voice Control session log (latest.json or sessions/*.json).")
    var session: String

    @Option(name: .long, help: "The instruction to route. Defaults to the session's recorded instruction.")
    var goal: String?

    @Option(name: .long, help: "Observation index within the session (0-based). Defaults to the last one.")
    var observation: Int?

    @Option(
        name: .long,
        help: "Executed history as comma-separated op:targetID[:receipt] entries, e.g. setValue:n:3:verified,press:n:9."
    )
    var history: String?

    @Flag(
        name: .long,
        help: "Call Jev when the router falls through. Requires JEV_API_KEY. Off: report what Jev would be asked.")
    var jev: Bool = false

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let persisted = try VoiceControlPersistedSession.load(from: URL(fileURLWithPath: session))
        guard !persisted.observations.isEmpty else {
            throw ValidationError("The session has no observations to replay.")
        }
        let index = observation ?? (persisted.observations.count - 1)
        guard persisted.observations.indices.contains(index) else {
            throw ValidationError("Observation index \(index) is out of range (0..<\(persisted.observations.count)).")
        }
        let snapshot = persisted.observations[index].snapshot()
        let instruction = goal ?? persisted.instruction
        guard !instruction.isEmpty else {
            throw ValidationError("Pass --goal; the session has no recorded instruction.")
        }
        let executed = try Self.parseHistory(history)

        let probe = VoiceControlReplayProbe()
        let engine: any VoiceControlDecisionEngine
        if jev {
            guard let key = ProcessInfo.processInfo.environment["JEV_API_KEY"], !key.isEmpty else {
                throw ValidationError("--jev requires JEV_API_KEY in the environment.")
            }
            engine = VoiceControlReplayJevEngine(
                client: JevDecisionClient(apiKey: key, consent: { true }, onDecision: { await probe.noteDecision($0) }),
                probe: probe)
        } else {
            engine = probe
        }
        let router = VoiceControlCommandRouter(fallback: engine)
        let started = ContinuousClock.now
        let decision = try await router.decide(goal: instruction, snapshot: snapshot, history: executed)
        let elapsed = started.duration(to: .now)
        let labels = Dictionary(snapshot.targets.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })

        let report = await VoiceControlReplayReport(
            goal: instruction, observation: index, application: snapshot.applicationName,
            targetCount: snapshot.targets.count, situation: VoiceControlSituation.classify(snapshot).rawValue,
            routeMilliseconds: Int(elapsed.components.seconds) * 1000
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
            decision: .init(decision, labels: labels), jevRequest: probe.request, jevDecision: probe.decision)

        if json {
            try printJSON(report)
            return
        }
        print("goal: \(report.goal)")
        print(
            "observation: #\(report.observation)  app: \(report.application)  targets: \(report.targetCount)  situation: \(report.situation)"
        )
        print("decision: \(report.decision.kind)" + (report.decision.actor.map { "  actor: \($0)" } ?? ""))
        if let action = report.decision.action {
            print(
                "  \(action.operation) \(action.targetID)" + (action.label.map { " \"\($0)\"" } ?? "")
                    + (action.value.map { " value=\"\($0)\"" } ?? "")
                    + (action.confidence.map { String(format: "  confidence=%.2f", $0) } ?? ""))
        }
        if let message = report.decision.message { print("  \(message)") }
        if let request = report.jevRequest {
            print("jev request: \(request.kind)" + (request.jev ? " (sent)" : " (not sent; pass --jev)"))
            for option in request.options.prefix(40) {
                print("  \(option.id)" + (option.label.map { " \"\($0)\"" } ?? ""))
            }
            if request.options.count > 40 { print("  … \(request.options.count - 40) more") }
        }
        if let jevDecision = report.jevDecision {
            print(
                "jev answer: \(jevDecision.resolution)  \(jevDecision.latencyMilliseconds)ms  \(jevDecision.requestBytes)B"
            )
            for name in jevDecision.heads.keys.sorted() {
                guard let head = jevDecision.heads[name] else { continue }
                let top = head.top(5).map { option -> String in
                    let label = labels[option.option].map { " \"\(String($0.prefix(40)))\"" } ?? ""
                    return "\(option.option)\(label)=\(String(format: "%.2f", option.probability))"
                }
                print(
                    "  \(name): \(head.choice) (\(String(format: "%.2f", head.confidence)))  "
                        + top.joined(separator: "  "))
            }
        }
        print("routed in \(report.routeMilliseconds)ms; nothing was executed")
    }

    static func parseHistory(_ raw: String?) throws -> [VoiceControlAction] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try raw.split(separator: ",").map { entry in
            let parts = entry.trimmingCharacters(in: .whitespaces).split(
                separator: ":", omittingEmptySubsequences: false
            ).map(String.init)
            guard parts.count >= 2, let operation = VoiceControlOperation(rawValue: parts[0]) else {
                throw ValidationError("History entry '\(entry)' must be op:targetID[:receipt] with a known operation.")
            }
            // Target ids themselves contain a colon (`n:3`, `app:812`), so the
            // receipt is only the last component when it names a known status.
            var receipt = VoiceControlReceipt.Status.verified
            var idParts = Array(parts.dropFirst())
            if idParts.count > 1, let last = idParts.last, let status = VoiceControlReceipt.Status(rawValue: last) {
                receipt = status; idParts.removeLast()
            }
            return VoiceControlAction(
                operation: operation, targetID: idParts.joined(separator: ":"), receiptStatus: receipt)
        }
    }
}

struct VoiceControlReplayReport: Encodable {
    struct Decision: Encodable {
        struct Action: Encodable {
            let operation: String
            let targetID: String
            let label: String?
            let value: String?
            let confidence: Double?
        }
        let kind: String
        let actor: String?
        let action: Action?
        let message: String?

        init(_ decision: VoiceControlDecision, labels: [String: String]) {
            switch decision {
            case .action(let action):
                kind = "action"
                actor = action.modelID == nil ? "local" : "jev"
                self.action = Action(
                    operation: action.operation.rawValue, targetID: action.targetID,
                    label: action.targetLabel ?? labels[action.targetID], value: action.value,
                    confidence: action.decisionConfidence)
                message = nil
            case .clarify(let question):
                kind = "clarify"; actor = nil; action = nil; message = question
            case .finished:
                kind = "finished"; actor = nil; action = nil; message = nil
            case .directCompleted(let text):
                kind = "directCompleted"; actor = "local"; action = nil; message = text
            case .information(let text):
                kind = "information"; actor = "local"; action = nil; message = text
            case .pick(let prompt, let pickLabels, let targetIDs):
                kind = "pick"; actor = "local"; action = nil
                message =
                    prompt + " "
                    + zip(targetIDs, pickLabels).enumerated().map {
                        "\($0.offset + 1)=\($0.element.0) \"\($0.element.1)\""
                    }.joined(separator: " ")
            }
        }
    }
    struct JevRequest: Encodable {
        struct Option: Encodable {
            let id: String
            let label: String?
        }
        /// `outcome` (enabled events) or `unconstrained` (legality-filtered targets).
        let kind: String
        let jev: Bool
        let options: [Option]
    }
    let goal: String
    let observation: Int
    let application: String
    let targetCount: Int
    let situation: String
    let routeMilliseconds: Int
    let decision: Decision
    let jevRequest: JevRequest?
    let jevDecision: VoiceControlDecisionTrace?
}

/// Records what the router would have asked Jev. Without `--jev` it stands in
/// for the model and answers "clarify" so the replay stays offline.
actor VoiceControlReplayProbe: VoiceControlDecisionEngine {
    private(set) var request: VoiceControlReplayReport.JevRequest?
    private(set) var decision: VoiceControlDecisionTrace?

    func noteDecision(_ trace: VoiceControlDecisionTrace) { decision = trace }
    func markSent() {
        if let request { self.request = .init(kind: request.kind, jev: true, options: request.options) }
    }

    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        let offered = VoiceControlLegality.offeredTargets(in: snapshot)
        request = .init(kind: "unconstrained", jev: false, options: offered.map { .init(id: $0.id, label: $0.label) })
        return .clarify(
            "(replay) The router fell through; Jev would choose among \(offered.count) legality-filtered controls.")
    }

    func decide(
        goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
        events: [VoiceControlEnabledEvent]
    ) async throws -> VoiceControlDecision {
        request = .init(kind: "outcome", jev: false, options: events.map { .init(id: $0.id, label: $0.criteria) })
        return .clarify("(replay) The router fell through; Jev would choose among \(events.count) enabled events.")
    }
}

/// Records the request shape through the probe, then asks the real client.
struct VoiceControlReplayJevEngine: VoiceControlDecisionEngine {
    let client: JevDecisionClient
    let probe: VoiceControlReplayProbe

    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        _ = try await probe.decide(goal: goal, snapshot: snapshot, history: history)
        await probe.markSent()
        return try await client.decide(goal: goal, snapshot: snapshot, history: history)
    }

    func decide(
        goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
        events: [VoiceControlEnabledEvent]
    ) async throws -> VoiceControlDecision {
        _ = try await probe.decide(goal: goal, snapshot: snapshot, history: history, events: events)
        await probe.markSent()
        return try await client.decide(goal: goal, snapshot: snapshot, history: history, events: events)
    }
}
