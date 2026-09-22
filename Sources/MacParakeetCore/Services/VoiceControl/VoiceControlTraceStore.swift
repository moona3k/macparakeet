import Foundation

public struct VoiceControlPersistedTarget: Codable, Sendable, Equatable {
    public var id: String
    public var role: String
    public var label: String
    public var operations: [String]
    public var isFocused: Bool
    public var isNavigation: Bool
    public var valueIsComplete: Bool
    public var hasValue: Bool
    public var region: String?
}

/// One observation as a replayable fixture. Field values and selected text
/// are omitted; `summary` is the window title and visible static text the
/// adapter already sends to Jev, kept so an offline replay sees the same state.
public struct VoiceControlPersistedObservation: Codable, Sendable, Equatable {
    public var at: Date
    public var complete: Bool
    public var applicationName: String
    public var targetCount: Int
    public var targets: [VoiceControlPersistedTarget]
    public var snapshotID: UUID?
    public var contextID: String?
    public var summary: String?
    public var metrics: VoiceControlObservationMetrics?

    /// Rebuild a snapshot the router and decision engine can run against.
    /// Values are absent, so `value`-dependent local routes (`replace X with Y`,
    /// skip-if-already-typed) behave as if the field were empty.
    public func snapshot() -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            id: snapshotID ?? UUID(), contextID: contextID ?? "replay:\(applicationName)",
            applicationName: applicationName,
            targets: targets.map { target in
                VoiceControlTarget(
                    id: target.id, label: target.label, role: target.role, value: target.hasValue ? "" : nil,
                    operations: Set(target.operations.compactMap(VoiceControlOperation.init(rawValue:))),
                    isNavigation: target.isNavigation, isFocused: target.isFocused,
                    valueIsComplete: target.valueIsComplete, region: target.region)
            },
            summary: summary ?? "", isComplete: complete, metrics: metrics)
    }
}

public struct VoiceControlPersistedSession: Codable, Sendable, Equatable {
    public var schema: String
    public var taskID: UUID
    public var startedAt: Date
    public var updatedAt: Date
    public var instruction: String
    public var applicationName: String?
    public var phase: String?
    public var status: String?
    public var summary: VoiceControlTurnSummary?
    public var observations: [VoiceControlPersistedObservation]
    public var records: [VoiceControlTraceRecord]
    public var decisions: [VoiceControlDecisionTrace]?

    public static func load(from url: URL) throws -> VoiceControlPersistedSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceControlPersistedSession.self, from: Data(contentsOf: url))
    }
}

