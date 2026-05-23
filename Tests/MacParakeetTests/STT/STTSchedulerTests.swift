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

    func testSetSpeechEngineForwardsWhenIdle() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        try await scheduler.setSpeechEngine(.whisper)

        let count = await runtime.setSpeechEngineCallCount
        XCTAssertEqual(count, 1)
    }

    func testSetSpeechEngineForwardsProgressWhenIdle() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)
        let progressMessages = LockedStringRecorder()

        try await scheduler.setSpeechEngine(.whisper) { message in
            progressMessages.record(message)
        }

        let usedProgressOverload = await runtime.usedSpeechEngineProgressOverload
        XCTAssertTrue(usedProgressOverload)
        XCTAssertEqual(progressMessages.values, ["Mock loading Whisper"])
    }

    func testSetSpeechEngineFailsWhileJobIsRunning() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "active")
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "active", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        do {
            try await scheduler.setSpeechEngine(.whisper)
            XCTFail("Expected engine switch to fail while STT job is running")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await runtime.release(path: "active")
        _ = try await activeTask.value
    }

    func testSetSpeechEngineFailsWhileSessionLeaseIsActive() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let lease = await scheduler.beginSpeechEngineSession()
        do {
            try await scheduler.setSpeechEngine(.whisper)
            XCTFail("Expected engine switch to fail while a speech engine session is active")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await scheduler.endSpeechEngineSession(lease)
        try await scheduler.setSpeechEngine(.whisper)
        let count = await runtime.setSpeechEngineCallCount
        XCTAssertEqual(count, 1)
    }

    func testEngineSwitchAvailabilityReportsAvailableWhenIdle() async {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let availability = await scheduler.engineSwitchAvailability()

        XCTAssertEqual(availability, .available)
    }

    func testEngineSwitchAvailabilityReportsMeetingActiveForSessionLease() async {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let lease = await scheduler.beginSpeechEngineSession()

        let availability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(availability, .meetingActive)

        await scheduler.endSpeechEngineSession(lease)
    }

    func testEngineSwitchAvailabilityReportsTranscribingForActiveJob() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "active")
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "active", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let availability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(availability, .transcribing)

        await runtime.release(path: "active")
        _ = try await activeTask.value
    }

    func testEngineSwitchAvailabilityReportsSwitchInProgress() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitch()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        try await waitForSpeechEngineSwitch(runtime: runtime, count: 1)

        let availability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(availability, .switchInProgress)

        await runtime.releaseSpeechEngineSwitch()
        _ = try await switchTask.value
    }

    func testEngineSwitchAvailabilityReportsUnavailableAfterShutdown() async {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        await scheduler.shutdown()

        let availability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(availability, .unavailable)
    }

    func testSpeechEngineSessionWaitsForInFlightEngineSwitch() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitch()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        try await waitForSpeechEngineSwitch(runtime: runtime, count: 1)

        let leaseTask = Task {
            await scheduler.beginSpeechEngineSession()
        }
        try await Task.sleep(for: .milliseconds(50))
        await runtime.releaseSpeechEngineSwitch()

        let lease = await leaseTask.value
        XCTAssertEqual(lease.selection, SpeechEngineSelection(engine: .whisper))

        await scheduler.endSpeechEngineSession(lease)
        _ = try await switchTask.value
    }

    func testCancelledSpeechEngineSwitchRestoresSchedulerAvailability() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitch()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        try await waitForSpeechEngineSwitch(runtime: runtime, count: 1)

        switchTask.cancel()
        do {
            try await value(switchTask)
            XCTFail("Expected cancelled engine switch to throw")
        } catch is CancellationError {
            // Expected.
        }

        try await scheduler.setSpeechEngine(.parakeet)
        let count = await runtime.setSpeechEngineCallCount
        XCTAssertEqual(count, 2)
    }

    func testSpeechEngineSessionLeaseUsesRuntimeSelection() async {
        let runtime = MockSTTRuntime()
        await runtime.setCurrentSelection(SpeechEngineSelection(engine: .whisper, language: "KO"))
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let lease = await scheduler.beginSpeechEngineSession()

        XCTAssertEqual(lease.selection, SpeechEngineSelection(engine: .whisper, language: "ko"))
    }

    func testRoutedTranscribeForwardsSpeechEngineSelection() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)
        let selection = SpeechEngineSelection(engine: .whisper, language: "KO")

        _ = try await scheduler.transcribe(
            audioPath: "meeting-final",
            job: .meetingFinalize,
            speechEngine: selection,
            onProgress: nil
        )

        let routedSelection = await runtime.routedSelection(for: "meeting-final")
        XCTAssertEqual(routedSelection, SpeechEngineSelection(engine: .whisper, language: "ko"))
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
        // Let the first live chunk settle into the pending queue before the next chunk evicts it.
        try await Task.sleep(for: .milliseconds(50))
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
        // Let the first live chunk settle into the pending queue before the next chunk evicts it.
        try await Task.sleep(for: .milliseconds(50))
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

    private func waitForSpeechEngineSwitch(
        runtime: MockSTTRuntime,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = ContinuousClock.now
        while await runtime.setSpeechEngineCallCount < count {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for \(count) speech engine switches")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func value<T>(
        _ task: Task<T, any Error>,
        timeout: Duration = .seconds(1)
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await task.value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw STTSchedulerTestError.timeout
            }
            return try await group.next()!
        }
    }

    // MARK: - Watchdog probe (stt_runtime_unhealthy telemetry)

    func testWatchdogFiresWhenCancelDrainExceedsTimeout() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setIgnoreCancellation(true)
        await runtime.block(path: "wedge")

        let spy = STTRuntimeUnhealthySpy()
        Telemetry.configure(spy)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            meetingLiveChunkBacklogLimit: 8,
            runtimeOperationWatchdogTimeout: .milliseconds(50)
        )

        let wedgedTask = Task {
            try await scheduler.transcribe(audioPath: "wedge", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        // clearModelCache calls quiesce → cancelAndDrainRunningJobs. The runtime
        // ignores cancellation, so the drain blocks past the watchdog timeout
        // and we expect a `cancel_drain` telemetry event.
        let clearTask = Task { await scheduler.clearModelCache() }

        try await waitForUnhealthyEvent(
            spy: spy,
            reason: "cancel_drain",
            timeout: .seconds(2)
        )

        // Cleanup: unwedge the runtime so the in-flight call completes and the
        // scheduler-level Task can return.
        await runtime.forceReleaseAll()
        await runtime.setIgnoreCancellation(false)
        _ = try? await wedgedTask.value
        _ = await clearTask.value
    }

    func testWatchdogStaysSilentOnHappyPath() async throws {
        let runtime = MockSTTRuntime()

        let spy = STTRuntimeUnhealthySpy()
        Telemetry.configure(spy)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            meetingLiveChunkBacklogLimit: 8,
            runtimeOperationWatchdogTimeout: .seconds(5)
        )

        // Normal lifecycle: idle scheduler, no in-flight jobs. clearModelCache
        // and shutdown should both return well under the timeout, so the
        // watchdog must not fire.
        await scheduler.clearModelCache()
        await scheduler.shutdown()

        // Give any latent watchdog Task time to (incorrectly) fire — it
        // shouldn't, but we want a positive assertion of silence.
        try await Task.sleep(for: .milliseconds(100))

        let unhealthyEvents = spy.unhealthyEvents()
        XCTAssertTrue(
            unhealthyEvents.isEmpty,
            "Watchdog fired spuriously on happy path: \(unhealthyEvents)"
        )
    }

    private func waitForUnhealthyEvent(
        spy: STTRuntimeUnhealthySpy,
        reason: String,
        timeout: Duration
    ) async throws {
        let start = ContinuousClock.now
        while !spy.unhealthyEvents().contains(where: { $0 == reason }) {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for stt_runtime_unhealthy reason=\(reason); saw=\(spy.unhealthyEvents())")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class STTRuntimeUnhealthySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []

    func send(_ event: TelemetryEventSpec) {
        if case .sttRuntimeUnhealthy(let reason) = event {
            lock.lock()
            reasons.append(reason)
            lock.unlock()
        }
    }

    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return true
    }

    func flush() async {}
    func clearQueue() {
        lock.lock()
        reasons.removeAll()
        lock.unlock()
    }
    func flushForTermination() {}

    func unhealthyEvents() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return reasons
    }
}

