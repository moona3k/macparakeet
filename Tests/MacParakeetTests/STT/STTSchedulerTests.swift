import XCTest
@testable import MacParakeetCore

final class STTSchedulerTests: XCTestCase {
    func testDictationRunsWhileBackgroundSlotIsBusy() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "meeting-live")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let meetingTask = Task {
            try await scheduler.transcribe(audioPath: "meeting-live", job: .meetingLiveChunk)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let dictationTask = Task {
            try await scheduler.transcribe(audioPath: "dictation", job: .dictation)
        }
        try await waitForStartedPaths(runtime: runtime, count: 2)

        let startedWhileMeetingBlocked = await runtime.startedPaths()
        XCTAssertEqual(startedWhileMeetingBlocked, ["meeting-live", "dictation"])

        _ = try await dictationTask.value
        await runtime.release(path: "meeting-live")
        _ = try await meetingTask.value
    }

    func testMeetingFinalizeWaitsBehindRunningFileTranscriptionOnSharedBackgroundSlot() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "file")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let fileTask = Task {
            try await scheduler.transcribe(audioPath: "file", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let finalizeTask = Task {
            try await scheduler.transcribe(audioPath: "meeting-finalize", job: .meetingFinalize)
        }
        try await Task.sleep(for: .milliseconds(100))

        let startedWhileFileBlocked = await runtime.startedPaths()
        XCTAssertEqual(startedWhileFileBlocked, ["file"])

        await runtime.release(path: "file")
        _ = try await fileTask.value
        _ = try await finalizeTask.value

        let finalStartedPaths = await runtime.startedPaths()
        XCTAssertEqual(finalStartedPaths, ["file", "meeting-finalize"])
    }

    func testMeetingFinalizeBeatsQueuedMeetingLiveChunkWithinBackgroundSlot() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "seed")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let seedTask = Task { try await scheduler.transcribe(audioPath: "seed", job: .meetingLiveChunk) }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let liveTask = Task { try await scheduler.transcribe(audioPath: "live", job: .meetingLiveChunk) }
        let finalizeTask = Task {
            try await scheduler.transcribe(audioPath: "meeting-finalize", job: .meetingFinalize)
        }

        try await Task.sleep(for: .milliseconds(100))
        let startedWhileSeedBlocked = await runtime.startedPaths()
        XCTAssertEqual(startedWhileSeedBlocked, ["seed"])

        await runtime.release(path: "seed")

        _ = try await seedTask.value
        _ = try await finalizeTask.value
        _ = try await liveTask.value

        let finalStartedPaths = await runtime.startedPaths()
        XCTAssertEqual(finalStartedPaths, ["seed", "meeting-finalize", "live"])
    }

    func testMeetingFinalizeBeatsQueuedFileTranscriptionWithinBackgroundSlot() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "seed")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let seedTask = Task { try await scheduler.transcribe(audioPath: "seed", job: .meetingLiveChunk) }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let fileTask = Task { try await scheduler.transcribe(audioPath: "file", job: .fileTranscription) }
        let finalizeTask = Task {
            try await scheduler.transcribe(audioPath: "meeting-finalize", job: .meetingFinalize)
        }

        try await Task.sleep(for: .milliseconds(100))
        let startedWhileSeedBlocked = await runtime.startedPaths()
        XCTAssertEqual(startedWhileSeedBlocked, ["seed"])

        await runtime.release(path: "seed")

        _ = try await seedTask.value
        _ = try await finalizeTask.value
        _ = try await fileTask.value

        let finalStartedPaths = await runtime.startedPaths()
        XCTAssertEqual(finalStartedPaths, ["seed", "meeting-finalize", "file"])
    }

    func testLifecycleOperationsTargetSharedRuntime() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        try await scheduler.warmUp()
        _ = await scheduler.isReady()
        await scheduler.clearModelCache()
        await scheduler.shutdown()

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.warmUp, 1)
        XCTAssertEqual(counts.isReady, 1)
        XCTAssertEqual(counts.clearModelCache, 1)
        XCTAssertEqual(counts.shutdown, 1)
    }

    func testProgressIsScopedPerJobAcrossSlots() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setProgressScript([10, 50], for: "file")
        await runtime.setProgressScript([20, 80], for: "dictation")
        await runtime.block(path: "file")

        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)
        let fileProgress = ProgressSink()
        let dictationProgress = ProgressSink()

        let fileTask = Task {
            try await scheduler.transcribe(audioPath: "file", job: .fileTranscription) { current, _ in
                fileProgress.record(current)
            }
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let dictationTask = Task {
            try await scheduler.transcribe(audioPath: "dictation", job: .dictation) { current, _ in
                dictationProgress.record(current)
            }
        }
        try await waitForStartedPaths(runtime: runtime, count: 2)

        _ = try await dictationTask.value

        let fileValuesWhileBlocked = fileProgress.currentValues()
        let dictationValuesWhileBlocked = dictationProgress.currentValues()
        XCTAssertEqual(fileValuesWhileBlocked, [10, 50])
        XCTAssertEqual(dictationValuesWhileBlocked, [20, 80])

        await runtime.release(path: "file")
        _ = try await fileTask.value
    }

    func testMeetingLiveChunkBackpressureDropsOldestPendingLiveChunk() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "seed")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 1)

        let seedTask = Task { try await scheduler.transcribe(audioPath: "seed", job: .meetingLiveChunk) }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let droppedTask = Task { try await scheduler.transcribe(audioPath: "live-1", job: .meetingLiveChunk) }
        let survivingTask = Task { try await scheduler.transcribe(audioPath: "live-2", job: .meetingLiveChunk) }

        do {
            _ = try await droppedTask.value
            XCTFail("Expected dropped live chunk to fail")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .droppedDueToBackpressure(job: .meetingLiveChunk))
        }

        await runtime.release(path: "seed")

        _ = try await seedTask.value
        _ = try await survivingTask.value

        let finalStartedPaths = await runtime.startedPaths()
        XCTAssertEqual(finalStartedPaths, ["seed", "live-2"])
    }

    func testMeetingLiveChunkBacklogLimitClampsToAtLeastOne() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "seed")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 0)

        let seedTask = Task { try await scheduler.transcribe(audioPath: "seed", job: .meetingLiveChunk) }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let droppedTask = Task { try await scheduler.transcribe(audioPath: "live-1", job: .meetingLiveChunk) }
        let survivingTask = Task { try await scheduler.transcribe(audioPath: "live-2", job: .meetingLiveChunk) }

        do {
            _ = try await droppedTask.value
            XCTFail("Expected dropped live chunk to fail")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .droppedDueToBackpressure(job: .meetingLiveChunk))
        }

        await runtime.release(path: "seed")

        _ = try await seedTask.value
        _ = try await survivingTask.value

        let finalStartedPaths = await runtime.startedPaths()
        XCTAssertEqual(finalStartedPaths, ["seed", "live-2"])
    }

    func testAlreadyCancelledTaskNeverEnqueuesScheduledJob() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scheduler.transcribe(audioPath: "cancelled-before-enqueue", job: .fileTranscription)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let startedPaths = await runtime.startedPaths()
        XCTAssertTrue(startedPaths.isEmpty)
    }

    func testShutdownKeepsSchedulerClosedToNewJobs() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        await scheduler.shutdown()

        do {
            _ = try await scheduler.transcribe(audioPath: "after-shutdown", job: .dictation)
            XCTFail("Expected scheduler to reject new work after shutdown")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        }

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.shutdown, 1)
        let startedPaths = await runtime.startedPaths()
        XCTAssertTrue(startedPaths.isEmpty)
    }

    func testShutdownCancelsActiveAndPendingJobs() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "active")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        // Start an active job in the shared background slot.
        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "active", job: .meetingLiveChunk)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        // Queue a pending job behind it in the same slot.
        let pendingTask = Task {
            try await scheduler.transcribe(audioPath: "pending", job: .meetingLiveChunk)
        }
        // Let the enqueue settle.
        try await Task.sleep(for: .milliseconds(50))

        // Shutdown should cancel both.
        await scheduler.shutdown()

        do {
            _ = try await activeTask.value
            XCTFail("Expected active job to be cancelled by shutdown")
        } catch is CancellationError {
            // Expected.
        }

        do {
            _ = try await pendingTask.value
            XCTFail("Expected pending job to be cancelled by shutdown")
        } catch is CancellationError {
            // Expected.
        }

        // Runtime shutdown was called.
        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.shutdown, 1)
    }

    func testPendingJobCancelledBeforeExecution() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "blocker")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        // Block the shared background slot with a long-running file job.
        let blockerTask = Task {
            try await scheduler.transcribe(audioPath: "blocker", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        // Queue a second job in the same slot — it will be pending.
        let pendingTask = Task {
            try await scheduler.transcribe(audioPath: "queued", job: .fileTranscription)
        }
        // Let the enqueue settle.
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the pending task from the caller side.
        pendingTask.cancel()

        do {
            _ = try await pendingTask.value
            XCTFail("Expected pending job to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        // The cancelled job should never have reached the runtime.
        let startedPaths = await runtime.startedPaths()
        XCTAssertEqual(startedPaths, ["blocker"])

        // Unblock and verify the original job still completes.
        await runtime.release(path: "blocker")
        _ = try await blockerTask.value
    }

    private func waitForStartedPaths(
        runtime: MockSTTRuntime,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = ContinuousClock.now
        while await runtime.startedPaths().count < count {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for \(count) started paths")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private actor MockSTTRuntime: STTRuntimeProtocol {
    private var blockedPaths: Set<String> = []
    private var waitingContinuations: [String: CheckedContinuation<Void, any Error>] = [:]
    private var progressScripts: [String: [Int]] = [:]
    private var started: [String] = []

    private(set) var warmUpCallCount = 0
    private(set) var isReadyCallCount = 0
    private(set) var clearModelCacheCallCount = 0
    private(set) var shutdownCallCount = 0
    private var ready = false

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        started.append(audioPath)

        if let script = progressScripts[audioPath] {
            for progress in script {
                onProgress?(progress, 100)
            }
        }

        if blockedPaths.contains(audioPath) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waitingContinuations[audioPath] = continuation
                }
            } onCancel: {
                Task { await self.cancelBlocked(path: audioPath) }
            }
        }

        try Task.checkCancellation()
        return STTResult(text: "\(job):\(audioPath)", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpCallCount += 1
        ready = true
        onProgress?("Ready")
    }

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(ready ? .ready : .idle)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool {
        isReadyCallCount += 1
        return ready
    }

    func shutdown() async {
        shutdownCallCount += 1
    }

    func clearModelCache() async {
        clearModelCacheCallCount += 1
        ready = false
    }

    func block(path: String) {
        blockedPaths.insert(path)
    }

    func release(path: String) {
        blockedPaths.remove(path)
        waitingContinuations.removeValue(forKey: path)?.resume(returning: ())
    }

    private func cancelBlocked(path: String) {
        waitingContinuations.removeValue(forKey: path)?.resume(throwing: CancellationError())
    }

    func setProgressScript(_ values: [Int], for path: String) {
        progressScripts[path] = values
    }

    func startedPaths() -> [String] {
        started
    }

    func lifecycleCounts() -> (warmUp: Int, isReady: Int, clearModelCache: Int, shutdown: Int) {
        (warmUpCallCount, isReadyCallCount, clearModelCacheCallCount, shutdownCallCount)
    }
}

private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func currentValues() -> [Int] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}
