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

    func testLiveDictationSessionOwnsInteractiveSlotUntilFinish() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setCurrentSelection(SpeechEngineSelection(engine: .nemotron))
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let partials = LockedStringRecorder()
        let sessionID = try await scheduler.beginLiveDictationTranscription { partial in
            partials.record(partial)
        }

        XCTAssertEqual(partials.values, ["live partial"])
        let busyAvailability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(busyAvailability, .transcribing)

        do {
            _ = try await scheduler.transcribe(audioPath: "dictation", job: .dictation)
            XCTFail("Expected live dictation to occupy the interactive slot")
        } catch let error as STTError {
            if case .engineBusy = error {} else {
                XCTFail("Expected engineBusy, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let meetingLiveResult = try await scheduler.transcribe(
            audioPath: "meeting-live",
            job: .meetingLiveChunk
        )
        XCTAssertEqual(meetingLiveResult.text, "meetingLiveChunk:meeting-live")

        try await scheduler.appendLiveDictationSamples([0.1, 0.2], sessionID: sessionID)
        let result = try await scheduler.finishLiveDictationTranscription(sessionID: sessionID)

        XCTAssertEqual(result.text, "live dictation")
        let liveDictationSamples = await runtime.liveDictationSamples
        XCTAssertEqual(liveDictationSamples, [[0.1, 0.2]])
        let finalAvailability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(finalAvailability, .available)
    }

    func testLiveDictationFinalizationIgnoresConcurrentCancel() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setCurrentSelection(SpeechEngineSelection(engine: .nemotron))
        await runtime.blockNextLiveFinish()
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let sessionID = try await scheduler.beginLiveDictationTranscription { _ in }
        let finishTask = Task {
            try await scheduler.finishLiveDictationTranscription(sessionID: sessionID)
        }

        await runtime.waitForLiveFinishStart()
        await scheduler.cancelLiveDictationTranscription(sessionID: sessionID)

        let liveCancelCallCount = await runtime.liveCancelCallCount
        XCTAssertEqual(liveCancelCallCount, 0)
        let busyAvailability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(busyAvailability, .transcribing)

        await runtime.resumeLiveFinish()
        let result = try await finishTask.value

        XCTAssertEqual(result.text, "live dictation")
        let finalAvailability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(finalAvailability, .available)
    }

    func testLiveDictationBeginRacingShutdownUnwindsRuntimeSession() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setCurrentSelection(SpeechEngineSelection(engine: .nemotron))
        await runtime.blockNextLiveBegin()
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let beginTask = Task {
            try await scheduler.beginLiveDictationTranscription { _ in }
        }
        await runtime.waitForLiveBeginStart()
        // Quiesce clears the scheduler-side reservation while runtime.begin is
        // still in flight; its runtime-level cancel is a no-op at this point.
        await scheduler.shutdown()
        await runtime.resumeLiveBegin()

        do {
            _ = try await beginTask.value
            XCTFail("Expected begin to unwind after losing its reservation")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        }

        // The runtime session created by the in-flight begin must have been
        // cancelled, not orphaned (an orphan would block the interactive lane
        // until app restart).
        let liveCancelCallCount = await runtime.liveCancelCallCount
        XCTAssertEqual(liveCancelCallCount, 1)
        let hasActiveSession = await runtime.hasActiveLiveDictationSession
        XCTAssertFalse(hasActiveSession)
    }

    func testDictationPreviewDoesNotUseLiveSessionReservation() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "meeting-live")
        let scheduler = STTScheduler(runtimeProvider: runtime, meetingLiveChunkBacklogLimit: 8)

        let meetingTask = Task {
            try await scheduler.transcribe(audioPath: "meeting-live", job: .meetingLiveChunk)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        let preview = try await scheduler.transcribeDictationPreview(
            samples: [0.1, 0.2, 0.3],
            speechEngine: SpeechEngineSelection(engine: .parakeet)
        )
        XCTAssertEqual(preview.text, "preview:3")

        let availability = await scheduler.engineSwitchAvailability()
        XCTAssertEqual(availability, .transcribing)

        await runtime.release(path: "meeting-live")
        _ = try await meetingTask.value
    }

    func testEngineSwitchCancelsRunningDictationPreview() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextPreview()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            dictationPreviewDrainTimeout: .milliseconds(50)
        )

        let previewTask = Task {
            try await scheduler.transcribeDictationPreview(
                samples: [0.1, 0.2, 0.3],
                speechEngine: SpeechEngineSelection(engine: .parakeet)
            )
        }
        await runtime.waitForPreviewStart()

        try await scheduler.setSpeechEngine(.whisper)

        do {
            _ = try await previewTask.value
            XCTFail("Expected preview task to be cancelled by engine switch")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let switchCount = await runtime.setSpeechEngineCallCount
        XCTAssertEqual(switchCount, 1)
    }

    func testLiveDictationBeginRejectedWhileDictationPreviewIsRunning() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setCurrentSelection(SpeechEngineSelection(engine: .nemotron))
        await runtime.blockNextPreview()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let previewTask = Task {
            try await scheduler.transcribeDictationPreview(
                samples: [0.1, 0.2, 0.3],
                speechEngine: SpeechEngineSelection(engine: .parakeet)
            )
        }
        await runtime.waitForPreviewStart()

        do {
            _ = try await scheduler.beginLiveDictationTranscription { _ in }
            XCTFail("Expected live dictation begin to be rejected while preview is running")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        } catch {
            XCTFail("Expected engineBusy, got \(error)")
        }

        await runtime.releasePreview()
        _ = try await previewTask.value
    }

    func testEngineSwitchPreviewDrainTimeoutFailsFastAndAllowsRetryAfterDrain() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setIgnoreCancellation(true)
        await runtime.blockNextPreview()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            dictationPreviewDrainTimeout: .milliseconds(50)
        )

        let previewTask = Task {
            try await scheduler.transcribeDictationPreview(
                samples: [0.1, 0.2, 0.3],
                speechEngine: SpeechEngineSelection(engine: .parakeet)
            )
        }
        await runtime.waitForPreviewStart()

        let switchTask = Task {
            try await scheduler.setSpeechEngine(.whisper)
        }
        do {
            _ = try await value(switchTask, timeout: .seconds(1))
            XCTFail("Expected switch to fail while cancelled preview is still draining")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        } catch {
            XCTFail("Expected engineBusy, got \(error)")
        }

        let switchCount = await runtime.setSpeechEngineCallCount
        XCTAssertEqual(switchCount, 0)

        await runtime.setIgnoreCancellation(false)
        await runtime.forceReleaseAll()
        _ = try? await previewTask.value

        try await scheduler.setSpeechEngine(.whisper)
        let retrySwitchCount = await runtime.setSpeechEngineCallCount
        XCTAssertEqual(retrySwitchCount, 1)
    }

    func testShutdownWaitsForDictationPreviewDrainBeforeRuntimeShutdown() async throws {
        let runtime = MockSTTRuntime()
        await runtime.setIgnoreCancellation(true)
        await runtime.blockNextPreview()
        let scheduler = STTScheduler(
            runtimeProvider: runtime,
            dictationPreviewDrainTimeout: .milliseconds(50)
        )

        let previewTask = Task {
            try await scheduler.transcribeDictationPreview(
                samples: [0.1, 0.2, 0.3],
                speechEngine: SpeechEngineSelection(engine: .parakeet)
            )
        }
        await runtime.waitForPreviewStart()

        let shutdownTask = Task {
            await scheduler.shutdown()
        }
        try await Task.sleep(for: .milliseconds(100))

        let countsBeforeRelease = await runtime.lifecycleCounts()
        XCTAssertEqual(countsBeforeRelease.shutdown, 0)

        await runtime.setIgnoreCancellation(false)
        await runtime.forceReleaseAll()
        let shutdownWaitTask = Task<Void, any Error> {
            await shutdownTask.value
        }
        try await value(shutdownWaitTask, timeout: .seconds(1))
        _ = try? await previewTask.value

        let countsAfterRelease = await runtime.lifecycleCounts()
        XCTAssertEqual(countsAfterRelease.shutdown, 1)
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

    func testClearModelCacheRejectsNewJobsUntilRuntimeClearCompletes() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextClearModelCache()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let clearTask = Task { await scheduler.clearModelCache() }
        try await waitForClearModelCacheCall(runtime: runtime, count: 1)

        do {
            _ = try await scheduler.transcribe(audioPath: "during-clear", job: .dictation)
            XCTFail("Expected new STT work to be rejected while cache clear is still running.")
        } catch let error as STTSchedulerError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("Expected STTSchedulerError.unavailable, got \(error)")
        }

        await runtime.releaseClearModelCache()
        _ = await clearTask.value

        let result = try await scheduler.transcribe(audioPath: "after-clear", job: .dictation)
        XCTAssertEqual(result.text, "dictation:after-clear")
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

    /// AUDIT-071 regression: `beginSpeechEngineSession` suspends while
    /// reading the runtime selection, *before* it used to insert the lease
    /// ID. An engine switch arriving during that window passed the
    /// `activeSpeechEngineSessionIDs.isEmpty` guard, so the lease could pin
    /// a different engine than the runtime ended up on. The session slot
    /// must now be reserved before the first suspension point.
    func testSetSpeechEngineFailsWhileSessionBeginIsInFlight() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSelectionRead()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let leaseTask = Task {
            await scheduler.beginSpeechEngineSession()
        }
        try await waitForHeldSelectionRead(runtime: runtime, count: 1)

        do {
            try await scheduler.setSpeechEngine(.whisper)
            XCTFail("Expected engine switch to fail while a session begin is in flight")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await runtime.releaseSelectionRead()
        let lease = await leaseTask.value
        XCTAssertEqual(lease.selection, SpeechEngineSelection(engine: .parakeet))
        let switches = await runtime.setSpeechEngineCallCount
        XCTAssertEqual(switches, 0, "No switch may reach the runtime mid-begin")

        await scheduler.endSpeechEngineSession(lease)
        try await scheduler.setSpeechEngine(.whisper)
    }

    /// Same AUDIT-071 window, via the Parakeet variant-swap path that shares
    /// the engine-switch guard.
    func testSetParakeetModelVariantFailsWhileSessionBeginIsInFlight() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSelectionRead()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let leaseTask = Task {
            await scheduler.beginSpeechEngineSession()
        }
        try await waitForHeldSelectionRead(runtime: runtime, count: 1)

        do {
            try await scheduler.setParakeetModelVariant(.v2, onProgress: nil)
            XCTFail("Expected variant swap to fail while a session begin is in flight")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await runtime.releaseSelectionRead()
        let lease = await leaseTask.value
        XCTAssertEqual(lease.selection, SpeechEngineSelection(engine: .parakeet))
        let swaps = await runtime.parakeetModelVariantSwitches
        XCTAssertTrue(swaps.isEmpty, "No variant swap may reach the runtime mid-begin")

        await scheduler.endSpeechEngineSession(lease)
        try await scheduler.setParakeetModelVariant(.v2, onProgress: nil)
        let swapsAfterEnd = await runtime.parakeetModelVariantSwitches
        XCTAssertEqual(swapsAfterEnd, [.v2], "Variant swap must succeed once the session is released")
    }

    func testSetParakeetModelVariantForwardsWhenIdle() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)
        let progressMessages = LockedStringRecorder()

        try await scheduler.setParakeetModelVariant(.v2) { message in
            progressMessages.record(message)
        }

        let variants = await runtime.parakeetModelVariantSwitches
        XCTAssertEqual(variants, [.v2])
        XCTAssertEqual(progressMessages.values, ["Mock loading Parakeet TDT 0.6B v2"])
    }

    func testSetParakeetModelVariantFailsWhileJobIsRunning() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "active")
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "active", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        do {
            try await scheduler.setParakeetModelVariant(.v2, onProgress: nil)
            XCTFail("Expected variant switch to fail while STT job is running")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await runtime.release(path: "active")
        _ = try await activeTask.value
    }

    func testSetParakeetModelVariantFailsWhileSessionLeaseIsActive() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let lease = await scheduler.beginSpeechEngineSession()
        do {
            try await scheduler.setParakeetModelVariant(.v2, onProgress: nil)
            XCTFail("Expected variant switch to fail while a speech engine session is active")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await scheduler.endSpeechEngineSession(lease)
        try await scheduler.setParakeetModelVariant(.v2, onProgress: nil)
        let variants = await runtime.parakeetModelVariantSwitches
        XCTAssertEqual(variants, [.v2])
    }

    /// Same AUDIT-071 window, via the Nemotron variant-swap path that shares
    /// the engine-switch guard.
    func testSetNemotronModelVariantFailsWhileSessionBeginIsInFlight() async throws {
        let runtime = MockSTTRuntime()
        await runtime.blockNextSelectionRead()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let leaseTask = Task {
            await scheduler.beginSpeechEngineSession()
        }
        try await waitForHeldSelectionRead(runtime: runtime, count: 1)

        do {
            try await scheduler.setNemotronModelVariant(.english1120, onProgress: nil)
            XCTFail("Expected variant swap to fail while a session begin is in flight")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await runtime.releaseSelectionRead()
        let lease = await leaseTask.value
        XCTAssertEqual(lease.selection, SpeechEngineSelection(engine: .parakeet))
        let swaps = await runtime.nemotronModelVariantSwitches
        XCTAssertTrue(swaps.isEmpty, "No variant swap may reach the runtime mid-begin")

        await scheduler.endSpeechEngineSession(lease)
        try await scheduler.setNemotronModelVariant(.english1120, onProgress: nil)
        let swapsAfterEnd = await runtime.nemotronModelVariantSwitches
        XCTAssertEqual(swapsAfterEnd, [.english1120], "Variant swap must succeed once the session is released")
    }

    func testSetNemotronModelVariantForwardsWhenIdle() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)
        let progressMessages = LockedStringRecorder()

        try await scheduler.setNemotronModelVariant(.english1120) { message in
            progressMessages.record(message)
        }

        let variants = await runtime.nemotronModelVariantSwitches
        XCTAssertEqual(variants, [.english1120])
        XCTAssertEqual(progressMessages.values, ["Mock loading Nemotron Speech Streaming EN 0.6B"])
    }

    func testSetNemotronModelVariantFailsWhileJobIsRunning() async throws {
        let runtime = MockSTTRuntime()
        await runtime.block(path: "active")
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let activeTask = Task {
            try await scheduler.transcribe(audioPath: "active", job: .fileTranscription)
        }
        try await waitForStartedPaths(runtime: runtime, count: 1)

        do {
            try await scheduler.setNemotronModelVariant(.english1120, onProgress: nil)
            XCTFail("Expected variant switch to fail while STT job is running")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await runtime.release(path: "active")
        _ = try await activeTask.value
    }

    func testSetNemotronModelVariantFailsWhileSessionLeaseIsActive() async throws {
        let runtime = MockSTTRuntime()
        let scheduler = STTScheduler(runtimeProvider: runtime)

        let lease = await scheduler.beginSpeechEngineSession()
        do {
            try await scheduler.setNemotronModelVariant(.english1120, onProgress: nil)
            XCTFail("Expected variant switch to fail while a speech engine session is active")
        } catch let error as STTError {
            XCTAssertEqual(error.localizedDescription, STTError.engineBusy.localizedDescription)
        }

        await scheduler.endSpeechEngineSession(lease)
        try await scheduler.setNemotronModelVariant(.english1120, onProgress: nil)
        let variants = await runtime.nemotronModelVariantSwitches
        XCTAssertEqual(variants, [.english1120])
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

    private func waitForHeldSelectionRead(
        runtime: MockSTTRuntime,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = ContinuousClock.now
        while await runtime.heldSelectionReadCount < count {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for \(count) held selection reads")
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

    private func waitForClearModelCacheCall(
        runtime: MockSTTRuntime,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = ContinuousClock.now
        while await runtime.lifecycleCounts().clearModelCache < count {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for \(count) cache clears")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func value<T: Sendable>(
        _ task: Task<T, any Error>,
        timeout: Duration = .seconds(1)
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OneShotThrowingContinuation<T>(continuation)
            Task {
                do {
                    gate.resume(returning: try await task.value)
                } catch {
                    gate.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(throwing: STTSchedulerTestError.timeout)
            }
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

private final class OneShotThrowingContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
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
    private(set) var parakeetModelVariantSwitches: [ParakeetModelVariant] = []
    private(set) var nemotronModelVariantSwitches: [NemotronModelVariant] = []
    private var selection = SpeechEngineSelection(engine: .parakeet)
    private var ready = false
    private var shouldBlockNextSpeechEngineSwitch = false
    private var shouldBlockNextClearModelCache = false
    private var ignoreCancellation = false
    private var speechEngineSwitchContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextSelectionRead = false
    private var selectionReadContinuation: CheckedContinuation<Void, Never>?
    private(set) var heldSelectionReadCount = 0
    private var clearModelCacheContinuation: CheckedContinuation<Void, Never>?
    private var liveDictationSessionID: UUID?
    private(set) var liveDictationSamples: [[Float]] = []
    private(set) var liveCancelCallCount = 0
    private var shouldBlockNextLiveFinish = false
    private var liveFinishContinuation: CheckedContinuation<Void, Never>?
    private var liveFinishStartContinuation: CheckedContinuation<Void, Never>?
    private var liveFinishStartedCount = 0
    private var shouldBlockNextLiveBegin = false
    private var liveBeginContinuation: CheckedContinuation<Void, Never>?
    private var liveBeginStartContinuation: CheckedContinuation<Void, Never>?
    private var liveBeginStartedCount = 0
    private(set) var previewSamples: [[Float]] = []
    private(set) var previewSelections: [SpeechEngineSelection] = []
    private var blockedPreviewCount = 0
    private var previewContinuation: CheckedContinuation<Void, Never>?
    private var previewStartContinuation: CheckedContinuation<Void, Never>?

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

    func transcribeDictationPreview(
        samples: [Float],
        speechEngine: SpeechEngineSelection
    ) async throws -> STTResult {
        previewSamples.append(samples)
        previewSelections.append(speechEngine)
        previewStartContinuation?.resume()
        previewStartContinuation = nil
        if blockedPreviewCount > 0 {
            blockedPreviewCount -= 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    previewContinuation = continuation
                }
            } onCancel: {
                Task { await self.cancelBlockedPreview() }
            }
            try Task.checkCancellation()
        }
        return STTResult(text: "preview:\(samples.count)", words: [], engine: speechEngine.engine)
    }

    func blockNextPreview() {
        blockedPreviewCount += 1
    }

    func waitForPreviewStart() async {
        guard previewSamples.isEmpty else { return }
        await withCheckedContinuation { continuation in
            previewStartContinuation = continuation
        }
    }

    func releasePreview() {
        previewContinuation?.resume()
        previewContinuation = nil
    }

    private func cancelBlockedPreview() {
        guard !ignoreCancellation else { return }
        releasePreview()
    }

    func beginLiveDictationTranscription(
        sessionID: UUID,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        liveBeginStartedCount += 1
        liveBeginStartContinuation?.resume()
        liveBeginStartContinuation = nil
        if shouldBlockNextLiveBegin {
            shouldBlockNextLiveBegin = false
            await withCheckedContinuation { continuation in
                liveBeginContinuation = continuation
            }
        }
        liveDictationSessionID = sessionID
        onPartial("live partial")
    }

    func appendLiveDictationSamples(_ samples: [Float], sessionID: UUID) async throws {
        guard liveDictationSessionID == sessionID else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        liveDictationSamples.append(samples)
    }

    func finishLiveDictationTranscription(sessionID: UUID) async throws -> STTResult {
        guard liveDictationSessionID == sessionID else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        liveFinishStartedCount += 1
        liveFinishStartContinuation?.resume()
        liveFinishStartContinuation = nil
        if shouldBlockNextLiveFinish {
            shouldBlockNextLiveFinish = false
            await withCheckedContinuation { continuation in
                liveFinishContinuation = continuation
            }
        }
        liveDictationSessionID = nil
        return STTResult(text: "live dictation", words: [], engine: .nemotron)
    }

    func cancelLiveDictationTranscription(sessionID: UUID) async {
        guard liveDictationSessionID == sessionID else { return }
        liveCancelCallCount += 1
        liveDictationSessionID = nil
    }

    func blockNextLiveFinish() {
        shouldBlockNextLiveFinish = true
    }

    func waitForLiveFinishStart() async {
        guard liveFinishStartedCount == 0 else { return }
        await withCheckedContinuation { continuation in
            liveFinishStartContinuation = continuation
        }
    }

    func resumeLiveFinish() {
        liveFinishContinuation?.resume()
        liveFinishContinuation = nil
    }

    var hasActiveLiveDictationSession: Bool {
        liveDictationSessionID != nil
    }

    func blockNextLiveBegin() {
        shouldBlockNextLiveBegin = true
    }

    func waitForLiveBeginStart() async {
        guard liveBeginStartedCount == 0 else { return }
        await withCheckedContinuation { continuation in
            liveBeginStartContinuation = continuation
        }
    }

    func resumeLiveBegin() {
        liveBeginContinuation?.resume()
        liveBeginContinuation = nil
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

    func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        parakeetModelVariantSwitches.append(variant)
        onProgress?("Mock loading \(variant.modelName)")
        if shouldBlockNextSpeechEngineSwitch {
            shouldBlockNextSpeechEngineSwitch = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    speechEngineSwitchContinuation = continuation
                }
            } onCancel: {
                Task { await self.releaseSpeechEngineSwitch() }
            }
            try Task.checkCancellation()
        }
        selection = SpeechEngineSelection(engine: .parakeet)
    }

    func setNemotronModelVariant(
        _ variant: NemotronModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        nemotronModelVariantSwitches.append(variant)
        onProgress?("Mock loading \(variant.modelName)")
        if shouldBlockNextSpeechEngineSwitch {
            shouldBlockNextSpeechEngineSwitch = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    speechEngineSwitchContinuation = continuation
                }
            } onCancel: {
                Task { await self.releaseSpeechEngineSwitch() }
            }
            try Task.checkCancellation()
        }
        selection = SpeechEngineSelection(engine: .nemotron)
    }

    func currentSpeechEngineSelection() async -> SpeechEngineSelection {
        if shouldBlockNextSelectionRead {
            shouldBlockNextSelectionRead = false
            heldSelectionReadCount += 1
            await withCheckedContinuation { continuation in
                selectionReadContinuation = continuation
            }
        }
        return selection
    }

    func setCurrentSelection(_ selection: SpeechEngineSelection) {
        self.selection = selection
    }

    func blockNextSelectionRead() {
        shouldBlockNextSelectionRead = true
    }

    func releaseSelectionRead() {
        selectionReadContinuation?.resume()
        selectionReadContinuation = nil
    }

    func blockNextSpeechEngineSwitch() {
        shouldBlockNextSpeechEngineSwitch = true
    }

    func releaseSpeechEngineSwitch() {
        speechEngineSwitchContinuation?.resume()
        speechEngineSwitchContinuation = nil
    }

    func blockNextClearModelCache() {
        shouldBlockNextClearModelCache = true
    }

    func releaseClearModelCache() {
        clearModelCacheContinuation?.resume()
        clearModelCacheContinuation = nil
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
        releasePreview()
        releaseClearModelCache()
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