public actor VoiceControlTraceStore: VoiceControlTraceSink {
    public static let schema = "macparakeet.voice-control.trace.v2"
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: AppPaths.voiceControlLogsDir, isDirectory: true)
    }
    public static var defaultLatestURL: URL {
        defaultDirectory.appendingPathComponent("latest.json")
    }
    /// Stable path agents can open without knowing the app-state override.
    public static var agentPointerDirectory: URL {
        URL(fileURLWithPath: "/tmp/macparakeet-voice-control", isDirectory: true)
    }

    public nonisolated let directory: URL
    public nonisolated var latestURL: URL { directory.appendingPathComponent("latest.json") }
    public nonisolated var latestMarkdownURL: URL { directory.appendingPathComponent("latest.md") }
    public nonisolated var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }
    public nonisolated var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    private let pointerDirectory: URL?
    private let retention: Int
    private let fileManager: FileManager
    private var session: VoiceControlPersistedSession?
    private var sessionURL: URL?
    private var prepared = false

    public init(
        directory: URL = VoiceControlTraceStore.defaultDirectory,
        pointerDirectory: URL? = VoiceControlTraceStore.agentPointerDirectory,
        retention: Int = 20,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.pointerDirectory = pointerDirectory
        self.retention = max(1, retention)
        self.fileManager = fileManager
    }

    public func beginTask(id: UUID, instruction: String) async {
        prepareIfNeeded()
        let now = Date()
        session = VoiceControlPersistedSession(
            schema: Self.schema, taskID: id, startedAt: now, updatedAt: now,
            instruction: Self.clip(instruction, 2_000), applicationName: nil,
            phase: "started", status: nil, summary: nil, observations: [], records: [], decisions: [])
        sessionURL = sessionsDirectory.appendingPathComponent(Self.sessionFileName(id: id, at: now))
        truncateEvents()
        persist()
    }

    public func record(_ record: VoiceControlTraceRecord) async {
        prepareIfNeeded()
        if session == nil || session?.taskID != record.taskID {
            await beginTask(id: record.taskID, instruction: "")
        }
        session?.records.append(record)
        if let count = session?.records.count, count > 256 {
            session?.records.removeFirst(count - 256)
        }
        appendEvent(stepEvent(record))
        persist()
        if VoiceControlTurnSummary.isTerminal(record), let session, let summary = session.summary {
            appendEvent(turnEvent(session, summary: summary))
        }
    }

    public func noteObservation(_ snapshot: VoiceControlSnapshot) async {
        prepareIfNeeded()
        guard session != nil else { return }
        let observation = VoiceControlPersistedObservation(
            at: Date(), complete: snapshot.isComplete, applicationName: snapshot.applicationName,
            targetCount: snapshot.targets.count,
            targets: snapshot.targets.map { target in
                VoiceControlPersistedTarget(
                    id: target.id, role: target.role, label: Self.clip(target.label, 240),
                    operations: target.operations.map(\.rawValue).sorted(),
                    isFocused: target.isFocused, isNavigation: target.isNavigation,
                    valueIsComplete: target.valueIsComplete, hasValue: target.value != nil, region: target.region)
            },
            snapshotID: snapshot.id, contextID: snapshot.contextID,
            summary: Self.clip(snapshot.summary, 4_000), metrics: snapshot.metrics)
        session?.applicationName = snapshot.applicationName
        session?.observations.append(observation)
        if let count = session?.observations.count, count > 8 {
            session?.observations.removeFirst(count - 8)
        }
        persist()
    }

    public func noteDecision(_ decision: VoiceControlDecisionTrace) async {
        prepareIfNeeded()
        guard session != nil else { return }
        var decisions = session?.decisions ?? []
        decisions.append(decision)
        if decisions.count > 32 { decisions.removeFirst(decisions.count - 32) }
        session?.decisions = decisions
        appendEvent(decisionEvent(decision))
        persist()
    }

    public func noteStatus(phase: String, message: String) async {
        guard session != nil else { return }
        session?.phase = Self.clip(phase, 64)
        session?.status = Self.clip(message, 500)
        persist()
    }

    public func loadLatest() -> VoiceControlPersistedSession? {
        guard let data = try? Data(contentsOf: latestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceControlPersistedSession.self, from: data)
    }

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let readme = directory.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: readme.path) {
            try? Self.readme.data(using: .utf8)?.write(to: readme, options: .atomic)
        }
    }

    private func persist() {
        guard var session else { return }
        session.updatedAt = Date()
        session.summary = VoiceControlTurnSummary.make(
            records: session.records, observations: session.observations,
            applicationName: session.applicationName, startedAt: session.startedAt,
            updatedAt: session.updatedAt)
        self.session = session
        guard let data = try? Self.encoder.encode(session) else { return }
        if let sessionURL { try? data.write(to: sessionURL) }
        try? data.write(to: latestURL, options: .atomic)
        var markdown = session.summary?.markdown(instruction: session.instruction, taskID: session.taskID)
        if let metrics = session.observations.last?.metrics {
            markdown = (markdown ?? "") + "walk: visited=\(metrics.nodesVisited) capped=\(metrics.capped) \(metrics.walkMilliseconds)ms\n"
        }
        let decisionLines = Self.decisionLines(session.decisions, observations: session.observations)
        if !decisionLines.isEmpty { markdown = (markdown ?? "") + decisionLines.joined(separator: "\n") + "\n" }
        try? markdown?.data(using: .utf8)?.write(to: latestMarkdownURL, options: .atomic)
        publishPointer(data, markdown: markdown)
        pruneSessions()
    }

    private func publishPointer(_ data: Data, markdown: String?) {
        guard let pointerDirectory else { return }
        try? fileManager.createDirectory(at: pointerDirectory, withIntermediateDirectories: true)
        try? data.write(to: pointerDirectory.appendingPathComponent("latest.json"), options: .atomic)
        try? markdown?.data(using: .utf8)?.write(
            to: pointerDirectory.appendingPathComponent("latest.md"), options: .atomic)
        let whereText = """
            canonical=\(directory.path)
            latest=\(latestURL.path)
            summary=\(latestMarkdownURL.path)
            events=\(eventsURL.path)
            command=\(directory.appendingPathComponent("command.json").path)

            """
        try? whereText.data(using: .utf8)?.write(
            to: pointerDirectory.appendingPathComponent("WHERE"), options: .atomic)
        let pointerReadme = pointerDirectory.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: pointerReadme.path) {
            try? Self.readme.data(using: .utf8)?.write(to: pointerReadme, options: .atomic)
        }
    }

    private func truncateEvents() {
        try? Data().write(to: eventsURL, options: .atomic)
    }

    private func appendEvent(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
            let data = try? JSONSerialization.data(withJSONObject: event),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        guard let payload = line.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: eventsURL.path) {
            try? payload.write(to: eventsURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: eventsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: payload)
    }

    private func stepEvent(_ record: VoiceControlTraceRecord) -> [String: Any] {
        var event: [String: Any] = [
            "type": "step",
            "schema": Self.schema,
            "task_id": record.taskID.uuidString,
            "revision": record.revision,
            "stage": record.stage,
            "outcome": record.outcome,
            "ts": ISO8601DateFormatter().string(from: record.timestamp),
        ]
        if let operation = record.operation { event["operation"] = operation.rawValue }
        if let actor = record.actor { event["actor"] = actor }
        if let route = record.route { event["route"] = route }
        if let targetID = record.targetID { event["target_id"] = targetID }
        if let targetLabel = record.targetLabel { event["target_label"] = targetLabel }
        if let keyName = record.keyName { event["key"] = keyName }
        if let detail = record.detail { event["detail"] = detail }
        if let duration = record.durationMilliseconds { event["duration_ms"] = duration }
        if let candidates = record.candidateCount { event["candidate_count"] = candidates }
        if let complete = record.observationComplete { event["observation_complete"] = complete }
        if let modelID = record.modelID { event["model_id"] = modelID }
        return event
    }

    private func decisionEvent(_ decision: VoiceControlDecisionTrace) -> [String: Any] {
        var heads: [String: Any] = [:]
        for (name, head) in decision.heads {
            heads[name] = [
                "choice": head.choice,
                "confidence": head.confidence,
                "top": head.top(5).map { ["option": $0.option, "p": $0.probability] },
            ]
        }
        var event: [String: Any] = [
            "type": "decision",
            "schema": Self.schema,
            "task_id": session?.taskID.uuidString ?? "",
            "ts": ISO8601DateFormatter().string(from: decision.at),
            "model_id": decision.model,
            "kind": decision.kind,
            "resolution": decision.resolution,
            "request_bytes": decision.requestBytes,
            "latency_ms": decision.latencyMilliseconds,
            "heads": heads,
        ]
        if let situation = decision.situation { event["situation"] = situation }
        return event
    }

    /// Lines for `latest.md`: the last model request, one line per head with its
    /// top options. Reads as "why did Jev pick that" without opening the JSON.
    static func decisionLines(_ decisions: [VoiceControlDecisionTrace]?, observations: [VoiceControlPersistedObservation]) -> [String] {
        guard let decision = decisions?.last else { return [] }
        let labels = Dictionary(
            observations.last?.targets.map { ($0.id, $0.label) } ?? [], uniquingKeysWith: { first, _ in first })
        var lines = [
            "jev: \(decision.kind) \(decision.resolution) \(decision.latencyMilliseconds)ms \(decision.requestBytes)B"
                + (decision.situation.map { " situation=\($0)" } ?? "")
        ]
        for name in decision.heads.keys.sorted() {
            guard let head = decision.heads[name] else { continue }
            let options = head.top(3).map { option -> String in
                let label = labels[option.option].map { " \"\(String($0.prefix(40)))\"" } ?? ""
                return "\(option.option)\(label)=\(String(format: "%.2f", option.probability))"
            }
            lines.append("  \(name): \(head.choice) (\(String(format: "%.2f", head.confidence))) " + options.joined(separator: " "))
        }
        return lines
    }

    private func turnEvent(_ session: VoiceControlPersistedSession, summary: VoiceControlTurnSummary) -> [String: Any] {
        var event: [String: Any] = [
            "type": "turn",
            "schema": Self.schema,
            "task_id": session.taskID.uuidString,
            "instruction": session.instruction,
            "outcome": summary.outcome,
            "record_count": summary.recordCount,
            "observation_count": summary.observationCount,
            "local_decisions": summary.localDecisions,
            "jev_decisions": summary.jevDecisions,
        ]
        if let why = summary.why { event["why"] = why }
        if let actor = summary.actor { event["actor"] = actor }
        if let route = summary.route { event["route"] = route }
        if let app = summary.applicationName { event["app"] = app }
        if let duration = summary.durationMilliseconds { event["duration_ms"] = duration }
        if let targetID = summary.lastTargetID { event["target_id"] = targetID }
        if let targetLabel = summary.lastTargetLabel { event["target_label"] = targetLabel }
        if let key = summary.lastKeyName { event["key"] = key }
        if let receipt = summary.lastReceipt { event["last_receipt"] = receipt }
        if let complete = summary.lastObservationComplete { event["observation_complete"] = complete }
        if let count = summary.lastTargetCount { event["target_count"] = count }
        return event
    }

    private func pruneSessions() {
        let files =
            (try? fileManager.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        let sessions = files.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left =
                (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let right =
                (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if left != right { return left > right }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
        for stale in sessions.dropFirst(retention) {
            try? fileManager.removeItem(at: stale)
        }
    }

    private static func sessionFileName(id: UUID, at date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "")
        return "\(stamp)-\(id.uuidString).json"
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static let readme = """
        MacParakeet Voice Control logs
        ==============================
        These files stay on this Mac. Nothing here is uploaded.

        Read this first:
          latest.md
          latest.json

        latest.md is the wide event for the current turn: outcome, why, actor,
        route, last control, decision counts, per-stage timing, and the last
        Jev request's top options per head. latest.json is the same summary
        plus joinable per-step records, offered controls (id, role, label),
        replayable observations (window text, no values), and every Jev
        probability (`decisions`). events.jsonl is the streaming form: one JSON
        object per step, one `type=decision` per model request, plus one
        `type=turn` line when the turn stops.

        Replay an observation offline without touching the screen:
          macparakeet-cli voice-control replay latest.json --goal "..."

        Dry run through the inbox (observe, route, decide, execute nothing):
          command.json  {"action":"submit","text":"...","dryRun":true}

        The log does not include API keys, audio, screenshots, selected text,
        field values or remote Jev bodies.

        The Voice Control panel's Copy diagnostics button copies a shareable
        summary that omits the instruction and control labels.

        Agents can also open /tmp/macparakeet-voice-control/latest.md
        (a pointer to this folder). Retention is the last 20 sessions.

        Submit a typed instruction without using the panel:
          command.json  {"action":"submit","text":"..."}
        Other actions: revise, continue, confirm, stop, cancel.
        Plain text in command.json is treated as submit.
        """
}
