import Foundation

/// Local Voice Control session log. Instruction and control labels stay on this
/// Mac so a person or agent can see why a turn stalled. Field values, selected
/// text, audio, screenshots, credentials and remote bodies are omitted.
public protocol VoiceControlTraceSink: Sendable {
    func beginTask(id: UUID, instruction: String) async
    func record(_ record: VoiceControlTraceRecord) async
    func noteObservation(_ snapshot: VoiceControlSnapshot) async
    func noteStatus(phase: String, message: String) async
    func noteDecision(_ decision: VoiceControlDecisionTrace) async
}

public extension VoiceControlTraceSink {
    func noteDecision(_ decision: VoiceControlDecisionTrace) async {}
}

/// One model request as the decision engine saw it: every head, every
/// probability. Keys are snapshot-local target ids, closed operation/outcome
/// tokens, or span indices (`v3`) — never labels, spans, field values or the
/// instruction. This is what turns "Jev picked n:15" into a diagnosable event.
public struct VoiceControlDecisionTrace: Codable, Sendable, Equatable {
    public struct Head: Codable, Sendable, Equatable {
        public let choice: String
        /// Distribution concentration, not probability of task success.
        public let confidence: Double
        public let probabilities: [String: Double]
        public init(choice: String, confidence: Double, probabilities: [String: Double]) {
            self.choice = choice; self.confidence = confidence; self.probabilities = probabilities
        }
        /// The `limit` most probable options, highest first.
        public func top(_ limit: Int = 3) -> [(option: String, probability: Double)] {
            probabilities.sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }.prefix(limit).map { ($0.key, $0.value) }
        }
    }
    public let at: Date
    public let model: String
    /// `outcome` for an enabled-events Choice, `unconstrained` for the leftover request.
    public let kind: String
    public let situation: String?
    public let heads: [String: Head]
    public let requestBytes: Int
    public let latencyMilliseconds: Int
    /// Closed token: `action`, `clarify`, `finished`, `invalid`.
    public let resolution: String
    /// Controls dropped to stay under the request ceiling. Non-zero explains an
    /// `insufficient_evidence` or `none` that a fuller page would not have given.
    public let truncatedTargets: Int
    public init(
        at: Date = Date(), model: String, kind: String, situation: String?, heads: [String: Head],
        requestBytes: Int, latencyMilliseconds: Int, resolution: String, truncatedTargets: Int = 0
    ) {
        self.at = at; self.model = model; self.kind = kind; self.situation = situation
        self.heads = heads; self.requestBytes = requestBytes
        self.latencyMilliseconds = latencyMilliseconds; self.resolution = resolution
        self.truncatedTargets = truncatedTargets
    }
    private enum CodingKeys: String, CodingKey {
        case at, model, kind, situation, heads, requestBytes, latencyMilliseconds, resolution, truncatedTargets
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        model = try container.decode(String.self, forKey: .model)
        kind = try container.decode(String.self, forKey: .kind)
        situation = try container.decodeIfPresent(String.self, forKey: .situation)
        heads = try container.decode([String: Head].self, forKey: .heads)
        requestBytes = try container.decode(Int.self, forKey: .requestBytes)
        latencyMilliseconds = try container.decode(Int.self, forKey: .latencyMilliseconds)
        resolution = try container.decode(String.self, forKey: .resolution)
        truncatedTargets = try container.decodeIfPresent(Int.self, forKey: .truncatedTargets) ?? 0
    }
}

