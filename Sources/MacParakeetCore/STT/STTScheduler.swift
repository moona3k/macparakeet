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
public actor STTScheduler: STTManaging {
    private struct ScheduledJob: Sendable {
        let id: UUID
        let audioPath: String
        let job: STTJobKind
        let enqueueOrder: UInt64
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
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTScheduler")
    private let runtime: STTRuntimeProtocol
    private let meetingLiveChunkBacklogLimit: Int

    private var enqueueCounter: UInt64 = 0
    private var continuations: [UUID: CheckedContinuation<STTResult, Error>] = [:]
    private var slotStates: [SchedulerSlot: SlotState] = Dictionary(
        uniqueKeysWithValues: SchedulerSlot.allCases.map { ($0, SlotState()) }
    )
    private var cancelledJobIDs: Set<UUID> = []
    private var acceptsNewJobs = true

    /// - Parameter meetingLiveChunkBacklogLimit: Maximum pending live-preview chunks before the
    ///   oldest is dropped. 24 ≈ 4 minutes of 10-second chunks, enough to absorb a burst of
    ///   dictation activity without losing meaningful meeting context.
    public init(
        runtime: STTRuntime = STTRuntime(),
        meetingLiveChunkBacklogLimit: Int = 24
    ) {
        self.runtime = runtime as STTRuntimeProtocol
        self.meetingLiveChunkBacklogLimit = meetingLiveChunkBacklogLimit
    }

    init(
        runtimeProvider: STTRuntimeProtocol,
        meetingLiveChunkBacklogLimit: Int = 24
    ) {
        self.runtime = runtimeProvider
        self.meetingLiveChunkBacklogLimit = meetingLiveChunkBacklogLimit
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
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
        await runtime.clearModelCache()
    }

    public func shutdown() async {
        await quiesce(restoreAcceptsNewJobs: false)
        await runtime.shutdown()
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

    private func slotState(for slot: SchedulerSlot) -> SlotState {
        slotStates[slot, default: SlotState()]
    }

    private func setSlotState(_ slotState: SlotState, for slot: SchedulerSlot) {
        slotStates[slot] = slotState
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
        guard let next = dequeueNextJob(in: &currentSlotState) else {
            setSlotState(currentSlotState, for: slot)
            return
        }

        currentSlotState.currentJob = next
        currentSlotState.currentExecutionTask = Task {
            try await runtime.transcribe(audioPath: next.audioPath, job: next.job, onProgress: next.onProgress)
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
        cancelAllPendingJobs()
        await cancelAndDrainRunningJobs()
        if restoreAcceptsNewJobs {
            acceptsNewJobs = true
        }
    }

    private func cancelAndDrainRunningJobs() async {
        let waitTasks = SchedulerSlot.allCases.compactMap { slot -> Task<Void, Never>? in
            let slotState = slotState(for: slot)
            slotState.currentExecutionTask?.cancel()
            return slotState.currentWaitTask
        }
        for task in waitTasks {
            await task.value
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
