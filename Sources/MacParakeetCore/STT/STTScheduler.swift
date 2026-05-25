import Foundation
import OSLog

public enum STTSchedulerError: Error, LocalizedError, Equatable {
    case droppedDueToBackpressure(job: STTJobKind)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .droppedDueToBackpressure(let job):
            return "Speech job dropped due to backpressure: \(String(describing: job))"
        case .unavailable:
            return "Speech scheduler is temporarily unavailable"
        }
    }
}

/// Centralized broker for all STT work in the app process.
///
/// Jobs execute independently per slot so dictation can remain responsive while
/// meeting and file work share an explicitly prioritized background path.
public actor STTScheduler: STTManaging, SpeechEngineRoutedTranscribing, SpeechEngineSwitching, SpeechEngineSwitchAvailabilityProviding, SpeechEngineSessionManaging {
    private struct ScheduledJob: Sendable {
        let id: UUID
        let audioPath: String
        let job: STTJobKind
        let speechEngine: SpeechEngineSelection?
        let enqueueOrder: UInt64
        let onProgress: (@Sendable (Int, Int) -> Void)?

        var slot: Slot {
            // When the engine is already resolved (explicit-engine path), use it
            // to decide the slot. When nil (no-engine path), default to parakeet
            // so dictation keeps the interactive slot until preferences are read.
            let engine = speechEngine?.engine ?? .parakeet
            return STTScheduler.preferredSlot(for: job, engine: engine)
        }
    }

    private struct SlotState {
        var pendingJobs: [ScheduledJob] = []
        var currentJob: ScheduledJob?
        var currentExecutionTask: Task<STTResult, Error>?
        var currentWaitTask: Task<Void, Never>?
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTScheduler")
    private let runtime: STTRuntimeProtocol
    private let meetingLiveChunkBacklogLimit: Int
    private let runtimeOperationWatchdogTimeout: Duration

    private var enqueueCounter: UInt64 = 0
    private var continuations: [UUID: CheckedContinuation<STTResult, Error>] = [:]
    private var slotStates: [Slot: SlotState] = Dictionary(
        uniqueKeysWithValues: Slot.allCases.map { ($0, SlotState()) }
    )
    private var cancelledJobIDs: Set<UUID> = []
    private var acceptsNewJobs = true
    private var activeSpeechEngineSessionIDs: Set<UUID> = []
    private var speechEngineSwitchTask: Task<Void, Error>?
    // Single-flight guard for VibeVoice: the C library has one global engine,
    // so only one job runs at a time. The actor serializes access, making the
    // flag safe without additional locking.
    private var vibevoiceInFlight = false

    /// - Parameter meetingLiveChunkBacklogLimit: Maximum pending live-preview chunks before the
    ///   oldest is dropped. 120 ≈ 4 minutes of dual-source 5-second chunks emitted every ~4
    ///   seconds, enough to absorb a prolonged dictation burst before preview starts dropping.
    /// - Parameter runtimeOperationWatchdogTimeout: How long an STT runtime call (cancel-drain,
    ///   model-cache clear, shutdown, engine swap) may take before we emit
    ///   `stt_runtime_unhealthy` telemetry. Detection-only — no behavior changes; the caller
    ///   continues to await regardless. 30 s is generous enough that legitimate slow operations
    ///   on thermally throttled hardware should not trip it.
    public init(
        runtime: STTRuntime = STTRuntime(),
        meetingLiveChunkBacklogLimit: Int = 120,
        runtimeOperationWatchdogTimeout: Duration = .seconds(30)
    ) {
        self.runtime = runtime as STTRuntimeProtocol
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runtimeOperationWatchdogTimeout = runtimeOperationWatchdogTimeout
    }

    init(
        runtimeProvider: STTRuntimeProtocol,
        meetingLiveChunkBacklogLimit: Int = 120,
        runtimeOperationWatchdogTimeout: Duration = .seconds(30)
    ) {
        self.runtime = runtimeProvider
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runtimeOperationWatchdogTimeout = runtimeOperationWatchdogTimeout
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        // Resolve the engine per job from the current preferences. This means a
        // call like `scheduler.transcribe(audioPath:job:)` honours per-feature
        // overrides (e.g. dictation pinned to Parakeet even if global = Whisper).
        let prefs = SpeechEnginePreferences.current()
        let resolvedEngine = prefs.engine(for: job)
        let selection = SpeechEngineSelection(engine: resolvedEngine, language: nil)
        return try await transcribe(
            audioPath: audioPath,
            job: job,
            speechEngine: selection,
            onProgress: onProgress
        )
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    ScheduledJob(
                        id: id,
                        audioPath: audioPath,
                        job: job,
                        speechEngine: speechEngine,
                        enqueueOrder: nextEnqueueOrder(),
                        onProgress: onProgress
                    ),
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancel(jobID: id)
            }
        }
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await runtime.warmUp(onProgress: onProgress)
    }

    public func backgroundWarmUp() async {
        await runtime.backgroundWarmUp()
    }

    public func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        await runtime.observeWarmUpProgress()
    }

    public func removeWarmUpObserver(id: UUID) async {
        await runtime.removeWarmUpObserver(id: id)
    }

    public func isReady() async -> Bool {
        await runtime.isReady()
    }

    public func clearModelCache() async {
        await quiesce(restoreAcceptsNewJobs: true)
        await observingRuntimeTimeout(reason: "clear_model_cache") {
            await runtime.clearModelCache()
        }
    }

    public func shutdown() async {
        await quiesce(restoreAcceptsNewJobs: false)
        await observingRuntimeTimeout(reason: "shutdown") {
            await runtime.shutdown()
        }
    }

    public func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        try await setSpeechEngine(preference, onProgress: nil)
    }

    public func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard acceptsNewJobs,
              activeSpeechEngineSessionIDs.isEmpty,
              !hasQueuedOrRunningJobs,
              speechEngineSwitchTask == nil else {
            throw STTError.engineBusy
        }

        acceptsNewJobs = false
        let switchTask = Task {
            try await runtime.setSpeechEngine(preference, onProgress: onProgress)
        }
        speechEngineSwitchTask = switchTask
        defer {
            speechEngineSwitchTask = nil
            acceptsNewJobs = true
        }
        try await observingRuntimeTimeoutThrowing(reason: "set_speech_engine") {
            try await withTaskCancellationHandler {
                try await switchTask.value
            } onCancel: {
                switchTask.cancel()
            }
        }
    }

    public func engineSwitchAvailability() async -> SpeechEngineSwitchAvailability {
        if speechEngineSwitchTask != nil {
            return .switchInProgress
        }
        if !activeSpeechEngineSessionIDs.isEmpty {
            return .meetingActive
        }
        if hasQueuedOrRunningJobs {
            return .transcribing
        }
        if !acceptsNewJobs {
            return .unavailable
        }
        return .available
    }

    public func beginSpeechEngineSession() async -> SpeechEngineLease {
        if let speechEngineSwitchTask {
            let result = await speechEngineSwitchTask.result
            if case .failure(let error) = result {
                logger.warning("Proceeding with speech engine session after failed engine switch: \(error.localizedDescription, privacy: .public)")
            }
        }
        let lease = SpeechEngineLease(selection: await runtime.currentSpeechEngineSelection())
        activeSpeechEngineSessionIDs.insert(lease.id)
        return lease
    }

    public func endSpeechEngineSession(_ lease: SpeechEngineLease) async {
        activeSpeechEngineSessionIDs.remove(lease.id)
    }

    private func enqueue(
        _ job: ScheduledJob,
        continuation: CheckedContinuation<STTResult, Error>
    ) {
        if Task.isCancelled || cancelledJobIDs.remove(job.id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        guard acceptsNewJobs else {
            continuation.resume(throwing: STTSchedulerError.unavailable)
            return
        }

        continuations[job.id] = continuation
        var currentSlotState = slotState(for: job.slot)

        if job.job == .meetingLiveChunk,
           pendingMeetingLiveJobCount(in: currentSlotState) >= meetingLiveChunkBacklogLimit,
           let droppedJob = dropOldestPendingMeetingLiveJob(in: &currentSlotState) {
            logger.notice(
                "stt_backpressure drop_pending_meeting_live_chunk id=\(droppedJob.id.uuidString, privacy: .public)"
            )
            continuations.removeValue(forKey: droppedJob.id)?.resume(
                throwing: STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
            )
        }

        currentSlotState.pendingJobs.append(job)
        setSlotState(currentSlotState, for: job.slot)
        startNextJobIfNeeded(in: job.slot)
    }

    private func nextEnqueueOrder() -> UInt64 {
        defer { enqueueCounter &+= 1 }
        return enqueueCounter
    }

    private func slotState(for slot: Slot) -> SlotState {
        slotStates[slot, default: SlotState()]
    }

    private func setSlotState(_ slotState: SlotState, for slot: Slot) {
        slotStates[slot] = slotState
    }

    private var hasQueuedOrRunningJobs: Bool {
        slotStates.values.contains { state in
            state.currentJob != nil || !state.pendingJobs.isEmpty
        }
    }

    private func pendingMeetingLiveJobCount(in slotState: SlotState) -> Int {
        slotState.pendingJobs.reduce(into: 0) { count, job in
            if job.job == .meetingLiveChunk {
                count += 1
            }
        }
    }

    private func dropOldestPendingMeetingLiveJob(in slotState: inout SlotState) -> ScheduledJob? {
        guard let index = slotState.pendingJobs.enumerated()
            .filter({ $0.element.job == .meetingLiveChunk })
            .min(by: { $0.element.enqueueOrder < $1.element.enqueueOrder })?
            .offset else {
            return nil
        }
        return slotState.pendingJobs.remove(at: index)
    }

    private func startNextJobIfNeeded(in slot: Slot) {
        var currentSlotState = slotState(for: slot)
        guard currentSlotState.currentJob == nil else { return }
        guard let next = dequeueNextJob(in: &currentSlotState) else {
            setSlotState(currentSlotState, for: slot)
            return
        }

        currentSlotState.currentJob = next
        currentSlotState.currentExecutionTask = Task { [weak self] in
            guard let self else { throw CancellationError() }

            // All jobs come in with a resolved SpeechEngineSelection because the
            // no-engine transcribe overload now resolves preferences before enqueue.
            // The fallback branch below should not be reached in practice, but is
            // retained for any direct callers of the legacy enqueue path.
            guard let speechEngine = next.speechEngine else {
                return try await runtime.transcribe(
                    audioPath: next.audioPath, job: next.job, onProgress: next.onProgress
                )
            }

            // VibeVoice single-flight: the C library owns a single global engine.
            // Only one job may be active at a time. Wait for the flag to clear
            // before acquiring it. The actor serialises access so no locks needed.
            if speechEngine.engine == .vibevoice {
                while await self.vibevoiceInFlight {
                    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms poll
                }
                await self.setVibeVoiceInFlight(true)
            }
            defer {
                if speechEngine.engine == .vibevoice {
                    Task { [weak self] in await self?.setVibeVoiceInFlight(false) }
                }
            }

            return try await runtime.transcribe(
                audioPath: next.audioPath,
                job: next.job,
                speechEngine: speechEngine,
                onProgress: next.onProgress
            )
        }
        currentSlotState.currentWaitTask = Task { [weak self] in
            await self?.awaitCurrentJobCompletion(jobID: next.id, in: slot)
        }
        setSlotState(currentSlotState, for: slot)
    }

    private func dequeueNextJob(in slotState: inout SlotState) -> ScheduledJob? {
        guard let index = slotState.pendingJobs.indices.min(by: { lhs, rhs in
            let left = slotState.pendingJobs[lhs]
            let right = slotState.pendingJobs[rhs]
            if left.job.priorityRank != right.job.priorityRank {
                return left.job.priorityRank < right.job.priorityRank
            }
            return left.enqueueOrder < right.enqueueOrder
        }) else {
            return nil
        }
        return slotState.pendingJobs.remove(at: index)
    }

    private func setVibeVoiceInFlight(_ value: Bool) {
        vibevoiceInFlight = value
    }

    private func awaitCurrentJobCompletion(jobID: UUID, in slot: Slot) async {
        let slotState = slotState(for: slot)
        guard slotState.currentJob?.id == jobID, let executionTask = slotState.currentExecutionTask else { return }

        let result: Result<STTResult, Error>
        do {
            result = .success(try await executionTask.value)
        } catch {
            result = .failure(error)
        }

        finishCurrentJob(jobID: jobID, in: slot, result: result)
    }

    private func finishCurrentJob(jobID: UUID, in slot: Slot, result: Result<STTResult, Error>) {
        var slotState = slotState(for: slot)
        guard slotState.currentJob?.id == jobID else { return }

        let continuation = continuations.removeValue(forKey: jobID)
        cancelledJobIDs.remove(jobID)
        slotState.currentJob = nil
        slotState.currentExecutionTask = nil
        slotState.currentWaitTask = nil
        setSlotState(slotState, for: slot)

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }

        startNextJobIfNeeded(in: slot)
    }

    private func cancel(jobID: UUID) {
        for slot in Slot.allCases {
            var currentSlotState = slotState(for: slot)
            if let index = currentSlotState.pendingJobs.firstIndex(where: { $0.id == jobID }) {
                currentSlotState.pendingJobs.remove(at: index)
                setSlotState(currentSlotState, for: slot)
                cancelledJobIDs.remove(jobID)
                continuations.removeValue(forKey: jobID)?.resume(throwing: CancellationError())
                return
            }

            if currentSlotState.currentJob?.id == jobID {
                currentSlotState.currentExecutionTask?.cancel()
                cancelledJobIDs.remove(jobID)
                setSlotState(currentSlotState, for: slot)
                return
            }
        }

        cancelledJobIDs.insert(jobID)
    }

    private func cancelAllPendingJobs() {
        let pendingIDs = Slot.allCases.flatMap { slotState(for: $0).pendingJobs.map(\.id) }
        for slot in Slot.allCases {
            var currentSlotState = slotState(for: slot)
            currentSlotState.pendingJobs.removeAll()
            setSlotState(currentSlotState, for: slot)
        }
        for id in pendingIDs {
            continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    private func quiesce(restoreAcceptsNewJobs: Bool) async {
        acceptsNewJobs = false
        cancelAllPendingJobs()
        await cancelAndDrainRunningJobs()
        if restoreAcceptsNewJobs {
            acceptsNewJobs = true
        }
    }

    private func cancelAndDrainRunningJobs() async {
        let waitTasks = Slot.allCases.compactMap { slot -> Task<Void, Never>? in
            let slotState = slotState(for: slot)
            slotState.currentExecutionTask?.cancel()
            return slotState.currentWaitTask
        }
        guard !waitTasks.isEmpty else { return }
        await observingRuntimeTimeout(reason: "cancel_drain") {
            for task in waitTasks {
                await task.value
            }
        }
    }

    /// Watchdog probe for an STT runtime call that may hang if the underlying
    /// runtime (FluidAudio / WhisperKit) ignores cancellation. If `operation`
    /// exceeds `runtimeOperationWatchdogTimeout`, emits
    /// `stt_runtime_unhealthy` telemetry. The caller continues to await; this
    /// is observability-only.
    private func observingRuntimeTimeout<T: Sendable>(
        reason: String,
        operation: () async -> T
    ) async -> T {
        let watchdog = Self.makeRuntimeWatchdog(
            reason: reason,
            timeout: runtimeOperationWatchdogTimeout
        )
        defer { watchdog.cancel() }
        return await operation()
    }

    private func observingRuntimeTimeoutThrowing<T: Sendable>(
        reason: String,
        operation: () async throws -> T
    ) async throws -> T {
        let watchdog = Self.makeRuntimeWatchdog(
            reason: reason,
            timeout: runtimeOperationWatchdogTimeout
        )
        defer { watchdog.cancel() }
        return try await operation()
    }

    private nonisolated static func makeRuntimeWatchdog(
        reason: String,
        timeout: Duration
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            Telemetry.send(.sttRuntimeUnhealthy(reason: reason))
        }
    }
}