/// Content-minimized shareable diagnostics. Never stores commands, field values,
/// selected text, screenshots, audio, credentials or remote error bodies.
/// Local session logs (`VoiceControlTraceStore`) keep a separate on-disk copy
/// that may include the instruction and control labels.
public struct VoiceControlTraceRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let revision: Int
    public let timestamp: Date
    public let stage: String
    public let operation: VoiceControlOperation?
    public let outcome: String
    public let durationMilliseconds: Int?
    public let candidateCount: Int?
    public let observationComplete: Bool?
    public let modelID: String?
    /// Model distribution concentration, never probability of task success.
    public let decisionScore: Double?
    /// Closed error/policy token such as `noWindow` or `permission`. Never page text.
    public let detail: String?
    /// `local` or `jev`. Nil for runtime stages that are neither.
    public let actor: String?
    /// Closed route token: `destination`, `flight_plan`, `web_query`, `app`, `jev`, `policy`.
    public let route: String?
    /// Snapshot-local target id. Join to `observations[].targets[].id`. Never a field value.
    public let targetID: String?
    /// Control name for the local session log. Omitted from Copy diagnostics.
    public let targetLabel: String?
    /// Closed keyboard token such as `return` or `escape`. Never typed payload.
    public let keyName: String?

    public init(
        id: UUID, taskID: UUID, revision: Int, timestamp: Date, stage: String,
        operation: VoiceControlOperation?, outcome: String, durationMilliseconds: Int?,
        candidateCount: Int?, observationComplete: Bool?, modelID: String?, decisionScore: Double?,
        detail: String?, actor: String? = nil, route: String? = nil, targetID: String? = nil,
        targetLabel: String? = nil, keyName: String? = nil
    ) {
        self.id = id; self.taskID = taskID; self.revision = revision; self.timestamp = timestamp
        self.stage = stage; self.operation = operation; self.outcome = outcome
        self.durationMilliseconds = durationMilliseconds; self.candidateCount = candidateCount
        self.observationComplete = observationComplete; self.modelID = modelID
        self.decisionScore = decisionScore; self.detail = detail; self.actor = actor
        self.route = route; self.targetID = targetID; self.targetLabel = targetLabel; self.keyName = keyName
    }

    /// Shareable copy: opaque ids stay, control names do not.
    public func shareable() -> VoiceControlTraceRecord {
        VoiceControlTraceRecord(
            id: id, taskID: taskID, revision: revision, timestamp: timestamp, stage: stage,
            operation: operation, outcome: outcome, durationMilliseconds: durationMilliseconds,
            candidateCount: candidateCount, observationComplete: observationComplete, modelID: modelID,
            decisionScore: decisionScore, detail: detail, actor: actor, route: route,
            targetID: targetID, targetLabel: nil, keyName: keyName)
    }
}

/// One wide event per Voice Control turn. Answers "what happened to this task?"
/// without grepping stage lines. Field values and selected text are never stored.
public struct VoiceControlTurnSummary: Codable, Sendable, Equatable {
    public var outcome: String
    public var why: String?
    public var actor: String?
    public var route: String?
    public var lastStage: String?
    public var lastOperation: String?
    public var lastTargetID: String?
    public var lastTargetLabel: String?
    public var lastKeyName: String?
    public var lastReceipt: String?
    public var lastObservationComplete: Bool?
    public var lastTargetCount: Int?
    public var applicationName: String?
    public var durationMilliseconds: Int?
    public var observationCount: Int
    public var recordCount: Int
    public var localDecisions: Int
    public var jevDecisions: Int
    /// Mean and max milliseconds per stage over the records that timed it.
    public var timing: [String: VoiceControlStageTiming]?

    public static let timedStages = ["observation", "decision", "dispatch", "verification"]

    public static func timing(from records: [VoiceControlTraceRecord]) -> [String: VoiceControlStageTiming] {
        var result: [String: VoiceControlStageTiming] = [:]
        for stage in timedStages {
            let samples = records.filter { $0.stage == stage }.compactMap(\.durationMilliseconds)
            guard !samples.isEmpty else { continue }
            result[stage] = VoiceControlStageTiming(
                count: samples.count, meanMilliseconds: samples.reduce(0, +) / samples.count,
                maxMilliseconds: samples.max() ?? 0)
        }
        return result
    }

    /// `timing: observation 412ms (max 980, n=3)  decision 240ms …` in stage order.
    public var timingLine: String? {
        guard let timing, !timing.isEmpty else { return nil }
        let parts = Self.timedStages.compactMap { stage -> String? in
            guard let stat = timing[stage] else { return nil }
            return "\(stage) \(stat.meanMilliseconds)ms (max \(stat.maxMilliseconds), n=\(stat.count))"
        }
        return "timing: " + parts.joined(separator: "  ")
    }

