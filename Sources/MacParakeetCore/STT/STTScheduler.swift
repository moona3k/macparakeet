import Foundation
import OSLog

private typealias OneShotBoolContinuation = OneShotContinuation<Bool>

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
public actor STTScheduler: STTManaging, STTDictationPreviewTranscribing, SpeechEngineRoutedTranscribing,
    STTLiveDictationTranscribing, SpeechEngineSwitching, SpeechEngineSwitchAvailabilityProviding,
    SpeechEngineSessionManaging
{
    private struct ScheduledJob: Sendable {
        let id: UUID
        let audioPath: String
        let job: STTJobKind
        let speechEngine: SpeechEngineSelection
        let enqueueOrder: UInt64
        let onProgress: (@Sendable (Int, Int) -> Void)?

        var slot: SchedulerSlot {
            SchedulerSlot(job: job)
        }

        var serialResource: SchedulerSerialResource? {
            speechEngine.engine == .cohere ? .cohere : nil
        }
    }

    private struct SlotState {
        var pendingJobs: [ScheduledJob] = []
        var currentJob: ScheduledJob?
        var currentExecutionTask: Task<STTResult, Error>?
        var currentWaitTask: Task<Void, Never>?
    }

    private struct DictationPreviewExecution: Sendable {
        let id: UUID
        let task: Task<STTResult, Error>
    }

    private enum LiveDictationSessionState: Equatable {
        case active(UUID)
        case finishing(UUID)
        case cancelling(UUID)

        var id: UUID {
            switch self {
            case .active(let id), .finishing(let id), .cancelling(let id):
                return id
            }
        }
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTScheduler")
    private let runtime: STTRuntimeProtocol
    private let meetingLiveChunkBacklogLimit: Int
    private let runtimeOperationWatchdogTimeout: Duration
    private let dictationPreviewDrainTimeout: Duration

    private var enqueueCounter: UInt64 = 0
    private var continuations: [UUID: CheckedContinuation<STTResult, Error>] = [:]
    private var slotStates: [SchedulerSlot: SlotState] = Dictionary(
        uniqueKeysWithValues: SchedulerSlot.allCases.map { ($0, SlotState()) }
    )
    private var cancelledJobIDs: Set<UUID> = []
    private var acceptsNewJobs = true
    private var pendingJobAdmissionCount = 0
    private var activeSpeechEngineSessionIDs: Set<UUID> = []
    private var speechEngineSwitchTask: Task<Void, Error>?
    private var dictationPreviewExecution: DictationPreviewExecution?
    private var liveDictationSession: LiveDictationSessionState? {
        didSet {
            guard liveDictationSession == nil, !liveDictationSessionWaiters.isEmpty else { return }
            let waiters = liveDictationSessionWaiters
            liveDictationSessionWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
    private var liveDictationSessionWaiters: [CheckedContinuation<Void, Never>] = []

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
        runtimeOperationWatchdogTimeout: Duration = .seconds(30),
        dictationPreviewDrainTimeout: Duration = .seconds(2)
    ) {
        self.runtime = runtime as STTRuntimeProtocol
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runtimeOperationWatchdogTimeout = runtimeOperationWatchdogTimeout
        self.dictationPreviewDrainTimeout = dictationPreviewDrainTimeout
    }

    init(
        runtimeProvider: STTRuntimeProtocol,
        meetingLiveChunkBacklogLimit: Int = 120,
        runtimeOperationWatchdogTimeout: Duration = .seconds(30),
        dictationPreviewDrainTimeout: Duration = .seconds(2)
    ) {
        self.runtime = runtimeProvider
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runtimeOperationWatchdogTimeout = runtimeOperationWatchdogTimeout
        self.dictationPreviewDrainTimeout = dictationPreviewDrainTimeout
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try Task.checkCancellation()
        let id = UUID()
        pendingJobAdmissionCount += 1
        var admissionOpen = true
        defer {
            if admissionOpen {
                pendingJobAdmissionCount -= 1
            }
        }
        let selection = await runtime.currentSpeechEngineSelection()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                admissionOpen = false
                pendingJobAdmissionCount -= 1
                enqueue(
                    ScheduledJob(
                        id: id,
                        audioPath: audioPath,
                        job: job,
                        speechEngine: selection,
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

    public func beginLiveDictationTranscription(
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> UUID {
        guard acceptsNewJobs else {
            throw STTSchedulerError.unavailable
        }
        guard liveDictationSession == nil else {
            throw STTError.engineBusy
        }
        guard dictationPreviewExecution == nil else {
            throw STTError.engineBusy
        }
        let interactiveState = slotState(for: .interactive)
        guard interactiveState.currentJob == nil,
            interactiveState.pendingJobs.isEmpty
        else {
            throw STTError.engineBusy
        }

        let id = UUID()
        liveDictationSession = .active(id)
        do {
            let selection = await runtime.currentSpeechEngineSelection()
            // Selection only carries the engine family. `STTRuntime` owns the
            // active Parakeet sub-variant and rejects TDT v2/v3 below; the
            // scheduler only filters families with no native live path at all.
            guard selection.engine == .nemotron || selection.engine == .parakeet else {
                throw STTLiveDictationTranscriptionError.unsupportedEngine(selection.engine)
            }
            try await runtime.beginLiveDictationTranscription(
                sessionID: id,
                onPartial: onPartial
            )
            // A quiesce (engine switch, shutdown, cache clear) may have run
            // while runtime.begin was in flight; its runtime-level cancel was
            // a no-op because the runtime session did not exist yet. If our
            // reservation is gone, unwind the runtime session we just created
            // or it would be orphaned and block the interactive lane forever.
            guard liveDictationSession == .active(id) else {
                await runtime.cancelLiveDictationTranscription(sessionID: id)
                throw STTSchedulerError.unavailable
            }
            return id
        } catch {
            if liveDictationSession?.id == id {
                liveDictationSession = nil
            }
            throw error
        }
    }

    public func appendLiveDictationSamples(_ samples: [Float], sessionID: UUID) async throws {
        guard liveDictationSession == .active(sessionID) else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        try await runtime.appendLiveDictationSamples(samples, sessionID: sessionID)
    }

    public func finishLiveDictationTranscription(sessionID: UUID) async throws -> STTResult {
        guard liveDictationSession == .active(sessionID) else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        liveDictationSession = .finishing(sessionID)
        defer {
            if liveDictationSession == .finishing(sessionID) {
                liveDictationSession = nil
            }
        }
        return try await runtime.finishLiveDictationTranscription(sessionID: sessionID)
    }

    public func cancelLiveDictationTranscription(sessionID: UUID) async {
        guard liveDictationSession == .active(sessionID) else { return }
        liveDictationSession = .cancelling(sessionID)
        await runtime.cancelLiveDictationTranscription(sessionID: sessionID)
        if liveDictationSession == .cancelling(sessionID) {
            liveDictationSession = nil
        }
    }

    public func transcribeDictationPreview(
        samples: [Float],
        speechEngine selection: SpeechEngineSelection
    ) async throws -> STTResult {
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw STTError.transcriptionFailed("No dictation preview samples")
        }
        guard acceptsNewJobs, speechEngineSwitchTask == nil else {
            throw STTSchedulerError.unavailable
        }
        guard liveDictationSession == nil else {
            throw STTError.engineBusy
        }
        guard dictationPreviewExecution == nil else {
            throw STTError.engineBusy
        }

        let id = UUID()
        let task = Task {
            try await runtime.transcribeDictationPreview(samples: samples, speechEngine: selection)
        }
        dictationPreviewExecution = DictationPreviewExecution(id: id, task: task)
        defer {
            clearDictationPreviewExecution(id: id)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancelDictationPreview() async {
        await cancelDictationPreviewIfNeeded()
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
        await quiesce(restoreAcceptsNewJobs: false)
        defer { acceptsNewJobs = true }
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
        guard await cancelDictationPreviewIfNeeded() else {
            throw STTError.engineBusy
        }
        guard acceptsNewJobs,
            activeSpeechEngineSessionIDs.isEmpty,
            !hasQueuedOrRunningJobs,
            speechEngineSwitchTask == nil
        else {
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

    public func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard await cancelDictationPreviewIfNeeded() else {
            throw STTError.engineBusy
        }
        // Shares the engine-switch guard + task slot: a variant swap reloads the
        // model and must not race transcription, meetings, or an engine switch.
        guard acceptsNewJobs,
            activeSpeechEngineSessionIDs.isEmpty,
            !hasQueuedOrRunningJobs,
            speechEngineSwitchTask == nil
        else {
            throw STTError.engineBusy
        }

        acceptsNewJobs = false
        let switchTask = Task {
            try await runtime.setParakeetModelVariant(variant, onProgress: onProgress)
        }
        speechEngineSwitchTask = switchTask
        defer {
            speechEngineSwitchTask = nil
            acceptsNewJobs = true
        }
        try await observingRuntimeTimeoutThrowing(reason: "set_parakeet_model_variant") {
            try await withTaskCancellationHandler {
                try await switchTask.value
            } onCancel: {
                switchTask.cancel()
            }
        }
    }

    public func setNemotronModelVariant(
        _ variant: NemotronModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard await cancelDictationPreviewIfNeeded() else {
            throw STTError.engineBusy
        }
        // Shares the engine-switch guard + task slot: a variant swap reloads the
        // model and must not race transcription, meetings, or an engine switch.
        guard acceptsNewJobs,
            activeSpeechEngineSessionIDs.isEmpty,
            !hasQueuedOrRunningJobs,
            speechEngineSwitchTask == nil
        else {
            throw STTError.engineBusy
        }

        acceptsNewJobs = false
        let switchTask = Task {
            try await runtime.setNemotronModelVariant(variant, onProgress: onProgress)
        }
        speechEngineSwitchTask = switchTask
        defer {
            speechEngineSwitchTask = nil
            acceptsNewJobs = true
        }
        try await observingRuntimeTimeoutThrowing(reason: "set_nemotron_model_variant") {
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
        // Reserve the session slot before the first suspension point. From
        // here on, the `activeSpeechEngineSessionIDs.isEmpty` guard in
        // setSpeechEngine / setParakeetModelVariant fails, so no engine
        // switch can start while this method is suspended below. Inserting
        // the ID only after reading the selection left a TOCTOU window: a
        // switch could interleave at either await and the lease would pin a
        // different engine than the runtime ends up on (AUDIT-071).
        let sessionID = UUID()
        activeSpeechEngineSessionIDs.insert(sessionID)

        // Drain a switch that was already in flight when we entered; the
        // reservation above guarantees no new one starts behind it.
        if let speechEngineSwitchTask {
            let result = await speechEngineSwitchTask.result
            if case .failure(let error) = result {
                logger.warning(
                    "Proceeding with speech engine session after failed engine switch: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return SpeechEngineLease(id: sessionID, selection: await runtime.currentSpeechEngineSelection())
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

        guard !(job.slot == .interactive && liveDictationSession != nil) else {
            continuation.resume(throwing: STTError.engineBusy)
            return
        }

        continuations[job.id] = continuation
        var currentSlotState = slotState(for: job.slot)

        if job.job == .meetingLiveChunk,
            pendingMeetingLiveJobCount(in: currentSlotState) >= meetingLiveChunkBacklogLimit,
            let droppedJob = dropOldestPendingMeetingLiveJob(in: &currentSlotState)
        {
            logger.notice(
                "stt_backpressure drop_pending_meeting_live_chunk id=\(droppedJob.id.uuidString, privacy: .public)"
            )
            continuations.removeValue(forKey: droppedJob.id)?.resume(
                throwing: STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
            )
        }

        currentSlotState.pendingJobs.append(job)
        setSlotState(currentSlotState, for: job.slot)
        startNextJobsIfNeeded()
    }

    private func nextEnqueueOrder() -> UInt64 {
        defer { enqueueCounter &+= 1 }
        return enqueueCounter
    }

    private func slotState(for slot: SchedulerSlot) -> SlotState {
        slotStates[slot, default: SlotState()]
    }

    private func setSlotState(_ slotState: SlotState, for slot: SchedulerSlot) {
        slotStates[slot] = slotState
    }

    private var hasQueuedOrRunningJobs: Bool {
        pendingJobAdmissionCount > 0 || liveDictationSession != nil
            || slotStates.values.contains { state in
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
        guard
            let index = slotState.pendingJobs.enumerated()
                .filter({ $0.element.job == .meetingLiveChunk })
                .min(by: { $0.element.enqueueOrder < $1.element.enqueueOrder })?
                .offset
        else {
            return nil
        }
        return slotState.pendingJobs.remove(at: index)
    }

    private func startNextJobIfNeeded(in slot: SchedulerSlot) {
        var currentSlotState = slotState(for: slot)
        guard currentSlotState.currentJob == nil else { return }
        guard let next = dequeueNextJob(in: &currentSlotState) else {
            setSlotState(currentSlotState, for: slot)
            return
        }

        currentSlotState.currentJob = next
        currentSlotState.currentExecutionTask = Task {
            try await runtime.transcribe(
                audioPath: next.audioPath,
                job: next.job,
                speechEngine: next.speechEngine,
                onProgress: next.onProgress
            )
        }
        currentSlotState.currentWaitTask = Task { [weak self] in
            await self?.awaitCurrentJobCompletion(jobID: next.id, in: slot)
        }
        setSlotState(currentSlotState, for: slot)
    }

    private func startNextJobsIfNeeded() {
        for slot in SchedulerSlot.allCases {
            startNextJobIfNeeded(in: slot)
        }
    }

    private func dequeueNextJob(in slotState: inout SlotState) -> ScheduledJob? {
        guard
            let index = slotState.pendingJobs.indices
                .filter({ !isSerialResourceBusy(for: slotState.pendingJobs[$0]) })
                .min(by: { lhs, rhs in
                    let left = slotState.pendingJobs[lhs]
                    let right = slotState.pendingJobs[rhs]
                    if left.job.priorityRank != right.job.priorityRank {
                        return left.job.priorityRank < right.job.priorityRank
                    }
                    return left.enqueueOrder < right.enqueueOrder
                })
        else {
            return nil
        }
        return slotState.pendingJobs.remove(at: index)
    }

    private func isSerialResourceBusy(for job: ScheduledJob) -> Bool {
        guard let resource = job.serialResource else { return false }
        return slotStates.values.contains { state in
            state.currentJob?.serialResource == resource
        }
    }

    private func awaitCurrentJobCompletion(jobID: UUID, in slot: SchedulerSlot) async {
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

    private func finishCurrentJob(jobID: UUID, in slot: SchedulerSlot, result: Result<STTResult, Error>) {
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

        startNextJobsIfNeeded()
    }

    private func cancel(jobID: UUID) {
        for slot in SchedulerSlot.allCases {
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
        let pendingIDs = SchedulerSlot.allCases.flatMap { slotState(for: $0).pendingJobs.map(\.id) }
        for slot in SchedulerSlot.allCases {
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
        await cancelAndDrainDictationPreviewIfNeeded()
        cancelAllPendingJobs()
        await cancelLiveDictationSessionIfNeeded()
        await cancelAndDrainRunningJobs()
        if restoreAcceptsNewJobs {
            acceptsNewJobs = true
        }
    }

    private func cancelLiveDictationSessionIfNeeded() async {
        switch liveDictationSession {
        case .active(let sessionID):
            liveDictationSession = .cancelling(sessionID)
            await runtime.cancelLiveDictationTranscription(sessionID: sessionID)
            if liveDictationSession == .cancelling(sessionID) {
                liveDictationSession = nil
            }
        case .finishing, .cancelling:
            await waitForLiveDictationSessionToEnd()
        case nil:
            return
        }
    }

    private func waitForLiveDictationSessionToEnd() async {
        while liveDictationSession != nil {
            await withCheckedContinuation { continuation in
                liveDictationSessionWaiters.append(continuation)
            }
        }
    }

    @discardableResult
    private func cancelDictationPreviewIfNeeded() async -> Bool {
        guard let execution = dictationPreviewExecution else { return true }
        execution.task.cancel()
        let drained = await waitForDictationPreviewDrain(execution.task)
        if drained {
            clearDictationPreviewExecution(id: execution.id)
        } else {
            Telemetry.send(.sttRuntimeUnhealthy(reason: "dictation_preview_cancel_drain"))
        }
        return drained
    }

    private func cancelAndDrainDictationPreviewIfNeeded() async {
        guard let execution = dictationPreviewExecution else { return }
        execution.task.cancel()
        await observingRuntimeTimeout(reason: "dictation_preview_cancel_drain") {
            _ = await execution.task.result
        }
        clearDictationPreviewExecution(id: execution.id)
    }

    private func waitForDictationPreviewDrain(_ task: Task<STTResult, Error>) async -> Bool {
        let timeout = dictationPreviewDrainTimeout
        return await withCheckedContinuation { continuation in
            let gate = OneShotBoolContinuation(continuation)
            Task {
                _ = await task.result
                gate.resume(returning: true)
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(returning: false)
            }
        }
    }

    private func clearDictationPreviewExecution(id: UUID) {
        guard dictationPreviewExecution?.id == id else { return }
        dictationPreviewExecution = nil
    }

    private func cancelAndDrainRunningJobs() async {
        let waitTasks = SchedulerSlot.allCases.compactMap { slot -> Task<Void, Never>? in
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

private enum SchedulerSlot: CaseIterable, Sendable {
    case interactive
    case background

    init(job: STTJobKind) {
        switch job {
        case .dictation:
            self = .interactive
        case .meetingFinalize, .meetingLiveChunk, .fileTranscription:
            self = .background
        }
    }
}

private enum SchedulerSerialResource: Sendable {
    case cohere
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