extension STTScheduler {
    /// The two execution slots. `.interactive` is reserved for dictation;
    /// `.background` handles all other work (meetings, file transcription,
    /// and any VibeVoice job — see `preferredSlot(for:engine:)`).
    public enum Slot: CaseIterable, Sendable {
        case interactive   // reserved for fast-latency dictation
        case background    // everything else
    }

    /// Routes a job to the right slot, taking the engine into account.
    ///
    /// VibeVoice never claims the interactive slot — its ~13 s load time
    /// would block dictation latency. Even when the user has configured
    /// VibeVoice for dictation, those jobs go to the background slot.
    public nonisolated static func preferredSlot(
        for jobKind: STTJobKind,
        engine: SpeechEnginePreference
    ) -> Slot {
        switch jobKind {
        case .dictation:
            return engine == .vibevoice ? .background : .interactive
        case .fileTranscription, .meetingFinalize, .meetingLiveChunk:
            return .background
        }
    }
}

private extension STTJobKind {
    // Priority is compared only within a slot. `dictation` and `meetingFinalize`
    // both rank highest, but they never contend because they execute on different slots.
    var priorityRank: Int {
        switch self {
        case .dictation:
            0
        case .meetingFinalize:
            0
        case .meetingLiveChunk:
            1
        case .fileTranscription:
            2
        }
    }
}