    public static func make(
        records: [VoiceControlTraceRecord], observations: [VoiceControlPersistedObservation],
        applicationName: String?, startedAt: Date, updatedAt: Date
    ) -> VoiceControlTurnSummary {
        let last = records.last
        let terminal = records.reversed().first { Self.isTerminal($0) }
        let decisions = records.filter { $0.stage == "decision" && $0.outcome == "received" }
        let verification = records.reversed().first { $0.stage == "verification" }
        let subject = terminal ?? last
        return VoiceControlTurnSummary(
            outcome: terminal?.outcome ?? last?.outcome ?? "started",
            why: Self.why(terminal: terminal, last: last),
            actor: subject?.actor,
            route: subject?.route,
            lastStage: last?.stage,
            lastOperation: last?.operation?.rawValue ?? terminal?.operation?.rawValue,
            lastTargetID: subject?.targetID,
            lastTargetLabel: subject?.targetLabel,
            lastKeyName: subject?.keyName,
            lastReceipt: verification?.outcome,
            lastObservationComplete: observations.last?.complete,
            lastTargetCount: observations.last?.targetCount,
            applicationName: applicationName,
            durationMilliseconds: Int(updatedAt.timeIntervalSince(startedAt) * 1000),
            observationCount: observations.count,
            recordCount: records.count,
            localDecisions: decisions.filter { $0.actor == "local" }.count,
            jevDecisions: decisions.filter { $0.actor == "jev" }.count,
            timing: Self.timing(from: records))
    }

    public func shareable() -> VoiceControlTurnSummary {
        var copy = self
        copy.lastTargetLabel = nil
        return copy
    }

    public func markdown(instruction: String, taskID: UUID) -> String {
        var lines = [
            "# Voice Control turn",
            "task: \(taskID.uuidString)",
            "instruction: \(instruction)",
            "outcome: \(outcome)",
        ]
        if let why { lines.append("why: \(why)") }
        if let actor { lines.append("actor: \(actor)") }
        if let route { lines.append("route: \(route)") }
        if let applicationName { lines.append("app: \(applicationName)") }
        if let durationMilliseconds { lines.append("duration_ms: \(durationMilliseconds)") }
        lines.append("decisions: local=\(localDecisions) jev=\(jevDecisions)")
        if let lastReceipt { lines.append("last_receipt: \(lastReceipt)") }
        if let lastStage {
            var last = "last: \(lastStage)"
            if let lastOperation { last += "/\(lastOperation)" }
            if let lastTargetLabel {
                last += " \(lastTargetLabel)"
            } else if let lastTargetID {
                last += " \(lastTargetID)"
            }
            if let lastKeyName { last += " key=\(lastKeyName)" }
            lines.append(last)
        }
        if let lastObservationComplete {
            lines.append(
                "observation: \(lastObservationComplete ? "complete" : "partial") targets=\(lastTargetCount ?? 0)")
        }
        lines.append("observations: \(observationCount) records: \(recordCount)")
        if let timingLine { lines.append(timingLine) }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func isTerminal(_ record: VoiceControlTraceRecord) -> Bool {
        [
            "clarification_needed", "duplicate_blocked", "uncertain_replay_blocked", "failed",
            "paused", "cancelled", "direct_effect_verified", "completion_inferred",
            "completion_inferred_partial_observation", "exhausted", "no_progress",
            "active_time_exhausted", "confirmation_expired", "unoffered_target",
            "commitment_outcome_unverified", "dry_run",
        ].contains(record.outcome)
            || (record.stage == "task" && record.outcome != "started" && record.outcome != "continued")
    }

    private static func why(terminal: VoiceControlTraceRecord?, last: VoiceControlTraceRecord?) -> String? {
        guard let record = terminal ?? last else { return nil }
        var parts = [record.outcome]
        if let key = record.keyName { parts.append("key=\(key)") }
        if let detail = record.detail, detail != record.outcome { parts.append(detail) }
        if let actor = record.actor { parts.append("actor=\(actor)") }
        if let route = record.route { parts.append("route=\(route)") }
        return parts.joined(separator: " ")
    }
}

public struct VoiceControlStageTiming: Codable, Sendable, Equatable {
    public var count: Int
    public var meanMilliseconds: Int
    public var maxMilliseconds: Int
    public init(count: Int, meanMilliseconds: Int, maxMilliseconds: Int) {
        self.count = count; self.meanMilliseconds = meanMilliseconds; self.maxMilliseconds = maxMilliseconds
    }
}

/// Clipboard payload. Omits instruction and control labels; keeps opaque ids.
public struct VoiceControlShareableDiagnostics: Codable, Sendable, Equatable {
    public var schema: String
    public var taskID: UUID?
    public var summary: VoiceControlTurnSummary?
    public var records: [VoiceControlTraceRecord]

