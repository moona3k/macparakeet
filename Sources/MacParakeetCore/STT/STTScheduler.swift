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
/// Jobs execute independently per lane so dictation can remain responsive while
/// meeting transcription is active, and batch/file transcription no longer
/// stalls meeting stop/finalize.
public actor STTScheduler: STTManaging {
    private struct ScheduledJob: Sendable {
        let id: UUID
        let audioPath: String
        let job: STTJobKind
        let enqueueOrder: UInt64
        let onProgress: (@Sendable (Int, Int) -> Void)?

        var lane: SchedulerLane {
            SchedulerLane(job: job)
        }
    }

    private struct LaneState {
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
    private var laneStates: [SchedulerLane: LaneState] = Dictionary(
        uniqueKeysWithValues: SchedulerLane.allCases.map { ($0, LaneState()) }
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
        var laneState = laneState(for: job.lane)

        if job.job == .meetingLiveChunk,
           pendingMeetingLiveJobCount(in: laneState) >= meetingLiveChunkBacklogLimit,
           let droppedJob = dropOldestPendingMeetingLiveJob(in: &laneState) {
            logger.notice(
                "stt_backpressure drop_pending_meeting_live_chunk id=\(droppedJob.id.uuidString, privacy: .public)"
            )
            continuations.removeValue(forKey: droppedJob.id)?.resume(
                throwing: STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
            )
        }

        laneState.pendingJobs.append(job)
        setLaneState(laneState, for: job.lane)
        startNextJobIfNeeded(in: job.lane)
    }

    private func nextEnqueueOrder() -> UInt64 {
        defer { enqueueCounter += 1 }
        return enqueueCounter
    }

    private func laneState(for lane: SchedulerLane) -> LaneState {
        laneStates[lane, default: LaneState()]
    }

    private func setLaneState(_ laneState: LaneState, for lane: SchedulerLane) {
        laneStates[lane] = laneState
    }

    private func pendingMeetingLiveJobCount(in laneState: LaneState) -> Int {
        laneState.pendingJobs.reduce(into: 0) { count, job in
            if job.job == .meetingLiveChunk {
                count += 1
            }
        }
    }

    private func dropOldestPendingMeetingLiveJob(in laneState: inout LaneState) -> ScheduledJob? {
        guard let index = laneState.pendingJobs.enumerated()
            .filter({ $0.element.job == .meetingLiveChunk })
            .min(by: { $0.element.enqueueOrder < $1.element.enqueueOrder })?
            .offset else {
            return nil
        }
        return laneState.pendingJobs.remove(at: index)
    }

    private func startNextJobIfNeeded(in lane: SchedulerLane) {
        var laneState = laneState(for: lane)
        guard laneState.currentJob == nil else { return }
        guard let next = dequeueNextJob(in: &laneState) else {
            setLaneState(laneState, for: lane)
            return
        }

        laneState.currentJob = next
        laneState.currentExecutionTask = Task {
            try await runtime.transcribe(audioPath: next.audioPath, job: next.job, onProgress: next.onProgress)
        }
        laneState.currentWaitTask = Task { [weak self] in
            await self?.awaitCurrentJobCompletion(jobID: next.id, in: lane)
        }
        setLaneState(laneState, for: lane)
    }

    private func dequeueNextJob(in laneState: inout LaneState) -> ScheduledJob? {
        guard let index = laneState.pendingJobs.indices.min(by: { lhs, rhs in
            let left = laneState.pendingJobs[lhs]
            let right = laneState.pendingJobs[rhs]
            if left.job.priorityRank != right.job.priorityRank {
                return left.job.priorityRank < right.job.priorityRank
            }
            return left.enqueueOrder < right.enqueueOrder
        }) else {
            return nil
        }
        return laneState.pendingJobs.remove(at: index)
    }

    private func awaitCurrentJobCompletion(jobID: UUID, in lane: SchedulerLane) async {
        let laneState = laneState(for: lane)
        guard laneState.currentJob?.id == jobID, let executionTask = laneState.currentExecutionTask else { return }

        let result: Result<STTResult, Error>
        do {
            result = .success(try await executionTask.value)
        } catch {
            result = .failure(error)
        }

        finishCurrentJob(jobID: jobID, in: lane, result: result)
    }

    private func finishCurrentJob(jobID: UUID, in lane: SchedulerLane, result: Result<STTResult, Error>) {
        var laneState = laneState(for: lane)
        guard laneState.currentJob?.id == jobID else { return }

        let continuation = continuations.removeValue(forKey: jobID)
        cancelledJobIDs.remove(jobID)
        laneState.currentJob = nil
        laneState.currentExecutionTask = nil
        laneState.currentWaitTask = nil
        setLaneState(laneState, for: lane)

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }

        startNextJobIfNeeded(in: lane)
    }

    private func cancel(jobID: UUID) {
        for lane in SchedulerLane.allCases {
            var laneState = laneState(for: lane)
            if let index = laneState.pendingJobs.firstIndex(where: { $0.id == jobID }) {
                laneState.pendingJobs.remove(at: index)
                setLaneState(laneState, for: lane)
                cancelledJobIDs.remove(jobID)
                continuations.removeValue(forKey: jobID)?.resume(throwing: CancellationError())
                return
            }

            if laneState.currentJob?.id == jobID {
                laneState.currentExecutionTask?.cancel()
                cancelledJobIDs.remove(jobID)
                setLaneState(laneState, for: lane)
                return
            }
        }

        cancelledJobIDs.insert(jobID)
    }

    private func cancelAllPendingJobs() {
        let pendingIDs = SchedulerLane.allCases.flatMap { laneState(for: $0).pendingJobs.map(\.id) }
        for lane in SchedulerLane.allCases {
            var laneState = laneState(for: lane)
            laneState.pendingJobs.removeAll()
            setLaneState(laneState, for: lane)
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
        let waitTasks = SchedulerLane.allCases.compactMap { lane -> Task<Void, Never>? in
            let laneState = laneState(for: lane)
            laneState.currentExecutionTask?.cancel()
            return laneState.currentWaitTask
        }
        for task in waitTasks {
            await task.value
        }
    }
}

private enum SchedulerLane: CaseIterable, Sendable {
    case dictation
    case meeting
    case batch

    init(job: STTJobKind) {
        switch job {
        case .dictation:
            self = .dictation
        case .meetingFinalize, .meetingLiveChunk:
            self = .meeting
        case .fileTranscription:
            self = .batch
        }
    }
}

private extension STTJobKind {
    var priorityRank: Int {
        switch self {
        case .dictation:
            0
        case .meetingFinalize:
            0
        case .meetingLiveChunk:
            1
        case .fileTranscription:
            0
        }
    }
}