private enum STTSchedulerTestError: Error {
    case timeout
}

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

private actor MockSTTRuntime: STTRuntimeProtocol {
    private var blockedPaths: Set<String> = []
    private var waitingContinuations: [String: CheckedContinuation<Void, any Error>] = [:]
    private var progressScripts: [String: [Int]] = [:]
    private var started: [String] = []
    private var routedSelections: [String: SpeechEngineSelection] = [:]

    private(set) var warmUpCallCount = 0
    private(set) var isReadyCallCount = 0
    private(set) var clearModelCacheCallCount = 0
    private(set) var shutdownCallCount = 0
    private(set) var setSpeechEngineCallCount = 0
    private(set) var usedSpeechEngineProgressOverload = false
    private var selection = SpeechEngineSelection(engine: .parakeet)
    private var ready = false
    private var shouldBlockNextSpeechEngineSwitch = false
    private var ignoreCancellation = false
    private var speechEngineSwitchContinuation: CheckedContinuation<Void, Never>?

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

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        routedSelections[audioPath] = speechEngine
        return try await transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
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

    func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        setSpeechEngineCallCount += 1
        if shouldBlockNextSpeechEngineSwitch {
            shouldBlockNextSpeechEngineSwitch = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    speechEngineSwitchContinuation = continuation
                }
            } onCancel: {
                Task {
                    await self.releaseSpeechEngineSwitch()
                }
            }
            try Task.checkCancellation()
        }
        selection = SpeechEngineSelection(engine: preference)
        ready = false
    }

    func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        usedSpeechEngineProgressOverload = true
        onProgress?("Mock loading \(preference.displayName)")
        try await setSpeechEngine(preference)
    }

    func currentSpeechEngineSelection() async -> SpeechEngineSelection {
        selection
    }

    func setCurrentSelection(_ selection: SpeechEngineSelection) {
        self.selection = selection
    }

    func blockNextSpeechEngineSwitch() {
        shouldBlockNextSpeechEngineSwitch = true
    }

    func releaseSpeechEngineSwitch() {
        speechEngineSwitchContinuation?.resume()
        speechEngineSwitchContinuation = nil
    }

    func block(path: String) {
        blockedPaths.insert(path)
    }

    func release(path: String) {
        blockedPaths.remove(path)
        waitingContinuations.removeValue(forKey: path)?.resume(returning: ())
    }

    /// When true, `cancelBlocked` becomes a no-op so a cancelled blocked
    /// transcribe stays wedged. Lets us simulate a runtime that ignores
    /// `Task.cancel()` for watchdog tests.
    func setIgnoreCancellation(_ value: Bool) {
        ignoreCancellation = value
    }

    /// Force-resume any held continuations regardless of `ignoreCancellation`.
    /// Used by tests to clean up after a deliberately-wedged path.
    func forceReleaseAll() {
        for (path, continuation) in waitingContinuations {
            blockedPaths.remove(path)
            continuation.resume(throwing: CancellationError())
        }
        waitingContinuations.removeAll()
    }

    private func cancelBlocked(path: String) {
        guard !ignoreCancellation else { return }
        waitingContinuations.removeValue(forKey: path)?.resume(throwing: CancellationError())
    }

    func setProgressScript(_ values: [Int], for path: String) {
        progressScripts[path] = values
    }

    func startedPaths() -> [String] {
        started
    }

    func routedSelection(for path: String) -> SpeechEngineSelection? {
        routedSelections[path]
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
