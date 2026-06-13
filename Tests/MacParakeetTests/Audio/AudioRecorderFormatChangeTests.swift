import AVFoundation
import os
import XCTest
@testable import MacParakeetCore

final class AudioRecorderFormatChangeTests: XCTestCase {
    func testTapConverterNeedsRebuildWhenNoCachedFormat() throws {
        let incoming = try makeFormat()
        XCTAssertTrue(tapConverterNeedsRebuild(cachedSourceFormat: nil, incomingBufferFormat: incoming))
    }

    func testTapConverterDoesNotNeedRebuildForEquivalentFormat() throws {
        let cached = try makeFormat()
        let incoming = try makeFormat()
        XCTAssertFalse(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    func testTapConverterNeedsRebuildWhenInterleavingChanges() throws {
        let nonInterleaved = try makeFormat(interleaved: false)
        let interleaved = try makeFormat(interleaved: true)
        XCTAssertTrue(
            tapConverterNeedsRebuild(
                cachedSourceFormat: nonInterleaved,
                incomingBufferFormat: interleaved
            )
        )
    }

    func testTapConverterNeedsRebuildWhenSampleRateChanges() throws {
        let cached = try makeFormat(sampleRate: 48_000)
        let incoming = try makeFormat(sampleRate: 44_100)
        XCTAssertTrue(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    func testSharedModeStopAcceptsFluidAudioMinimumSamples() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800))

        let url = try await recorder.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    func testSharedModeStopRejectsBelowFluidAudioMinimumSamples() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_799))

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should reject recordings below FluidAudio's current 0.3s floor")
        } catch AudioProcessorError.insufficientSamples {
            // Expected.
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }
    }

    func testStopInvokesSampleSinkOnFinishWhenSamplesSufficient() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let spy = SampleSinkSpy()
        let sink = DictationAudioSampleSink(
            onSamples: { _ in },
            onFinish: { spy.recordFinish() },
            onCancel: { spy.recordCancel() }
        )

        try await recorder.start(sampleSink: sink)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800))

        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(spy.counts.finish, 1, "a completed capture should finish the sample sink")
        XCTAssertEqual(spy.counts.cancel, 0, "a completed capture must not cancel the sample sink")
    }

    func testStopInvokesSampleSinkOnCancelBelowMinimumSamples() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let spy = SampleSinkSpy()
        let sink = DictationAudioSampleSink(
            onSamples: { _ in },
            onFinish: { spy.recordFinish() },
            onCancel: { spy.recordCancel() }
        )

        try await recorder.start(sampleSink: sink)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_799))

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should reject recordings below FluidAudio's current 0.3s floor")
        } catch AudioProcessorError.insufficientSamples {
            // Expected — a too-short capture is a cancellation, not a finish:
            // the live-transcription continuations must be torn down rather
            // than left to drain a result the recorded WAV won't back.
        }

        XCTAssertEqual(spy.counts.cancel, 1, "a cancelled capture should cancel the sample sink")
        XCTAssertEqual(spy.counts.finish, 0, "a cancelled capture must not finish the sample sink")
    }

    func testInstantDictationPrependsWarmPreRoll() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        XCTAssertTrue(stream.diagnostics.engineRunning)
        XCTAssertEqual(stream.diagnostics.passiveSubscriberCount, 1)

        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.6))
        try await Task.sleep(for: .milliseconds(50))

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))

        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 12_000)
        XCTAssertEqual(samples[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(samples[7_199], 0.6, accuracy: 0.0001)
        XCTAssertEqual(samples[7_200], 0.2, accuracy: 0.0001)
        XCTAssertEqual(samples[11_999], 0.2, accuracy: 0.0001)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 1, "warm passive subscriber should remain after dictation stop")

        await recorder.setInstantDictationEnabled(false)
    }

    func testInstantDictationIncludesQueuedWarmPreRollAtStart() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.8))

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))

        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 12_000)
        XCTAssertEqual(samples[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(samples[7_199], 0.8, accuracy: 0.0001)
        XCTAssertEqual(samples[7_200], 0.2, accuracy: 0.0001)

        await recorder.setInstantDictationEnabled(false)
    }

    func testInstantDictationDoesNotCarryPreviousRecordingTailIntoNextStart() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.7))
        try await Task.sleep(for: .milliseconds(50))

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.3))
        let firstURL = try await recorder.stop()
        try? FileManager.default.removeItem(at: firstURL)

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.4))
        let secondURL = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: secondURL) }

        let samples = try readFloatSamples(from: secondURL)
        XCTAssertEqual(samples.count, 4_800)
        XCTAssertEqual(try XCTUnwrap(samples.first), 0.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(samples.last), 0.4, accuracy: 0.0001)

        await recorder.setInstantDictationEnabled(false)
    }

    func testInstantDictationDisableDuringPendingWarmStartDoesNotLeaveSubscriber() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }

        let enableTask = Task {
            await recorder.setInstantDictationEnabled(true)
        }

        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)
        await recorder.setInstantDictationEnabled(false)
        release.signal()
        await enableTask.value

        let drained = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 0 && !stream.diagnostics.engineRunning
        }
        XCTAssertTrue(drained, "disabling during a pending warm subscribe must unsubscribe the stale token")
        XCTAssertEqual(stream.diagnostics.passiveSubscriberCount, 0)
    }

    func testInstantDictationReenableDuringStaleWarmStartCleanupStartsWarmCapture() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }

        let enableTask = Task {
            await recorder.setInstantDictationEnabled(true)
        }

        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)
        await recorder.setInstantDictationEnabled(false)
        let reenableTask = Task {
            await recorder.setInstantDictationEnabled(true)
        }
        platform.configureAndStartHook = nil
        release.signal()
        await enableTask.value
        await reenableTask.value

        let restarted = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 1
                && stream.diagnostics.passiveSubscriberCount == 1
                && stream.diagnostics.engineRunning
        }
        XCTAssertTrue(restarted, "reenabling during stale cleanup should preserve the warm-start intent")

        await recorder.setInstantDictationEnabled(false)
    }

    func testInstantDictationRefreshClearsStaleWarmPreRoll() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.9))
        try await Task.sleep(for: .milliseconds(50))

        await recorder.refreshInstantDictationWarmCapture()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.5))
        try await Task.sleep(for: .milliseconds(50))

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))

        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 12_000)
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[7_199], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[7_200], 0.2, accuracy: 0.0001)
        XCTAssertFalse(samples.contains { abs($0 - 0.9) < 0.0001 })

        await recorder.setInstantDictationEnabled(false)
    }

    func testInstantDictationRefreshDuringActiveSubscriberRestartsWarmAfterActiveLeaves() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        let active = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        await recorder.refreshInstantDictationWarmCapture()

        XCTAssertEqual(platform.configureAndStartCallCount, 1, "active capture keeps the old engine until it leaves")
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.9))
        try await Task.sleep(for: .milliseconds(50))
        let oldEngineRestartBuffer = UncheckedSendableAudioPCMBuffer(
            try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.8)
        )
        platform.configureAndStartHook = {
            platform.deliverBuffer(oldEngineRestartBuffer.buffer)
        }
        await stream.unsubscribe(active)

        let restarted = await pollUntil(timeout: .seconds(2)) {
            platform.configureAndStartCallCount == 2
                && stream.diagnostics.subscriberCount == 1
                && stream.diagnostics.passiveSubscriberCount == 1
        }
        XCTAssertTrue(restarted, "warm capture should restart once only the passive subscriber remains")

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))
        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 4_800)
        XCTAssertEqual(try XCTUnwrap(samples.first), 0.2, accuracy: 0.0001)
        XCTAssertFalse(samples.contains { abs($0 - 0.9) < 0.0001 })
        XCTAssertFalse(samples.contains { abs($0 - 0.8) < 0.0001 })

        await recorder.setInstantDictationEnabled(false)
    }

    func testInstantDictationRefreshDuringActiveDictationRestartsWarmAfterStop() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.3))

        await recorder.refreshInstantDictationWarmCapture()

        XCTAssertEqual(platform.configureAndStartCallCount, 1, "active dictation keeps the old engine until stop")
        let url = try await recorder.stop()
        try? FileManager.default.removeItem(at: url)

        let restarted = await pollUntil(timeout: .seconds(2)) {
            platform.configureAndStartCallCount == 2
                && stream.diagnostics.subscriberCount == 1
                && stream.diagnostics.passiveSubscriberCount == 1
        }
        XCTAssertTrue(restarted, "warm capture should restart after active dictation drains")

        await recorder.setInstantDictationEnabled(false)
    }

    func testSharedModeStopDuringStartAbortsPendingSubscription() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }

        let startTask = Task {
            try await recorder.start()
        }

        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should throw while start is still pending")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "Not recording")
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }

        release.signal()

        do {
            try await startTask.value
            XCTFail("start() should abort after stop invalidates the pending generation")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "interrupted during subscribe")
        } catch {
            XCTFail("Unexpected start error: \(error)")
        }

        let isRecording = await recorder.isRecording
        XCTAssertFalse(isRecording)

        let drained = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 0 && !stream.diagnostics.engineRunning
        }
        XCTAssertTrue(drained, "expected pending unsubscribe to drain after interrupted start")
    }

    /// Reproduces the double-tap dictation race. Sequence is:
    ///   1. start #1 (provisional hold-to-talk) suspends in subscribe
    ///   2. stop runs (fn-up discard) — bumps generation, resets `starting`
    ///   3. start #2 (persistent double-tap) enters and suspends in subscribe
    ///   4. start #1's subscribe resumes — lostRace throws, defer fires
    ///   5. start #2's subscribe resumes — must succeed
    ///
    /// Today's bug: start #1's `defer { starting = false }` clobbers start #2's
    /// `starting = true` between #1's throw and #2's lostRace check, so #2's
    /// `!self.starting` clause trips lostRace and the user-wanted persistent
    /// recording also aborts. After the fix (per-call defer guard via
    /// `startCallGeneration`), the sibling defer leaves the active claim alone
    /// and start #2 succeeds.
    ///
    /// The `permissionProvider` is the synchronization gate: every `start()`
    /// invokes it after passing the entry guard, so signaling on the second
    /// call gives a deterministic "task #2 has entered start()" sync point.
    /// A blanket `Task.sleep` would risk task #2 entering AFTER task #1
    /// resolves, missing the bug entirely (false-pass regression sentinel).
    func testSharedModeStartAfterStopDuringFirstStartSucceeds() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)

        let permissionCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let task2EnteredStart = DispatchSemaphore(value: 0)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: {
                let n = permissionCallCount.withLock { v in
                    v += 1
                    return v
                }
                if n == 2 {
                    task2EnteredStart.signal()
                }
                return true
            }
        )

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }

        let task1 = Task { try await recorder.start() }
        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should throw while start #1 is still pending")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "Not recording")
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }

        // Disarm the hook so the engineQueue can drain start #2's subscribe
        // (no-op for an already-running engine) without re-blocking.
        platform.configureAndStartHook = nil

        // Launch start #2 while start #1 is still suspended in subscribe.
        let task2 = Task { try await recorder.start() }

        // Wait for task2 to reach permissionProvider — proof it's inside the
        // actor with `starting=true` set. From there to `await subscribe` is
        // a few lines of synchronous code (no awaits between), so a short
        // yield suffices to let the await be reached before we release.
        XCTAssertEqual(task2EnteredStart.wait(timeout: .now() + 5), .success)
        for _ in 0..<5 { await Task.yield() }

        // Release start #1's blocked engine startup. Subscribe #1 completes,
        // its continuation resumes on the actor, lostRace throws, defer fires.
        // Then subscribe #2 completes (engine already running) and resumes.
        release.signal()

        do {
            try await task1.value
            XCTFail("start #1 should abort — its generation was bumped by stop")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "interrupted during subscribe")
        } catch {
            XCTFail("Unexpected start #1 error: \(error)")
        }

        do {
            try await task2.value
        } catch {
            XCTFail("start #2 should succeed after start #1 aborted; got: \(error)")
        }

        let isRecording = await recorder.isRecording
        XCTAssertTrue(isRecording, "start #2 must leave the recorder in recording state")

        // Drain the fire-and-forget unsubscribe(token #1) before asserting
        // subscriber count. Poll instead of sleep — bounded, deterministic.
        let drained = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 1
        }
        XCTAssertTrue(drained, "expected exactly one remaining subscriber after #1 unsubscribed")
        XCTAssertTrue(stream.diagnostics.engineRunning)

        // Cleanup stop() throws `insufficientSamples` because the mock platform
        // never delivers buffers — expected here and unrelated to the race.
        _ = try? await recorder.stop()
    }

    // MARK: - Pre-roll discard (issue #474)

    func testDiscardPreRollRemovesPrependedSamplesFromFinalWAV() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.6))
        try await Task.sleep(for: .milliseconds(50))

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))
        await recorder.discardPreRollForActiveRecording()

        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 4_800)
        XCTAssertEqual(try XCTUnwrap(samples.first), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(samples.last), 0.2, accuracy: 0.0001)
        XCTAssertFalse(samples.contains { abs($0 - 0.6) < 0.0001 })

        await recorder.setInstantDictationEnabled(false)
    }

    func testDiscardPreRollMakesMediaOnlyCaptureInsufficient() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.6))
        try await Task.sleep(for: .milliseconds(50))

        // Total = 7,200 pre-roll + 3,200 live ≥ the 4,800 floor, but the
        // post-discard remainder (3,200) is below it: without the discard
        // this capture would transcribe nothing but the paused media audio.
        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 3_200, sampleValue: 0.2))
        await recorder.discardPreRollForActiveRecording()

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should report insufficient samples once the pre-roll is discarded")
        } catch AudioProcessorError.insufficientSamples {
            // Expected.
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }

        await recorder.setInstantDictationEnabled(false)
    }

    func testDiscardPreRollRequestIgnoredWhenIdle() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.6))
        try await Task.sleep(for: .milliseconds(50))

        // Idle request must be dropped, not pre-armed for the next session.
        await recorder.discardPreRollForActiveRecording()

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))

        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 12_000)
        XCTAssertEqual(samples[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(samples[7_200], 0.2, accuracy: 0.0001)

        await recorder.setInstantDictationEnabled(false)
    }

    func testDiscardPreRollStateDoesNotLeakIntoNextRecording() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.6))
        try await Task.sleep(for: .milliseconds(50))

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))
        await recorder.discardPreRollForActiveRecording()
        let firstURL = try await recorder.stop()
        try? FileManager.default.removeItem(at: firstURL)

        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 8_000, sampleValue: 0.7))
        try await Task.sleep(for: .milliseconds(50))

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))
        let secondURL = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: secondURL) }

        let samples = try readFloatSamples(from: secondURL)
        XCTAssertEqual(samples.count, 12_000)
        XCTAssertEqual(samples[0], 0.7, accuracy: 0.0001)
        XCTAssertEqual(samples[7_200], 0.2, accuracy: 0.0001)

        await recorder.setInstantDictationEnabled(false)
    }

    func testDiscardPreRollWithoutInstantDictationIsNoOp() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.3))
        await recorder.discardPreRollForActiveRecording()

        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 4_800)
        XCTAssertEqual(try XCTUnwrap(samples.first), 0.3, accuracy: 0.0001)
    }

    // MARK: - Bluetooth warm-capture suppression (issue #481)

    func testWarmCaptureSuppressedOnBluetoothInput() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true },
            isBluetoothInputProvider: { true }
        )

        await recorder.setInstantDictationEnabled(true)
        XCTAssertFalse(stream.diagnostics.engineRunning, "warm hold must not start on a Bluetooth input")
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0)

        // Dictation itself still works — cold start, no pre-roll.
        try await recorder.start()
        platform.deliverBuffer(try makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.2))
        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try readFloatSamples(from: url)
        XCTAssertEqual(samples.count, 4_800)
        XCTAssertEqual(try XCTUnwrap(samples.first), 0.2, accuracy: 0.0001)

        // The post-stop warm restart must also skip, releasing the engine.
        let released = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 0 && !stream.diagnostics.engineRunning
        }
        XCTAssertTrue(released, "engine must stop after dictation when the warm hold is suppressed")

        await recorder.setInstantDictationEnabled(false)
    }

    func testWarmCaptureStopsWhenInputBecomesBluetoothOnRefresh() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let bluetoothInput = OSAllocatedUnfairLock(initialState: false)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true },
            isBluetoothInputProvider: { bluetoothInput.withLock { $0 } }
        )

        await recorder.setInstantDictationEnabled(true)
        XCTAssertTrue(stream.diagnostics.engineRunning)
        XCTAssertEqual(stream.diagnostics.passiveSubscriberCount, 1)

        bluetoothInput.withLock { $0 = true }
        await recorder.refreshInstantDictationWarmCapture()

        let released = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 0 && !stream.diagnostics.engineRunning
        }
        XCTAssertTrue(released, "refresh must drop the warm hold once the input is Bluetooth")

        await recorder.setInstantDictationEnabled(false)
    }

    func testWarmCaptureResumesWhenBluetoothInputClears() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let bluetoothInput = OSAllocatedUnfairLock(initialState: true)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true },
            isBluetoothInputProvider: { bluetoothInput.withLock { $0 } }
        )

        await recorder.setInstantDictationEnabled(true)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0)

        bluetoothInput.withLock { $0 = false }
        await recorder.refreshInstantDictationWarmCapture()

        let resumed = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 1
                && stream.diagnostics.passiveSubscriberCount == 1
                && stream.diagnostics.engineRunning
        }
        XCTAssertTrue(resumed, "warm capture should resume once the input is no longer Bluetooth")

        await recorder.setInstantDictationEnabled(false)
    }

    /// Regression sentinel for the revival gap: if the refresh only deferred
    /// (instead of dropping the warm subscriber), the shared stream's
    /// passive restart would revive the warm engine on the Bluetooth input
    /// the moment the active subscriber leaves.
    func testRefreshDropsWarmLeaseOnBluetoothDuringActiveSubscriber() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let bluetoothInput = OSAllocatedUnfairLock(initialState: false)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true },
            isBluetoothInputProvider: { bluetoothInput.withLock { $0 } }
        )

        await recorder.setInstantDictationEnabled(true)
        let active = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        XCTAssertEqual(stream.diagnostics.subscriberCount, 2)

        bluetoothInput.withLock { $0 = true }
        await recorder.refreshInstantDictationWarmCapture()

        XCTAssertEqual(stream.diagnostics.subscriberCount, 1, "warm subscriber must be dropped, not deferred")
        XCTAssertEqual(stream.diagnostics.passiveSubscriberCount, 0)
        XCTAssertTrue(stream.diagnostics.engineRunning, "active capture keeps its engine")

        await stream.unsubscribe(active)

        let released = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 0 && !stream.diagnostics.engineRunning
        }
        XCTAssertTrue(released, "no warm engine may be revived on the Bluetooth input after the active session ends")
        XCTAssertEqual(
            platform.configureAndStartCallCount, 1,
            "engine must not restart for a dropped warm lease"
        )

        await recorder.setInstantDictationEnabled(false)
    }

    // MARK: - Warm refresh debounce (issue #481)

    func testRefreshDebounceCoalescesBurstsIntoOneRestart() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true },
            warmCaptureRefreshDebounce: 0.5
        )

        await recorder.setInstantDictationEnabled(true)
        XCTAssertEqual(platform.configureAndStartCallCount, 1)

        var refreshTasks: [Task<Void, Never>] = []
        for _ in 0..<5 {
            refreshTasks.append(Task { await recorder.refreshInstantDictationWarmCapture() })
            try await Task.sleep(for: .milliseconds(10))
        }
        for task in refreshTasks {
            await task.value
        }

        let settled = await pollUntil(timeout: .seconds(2)) {
            stream.diagnostics.subscriberCount == 1
                && stream.diagnostics.passiveSubscriberCount == 1
                && stream.diagnostics.engineRunning
        }
        XCTAssertTrue(settled, "warm capture should be running again after the coalesced refresh")
        XCTAssertEqual(
            platform.configureAndStartCallCount, 2,
            "a burst of refreshes must collapse into a single engine restart"
        )

        await recorder.setInstantDictationEnabled(false)
    }

    func testRefreshDebounceCancelledTaskLeavesStateUntouched() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true },
            warmCaptureRefreshDebounce: 0.1
        )

        await recorder.setInstantDictationEnabled(true)
        XCTAssertEqual(platform.configureAndStartCallCount, 1)

        let refreshTask = Task { await recorder.refreshInstantDictationWarmCapture() }
        refreshTask.cancel()
        await refreshTask.value

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            platform.configureAndStartCallCount, 1,
            "a cancelled debounced refresh must not restart the engine"
        )
        XCTAssertEqual(stream.diagnostics.subscriberCount, 1)
        XCTAssertTrue(stream.diagnostics.engineRunning)

        await recorder.setInstantDictationEnabled(false)
    }

    private func pollUntil(
        timeout: Duration,
        condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeFormat(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 2,
        interleaved: Bool = false
    ) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
        )
    }

    private func makeMonoFloatBuffer(
        frameCount: Int,
        sampleRate: Double = 16_000,
        sampleValue: Float = 0.25
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frameCount {
            samples[index] = sampleValue
        }
        return buffer
    }

    private func readFloatSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        )
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return (0..<Int(buffer.frameLength)).map { samples[$0] }
    }
}

private final class AudioRecorderBlockingPlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    private let lock = NSLock()
    private let hookLock = NSLock()
    private var _isRunning = false
    private var _configureAndStartCallCount = 0
    private var _tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var _configureAndStartHook: (@Sendable () -> Void)?

    var configureAndStartHook: (@Sendable () -> Void)? {
        get { hookLock.withLock { _configureAndStartHook } }
        set { hookLock.withLock { _configureAndStartHook = newValue } }
    }

    var isEngineRunning: Bool {
        lock.withLock { _isRunning }
    }

    var configureAndStartCallCount: Int {
        lock.withLock { _configureAndStartCallCount }
    }

    var inputFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    }

    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        configureAndStartHook?()
        lock.withLock {
            _configureAndStartCallCount += 1
            _isRunning = true
            _tapHandler = tapHandler
        }
    }

    func stopEngine() {
        lock.withLock {
            _isRunning = false
            _tapHandler = nil
        }
    }

    func deliverBuffer(_ buffer: AVAudioPCMBuffer) {
        let handler = lock.withLock { _tapHandler }
        handler?(buffer, AVAudioTime(hostTime: 1))
    }
}

/// Thread-safe tally for a `DictationAudioSampleSink`'s lifecycle callbacks,
/// which the recorder invokes from its actor.
private final class SampleSinkSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var finish = 0
    private var cancel = 0

    func recordFinish() { lock.withLock { finish += 1 } }
    func recordCancel() { lock.withLock { cancel += 1 } }

    var counts: (finish: Int, cancel: Int) {
        lock.withLock { (finish, cancel) }
    }
}
