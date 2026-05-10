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

        let lease = try await scheduler.beginSpeechEngineSession()
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

    func testClearModelCacheSkipsWhileSessionLeaseIsActive() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let lease = try await scheduler.beginSpeechEngineSession()

        await scheduler.clearModelCache()
        var counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 0)

        await scheduler.endSpeechEngineSession(lease)
        await scheduler.clearModelCache()

        counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 1)
    }

    func testClearModelCacheSkipsWhileSpeechEngineSessionIsStarting() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextCurrentSpeechEngineSelection()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let leaseTask = Task {
            try await scheduler.beginSpeechEngineSession()
        }
        try await waitForCurrentSpeechEngineSelection(runtime: runtime, count: 1)

        await scheduler.clearModelCache()
        var counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 0)

        await runtime.releaseCurrentSpeechEngineSelection()
        let lease = try await leaseTask.value
        await scheduler.endSpeechEngineSession(lease)

        await scheduler.clearModelCache()
        counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 1)
    }

    func testSpeechEngineSessionFailsWhileInFlightEngineSwitchIsActive() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitch()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        try await waitForSpeechEngineSwitch(runtime: runtime, count: 1)

        do {
            _ = try await scheduler.beginSpeechEngineSession()
            XCTFail("Expected speech engine session to fail while an engine switch is active")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await runtime.releaseSpeechEngineSwitch()
        _ = try await switchTask.value
    }

    func testSpeechEngineSessionFailsWhileCancelledRuntimeJobDrains() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockIgnoringCancellation(path: "slow-cancel")
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .seconds(1)
        )

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "slow-cancel", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        activeTask.cancel()
        do {
            _ = try await scheduler.beginSpeechEngineSession()
            XCTFail("Expected speech engine session to fail while a cancelled runtime task is draining")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        }

        await runtime.release(path: "slow-cancel")
        do {
            _ = try await value(activeTask)
            XCTFail("Expected active job cancellation to throw")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancelledSpeechEngineSessionStartReleasesReservation() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextCurrentSpeechEngineSelection()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .seconds(1)
        )

        let leaseTask = Task {
            try await scheduler.beginSpeechEngineSession()
        }
        try await waitForCurrentSpeechEngineSelection(runtime: runtime, count: 1)

        leaseTask.cancel()
        do {
            _ = try await value(leaseTask)
            XCTFail("Expected speech engine session start cancellation to throw")
        } catch is CancellationError {
            // Expected.
        }

        await scheduler.clearModelCache()
        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 1)

        await runtime.releaseCurrentSpeechEngineSelection()
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

    func testCancelledSpeechEngineSwitchReturnsWhenRuntimeIgnoresCancellation() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitchIgnoringCancellation()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

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

        do {
            _ = try await scheduler.transcribe(audioPath: "after-wedged-cancelled-switch", job: .dictation)
            XCTFail("Expected scheduler to reject jobs after wedged engine switch cancellation")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.releaseSpeechEngineSwitch()
    }

    func testShutdownCancelsInFlightSpeechEngineSwitchBeforeRuntimeShutdown() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitch()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        try await waitForSpeechEngineSwitch(runtime: runtime, count: 1)

        await scheduler.shutdown()

        do {
            try await value(switchTask)
            XCTFail("Expected shutdown to cancel in-flight engine switch")
        } catch is CancellationError {
            // Expected.
        }

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.shutdown, 1)

        do {
            _ = try await scheduler.transcribe(audioPath: "after-shutdown", job: .dictation)
            XCTFail("Expected shutdown to keep scheduler closed after an in-flight engine switch")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testShutdownReturnsWhenInFlightSpeechEngineSwitchIgnoresCancellation() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitchIgnoringCancellation()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        try await waitForSpeechEngineSwitch(runtime: runtime, count: 1)

        let shutdownFinished = expectation(description: "shutdown returns")
        let shutdownTask = Task {
            await scheduler.shutdown()
            shutdownFinished.fulfill()
        }

        await fulfillment(of: [shutdownFinished], timeout: 1.0)

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.shutdown, 0)

        do {
            _ = try await scheduler.transcribe(audioPath: "after-wedged-switch", job: .dictation)
            XCTFail("Expected scheduler to reject new jobs after wedged engine switch")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.releaseSpeechEngineSwitch()
        do {
            try await value(switchTask)
            XCTFail("Expected wedged engine switch to throw after shutdown marks runtime unhealthy")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        } catch is CancellationError {
            // Expected.
        }
        await shutdownTask.value
    }

    func testSpeechEngineSessionLeaseUsesRuntimeSelection() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setCurrentSelection(SpeechEngineSelection(engine: .whisper, language: "KO"))
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let lease = try await scheduler.beginSpeechEngineSession()

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

    func testActiveJobCancellationReturnsWhenRuntimeIgnoresCancellation() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockIgnoringCancellation(path: "stuck")
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "stuck", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let cancelled = expectation(description: "cancelled active job returns")
        let recorder = AsyncResultRecorder<STTResult>()
        let observerTask = Task {
            do {
                let value = try await activeTask.value
                await recorder.record(.success(value))
            } catch {
                await recorder.record(.failure(error))
            }
            cancelled.fulfill()
        }

        activeTask.cancel()
        await fulfillment(of: [cancelled], timeout: 1.0)

        switch await recorder.result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        case .success:
            XCTFail("Expected cancelled active job to throw CancellationError")
        case nil:
            XCTFail("Expected cancelled active job result")
        }

        do {
            _ = try await scheduler.transcribe(audioPath: "after-wedge", job: .dictation)
            XCTFail("Expected scheduler to reject new jobs after runtime watchdog timeout")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.release(path: "stuck")
        observerTask.cancel()
    }

    func testActiveJobCancellationWinsWhenRuntimeReturnsSuccessBeforeWatchdog() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockIgnoringCancellationAndSucceed(path: "returns")
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .seconds(1)
        )

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "returns", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        activeTask.cancel()
        await runtime.release(path: "returns")

        do {
            _ = try await value(activeTask)
            XCTFail("Expected caller cancellation to win over a late successful runtime result")
        } catch is CancellationError {
            // Expected.
        }

        let result = try await scheduler.transcribe(audioPath: "after-cancel", job: .dictation)
        XCTAssertEqual(result.text, "dictation:after-cancel")
    }

    func testActiveJobCancellationRejectsNewJobsUntilRuntimeReturns() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockIgnoringCancellation(path: "slow-cancel")
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .seconds(1)
        )

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "slow-cancel", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        activeTask.cancel()

        do {
            _ = try await scheduler.transcribe(audioPath: "during-cancel", job: .dictation)
            XCTFail("Expected scheduler to reject new jobs while a cancelled runtime task is draining")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        }

        await runtime.release(path: "slow-cancel")
        do {
            _ = try await value(activeTask)
            XCTFail("Expected active job cancellation to throw")
        } catch is CancellationError {
            // Expected.
        }

        let result = try await scheduler.transcribe(audioPath: "after-cancel-drained", job: .dictation)
        XCTAssertEqual(result.text, "dictation:after-cancel-drained")
    }

    func testRuntimeUnhealthyPreservesCancellationForAllCancelledActiveSlots() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockIgnoringCancellation(path: "background-stuck")
        await runtime.blockIgnoringCancellation(path: "dictation-stuck")
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

        let backgroundTask = Task {
            try await scheduler.transcribe(audioPath: "background-stuck", job: .fileTranscription)
        }
        let dictationTask = Task {
            try await scheduler.transcribe(audioPath: "dictation-stuck", job: .dictation)
        }
        try await waitForStartedPaths(runtime: runtime, count: 2)

        backgroundTask.cancel()
        dictationTask.cancel()

        do {
            _ = try await value(backgroundTask)
            XCTFail("Expected cancelled background job to throw")
        } catch is CancellationError {
            // Expected.
        }

        do {
            _ = try await value(dictationTask)
            XCTFail("Expected cancelled dictation job to throw")
        } catch is CancellationError {
            // Expected.
        }

        do {
            _ = try await scheduler.transcribe(audioPath: "after-two-slot-wedge", job: .dictation)
            XCTFail("Expected scheduler to reject new jobs after runtime watchdog timeout")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.release(path: "background-stuck")
        await runtime.release(path: "dictation-stuck")
    }

    func testClearModelCacheReturnsWhenActiveRuntimeIgnoresCancellation() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockIgnoringCancellation(path: "stuck")
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "stuck", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let clearFinished = expectation(description: "clear model cache returns")
        let clearTask = Task {
            await scheduler.clearModelCache()
            clearFinished.fulfill()
        }

        await fulfillment(of: [clearFinished], timeout: 1.0)

        do {
            _ = try await value(activeTask)
            XCTFail("Expected active job to be cancelled by cache clear")
        } catch is CancellationError {
            // Expected.
        }

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 0)

        do {
            _ = try await scheduler.transcribe(audioPath: "after-wedge", job: .dictation)
            XCTFail("Expected scheduler to reject new jobs after runtime watchdog timeout")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.release(path: "stuck")
        clearTask.cancel()
    }

    func testClearModelCacheRejectsJobsUntilRuntimeCacheClearFinishes() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextClearModelCache()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let clearTask = Task {
            await scheduler.clearModelCache()
        }
        try await waitForClearModelCacheStarted(runtime: runtime)

        do {
            _ = try await scheduler.transcribe(audioPath: "during-clear", job: .dictation)
            XCTFail("Expected scheduler to reject jobs while runtime cache clear is in progress")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        }

        await runtime.releaseClearModelCache()
        await clearTask.value

        let result = try await scheduler.transcribe(audioPath: "after-clear", job: .dictation)
        XCTAssertEqual(result.text, "dictation:after-clear")
    }

    func testClearModelCacheRejectsSpeechEngineSessionUntilRuntimeCacheClearFinishes() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextClearModelCache()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let clearTask = Task {
            await scheduler.clearModelCache()
        }
        try await waitForClearModelCacheStarted(runtime: runtime)

        do {
            _ = try await scheduler.beginSpeechEngineSession()
            XCTFail("Expected scheduler to reject speech engine sessions during cache clear")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        }

        await runtime.releaseClearModelCache()
        await clearTask.value

        let lease = try await scheduler.beginSpeechEngineSession()
        await scheduler.endSpeechEngineSession(lease)
    }

    func testClearModelCacheSkipsWhileInFlightEngineSwitchIsActive() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSpeechEngineSwitch()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        try await waitForSpeechEngineSwitch(runtime: runtime, count: 1)

        await scheduler.clearModelCache()
        var counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 0)

        await runtime.releaseSpeechEngineSwitch()
        _ = try await switchTask.value

        await scheduler.clearModelCache()
        counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 1)

        let result = try await scheduler.transcribe(audioPath: "after-clear-switch", job: .dictation)
        XCTAssertEqual(result.text, "dictation:after-clear-switch")
    }

    func testClearModelCacheReturnsWhenRuntimeCacheClearHangs() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextClearModelCache()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

        let clearFinished = expectation(description: "clear model cache returns")
        let clearTask = Task {
            await scheduler.clearModelCache()
            clearFinished.fulfill()
        }

        await fulfillment(of: [clearFinished], timeout: 1.0)

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.clearModelCache, 1)

        do {
            _ = try await scheduler.transcribe(audioPath: "after-stuck-cache-clear", job: .dictation)
            XCTFail("Expected scheduler to reject jobs after runtime cache clear timeout")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.releaseClearModelCache()
        await clearTask.value
    }

    func testShutdownReturnsWhenActiveRuntimeIgnoresCancellation() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockIgnoringCancellation(path: "stuck")
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "stuck", job: .meetingLiveChunk)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let shutdownFinished = expectation(description: "shutdown returns")
        let shutdownTask = Task {
            await scheduler.shutdown()
            shutdownFinished.fulfill()
        }

        await fulfillment(of: [shutdownFinished], timeout: 1.0)

        do {
            _ = try await value(activeTask)
            XCTFail("Expected active job to be cancelled by shutdown")
        } catch is CancellationError {
            // Expected.
        }

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.shutdown, 0)

        do {
            _ = try await scheduler.transcribe(audioPath: "after-wedge", job: .dictation)
            XCTFail("Expected scheduler to reject new jobs after runtime watchdog timeout")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.release(path: "stuck")
        shutdownTask.cancel()
    }

    func testShutdownReturnsWhenRuntimeShutdownHangs() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextShutdown()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            runningJobCancellationTimeout: .milliseconds(50)
        )

        let shutdownFinished = expectation(description: "shutdown returns")
        let shutdownTask = Task {
            await scheduler.shutdown()
            shutdownFinished.fulfill()
        }

        await fulfillment(of: [shutdownFinished], timeout: 1.0)

        let counts = await runtime.lifecycleCounts()
        XCTAssertEqual(counts.shutdown, 1)

        do {
            _ = try await scheduler.transcribe(audioPath: "after-stuck-shutdown", job: .dictation)
            XCTFail("Expected scheduler to reject jobs after runtime shutdown timeout")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .runtimeUnhealthy)
        }

        await runtime.releaseShutdown()
        await shutdownTask.value
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

    private func waitForCurrentSpeechEngineSelection(
        runtime: MockSTTRuntime,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = ContinuousClock.now
        while await runtime.currentSpeechEngineSelectionCallCount < count {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for \(count) speech engine selection reads")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForClearModelCacheStarted(
        runtime: MockSTTRuntime,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = ContinuousClock.now
        while await runtime.lifecycleCounts().clearModelCache < 1 {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for clearModelCache to start")
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
}

private enum STTSchedulerTestError: Error {
    case timeout
}

private actor AsyncResultRecorder<Value: Sendable> {
    private(set) var result: Result<Value, Error>?

    func record(_ result: Result<Value, Error>) {
        self.result = result
    }
}

private actor MockSTTRuntime: STTRuntimeProtocol {
    private var blockedPaths: Set<String> = []
    private var cancellationIgnoringPaths: Set<String> = []
    private var cancellationIgnoringSuccessPaths: Set<String> = []
    private var waitingContinuations: [String: CheckedContinuation<Void, any Error>] = [:]
    private var progressScripts: [String: [Int]] = [:]
    private var started: [String] = []
    private var routedSelections: [String: SpeechEngineSelection] = [:]

    private(set) var warmUpCallCount = 0
    private(set) var isReadyCallCount = 0
    private(set) var clearModelCacheCallCount = 0
    private(set) var shutdownCallCount = 0
    private(set) var setSpeechEngineCallCount = 0
    private(set) var currentSpeechEngineSelectionCallCount = 0
    private var selection = SpeechEngineSelection(engine: .parakeet)
    private var ready = false
    private var shouldBlockNextClearModelCache = false
    private var clearModelCacheContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextShutdown = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextCurrentSpeechEngineSelection = false
    private var currentSpeechEngineSelectionContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextSpeechEngineSwitch = false
    private var shouldIgnoreNextSpeechEngineSwitchCancellation = false
    private var speechEngineSwitchContinuation: CheckedContinuation<Void, Never>?

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        started.append(audioPath)
        let ignoresCancellation = cancellationIgnoringPaths.contains(audioPath)
        let skipsCancellationCheck = cancellationIgnoringSuccessPaths.contains(audioPath)

        if let script = progressScripts[audioPath] {
            for progress in script {
                onProgress?(progress, 100)
            }
        }

        if ignoresCancellation {
            try await withCheckedThrowingContinuation { continuation in
                waitingContinuations[audioPath] = continuation
            }
        } else if blockedPaths.contains(audioPath) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waitingContinuations[audioPath] = continuation
                }
            } onCancel: {
                Task { await self.cancelBlocked(path: audioPath) }
            }
        }

        if !skipsCancellationCheck {
            try Task.checkCancellation()
        }
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
        if shouldBlockNextShutdown {
            shouldBlockNextShutdown = false
            await withCheckedContinuation { continuation in
                shutdownContinuation = continuation
            }
        }
    }

    func clearModelCache() async {
        clearModelCacheCallCount += 1
        if shouldBlockNextClearModelCache {
            shouldBlockNextClearModelCache = false
            await withCheckedContinuation { continuation in
                clearModelCacheContinuation = continuation
            }
        }
        ready = false
    }

    func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        setSpeechEngineCallCount += 1
        if shouldBlockNextSpeechEngineSwitch {
            shouldBlockNextSpeechEngineSwitch = false
            let ignoresCancellation = shouldIgnoreNextSpeechEngineSwitchCancellation
            shouldIgnoreNextSpeechEngineSwitchCancellation = false
            if ignoresCancellation {
                await withCheckedContinuation { continuation in
                    speechEngineSwitchContinuation = continuation
                }
            } else {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        speechEngineSwitchContinuation = continuation
                    }
                } onCancel: {
                    Task {
                        await self.releaseSpeechEngineSwitch()
                    }
                }
            }
            try Task.checkCancellation()
        }
        selection = SpeechEngineSelection(engine: preference)
        ready = false
    }

    func currentSpeechEngineSelection() async -> SpeechEngineSelection {
        currentSpeechEngineSelectionCallCount += 1
        if shouldBlockNextCurrentSpeechEngineSelection {
            shouldBlockNextCurrentSpeechEngineSelection = false
            await withCheckedContinuation { continuation in
                currentSpeechEngineSelectionContinuation = continuation
            }
        }
        return selection
    }

    func setCurrentSelection(_ selection: SpeechEngineSelection) {
        self.selection = selection
    }

    func blockNextSpeechEngineSwitch() {
        shouldBlockNextSpeechEngineSwitch = true
    }

    func blockNextSpeechEngineSwitchIgnoringCancellation() {
        shouldBlockNextSpeechEngineSwitch = true
        shouldIgnoreNextSpeechEngineSwitchCancellation = true
    }

    func releaseSpeechEngineSwitch() {
        speechEngineSwitchContinuation?.resume()
        speechEngineSwitchContinuation = nil
    }

    func block(path: String) {
        blockedPaths.insert(path)
    }

    func blockIgnoringCancellation(path: String) {
        cancellationIgnoringPaths.insert(path)
    }

    func blockIgnoringCancellationAndSucceed(path: String) {
        cancellationIgnoringPaths.insert(path)
        cancellationIgnoringSuccessPaths.insert(path)
    }

    func blockNextClearModelCache() {
        shouldBlockNextClearModelCache = true
    }

    func releaseClearModelCache() {
        clearModelCacheContinuation?.resume()
        clearModelCacheContinuation = nil
    }

    func blockNextShutdown() {
        shouldBlockNextShutdown = true
    }

    func releaseShutdown() {
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    func blockNextCurrentSpeechEngineSelection() {
        shouldBlockNextCurrentSpeechEngineSelection = true
    }

    func releaseCurrentSpeechEngineSelection() {
        currentSpeechEngineSelectionContinuation?.resume()
        currentSpeechEngineSelectionContinuation = nil
    }

    func release(path: String) {
        blockedPaths.remove(path)
        cancellationIgnoringPaths.remove(path)
        cancellationIgnoringSuccessPaths.remove(path)
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
