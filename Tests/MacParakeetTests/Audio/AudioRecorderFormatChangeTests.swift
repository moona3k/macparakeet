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
