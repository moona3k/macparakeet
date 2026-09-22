import Foundation

private final class LiveWorkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ next: Bool) {
        lock.lock(); value = next; lock.unlock()
    }
}

public actor VoiceControlTurnRunner {
    public nonisolated let events: AsyncStream<VoiceControlEvent>
    private let continuation: AsyncStream<VoiceControlEvent>.Continuation
    private let adapter: any VoiceControlAdapter
    private let engine: any VoiceControlDecisionEngine
    private let limits: VoiceControlTaskLimits
    private nonisolated let gate = VoiceControlAuthorityGate()
    private var ingressAuthority: ActionAuthority?
    private var goal = ""
    private var amendments: [String] = []
    private var history: [VoiceControlAction] = []
    private struct Pending {
        let id: UUID
        let action: VoiceControlAction
        let snapshot: VoiceControlSnapshot
        let created: Date
        let authority: ActionAuthority
    }
    private var pending: Pending?
    private var expiryTask: Task<Void, Never>?
    private var running = false
    /// In-flight work or a pending confirmation. A dry run reads this without
    /// hopping to the actor, and must not stop either one.
    private nonisolated let liveWork = LiveWorkFlag()
    public nonisolated var hasLiveWork: Bool { liveWork.isSet }
    private var cancelled = false
    private var dryRun = false
    private var submissionID = UUID()
    private var stoppedWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests = 0
    private var dispatched = 0
    private var activeSeconds: Double = 0
    private var segmentStarted: ContinuousClock.Instant?
    private var taskID = UUID()
    private var revision = 0
    private var traces: [VoiceControlTraceRecord] = []
    private let sink: (any VoiceControlTraceSink)?
    private var persistChain: Task<Void, Never>?
    private var lastSnapshot: VoiceControlSnapshot?
    private var referenceSnapshot: VoiceControlSnapshot?
    private var referenceAction: VoiceControlAction?
    private var referenceTime = Date.distantPast
    private var otherRequested = false
    private var alternativeLabels: [String] = []
    private var alternativeIDs: [String] = []
    private var alternativeRawLabels: [String] = []
    private var chosenAlternative: String?
    private var chosenTargetID: String?
    private var manualOverrides: [String: String] = [:]
    private var manualContextMismatch = false
    private var revisionSupersedesManualValues = false
    private struct EffectIdentity: Hashable {
        let operation: VoiceControlOperation
        let label: String
        let value: String?
    }
    private struct DispatchIdentity: Hashable {
        let context: String
        let prestate: [String]
        let summary: String
        let effect: EffectIdentity
    }
    private var dispatchedStates: Set<DispatchIdentity> = []
    private var uncertainEffects: Set<EffectIdentity> = []

    public init(
        adapter: any VoiceControlAdapter, engine: any VoiceControlDecisionEngine,
        limits: VoiceControlTaskLimits = VoiceControlTaskLimits(),
        sink: (any VoiceControlTraceSink)? = nil
    ) {
        self.adapter = adapter; self.engine = engine; self.limits = limits; self.sink = sink
        let pair = AsyncStream<VoiceControlEvent>.makeStream(bufferingPolicy: .bufferingNewest(200))
        events = pair.stream; continuation = pair.continuation
    }
    deinit { expiryTask?.cancel(); continuation.finish() }
    public var hasTask: Bool { !goal.isEmpty && !cancelled }
    public func traceSnapshot() -> [VoiceControlTraceRecord] { traces }
    public func flushTraces() async { await persistChain?.value }
    public nonisolated func stop() { gate.revoke() }
    public nonisolated func pauseForManualInput() { gate.revoke(manual: true) }

    public func cancel(submissionAuthority: ActionAuthority? = nil) {
        guard submissionAuthority?.isValid != false else { return }
        stop(); submissionID = UUID(); pending = nil; expiryTask?.cancel(); cancelled = true
        liveWork.set(false)
        goal = ""; amendments = []; history = []; referenceSnapshot = nil; referenceAction = nil
        lastSnapshot = nil; manualOverrides = [:]; otherRequested = false; alternativeLabels = []; alternativeIDs = []; alternativeRawLabels = []; chosenAlternative = nil; chosenTargetID = nil
        record("task", outcome: "cancelled")
        continuation.yield(.cancelled)
    }
    public func waitForIdle() async {
        if running { await withCheckedContinuation { stoppedWaiters.append($0) } }
    }
    public func cancelAndDrain() async {
        cancel()
        if running { await withCheckedContinuation { stoppedWaiters.append($0) } }
    }
    /// `dryRun` observes, routes and decides, then reports the compiled action
    /// instead of executing it. The task ends after that report.
    public func submit(_ goal: String, submissionAuthority: ActionAuthority? = nil, dryRun: Bool = false) async {
        guard submissionAuthority?.isValid != false else { return }
        stop()
        let id = UUID(); submissionID = id
        if running { await withCheckedContinuation { stoppedWaiters.append($0) } }
        guard submissionID == id, submissionAuthority?.isValid != false else { return }
        ingressAuthority = submissionAuthority
        self.dryRun = dryRun
        self.goal = goal; amendments = []; history = []; pending = nil; cancelled = false
        expiryTask?.cancel(); requests = 0; dispatched = 0; activeSeconds = 0
        dispatchedStates = []; uncertainEffects = []; manualOverrides = [:]; manualContextMismatch = false; revisionSupersedesManualValues = false
        lastSnapshot = nil; referenceSnapshot = nil; referenceAction = nil
        otherRequested = false; alternativeLabels = []; alternativeIDs = []; alternativeRawLabels = []; chosenAlternative = nil; chosenTargetID = nil
        _ = gate.takeManualPause()
        taskID = UUID(); revision = 0
        record("task", outcome: "started")
        await run()
    }
    public func revise(_ correction: String, submissionAuthority: ActionAuthority? = nil) async {
        dryRun = false
        guard submissionAuthority?.isValid != false else { return }
        guard hasTask else { await submit(correction, submissionAuthority: submissionAuthority); return }
        stop()
        let id = UUID(); submissionID = id
        if running { await withCheckedContinuation { stoppedWaiters.append($0) } }
        guard submissionID == id, hasTask, submissionAuthority?.isValid != false else { return }
        ingressAuthority = submissionAuthority
        manualOverrides = [:]; revisionSupersedesManualValues = true
        pending = nil; expiryTask?.cancel(); revision += 1
        let normalized = correction.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        otherRequested = ["other one", "the other one", "no the other one", "no, the other one", "not that one"].contains(normalized)
        chosenAlternative = nil; chosenTargetID = nil; alternativeLabels = []; alternativeIDs = []; alternativeRawLabels = []
        amendments.append("User correction (overrides earlier conflicting requirements): " + correction)
        if amendments.count > 20 { amendments.removeFirst(amendments.count - 20) }
        record("revision", outcome: otherRequested ? "alternative_requested" : "goal_amended")
        continuation.yield(.activity("Correction: " + correction))
        await run()
    }
    public func continueTask(submissionAuthority: ActionAuthority? = nil) async { await resume(submissionAuthority: submissionAuthority) }
    public func resume(submissionAuthority: ActionAuthority? = nil) async {
        dryRun = false
        guard hasTask, !running, submissionAuthority?.isValid != false else { return }
        ingressAuthority = submissionAuthority
        pending = nil; expiryTask?.cancel()
        record("task", outcome: "continued")
        await run()
    }
    public func clarify(_ answer: String, submissionAuthority: ActionAuthority? = nil) async {
        dryRun = false
        guard hasTask, !running, submissionAuthority?.isValid != false else { return }
        ingressAuthority = submissionAuthority
        if !alternativeLabels.isEmpty || !alternativeIDs.isEmpty {
            let count = max(alternativeLabels.count, alternativeIDs.count)
            if let index = VoiceControlSpokenPick.index(in: answer, count: count) {
                if alternativeLabels.indices.contains(index) { chosenAlternative = alternativeLabels[index] }
                if alternativeIDs.indices.contains(index) { chosenTargetID = alternativeIDs[index] }
            } else {
                let matches = alternativeLabels.filter {
                    $0.caseInsensitiveCompare(answer.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }
                guard matches.count == 1, let match = matches.first,
                    let index = alternativeLabels.firstIndex(of: match)
                else {
                    continuation.yield(
                        .clarification(VoiceControlSpokenPick.prompt(labels: alternativeLabels))); return
                }
                chosenAlternative = match
                if alternativeIDs.indices.contains(index) { chosenTargetID = alternativeIDs[index] }
            }
        }
        amendments.append("User clarification: " + answer); revision += 1
        record("revision", outcome: "clarified")
        await run()
    }
    public func confirm(submissionAuthority: ActionAuthority? = nil) async {
        dryRun = false
        guard !running, let pending, submissionAuthority?.isValid != false else { return }
        self.pending = nil; expiryTask?.cancel()
        guard pending.authority.isValid, Date().timeIntervalSince(pending.created) < limits.confirmationSeconds,
              withinBudget else {
            liveWork.set(false)
            record("policy", outcome: "confirmation_expired")
            continuation.yield(.paused("Confirmation expired. Repeat or revise the request.")); return
        }
        ingressAuthority = submissionAuthority ?? pending.authority
        let authority = gate.replace(using: ingressAuthority)
        beginSegment()
        var continueGoal = false
        let action = pending.action
        let snapshot = pending.snapshot
        do {
            continueGoal = try await perform(action, snapshot: snapshot, authority: authority)
        } catch let error as NativeVoiceControlError
            where error == .targetChanged || error == .changed || error == .observationExpired
                || error == .windowChanged
        {
            record(
                "dispatch", operation: action.operation, outcome: "stale_reobserve",
                observation: snapshot, action: action)
            // Confirmation authorizes this observation. Target ids are walk
            // positions, so a fresh snapshot can reuse n:4 for a different control.
            record("policy", outcome: "confirmation_stale", observation: snapshot, action: action)
            continuation.yield(
                .paused("The confirmed interface changed. Repeat or revise the request to review the current action."))
        } catch { report(error) }
        finishSegment()
        if continueGoal, authority.isValid, !cancelled { await run() }
        else { liveWork.set(false) }
    }

    private var withinBudget: Bool {
        dispatched < limits.actions && requests < limits.decisions && elapsedActive < limits.activeSeconds
    }
    private var elapsedActive: Double {
        activeSeconds + (segmentStarted.map { Self.seconds($0.duration(to: .now)) } ?? 0)
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private func beginSegment() {
        running = true
        liveWork.set(true)
        segmentStarted = .now
    }
    private func finishSegment() {
        if let segmentStarted { activeSeconds += Self.seconds(segmentStarted.duration(to: .now)) }
        segmentStarted = nil; running = false; gate.clearCancellation()
        if pending == nil { liveWork.set(false) }
        let waiters = stoppedWaiters; stoppedWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    private func record(_ stage: String, operation: VoiceControlOperation? = nil, outcome: String,
                        started: ContinuousClock.Instant? = nil, candidates: Int? = nil, complete: Bool? = nil,
                        modelID: String? = nil, decisionScore: Double? = nil,
                        observation: VoiceControlSnapshot? = nil, action: VoiceControlAction? = nil,
                        detail: String? = nil) {
        let target = action.flatMap { act in observation?.targets.first { $0.id == act.targetID } }
        let resolvedModel = action?.modelID ?? modelID
        let key = action?.operation == .key ? action?.value?.lowercased() : nil
        let record = VoiceControlTraceRecord(
            id: UUID(), taskID: taskID, revision: revision, timestamp: Date(),
            stage: stage, operation: operation, outcome: outcome,
            durationMilliseconds: started.map { Int(Self.seconds($0.duration(to: .now)) * 1000) },
            candidateCount: candidates, observationComplete: complete, modelID: resolvedModel,
            decisionScore: decisionScore, detail: detail,
            actor: Self.traceActor(modelID: resolvedModel, action: action),
            route: resolvedRoute(stage: stage, action: action, modelID: resolvedModel, observation: observation),
            targetID: action?.targetID,
            targetLabel: Self.clipLabel(target?.label ?? action?.targetLabel),
            keyName: key.flatMap { Self.tracedKeys.contains($0) ? $0 : nil })
        traces.append(record)
        if traces.count > 256 { traces.removeFirst(traces.count - 256) }
        enqueuePersist(record, instruction: stage == "task" && outcome == "started" ? goal : nil, observation: observation)
    }
    private static let tracedKeys: Set<String> = [
        "tab", "escape", "return", "enter", "left", "right", "up", "down", "backspace", "delete",
    ]
    private static func clipLabel(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return label.count <= 120 ? label : String(label.prefix(120))
    }
    private static func traceActor(modelID: String?, action: VoiceControlAction?) -> String? {
        if modelID == JevDecisionClient.model { return "jev" }
        if action != nil || modelID == "local" { return "local" }
        return nil
    }
    private func resolvedRoute(
        stage: String, action: VoiceControlAction?, modelID: String?, observation: VoiceControlSnapshot?
    ) -> String? {
        if modelID == JevDecisionClient.model { return "jev" }
        if stage == "policy", action == nil { return "policy" }
        guard let action else { return nil }
        if action.operation == .activateApp { return "app" }
        if action.targetID.hasPrefix("web:"), action.operation == .press { return "destination" }
        if VoiceControlFlightPlan.parse(goal) != nil { return "flight_plan" }
        if VoiceControlWebQuery.parse(goal) != nil { return "web_query" }
        if let observation,
            VoiceControlNamedPageAction.next(command: goal, snapshot: observation, history: history) != nil
        {
            return "named_page"
        }
        if action.operation == .key { return "key" }
        if action.operation == .setValue || action.operation == .insertText { return "fill" }
        if action.operation == .press { return "press" }
        return "local"
    }
    private func enqueuePersist(
        _ record: VoiceControlTraceRecord, instruction: String?, observation: VoiceControlSnapshot?
    ) {
        guard let sink else { return }
        let previous = persistChain
        persistChain = Task {
            await previous?.value
            if let instruction { await sink.beginTask(id: record.taskID, instruction: instruction) }
            if let observation { await sink.noteObservation(observation) }
            await sink.record(record)
        }
    }
    private func observe(authority: ActionAuthority) async throws -> VoiceControlSnapshot {
        let adapter = adapter
        let task = Task { try await adapter.observe() }
        gate.installCancellation { task.cancel() }
        defer { gate.clearCancellation() }
        let start = ContinuousClock.now
        do {
            let snapshot = try await task.value
            try authority.check()
            record("observation", outcome: snapshot.isComplete ? "complete" : "partial", started: start, candidates: snapshot.targets.count, complete: snapshot.isComplete, observation: snapshot)
            return snapshot
        } catch {
            let detail = (error as? NativeVoiceControlError).map(String.init(describing:))
            record("observation", outcome: authority.isValid ? "failed" : "cancelled", started: start, detail: detail)
            throw error
        }
    }
    private func decision(snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws -> VoiceControlDecision {
        let engine = engine; let goal = effectiveGoal; let history = history
        let task = Task { try await engine.decide(goal: goal, snapshot: snapshot, history: history) }
        gate.installCancellation { task.cancel() }
        defer { gate.clearCancellation() }
        let start = ContinuousClock.now; requests += 1
        do {
            let decision = try await task.value
            try authority.check()
            if case .action(let action) = decision {
                record(
                    "decision", operation: action.operation, outcome: "received", started: start,
                    modelID: action.modelID, decisionScore: action.decisionConfidence,
                    observation: snapshot, action: action)
            } else if case .clarify = decision {
                record("decision", outcome: "clarify", started: start)
            } else { record("decision", outcome: "received", started: start) }
            return decision
        } catch {
            if let error = error as? JevDecisionError {
                record(
                    "decision", outcome: authority.isValid ? "failed" : "cancelled", started: start,
                    modelID: JevDecisionClient.model, detail: String(describing: error))
            } else {
                record("decision", outcome: authority.isValid ? "failed" : "cancelled", started: start)
            }
            throw error
        }
    }
    private var effectiveGoal: String {
        guard !amendments.isEmpty || !manualOverrides.isEmpty || !uncertainEffects.isEmpty else { return goal }
        var parts = ["Continue this task using the latest corrections. Original goal: " + goal]
        parts += amendments
        if !manualOverrides.isEmpty {
            parts.append("The user manually changed these fields. Preserve their current values; these override earlier conflicting requirements:")
            parts += manualOverrides.keys.sorted().map { "\($0): \(manualOverrides[$0]!)" }
        }
        if !uncertainEffects.isEmpty { parts.append("Some executed effects have unknown outcomes. Inspect the current state; never repeat those effects. Ask if their outcome is necessary but cannot be determined.") }
        return parts.joined(separator: "\n")
    }
    private func absorbManualChanges(_ snapshot: VoiceControlSnapshot) -> Bool {
        let manuallyPaused = gate.takeManualPause()
        guard manuallyPaused || manualContextMismatch else { return true }
        if let previous = lastSnapshot, previous.contextID != snapshot.contextID {
            let expectedActivation = history.last?.operation == .activateApp && history.last?.receiptStatus == .verified && history.last?.targetLabel == snapshot.applicationName
            if !expectedActivation {
                manualContextMismatch = true
                record("takeover", outcome: "context_changed")
                continuation.yield(.clarification("The active app or window changed. Return to the original task window, or give a new instruction for this app."))
                return false
            }
        }
        manualContextMismatch = false
        if !revisionSupersedesManualValues, let previous = lastSnapshot, previous.contextID == snapshot.contextID {
            for target in snapshot.targets where target.valueIsComplete && target.operations.contains(.setValue) {
                let old = previous.targets.filter { $0.label == target.label && $0.role == target.role }
                guard old.count == 1, old[0].value != target.value else { continue }
                manualOverrides[target.label] = target.value ?? ""
            }
        }
        revision += 1
        record("takeover", outcome: "manual_state_observed")
        continuation.yield(.activity(revisionSupersedesManualValues ? "Continuing from the current interface with your latest correction." : "Continuing from the current interface, preserving your manual changes."))
        revisionSupersedesManualValues = false
        return true
    }
    private func alternativeDecision(_ snapshot: VoiceControlSnapshot) -> VoiceControlDecision? {
        guard otherRequested else { return nil }
        guard Date().timeIntervalSince(referenceTime) < 30, let previous = referenceSnapshot, let action = referenceAction,
              previous.contextID == snapshot.contextID,
              let rejected = previous.targets.first(where: { $0.id == action.targetID }) else {
            return .clarify("Which control do you mean? The previous alternatives are no longer current.")
        }
        let offered = previous.targets.filter { $0.operations.contains(action.operation) && $0.role == rejected.role && $0.id != rejected.id }
        let alternatives = snapshot.targets.filter { target in
            target.operations.contains(action.operation) && target.label != rejected.label && offered.contains(where: { $0.label == target.label && $0.role == target.role })
        }
        let chosen = alternatives.filter {
            if let id = chosenTargetID { return $0.id == id }
            if let name = chosenAlternative { return $0.label == name }
            return true
        }
        guard chosen.count == 1, let target = chosen.first else {
            var seen = Set<String>()
            var picks: [VoiceControlTarget] = []
            for target in alternatives {
                if seen.insert(target.id).inserted { picks.append(target) }
                if picks.count == 6 { break }
            }
            alternativeLabels = picks.map(\.label)
            alternativeIDs = picks.map(\.id)
            alternativeRawLabels = picks.map(\.label)
            return alternativeLabels.isEmpty
                ? .clarify("No other matching control is visible. Name the control you want.")
                : .pick(
                    prompt: VoiceControlSpokenPick.prompt(labels: alternativeLabels),
                    labels: alternativeLabels, targetIDs: alternativeIDs)
        }
        otherRequested = false; alternativeLabels = []; alternativeIDs = []; alternativeRawLabels = []; chosenAlternative = nil; chosenTargetID = nil
        return .action(VoiceControlAction(operation: action.operation, targetID: target.id, value: action.value, targetLabel: target.label))
    }
    private func resolvedPick(_ snapshot: VoiceControlSnapshot) -> VoiceControlDecision? {
        guard !otherRequested, chosenTargetID != nil || chosenAlternative != nil else { return nil }
        let chosen = resolvedPickTarget(in: snapshot)
        chosenAlternative = nil
        chosenTargetID = nil
        alternativeLabels = []
        alternativeIDs = []
        alternativeRawLabels = []
        guard let target = chosen else {
            return .clarify("Those options are no longer current. Name the control you want.")
        }
        return .action(
            VoiceControlAction(
                operation: target.operations.contains(.activateApp) ? .activateApp : .press,
                targetID: target.id, targetLabel: target.label))
    }

    private func resolvedPickTarget(in snapshot: VoiceControlSnapshot) -> VoiceControlTarget? {
        let expectedLabel: String?
        if let id = chosenTargetID, let idx = alternativeIDs.firstIndex(of: id),
            alternativeRawLabels.indices.contains(idx)
        {
            expectedLabel = alternativeRawLabels[idx]
        } else if let name = chosenAlternative {
            expectedLabel = name
        } else {
            expectedLabel = nil
        }
        if let id = chosenTargetID, let target = snapshot.targets.first(where: { $0.id == id }),
            target.operations.contains(.press) || target.operations.contains(.activateApp)
        {
            if let expectedLabel, target.label.localizedStandardCompare(expectedLabel) != .orderedSame {
                // ID was reused for a different control. Fall through to unique-label rematch.
            } else {
                return target
            }
        }
        guard let expectedLabel else { return nil }
        let matches = snapshot.targets.filter {
            ($0.operations.contains(.press) || $0.operations.contains(.activateApp))
                && $0.label.localizedStandardCompare(expectedLabel) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private func run() async {
        guard !running, hasTask else { return }
        beginSegment(); defer { finishSegment() }
        let authority = gate.replace(using: ingressAuthority)
        var noProgress = 0
        var previous: VoiceControlSnapshot?
        do {
            while authority.isValid, !cancelled {
                guard withinBudget else {
                    record("budget", outcome: "exhausted")
                    continuation.yield(.paused("The task reached its experiment limit. Give a new instruction for the remaining work.")); return
                }
                continuation.yield(.observing)
                let snapshot = try await observe(authority: authority)
                reconcilePostcondition(in: snapshot)
                guard absorbManualChanges(snapshot) else { return }
                lastSnapshot = snapshot
                if let previous, Self.semanticTargets(previous) == Self.semanticTargets(snapshot), previous.contextID == snapshot.contextID, previous.summary == snapshot.summary { noProgress += 1 } else { noProgress = 0 }
                guard noProgress < 2 else {
                    record("verification", outcome: "no_progress")
                    continuation.yield(.paused("The interface is not changing. You can fix it manually, then Continue.")); return
                }
                previous = snapshot
                continuation.yield(.deciding)
                let next = alternativeDecision(snapshot) ?? resolvedPick(snapshot)
                let decision: VoiceControlDecision
                if let next {
                    if case .action(let action) = next {
                        record(
                            "decision", operation: action.operation, outcome: "received",
                            modelID: "local", observation: snapshot, action: action)
                    } else if case .clarify = next {
                        record("decision", outcome: "clarify", detail: "alternative")
                    } else if case .pick = next {
                        record("decision", outcome: "clarify", detail: "numbered_pick")
                    }
                    decision = next
                } else { decision = try await self.decision(snapshot: snapshot, authority: authority) }
                try authority.check()
                guard elapsedActive < limits.activeSeconds else {
                    record("budget", outcome: "active_time_exhausted")
                    continuation.yield(.paused("The active task time limit was reached. Give a new instruction for the remaining work.")); return
                }
                switch decision {
                case .information(let message): continuation.yield(.completed(message)); return
                case .directCompleted(let message):
                    guard history.last?.receiptStatus == .verified else { continuation.yield(.paused("The requested effect has not been verified. Check the app.")); return }
                    record("task", outcome: "direct_effect_verified"); continuation.yield(.completed(message)); return
                case .finished:
                    record("task", outcome: snapshot.isComplete ? "completion_inferred" : "completion_inferred_partial_observation")
                    continuation.yield(.completed(snapshot.isComplete ? "The task appears complete. Check the result in the app." : "The task appears complete from the visible controls. Check the result in the app.")); return
                case .clarify(let question):
                    record("policy", outcome: "clarification_needed")
                    continuation.yield(.clarification(question)); return
                case .pick(let prompt, let labels, let ids):
                    alternativeLabels = Array(labels.prefix(6))
                    alternativeIDs = Array(ids.prefix(6))
                    alternativeRawLabels = alternativeIDs.compactMap { id in
                        snapshot.targets.first(where: { $0.id == id })?.label
                    }
                    record("policy", outcome: "numbered_pick")
                    continuation.yield(.clarification(prompt)); return
                case .action(let action):
                    guard let bound = bind(action, to: snapshot),
                        let target = snapshot.targets.first(where: { $0.id == bound.targetID })
                    else {
                        record("policy", outcome: "unoffered_target", observation: snapshot, action: action)
                        continuation.yield(.failed("The requested control is no longer available.")); return
                    }
                    guard !isRepeated(bound, snapshot: snapshot) else { return }
                    let consequence = VoiceControlConsequencePolicy.consequence(of: bound, target: target)
                    if dryRun {
                        record(
                            "dispatch", operation: bound.operation, outcome: "dry_run",
                            observation: snapshot, action: bound, detail: consequence.rawValue)
                        let gate = bound.requiresConfirmation || consequence != .ordinary ? " (would confirm: \(consequence.rawValue))" : ""
                        continuation.yield(.completed("Dry run: would \(bound.operation.rawValue) \(target.label)\(gate). Nothing was executed."))
                        return
                    }
                    if bound.requiresConfirmation || consequence != .ordinary {
                        offerConfirmation(bound, target: target, snapshot: snapshot, authority: authority, consequence: consequence); return
                    }
                    record(
                        "policy", operation: bound.operation, outcome: "ordinary_authorized",
                        observation: snapshot, action: bound)
                    do {
                        guard try await perform(bound, snapshot: snapshot, authority: authority) else { return }
                    } catch let error as NativeVoiceControlError
                        where error == .targetChanged || error == .changed || error == .observationExpired
                            || error == .windowChanged
                    {
                        record(
                            "dispatch", operation: bound.operation, outcome: "stale_reobserve",
                            observation: snapshot, action: bound)
                        continue
                    }
                }
            }
        } catch { report(error) }
    }
    private func offerConfirmation(_ action: VoiceControlAction, target: VoiceControlTarget, snapshot: VoiceControlSnapshot,
                                   authority: ActionAuthority, consequence: VoiceControlConsequence) {
        let id = UUID()
        pending = Pending(id: id, action: action, snapshot: snapshot, created: Date(), authority: authority)
        record(
            "policy", operation: action.operation, outcome: "confirmation_" + consequence.rawValue,
            observation: snapshot, action: action)
        let prefix = VoiceControlConfirmationCopy.prompt(action: action, target: target, consequence: consequence)
        continuation.yield(.confirmation(action, prefix))
        expiryTask?.cancel()
        let seconds = limits.confirmationSeconds
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.expireConfirmation(id)
        }
    }
    private func expireConfirmation(_ id: UUID) {
        guard pending?.id == id else { return }
        pending?.authority.revoke(); pending = nil
        liveWork.set(false)
        record("policy", outcome: "confirmation_expired")
        continuation.yield(.paused("Confirmation expired. Repeat or revise the request."))
    }
    private func perform(_ action: VoiceControlAction, snapshot: VoiceControlSnapshot, authority: ActionAuthority) async throws -> Bool {
        guard !isRepeated(action, snapshot: snapshot) else { return false }
        try authority.check()
        let identity = dispatchIdentity(action, snapshot: snapshot)
        dispatchedStates.insert(identity); dispatched += 1
        let effect = effectIdentity(action, snapshot: snapshot)
        referenceSnapshot = snapshot; referenceAction = action; referenceTime = Date()
        continuation.yield(.acting(action))
        record("dispatch", operation: action.operation, outcome: "started", observation: snapshot, action: action)
        let start = ContinuousClock.now
        let receipt: VoiceControlReceipt
        do { receipt = try await adapter.execute(action: action, snapshot: snapshot, authority: authority) }
        catch let error as NativeVoiceControlError
            where error == .targetChanged || error == .changed || error == .observationExpired
                || error == .windowChanged
        {
            dispatchedStates.remove(identity)
            dispatched = max(0, dispatched - 1)
            record(
                "dispatch", operation: action.operation, outcome: "stale_target", started: start,
                observation: snapshot, action: action)
            throw error
        }
        catch {
            uncertainEffects.insert(effect)
            history.append(historyAction(action, snapshot: snapshot, status: .unknown))
            record(
                "dispatch", operation: action.operation, outcome: "unknown_error", started: start,
                observation: snapshot, action: action)
            throw error
        }
        history.append(historyAction(action, snapshot: snapshot, status: receipt.status))
        let target = snapshot.targets.first(where: { $0.id == action.targetID })
        let consequence = target.map { VoiceControlConsequencePolicy.consequence(of: action, target: $0) } ?? .unknown
        let unverifiedCommitment = receipt.status == .transitionObserved && consequence != .ordinary
        if receipt.status == .unknown || unverifiedCommitment { uncertainEffects.insert(effect) }
        record(
            "verification", operation: action.operation, outcome: receipt.status.rawValue, started: start,
            observation: snapshot, action: action)
        let label = snapshot.targets.first(where: { $0.id == action.targetID })?.label ?? "Control"
        continuation.yield(.activity(label + " — " + (receipt.status == .verified ? "verified" : receipt.status == .transitionObserved ? "interface changed" : receipt.status == .unknown ? "outcome uncertain" : "failed")))
        try authority.check()
        if unverifiedCommitment {
            record(
                "policy", operation: action.operation, outcome: "commitment_outcome_unverified",
                observation: snapshot, action: action)
            continuation.yield(.paused("The interface changed, but the outcome of \(label) was not verified. Check whether it completed before continuing. This effect will not be repeated."))
            return false
        }
        guard receipt.status == .verified || receipt.status == .transitionObserved else {
            continuation.yield(.paused("The result of \(label) could not be verified. Check it manually, then Continue; this effect will not be repeated.")); return false
        }
        return true
    }
    private func historyAction(_ action: VoiceControlAction, snapshot: VoiceControlSnapshot, status: VoiceControlReceipt.Status) -> VoiceControlAction {
        VoiceControlAction(operation: action.operation, targetID: action.targetID, value: action.value,
            targetLabel: snapshot.targets.first(where: { $0.id == action.targetID })?.label ?? action.targetLabel,
            receiptStatus: status, consequence: action.consequence, modelID: action.modelID,
            decisionConfidence: action.decisionConfidence, postcondition: action.postcondition)
    }
    private func reconcilePostcondition(in snapshot: VoiceControlSnapshot) {
        guard let last = history.last, last.postcondition != .unknown,
            last.postcondition.holds(in: snapshot),
            last.receiptStatus == .transitionObserved || last.receiptStatus == .unknown
        else { return }
        history[history.count - 1] = VoiceControlAction(
            operation: last.operation, targetID: last.targetID, value: last.value,
            targetLabel: last.targetLabel, requiresConfirmation: last.requiresConfirmation,
            receiptStatus: .verified, consequence: last.consequence, modelID: last.modelID,
            decisionConfidence: last.decisionConfidence, postcondition: last.postcondition)
        record(
            "verification", operation: last.operation, outcome: "postcondition_holds",
            observation: snapshot, action: last)
    }
    private func bind(_ action: VoiceControlAction, to snapshot: VoiceControlSnapshot) -> VoiceControlAction? {
        if let target = snapshot.targets.first(where: { $0.id == action.targetID }),
            target.operations.contains(action.operation)
        {
            return action
        }
        guard let label = action.targetLabel, !label.isEmpty else { return nil }
        let matches = snapshot.targets.filter {
            $0.operations.contains(action.operation)
                && $0.label.localizedStandardCompare(label) == .orderedSame
        }
        guard matches.count == 1 else { return nil }
        let target = matches[0]
        return VoiceControlAction(
            operation: action.operation, targetID: target.id, value: action.value,
            targetLabel: target.label, requiresConfirmation: action.requiresConfirmation,
            receiptStatus: action.receiptStatus, consequence: action.consequence,
            modelID: action.modelID, decisionConfidence: action.decisionConfidence,
            postcondition: action.postcondition)
    }
    private func isRepeated(_ action: VoiceControlAction, snapshot: VoiceControlSnapshot) -> Bool {
        if uncertainEffects.contains(effectIdentity(action, snapshot: snapshot)) {
            record(
                "policy", operation: action.operation, outcome: "uncertain_replay_blocked",
                observation: snapshot, action: action)
            continuation.yield(.clarification("That effect has an uncertain outcome and will not be repeated. Check the app and describe a different next step.")); return true
        }
        if dispatchedStates.contains(dispatchIdentity(action, snapshot: snapshot)) {
            record(
                "policy", operation: action.operation, outcome: "duplicate_blocked",
                observation: snapshot, action: action)
            continuation.yield(.paused("That action already ran against this interface. Fix the state or revise the request.")); return true
        }
        return false
    }
    private func effectIdentity(_ action: VoiceControlAction, snapshot: VoiceControlSnapshot) -> EffectIdentity {
        EffectIdentity(operation: action.operation, label: snapshot.targets.first(where: { $0.id == action.targetID })?.label ?? action.targetID, value: action.value)
    }
    private func dispatchIdentity(_ action: VoiceControlAction, snapshot: VoiceControlSnapshot) -> DispatchIdentity {
        DispatchIdentity(context: snapshot.contextID, prestate: Self.semanticTargets(snapshot), summary: snapshot.summary, effect: effectIdentity(action, snapshot: snapshot))
    }
    private static func semanticTargets(_ snapshot: VoiceControlSnapshot) -> [String] {
        snapshot.targets.map { "\($0.role)|\($0.label)|\($0.value ?? "")|\($0.isFocused)|\($0.selectedText ?? "")|\($0.operations.map(\.rawValue).sorted().joined(separator: ","))" }.sorted()
    }
    private func report(_ error: Error) {
        guard !cancelled else { return }
        if error is CancellationError {
            record("task", outcome: "paused")
            continuation.yield(.paused("Stopped. You can correct the task or Continue."))
        } else if let error = error as? JevDecisionError {
            record("task", outcome: "failed", modelID: JevDecisionClient.model, detail: String(describing: error))
            continuation.yield(.failed(error.localizedDescription))
        } else if let error = error as? NativeVoiceControlError {
            record("task", outcome: "failed", detail: String(describing: error))
            continuation.yield(.failed(error.localizedDescription))
        } else {
            record("task", outcome: "failed", detail: "unclassified")
            continuation.yield(.failed("Voice Control could not continue. Check the app and connection."))
        }
    }
}

private final class VoiceControlAuthorityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ActionAuthority()
    private var cancellation: (@Sendable () -> Void)?
    private var manual = false
    func revoke(manual: Bool = false) {
        lock.lock(); if manual { self.manual = true }; current.revoke(); let cancel = cancellation; lock.unlock()
        cancel?()
    }
    func replace(using supplied: ActionAuthority? = nil) -> ActionAuthority {
        lock.lock(); defer { lock.unlock() }
        let replacement = supplied ?? ActionAuthority()
        if current !== replacement { current.revoke() }
        current = replacement; cancellation = nil; return current
    }
    func installCancellation(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock(); cancellation = cancel; let revoked = !current.isValid; lock.unlock()
        if revoked { cancel() }
    }
    func clearCancellation() { lock.lock(); cancellation = nil; lock.unlock() }
    func takeManualPause() -> Bool { lock.lock(); defer { lock.unlock() }; let value = manual; manual = false; return value }
}
