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
public actor STTScheduler: STTManaging {
    private struct ScheduledJob: Sendable {
        let id: UUID
        let audioPath: String
        let job: STTJobKind
        let enqueueOrder: UInt64
        let onProgress: (@Sendable (Int, Int) -> Void)?
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTScheduler")
    private let runtime: STTRuntimeProtocol
    private let meetingLiveChunkBacklogLimit: Int

    private var enqueueCounter: UInt64 = 0
    private var pendingJobs: [ScheduledJob] = []
    private var continuations: [UUID: CheckedContinuation<STTResult, Error>] = [:]
    private var currentJob: ScheduledJob?
    private var currentExecutionTask: Task<STTResult, Error>?
    private var currentWaitTask: Task<Void, Never>?
    private var acceptsNewJobs = true

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
        acceptsNewJobs = false
        cancelAllPendingJobs()
        if let currentWaitTask {
            currentExecutionTask?.cancel()
            await currentWaitTask.value
        }
        await runtime.clearModelCache()
        acceptsNewJobs = true
    }

    public func shutdown() async {
        acceptsNewJobs = false
        cancelAllPendingJobs()
        if let currentWaitTask {
            currentExecutionTask?.cancel()
            await currentWaitTask.value
        }
        await runtime.shutdown()
        acceptsNewJobs = true
    }

    private func enqueue(
        _ job: ScheduledJob,
        continuation: CheckedContinuation<STTResult, Error>
    ) {
        guard acceptsNewJobs else {
            continuation.resume(throwing: STTSchedulerError.unavailable)
            return
        }

        continuations[job.id] = continuation

        if job.job == .meetingLiveChunk,
           pendingMeetingLiveJobCount >= meetingLiveChunkBacklogLimit,
           let droppedJob = dropOldestPendingMeetingLiveJob() {
            logger.notice(
                "stt_backpressure drop_pending_meeting_live_chunk id=\(droppedJob.id.uuidString, privacy: .public)"
            )
            continuations.removeValue(forKey: droppedJob.id)?.resume(
                throwing: STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
            )
        }

        pendingJobs.append(job)
        startNextJobIfNeeded()
    }

    private func nextEnqueueOrder() -> UInt64 {
        defer { enqueueCounter += 1 }
        return enqueueCounter
    }

    private var pendingMeetingLiveJobCount: Int {
        pendingJobs.reduce(into: 0) { count, job in
            if job.job == .meetingLiveChunk {
                count += 1
            }
        }
    }

    private func dropOldestPendingMeetingLiveJob() -> ScheduledJob? {
        guard let index = pendingJobs.enumerated()
            .filter({ $0.element.job == .meetingLiveChunk })
            .min(by: { $0.element.enqueueOrder < $1.element.enqueueOrder })?
            .offset else {
            return nil
        }
        return pendingJobs.remove(at: index)
    }

    private func startNextJobIfNeeded() {
        guard currentJob == nil else { return }
        guard let next = dequeueNextJob() else { return }

        currentJob = next
        currentExecutionTask = Task {
            try await runtime.transcribe(audioPath: next.audioPath, onProgress: next.onProgress)
        }
        currentWaitTask = Task { [weak self] in
            await self?.awaitCurrentJobCompletion(jobID: next.id)
        }
    }

    private func dequeueNextJob() -> ScheduledJob? {
        guard let index = pendingJobs.indices.min(by: { lhs, rhs in
            let left = pendingJobs[lhs]
            let right = pendingJobs[rhs]
            if left.job.priorityRank != right.job.priorityRank {
                return left.job.priorityRank < right.job.priorityRank
            }
            return left.enqueueOrder < right.enqueueOrder
        }) else {
            return nil
        }
        return pendingJobs.remove(at: index)
    }

    private func awaitCurrentJobCompletion(jobID: UUID) async {
        guard currentJob?.id == jobID, let executionTask = currentExecutionTask else { return }

        let result: Result<STTResult, Error>
        do {
            result = .success(try await executionTask.value)
        } catch {
            result = .failure(error)
        }

        finishCurrentJob(jobID: jobID, result: result)
    }

    private func finishCurrentJob(jobID: UUID, result: Result<STTResult, Error>) {
        guard currentJob?.id == jobID else { return }

        let continuation = continuations.removeValue(forKey: jobID)
        currentJob = nil
        currentExecutionTask = nil
        currentWaitTask = nil

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }

        startNextJobIfNeeded()
    }

    private func cancel(jobID: UUID) {
        if let index = pendingJobs.firstIndex(where: { $0.id == jobID }) {
            pendingJobs.remove(at: index)
            continuations.removeValue(forKey: jobID)?.resume(throwing: CancellationError())
            return
        }

        if currentJob?.id == jobID {
            currentExecutionTask?.cancel()
        }
    }

    private func cancelAllPendingJobs() {
        let pendingIDs = pendingJobs.map(\.id)
        pendingJobs.removeAll()
        for id in pendingIDs {
            continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }
}

private extension STTJobKind {
    var priorityRank: Int {
        switch self {
        case .dictation:
            0
        case .meetingFinalize:
            1
        case .meetingLiveChunk:
            2
        case .fileTranscription:
            3
        }
    }
}