    public static func make(
        schema: String, taskID: UUID?, summary: VoiceControlTurnSummary?,
        records: [VoiceControlTraceRecord]
    ) -> VoiceControlShareableDiagnostics {
        VoiceControlShareableDiagnostics(
            schema: schema, taskID: taskID, summary: summary?.shareable(),
            records: records.map { $0.shareable() })
    }
}

public struct VoiceControlTaskLimits: Sendable {
    public let actions: Int
    public let decisions: Int
    public let activeSeconds: Double
    public let confirmationSeconds: Double
    public init(actions: Int = 40, decisions: Int = 100, activeSeconds: Double = 180, confirmationSeconds: Double = 20)
    {
        self.actions = max(1, actions); self.decisions = max(1, decisions)
        self.activeSeconds = max(0.01, activeSeconds); self.confirmationSeconds = max(0.01, confirmationSeconds)
    }
}

public enum VoiceControlConsequence: String, Codable, Sendable, CaseIterable {
    case ordinary, payment, destructive, externalCommitment, unknown
}

public enum VoiceControlConsequencePolicy {
    public static func consequence(of action: VoiceControlAction, target: VoiceControlTarget) -> VoiceControlConsequence
    {
        // Editing payment-related fields is not a payment commitment.
        if [.setValue, .insertText, .scroll, .activateApp].contains(action.operation) { return .ordinary }
        if action.operation == .key, ["backspace", "delete"].contains(action.value?.lowercased() ?? "") {
            // Delete in a collection can remove a message/file, even when the
            // model labels it ordinary. Only focused text editing is exempt.
            return target.isFocused && target.operations.contains(.insertText) ? .ordinary : .destructive
        }
        let label = target.label.lowercased()
        let words = Set(label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let shortLabel = words.count <= 5
        // Reviewed local evidence always wins over model-proposed ordinary risk.
        if shortLabel,
            !words.isDisjoint(with: ["pay", "purchase", "checkout", "buy", "payment", "subscribe", "order", "booking"])
        {
            return .payment
        }
        if shortLabel, !words.isDisjoint(with: ["delete", "erase", "trash", "destroy"]) { return .destructive }
        if shortLabel, !words.isDisjoint(with: ["send", "publish", "post", "transfer", "invite", "share"]) {
            return .externalCommitment
        }
        // A model's ordinary label cannot downgrade metadata the adapter already set.
        if let known = target.consequence, known != .unknown && known != .ordinary { return known }
        if action.operation == .press, target.consequence == .unknown, !target.isNavigation { return .unknown }
        if action.consequence == .ordinary { return .ordinary }
        if let supplied = action.consequence, supplied != .ordinary && supplied != .unknown { return supplied }
        switch action.operation {
        case .setValue, .insertText, .scroll, .activateApp, .select: return .ordinary
        case .key:
            let key = action.value?.lowercased() ?? ""
            if ["tab", "escape", "left", "right", "up", "down"].contains(key) { return .ordinary }
            // Spoken/typed keys are host tools. Do not ask "are you sure?" for Return.
            if ["return", "enter"].contains(key) { return .ordinary }
        case .press:
            // Pay/delete/send already returned above. Everything else should proceed;
            // asking about unlabeled chrome is the opposite of a magic loop.
            return .ordinary
        }
        if target.consequence == .ordinary || action.consequence == .ordinary { return .ordinary }
        return .unknown
    }
}
