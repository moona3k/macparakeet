import Foundation
import OSLog

public enum STTSchedulerError: Error, LocalizedError, Equatable {
    case droppedDueToBackpressure(job: STTJobKind)
    case unavailable
    case runtimeUnhealthy

    public var errorDescription: String? {
        switch self {
        case .droppedDueToBackpressure(let job):
            return "Speech job dropped due to backpressure: \(String(describing: job))"
        case .unavailable:
            return "Speech scheduler is temporarily unavailable"
        case .runtimeUnhealthy:
            return "Speech runtime is unavailable until the app or command is restarted"
        }
    }
}

private final class JobCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class TaskResultFlag<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Success, Error>?

    func finish(_ result: Result<Success, Error>) {
        lock.lock()
        if self.result == nil {
            self.result = result
        }
        lock.unlock()
    }

    var currentResult: Result<Success, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// Centralized broker for all STT work in the app process.
///
/// Jobs execute independently per slot so dictation can remain responsive while
/// meeting and file work share an explicitly prioritized background path.
public actor STTScheduler: STTManaging, SpeechEngineRoutedTranscribing, SpeechEngineSwitching, SpeechEngineSessionManaging {
    private struct ScheduledJob: Sendable {
        let id: UUID
        let audioPath: String
        let job: STTJobKind
        let speechEngine: SpeechEngineSelection?
        let enqueueOrder: UInt64
        let cancellationFlag: JobCancellationFlag
        let onProgress: (@Sendable (Int, Int) -> Void)?

        var slot: SchedulerSlot {
            SchedulerSlot(job: job)
        }
    }

    private struct SlotState {
        var pendingJobs: [ScheduledJob] = []
        var currentJob: ScheduledJob?
        var currentExecutionTask: Task<STTResult, Error>?
        var currentWaitTask: Task<Void, Never>?
        var currentWatchdogTask: Task<Void, Never>?
    }

    private struct RunningJobSnapshot {
        let id: UUID
        let slot: SchedulerSlot
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTScheduler")
    private let runtime: STTRuntimeProtocol
    private let meetingLiveChunkBacklogLimit: Int
    private let runningJobCancellationTimeout: Duration

    private var enqueueCounter: UInt64 = 0
    private var continuations: [UUID: CheckedContinuation<STTResult, Error>] = [:]
    private var slotStates: [SchedulerSlot: SlotState] = Dictionary(
        uniqueKeysWithValues: SchedulerSlot.allCases.map { ($0, SlotState()) }
    )
    private var cancelledRunningJobIDs: Set<UUID> = []
    private var acceptsNewJobs = true
    private var exclusiveOperationCount = 0
    private var clearModelCacheInProgress = false
    private var shutdownRequested = false
    private var runtimeUnhealthy = false
    private var activeSpeechEngineSessionIDs: Set<UUID> = []
    private var speechEngineSwitchTask: Task<Void, Error>?

    /// - Parameter meetingLiveChunkBacklogLimit: Maximum pending live-preview chunks before the
    ///   oldest is dropped. 120 ≈ 4 minutes of dual-source 5-second chunks emitted every ~4
    ///   seconds, enough to absorb a prolonged dictation burst before preview starts dropping.
    public init(
        runtime: STTRuntime = STTRuntime(),
        meetingLiveChunkBacklogLimit: Int = 120,
        runningJobCancellationTimeout: Duration = .seconds(10)
    ) {
        self.runtime = runtime as STTRuntimeProtocol
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runningJobCancellationTimeout = runningJobCancellationTimeout
    }

    init(
        runtimeProvider: STTRuntimeProtocol,
        meetingLiveChunkBacklogLimit: Int = 120,
        runningJobCancellationTimeout: Duration = .seconds(10)
    ) {
        self.runtime = runtimeProvider
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runningJobCancellationTimeout = runningJobCancellationTimeout
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let id = UUID()
        let cancellationFlag = JobCancellationFlag()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    ScheduledJob(
                        id: id,
                        audioPath: audioPath,
                        job: job,
                        speechEngine: nil,
                        enqueueOrder: nextEnqueueOrder(),
                        cancellationFlag: cancellationFlag,
                        onProgress: onProgress
                    ),
                    continuation: continuation
                )
            }
        } onCancel: {
            cancellationFlag.cancel()
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
        let cancellationFlag = JobCancellationFlag()
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
                        cancellationFlag: cancellationFlag,
                        onProgress: onProgress
                    ),
                    continuation: continuation
                )
            }
        } onCancel: {
            cancellationFlag.cancel()
            Task { [weak self] in
                await self?.cancel(jobID: id)
            }
        }
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        guard !runtimeUnhealthy else {
            throw STTSchedulerError.runtimeUnhealthy
        }
        try await runtime.warmUp(onProgress: onProgress)
    }

    public func backgroundWarmUp() async {
        guard !runtimeUnhealthy else { return }
        await runtime.backgroundWarmUp()
    }

    public func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        if runtimeUnhealthy {
            let stream = AsyncStream<STTWarmUpState> { continuation in
                continuation.yield(.failed(message: STTSchedulerError.runtimeUnhealthy.localizedDescription))
                continuation.finish()
            }
            return (UUID(), stream)
        }
        return await runtime.observeWarmUpProgress()
    }

    public func removeWarmUpObserver(id: UUID) async {
        await runtime.removeWarmUpObserver(id: id)
    }

    public func isReady() async -> Bool {
        guard !runtimeUnhealthy else { return false }
        return await runtime.isReady()
    }

    public func clearModelCache() async {
        guard !shutdownRequested else {
            logger.error("stt_clear_model_cache_skipped shutdown_requested=true")
            return
        }
        guard activeSpeechEngineSessionIDs.isEmpty else {
            logger.error("stt_clear_model_cache_skipped active_speech_engine_sessions=\(self.activeSpeechEngineSessionIDs.count, privacy: .public)")
            return
        }
        guard speechEngineSwitchTask == nil else {
            logger.error("stt_clear_model_cache_skipped speech_engine_switch_in_flight=true")
            return
        }
        guard !clearModelCacheInProgress else { return }

        clearModelCacheInProgress = true
        beginExclusiveOperation()
        defer {
            clearModelCacheInProgress = false
            endExclusiveOperation(restoreAcceptsNewJobs: true)
        }

        let drained = await quiesce(restoreAcceptsNewJobs: false)
        guard drained else {
            logger.error("stt_clear_model_cache_skipped runtime_unhealthy=true")
            return
        }
        let clearTask = Task { await runtime.clearModelCache() }
        let cleared = await waitForNonThrowingTask(
            clearTask,
            timeoutReason: "timed out waiting for runtime model cache clear"
        )
        guard cleared else {
            logger.error("stt_clear_model_cache_timed_out runtime_unhealthy=true")
            return
        }
    }

    public func shutdown() async {
        shutdownRequested = true
        let switchDrained = await cancelAndDrainSpeechEngineSwitchForShutdown()
        let drained = await quiesce(restoreAcceptsNewJobs: false)
        guard switchDrained, drained else {
            logger.error("stt_runtime_shutdown_skipped runtime_unhealthy=true")
            return
        }
        let shutdownTask = Task { await runtime.shutdown() }
        let shutDown = await waitForNonThrowingTask(
            shutdownTask,
            timeoutReason: "timed out waiting for runtime shutdown"
        )
        guard shutDown else {
            logger.error("stt_runtime_shutdown_timed_out runtime_unhealthy=true")
            return
        }
    }

    public func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        guard !runtimeUnhealthy else {
            throw STTSchedulerError.runtimeUnhealthy
        }
        guard !shutdownRequested else {
            throw STTSchedulerError.unavailable
        }
        guard acceptsNewJobs,
              activeSpeechEngineSessionIDs.isEmpty,
              !hasQueuedOrRunningJobs,
              speechEngineSwitchTask == nil else {
            throw STTError.engineBusy
        }

        beginExclusiveOperation()
        let switchTask = Task {
            try await runtime.setSpeechEngine(preference)
        }
        speechEngineSwitchTask = switchTask
        defer {
            speechEngineSwitchTask = nil
            endExclusiveOperation(restoreAcceptsNewJobs: true)
        }
        try await awaitSpeechEngineSwitchForCaller(switchTask)
    }

    public func beginSpeechEngineSession() async throws -> SpeechEngineLease {
        guard !runtimeUnhealthy else {
            throw STTSchedulerError.runtimeUnhealthy
        }
        guard speechEngineSwitchTask == nil else {
            throw STTError.engineBusy
        }
        guard !shutdownRequested,
              exclusiveOperationCount == 0,
              acceptsNewJobs,
              !hasCancelledRunningJobPendingDrain,
              !clearModelCacheInProgress else {
            throw STTSchedulerError.unavailable
        }
        let leaseID = UUID()
        activeSpeechEngineSessionIDs.insert(leaseID)
        var leaseReturned = false
        defer {
            if !leaseReturned {
                activeSpeechEngineSessionIDs.remove(leaseID)
            }
        }

        let selection = try await currentSpeechEngineSelectionForSession()
        guard !runtimeUnhealthy else {
            throw STTSchedulerError.runtimeUnhealthy
        }
        guard !shutdownRequested,
              exclusiveOperationCount == 0,
              acceptsNewJobs,
              !hasCancelledRunningJobPendingDrain,
              !clearModelCacheInProgress else {
            throw STTSchedulerError.unavailable
        }
        leaseReturned = true
        return SpeechEngineLease(id: leaseID, selection: selection)
    }

    public func endSpeechEngineSession(_ lease: SpeechEngineLease) async {
        activeSpeechEngineSessionIDs.remove(lease.id)
    }

    private func enqueue(
        _ job: ScheduledJob,
        continuation: CheckedContinuation<STTResult, Error>
    ) {
        if Task.isCancelled || job.cancellationFlag.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }

        guard !runtimeUnhealthy else {
            continuation.resume(throwing: STTSchedulerError.runtimeUnhealthy)
            return
        }

        if hasCancelledRunningJobPendingDrain {
            acceptsNewJobs = false
            continuation.resume(throwing: STTSchedulerError.unavailable)
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
        startQueuedJobsIfPossible()
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

    private func startNextJobIfNeeded(in slot: SchedulerSlot) {
        var currentSlotState = slotState(for: slot)
        guard currentSlotState.currentJob == nil else { return }
        guard canStartQueuedJobs else { return }
        guard let next = dequeueNextJob(in: &currentSlotState) else {
            setSlotState(currentSlotState, for: slot)
            return
        }

        currentSlotState.currentJob = next
        currentSlotState.currentExecutionTask = Task {
            if let speechEngine = next.speechEngine {
                try await runtime.transcribe(
                    audioPath: next.audioPath,
                    job: next.job,
                    speechEngine: speechEngine,
                    onProgress: next.onProgress
                )
            } else {
                try await runtime.transcribe(audioPath: next.audioPath, job: next.job, onProgress: next.onProgress)
            }
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
        guard let currentJob = slotState.currentJob, currentJob.id == jobID else { return }

        let continuation = continuations.removeValue(forKey: jobID)
        let wasMarkedCancelled = cancelledRunningJobIDs.remove(jobID) != nil
        let wasCancelled = currentJob.cancellationFlag.isCancelled || wasMarkedCancelled
        slotState.currentJob = nil
        slotState.currentExecutionTask = nil
        slotState.currentWaitTask = nil
        slotState.currentWatchdogTask?.cancel()
        slotState.currentWatchdogTask = nil
        setSlotState(slotState, for: slot)

        guard !wasCancelled else {
            continuation?.resume(throwing: CancellationError())
            restoreAcceptsNewJobsIfPossible()
            startQueuedJobsIfPossible()
            return
        }

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }

        startQueuedJobsIfPossible()
    }

    private func cancel(jobID: UUID) {
        for slot in SchedulerSlot.allCases {
            var currentSlotState = slotState(for: slot)
            if let index = currentSlotState.pendingJobs.firstIndex(where: { $0.id == jobID }) {
                currentSlotState.pendingJobs.remove(at: index)
                setSlotState(currentSlotState, for: slot)
                cancelledRunningJobIDs.remove(jobID)
                continuations.removeValue(forKey: jobID)?.resume(throwing: CancellationError())
                return
            }

            if currentSlotState.currentJob?.id == jobID {
                currentSlotState.currentJob?.cancellationFlag.cancel()
                cancelledRunningJobIDs.insert(jobID)
                acceptsNewJobs = false
                currentSlotState.currentExecutionTask?.cancel()
                currentSlotState.currentWatchdogTask?.cancel()
                currentSlotState.currentWatchdogTask = makeRunningJobCancellationWatchdogTask(jobID: jobID, in: slot)
                setSlotState(currentSlotState, for: slot)
                return
            }
        }

        cancelledRunningJobIDs.remove(jobID)
    }

    private func cancelAllPendingJobs() {
        let pendingIDs = SchedulerSlot.allCases.flatMap { slotState(for: $0).pendingJobs.map(\.id) }
        for slot in SchedulerSlot.allCases {
            var currentSlotState = slotState(for: slot)
            for job in currentSlotState.pendingJobs {
                job.cancellationFlag.cancel()
            }
            currentSlotState.pendingJobs.removeAll()
            setSlotState(currentSlotState, for: slot)
        }
        for id in pendingIDs {
            cancelledRunningJobIDs.remove(id)
            continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    private func quiesce(restoreAcceptsNewJobs: Bool) async -> Bool {
        acceptsNewJobs = false
        cancelAllPendingJobs()
        let drained = await cancelAndDrainRunningJobs()
        if restoreAcceptsNewJobs, drained {
            restoreAcceptsNewJobsIfPossible()
        }
        return drained && !runtimeUnhealthy
    }

    private func cancelAndDrainSpeechEngineSwitchForShutdown() async -> Bool {
        guard let switchTask = speechEngineSwitchTask else { return true }
        switchTask.cancel()
        return await waitForThrowingTask(
            switchTask,
            timeoutReason: "timed out waiting for speech engine switch to cancel"
        )
    }

    private func awaitSpeechEngineSwitchForCaller(_ switchTask: Task<Void, Error>) async throws {
        let cancellationFlag = JobCancellationFlag()
        let completion = watchThrowingTask(switchTask)

        try await withTaskCancellationHandler {
            while true {
                if cancellationFlag.isCancelled {
                    switchTask.cancel()
                    _ = await waitForTaskCompletion(
                        completion,
                        timeoutReason: "timed out waiting for cancelled speech engine switch to drain"
                    )
                    throw CancellationError()
                }
                if runtimeUnhealthy {
                    switchTask.cancel()
                    throw STTSchedulerError.runtimeUnhealthy
                }
                if let result = completion.currentResult {
                    return try result.get()
                }
                await Self.sleepIgnoringCallerCancellation(for: .milliseconds(20))
            }
        } onCancel: {
            cancellationFlag.cancel()
            switchTask.cancel()
        }
    }

    private func currentSpeechEngineSelectionForSession() async throws -> SpeechEngineSelection {
        let selectionTask = Task {
            await runtime.currentSpeechEngineSelection()
        }
        let completion = TaskResultFlag<SpeechEngineSelection>()
        Task {
            completion.finish(.success(await selectionTask.value))
        }
        let cancellationFlag = JobCancellationFlag()

        return try await withTaskCancellationHandler {
            let start = ContinuousClock.now
            while start.duration(to: .now) < runningJobCancellationTimeout {
                if cancellationFlag.isCancelled {
                    selectionTask.cancel()
                    throw CancellationError()
                }
                if runtimeUnhealthy {
                    selectionTask.cancel()
                    throw STTSchedulerError.runtimeUnhealthy
                }
                if let result = completion.currentResult {
                    return try result.get()
                }
                await Self.sleepIgnoringCallerCancellation(for: .milliseconds(20))
            }

            selectionTask.cancel()
            if let result = completion.currentResult {
                return try result.get()
            }
            markRuntimeUnhealthy(
                reason: "timed out waiting for speech engine selection for session",
                cancelledActiveJobIDs: []
            )
            throw STTSchedulerError.runtimeUnhealthy
        } onCancel: {
            cancellationFlag.cancel()
            selectionTask.cancel()
        }
    }

    private func waitForThrowingTask(
        _ task: Task<Void, Error>,
        timeoutReason: String
    ) async -> Bool {
        await waitForTaskCompletion(
            watchThrowingTask(task),
            timeoutReason: timeoutReason
        )
    }

    private func waitForNonThrowingTask(
        _ task: Task<Void, Never>,
        timeoutReason: String
    ) async -> Bool {
        let completion = TaskResultFlag<Void>()
        Task {
            await task.value
            completion.finish(.success(()))
        }
        let completed = await waitForTaskCompletion(
            completion,
            timeoutReason: timeoutReason
        )
        if !completed {
            task.cancel()
        }
        return completed
    }

    private func watchThrowingTask(_ task: Task<Void, Error>) -> TaskResultFlag<Void> {
        let completion = TaskResultFlag<Void>()
        Task {
            completion.finish(await task.result)
        }
        return completion
    }

    private func waitForTaskCompletion(
        _ completion: TaskResultFlag<Void>,
        timeoutReason: String
    ) async -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now) < runningJobCancellationTimeout {
            if completion.currentResult != nil {
                return true
            }
            await Self.sleepIgnoringCallerCancellation(for: .milliseconds(20))
        }

        guard completion.currentResult != nil else {
            markRuntimeUnhealthy(
                reason: timeoutReason,
                cancelledActiveJobIDs: []
            )
            return false
        }

        return true
    }

    private func cancelAndDrainRunningJobs() async -> Bool {
        let runningJobs = SchedulerSlot.allCases.compactMap { slot -> RunningJobSnapshot? in
            let slotState = slotState(for: slot)
            slotState.currentExecutionTask?.cancel()
            guard let currentJob = slotState.currentJob else { return nil }
            currentJob.cancellationFlag.cancel()
            let jobID = currentJob.id
            cancelledRunningJobIDs.insert(jobID)
            return RunningJobSnapshot(id: jobID, slot: slot)
        }

        guard !runningJobs.isEmpty else { return true }

        let start = ContinuousClock.now
        while start.duration(to: .now) < runningJobCancellationTimeout {
            if runningJobs.allSatisfy({ slotState(for: $0.slot).currentJob?.id != $0.id }) {
                return true
            }
            await Self.sleepIgnoringCallerCancellation(for: .milliseconds(20))
        }

        let timedOutJobIDs = Set(
            runningJobs.compactMap { job in
                slotState(for: job.slot).currentJob?.id == job.id ? job.id : nil
            }
        )
        guard timedOutJobIDs.isEmpty else {
            markRuntimeUnhealthy(
                reason: "timed out waiting for cancelled STT jobs to drain",
                cancelledActiveJobIDs: timedOutJobIDs
            )
            return false
        }

        return true
    }

    private func makeRunningJobCancellationWatchdogTask(jobID: UUID, in slot: SchedulerSlot) -> Task<Void, Never> {
        let timeout = runningJobCancellationTimeout
        return Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.runningJobCancellationDidTimeOut(jobID: jobID, in: slot)
        }
    }

    private func runningJobCancellationDidTimeOut(jobID: UUID, in slot: SchedulerSlot) {
        guard slotState(for: slot).currentJob?.id == jobID else { return }
        markRuntimeUnhealthy(
            reason: "cancelled STT job did not return before watchdog timeout",
            cancelledActiveJobIDs: [jobID]
        )
    }

    private func markRuntimeUnhealthy(reason: String, cancelledActiveJobIDs: Set<UUID>) {
        if !runtimeUnhealthy {
            logger.error("stt_runtime_unhealthy reason=\(reason, privacy: .public)")
        }
        runtimeUnhealthy = true
        acceptsNewJobs = false

        for slot in SchedulerSlot.allCases {
            var currentSlotState = slotState(for: slot)
            let pendingJobs = currentSlotState.pendingJobs
            currentSlotState.pendingJobs.removeAll()

            if let currentJob = currentSlotState.currentJob {
                currentSlotState.currentExecutionTask?.cancel()
                currentSlotState.currentJob = nil
                currentSlotState.currentExecutionTask = nil
                currentSlotState.currentWaitTask = nil
                currentSlotState.currentWatchdogTask?.cancel()
                currentSlotState.currentWatchdogTask = nil
                let wasCancelled = currentJob.cancellationFlag.isCancelled
                    || cancelledRunningJobIDs.contains(currentJob.id)
                    || cancelledActiveJobIDs.contains(currentJob.id)
                cancelledRunningJobIDs.remove(currentJob.id)
                let error: Error = wasCancelled
                    ? CancellationError()
                    : STTSchedulerError.runtimeUnhealthy
                continuations.removeValue(forKey: currentJob.id)?.resume(throwing: error)
            }

            setSlotState(currentSlotState, for: slot)

            for job in pendingJobs {
                let wasCancelled = job.cancellationFlag.isCancelled
                job.cancellationFlag.cancel()
                cancelledRunningJobIDs.remove(job.id)
                let error: Error = wasCancelled
                    ? CancellationError()
                    : STTSchedulerError.runtimeUnhealthy
                continuations.removeValue(forKey: job.id)?.resume(throwing: error)
            }
        }
    }

    private nonisolated static func sleepIgnoringCallerCancellation(for duration: Duration) async {
        await Task.detached {
            try? await Task.sleep(for: duration)
        }.value
    }

    private var hasCancelledRunningJobPendingDrain: Bool {
        if !cancelledRunningJobIDs.isEmpty {
            return true
        }
        return slotStates.values.contains { state in
            state.currentJob?.cancellationFlag.isCancelled == true
        }
    }

    private var canStartQueuedJobs: Bool {
        acceptsNewJobs
            && !runtimeUnhealthy
            && !shutdownRequested
            && !hasCancelledRunningJobPendingDrain
    }

    private func restoreAcceptsNewJobsIfPossible() {
        if !runtimeUnhealthy,
           !shutdownRequested,
           exclusiveOperationCount == 0,
           !hasCancelledRunningJobPendingDrain {
            acceptsNewJobs = true
        }
    }

    private func startQueuedJobsIfPossible() {
        guard canStartQueuedJobs else { return }
        for slot in SchedulerSlot.allCases {
            startNextJobIfNeeded(in: slot)
        }
    }

    private func beginExclusiveOperation() {
        exclusiveOperationCount += 1
        acceptsNewJobs = false
    }

    private func endExclusiveOperation(restoreAcceptsNewJobs: Bool) {
        exclusiveOperationCount = max(0, exclusiveOperationCount - 1)
        if restoreAcceptsNewJobs {
            restoreAcceptsNewJobsIfPossible()
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
