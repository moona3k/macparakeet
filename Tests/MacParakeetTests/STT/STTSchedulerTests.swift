import XCTest
@testable import MacParakeetCore

final class STTSchedulerTests: XCTestCase {
    func testDictationBeatsQueuedMeetingLiveChunk() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "seed")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let seedTask = Task { try await scheduler.transcribe(audioPath: "seed", job: .fileTranscription) }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let liveTask = Task { try await scheduler.transcribe(audioPath: "live", job: .meetingLiveChunk) }
        let dictationTask = Task { try await scheduler.transcribe(audioPath: "dictation", job: .dictation) }

        try await Task.sleep(for: .milliseconds(100))
        let startedWhileSeedBlocked = await runtime.startedPaths()
        XCTAssertEqual(startedWhileSeedBlocked, ["seed"])

        await runtime.release(path: "seed")

        _ = try await seedTask.value
        _ = try await dictationTask.value
        _ = try await liveTask.value

        let finalStartedPaths = await runtime.startedPaths()
        XCTAssertEqual(finalStartedPaths, ["seed", "dictation", "live"])
    }

    func testMeetingFinalizeBeatsQueuedFileTranscription() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "seed")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let seedTask = Task { try await scheduler.transcribe(audioPath: "seed", job: .dictation) }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let fileTask = Task { try await scheduler.transcribe(audioPath: "file", job: .fileTranscription) }
        let finalizeTask = Task { try await scheduler.transcribe(audioPath: "meeting-finalize", job: .meetingFinalize) }

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

    func testProgressIsScopedPerJob() async throws {
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

        try await Task.sleep(for: .milliseconds(100))
        let fileValuesWhileBlocked = fileProgress.currentValues()
        let dictationValuesWhileBlocked = dictationProgress.currentValues()
        XCTAssertEqual(fileValuesWhileBlocked, [10, 50])
        XCTAssertEqual(dictationValuesWhileBlocked, [])

        await runtime.release(path: "file")

        _ = try await fileTask.value
        _ = try await dictationTask.value

        let finalFileValues = fileProgress.currentValues()
        let finalDictationValues = dictationProgress.currentValues()
        XCTAssertEqual(finalFileValues, [10, 50])
        XCTAssertEqual(finalDictationValues, [20, 80])
    }

    func testMeetingLiveChunkBackpressureDropsOldestPendingLiveChunk() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "seed")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 1)

        let seedTask = Task { try await scheduler.transcribe(audioPath: "seed", job: .fileTranscription) }
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
    private var waitingContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var progressScripts: [String: [Int]] = [:]
    private var started: [String] = []

    private(set) var warmUpCallCount = 0
    private(set) var isReadyCallCount = 0
    private(set) var clearModelCacheCallCount = 0
    private(set) var shutdownCallCount = 0
    private var ready = false

    func transcribe(
        audioPath: String,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        started.append(audioPath)

        if let script = progressScripts[audioPath] {
            for progress in script {
                onProgress?(progress, 100)
            }
        }

        if blockedPaths.contains(audioPath) {
            await withCheckedContinuation { continuation in
                waitingContinuations[audioPath] = continuation
            }
        }

        return STTResult(text: audioPath, words: [])
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
        waitingContinuations.removeValue(forKey: path)?.resume()
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
