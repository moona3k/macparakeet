import AVFAudio
import XCTest
@testable import MacParakeetCore

private final class FactoryInvocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock {
            count += 1
        }
    }

    func get() -> Int {
        lock.withLock { count }
    }
}

private final class MutableDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func value() -> Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
        }
    }
}

private final class BlockingDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var shouldBlock = true

    func value() -> Date {
        let blocksThisCall = lock.withLock {
            guard shouldBlock else { return false }
            shouldBlock = false
            return true
        }
        if blocksThisCall {
            entered.signal()
            release.wait()
        }
        return Date(timeIntervalSince1970: 1_000)
    }

    func waitUntilBlocked() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 5)
    }

    func resume() {
        release.signal()
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.withLock { completed = true }
    }

    var isCompleted: Bool {
        lock.withLock { completed }
    }
}

private final class MeetingAudioTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEventSpec] = []

    func send(_ event: TelemetryEventSpec) {
        lock.withLock {
            events.append(event)
        }
    }

    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return true
    }

    func clearQueue() {
        lock.withLock {
            events.removeAll()
        }
    }

    func flush() async {}
    func flushForTermination() {}

    func snapshot() -> [TelemetryEventSpec] {
        lock.withLock { events }
    }
}

final class MeetingAudioCaptureServiceTests: XCTestCase {
    func testConcurrentStopWaitsForFailedStartCleanupOwner() async throws {
        let systemCapture = FailingStartBlockingStopCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { systemCapture }
        )
        let startTask = Task { try await service.start(sourceMode: .systemOnly) }
        await systemCapture.waitForStopCall()

        let completion = CompletionFlag()
        let stopTask = Task {
            await service.stop()
            completion.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completion.isCompleted)

        systemCapture.releaseStop()
        await stopTask.value
        XCTAssertTrue(completion.isCompleted)
        do {
            _ = try await startTask.value
            XCTFail("Expected failed system start")
        } catch MeetingAudioError.unsupportedPlatform {
            // Expected.
        }
    }

    func testSystemFailureDuringInitialStartCannotTransitionDeadCaptureToRunning() async {
        let systemCapture = FailureDuringStartSystemAudioCapture(
            failure: .systemAudioStreamStopped("stream died before start completed")
        )
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { systemCapture }
        )
        addTeardownBlock { await service.stop() }

        do {
            _ = try await service.start(sourceMode: .systemOnly)
            XCTFail("A source failure delivered during start must fail the start attempt")
        } catch let error as MeetingAudioError {
            guard case .systemAudioStreamStopped(let reason) = error else {
                return XCTFail("Expected typed stream-stop failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("before start completed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(systemCapture.stopCallCount, 1)
    }

    func testStopDuringMicrophoneStartSettlesBeforeReplacementStartOwnsCapture() async throws {
        let microphone = BlockingMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )

        let startTask = Task { try await service.start() }
        await microphone.waitForStartCall()

        let stopCompletion = CompletionFlag()
        let stopTask = Task {
            await service.stop()
            stopCompletion.markCompleted()
        }
        await microphone.waitForStopCall()
        XCTAssertEqual(microphone.stopCallCount, 1)
        XCTAssertEqual(systemCapture.startCallCount, 0)

        let replacementCompletion = CompletionFlag()
        let replacementBufferCount = FactoryInvocationBox()
        let replacementStart = Task {
            let report = try await service.start(sourceMode: .microphoneOnly) { event in
                if case .microphoneBuffer = event {
                    replacementBufferCount.increment()
                }
            }
            replacementCompletion.markCompleted()
            return report
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(stopCompletion.isCompleted)
        XCTAssertFalse(replacementCompletion.isCompleted)

        microphone.releaseStart()
        do {
            _ = try await startTask.value
            XCTFail("A stopped start attempt must not report success")
        } catch is CancellationError {
            // Expected.
        }

        await stopTask.value
        _ = try await replacementStart.value

        XCTAssertTrue(stopCompletion.isCompleted)
        XCTAssertTrue(replacementCompletion.isCompleted)
        XCTAssertTrue(microphone.isRunning)
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        microphone.emitActiveBuffer(buffer, time: AVAudioTime(hostTime: 0))
        XCTAssertEqual(replacementBufferCount.get(), 1)
        XCTAssertEqual(microphone.stopCallCount, 1)
        XCTAssertEqual(systemCapture.startCallCount, 0)

        await service.stop()
        XCTAssertEqual(microphone.stopCallCount, 2)
    }

    func testStreamStartWaitingForStopUsesReplacementSessionStream() async throws {
        let microphone = BlockingMeetingMicrophoneCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() }
        )

        _ = await service.events
        let firstStart = Task {
            try await service.start(sourceMode: .microphoneOnly)
        }
        await microphone.waitForStartCall()

        let stopTask = Task { await service.stop() }
        await microphone.waitForStopCall()

        let replacementEventsTask = Task { await service.events }
        let replacementStart = Task {
            try await service.start(sourceMode: .microphoneOnly)
        }

        microphone.releaseStart()
        do {
            _ = try await firstStart.value
            XCTFail("A stopped start attempt must not report success")
        } catch is CancellationError {
            // Expected.
        }
        await stopTask.value

        let replacementEvents = await replacementEventsTask.value
        _ = try await replacementStart.value
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        microphone.emitActiveBuffer(buffer, time: AVAudioTime(hostTime: 1))

        var iterator = replacementEvents.makeAsyncIterator()
        guard case .microphoneBuffer? = await iterator.next() else {
            await service.stop()
            return XCTFail("Replacement capture must publish into its own live event stream")
        }

        await service.stop()
    }

    func testRetiredSessionCallbacksCannotEmitIntoReplacementSession() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let dateProvider = BlockingDateProvider()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            micHealthNowProvider: { dateProvider.value() },
            micHealthFeatureEnabled: true
        )
        addTeardownBlock {
            await service.stop()
        }
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        let sendableBuffer = UncheckedSendableAudioPCMBuffer(buffer)

        _ = try await service.start { _ in }
        let retiredMicrophoneCallbacks = try XCTUnwrap(
            microphone.retainedCallbacks(forStartAt: 0)
        )

        let oldSystemCallbackFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            systemCapture.emit(buffer: sendableBuffer.buffer, time: AVAudioTime(hostTime: 1))
            oldSystemCallbackFinished.signal()
        }
        XCTAssertEqual(
            dateProvider.waitUntilBlocked(),
            .success,
            "the old system callback should pause after its final generation check"
        )

        await service.stop()

        let replacementMicrophoneBuffers = FactoryInvocationBox()
        let replacementSystemBuffers = FactoryInvocationBox()
        let replacementErrors = FactoryInvocationBox()
        _ = try await service.start { event in
            switch event {
            case .microphoneBuffer:
                replacementMicrophoneBuffers.increment()
            case .systemBuffer:
                replacementSystemBuffers.increment()
            case .sourceInterrupted, .error:
                replacementErrors.increment()
            default:
                break
            }
        }

        retiredMicrophoneCallbacks.handler(buffer, AVAudioTime(hostTime: 2))
        retiredMicrophoneCallbacks.stallObserver?(
            .captureRuntimeFailure("retired microphone callback")
        )
        dateProvider.resume()
        XCTAssertEqual(
            oldSystemCallbackFinished.wait(timeout: .now() + 5),
            .success
        )

        XCTAssertEqual(replacementMicrophoneBuffers.get(), 0)
        XCTAssertEqual(replacementSystemBuffers.get(), 0)
        XCTAssertEqual(replacementErrors.get(), 0)
    }

    func testStopDuringSystemStartStopsBothSourcesAndLateStartCannotRevive() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = BlockingMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )

        let startTask = Task { try await service.start() }
        await systemCapture.waitForStartCall()

        let stopCompletion = CompletionFlag()
        let stopTask = Task {
            await service.stop()
            stopCompletion.markCompleted()
        }
        await systemCapture.waitForStopCall()
        XCTAssertEqual(microphone.stopCallCount, 1)
        XCTAssertEqual(systemCapture.stopCallCount, 1)
        XCTAssertFalse(stopCompletion.isCompleted)

        systemCapture.releaseStart()
        do {
            _ = try await startTask.value
            XCTFail("A stopped start attempt must not report success")
        } catch is CancellationError {
            // Expected.
        }
        await stopTask.value
        XCTAssertTrue(stopCompletion.isCompleted)

        let secondStart = Task { try await service.start() }
        await systemCapture.waitForStartCall(count: 2)
        systemCapture.releaseStart()
        _ = try await secondStart.value
        await service.stop()
    }

    func testSecondStartIsRejectedWhileFirstAttemptOwnsService() async throws {
        let microphone = BlockingMeetingMicrophoneCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() }
        )

        let firstStart = Task { try await service.start() }
        await microphone.waitForStartCall()

        do {
            _ = try await service.start()
            XCTFail("Expected alreadyRunning while start is in flight")
        } catch let error as MeetingAudioError {
            guard case .alreadyRunning = error else {
                return XCTFail("Expected alreadyRunning, got \(error)")
            }
        }

        let stopCompletion = CompletionFlag()
        let stopTask = Task {
            await service.stop()
            stopCompletion.markCompleted()
        }
        await microphone.waitForStopCall()
        XCTAssertFalse(stopCompletion.isCompleted)
        microphone.releaseStart()
        _ = try? await firstStart.value
        await stopTask.value
        XCTAssertTrue(stopCompletion.isCompleted)
    }

    func testFactoryInitUsesInjectedMicrophoneFactory() {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let invocationCount = FactoryInvocationBox()

        _ = MeetingAudioCaptureService(
            microphoneCaptureFactory: {
                invocationCount.increment()
                return microphone
            },
            systemAudioCaptureFactory: { systemCapture }
        )

        XCTAssertEqual(invocationCount.get(), 1)
    }

    func testDefaultMicProcessingModeRequestsRawCapture() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )

        _ = try await service.start()
        await service.stop()

        XCTAssertEqual(microphone.requestedModes, [.raw])
    }

    func testStartHandlerCopiesInterleavedMicrophoneBuffersIntoUsablePCM() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )

        let capturedBuffer = CapturedPCMBuffer()
        _ = try await service.start { event in
            guard case let .microphoneBuffer(buffer, _) = event else { return }
            Task {
                await capturedBuffer.store(buffer)
            }
        }
        defer { Task { await service.stop() } }

        let interleaved = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [
                1.0, 0.0,
                0.0, 1.0,
                -1.0, 1.0,
                0.5, -0.5,
            ]))
        microphone.emit(buffer: interleaved, time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1.0)))

        var copiedBuffer: AVAudioPCMBuffer?
        for _ in 0..<20 {
            copiedBuffer = await capturedBuffer.value()
            if copiedBuffer != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let buffer = try XCTUnwrap(copiedBuffer)
        let samples = try XCTUnwrap(AudioChunker.extractSamples(from: buffer))

        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[3], 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(buffer.rmsLevel, 0)
    }

    func testEventsStreamRetainsBurstSystemAudioBuffersWithoutDropping() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )

        let events = await service.events
        _ = try await service.start()

        let burstBuffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(
                sampleRate: 48_000,
                samples: [Float](repeating: 0.25, count: 96)
            ))

        for _ in 0..<2_100 {
            systemCapture.emit(buffer: burstBuffer, time: AVAudioTime(hostTime: 1))
        }

        try await Task.sleep(for: .milliseconds(150))
        await service.stop()

        var systemBufferCount = 0
        for await event in events {
            if case .systemBuffer = event {
                systemBufferCount += 1
            }
        }

        XCTAssertEqual(systemBufferCount, 2_100)
    }

    func testSystemOnlyModeStartsSystemCaptureWithoutMicrophone() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            sourceModeProvider: { .systemOnly }
        )

        let capturedEvents = CapturedMeetingCaptureEvents()
        let report = try await service.start { event in
            Task {
                await capturedEvents.append(event)
            }
        }
        defer { Task { await service.stop() } }

        XCTAssertEqual(report.sourceMode, .systemOnly)
        XCTAssertFalse(report.microphoneStarted)
        XCTAssertTrue(microphone.requestedModes.isEmpty)
        XCTAssertEqual(systemCapture.startCallCount, 1)

        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(
                sampleRate: 48_000,
                samples: [0.25, 0.25, 0.25, 0.25]
            ))
        microphone.emit(buffer: buffer, time: AVAudioTime(hostTime: 1))
        systemCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 1))

        for _ in 0..<20 {
            let events = await capturedEvents.values()
            if events.systemBufferCount == 1 {
                XCTAssertEqual(events.microphoneBufferCount, 0)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for system-only capture events")
    }

    func testMicrophoneOnlyModeStartsMicrophoneWithoutSystemCapture() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemFactoryCallCount = FactoryInvocationBox()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: {
                systemFactoryCallCount.increment()
                throw MeetingAudioError.unsupportedPlatform
            },
            sourceModeProvider: { .microphoneOnly }
        )

        let capturedEvents = CapturedMeetingCaptureEvents()
        let report = try await service.start { event in
            Task {
                await capturedEvents.append(event)
            }
        }
        defer { Task { await service.stop() } }

        XCTAssertEqual(report.sourceMode, .microphoneOnly)
        XCTAssertTrue(report.microphoneStarted)
        XCTAssertEqual(microphone.requestedModes, [.raw])
        XCTAssertEqual(systemFactoryCallCount.get(), 0)

        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(
                sampleRate: 48_000,
                samples: [0.25, 0.25, 0.25, 0.25]
            ))
        microphone.emit(buffer: buffer, time: AVAudioTime(hostTime: 1))

        for _ in 0..<20 {
            let events = await capturedEvents.values()
            if events.microphoneBufferCount == 1 {
                XCTAssertEqual(events.systemBufferCount, 0)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for microphone-only capture events")
    }

    func testMicHealthTelemetryReportsMissingMicOnce() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let telemetry = MeetingAudioTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let now = MutableDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            micHealthConfig: .init(systemActiveConfirmationSeconds: 0),
            micHealthNowProvider: { now.value() }
        )

        _ = try await service.start()
        defer { Task { await service.stop() } }

        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(
                sampleRate: 48_000,
                samples: [0.25, 0.25, 0.25, 0.25]
            ))
        systemCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 1))
        now.advance(by: 5)
        systemCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 2))

        let events = telemetry.snapshot().filter { $0.name == .micStallDetected }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.props?["signature"], "mic_missing")
        XCTAssertEqual(events.first?.props?["elapsed_ms"], "0")
        XCTAssertEqual(events.first?.props?["stall_count"], "1")
    }

    func testMicHealthTelemetryReportsFlappingSilentMicOnce() async throws {
        // A listening (not speaking) participant produces a near-silent mic that
        // momentarily crosses the non-silent threshold and back — the monitor
        // recovers and re-trips `.micSilent` on every crossing. Without per-recording
        // dedup this single recording emits hundreds of identical events (the field
        // firehose: ~38k events from ~240 sessions). It must emit exactly once.
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let telemetry = MeetingAudioTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let now = MutableDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            micHealthConfig: .init(systemActiveConfirmationSeconds: 0),
            micHealthNowProvider: { now.value() }
        )

        _ = try await service.start()

        let silent = try XCTUnwrap(makeInterleavedFloatStereoBuffer(samples: [0, 0, 0, 0]))
        let loud = try XCTUnwrap(makeInterleavedFloatStereoBuffer(samples: [0.25, 0.25, 0.25, 0.25]))

        // Mic delivers a silent buffer first (so the confirmed signature is mic_silent,
        // not mic_missing), then system audio goes active and confirms the stall.
        microphone.emit(buffer: silent, time: AVAudioTime(hostTime: 1))
        systemCapture.emit(buffer: loud, time: AVAudioTime(hostTime: 1))

        // Flap silent<->non-silent many times: each cycle recovers then re-trips
        // `.micSilent`. Dedup must collapse all of these to the single first event.
        for _ in 0..<10 {
            microphone.emit(buffer: loud, time: AVAudioTime(hostTime: 1))
            microphone.emit(buffer: silent, time: AVAudioTime(hostTime: 1))
        }

        let events = telemetry.snapshot().filter { $0.name == .micStallDetected }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.props?["signature"], "mic_silent")
        XCTAssertEqual(events.first?.props?["stall_count"], "1")
        XCTAssertNil(events.first?.props?["total_stalled_seconds"])

        await service.stop()

        let stoppedEvents = telemetry.snapshot().filter { $0.name == .micStallDetected }
        XCTAssertEqual(stoppedEvents.count, 2)
        let summary = try XCTUnwrap(stoppedEvents.last)
        XCTAssertNil(summary.props?["signature"])
        XCTAssertNil(summary.props?["elapsed_ms"])
        XCTAssertNotNil(summary.props?["total_stalled_seconds"])
        XCTAssertGreaterThan(Int(summary.props?["stall_count"] ?? "0") ?? 0, 1)
    }

    func testMicHealthTelemetryDoesNotRunInSystemOnlyMode() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let telemetry = MeetingAudioTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            sourceModeProvider: { .systemOnly },
            micHealthConfig: .init(systemActiveConfirmationSeconds: 0)
        )

        _ = try await service.start()
        defer { Task { await service.stop() } }

        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(
                sampleRate: 48_000,
                samples: [0.25, 0.25, 0.25, 0.25]
            ))
        systemCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 1))

        XCTAssertFalse(telemetry.snapshot().contains { $0.name == .micStallDetected })
    }

    func testMicHealthTelemetryRespectsKillSwitch() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let telemetry = MeetingAudioTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            micHealthConfig: .init(systemActiveConfirmationSeconds: 0),
            micHealthFeatureEnabled: false
        )

        _ = try await service.start()
        defer { Task { await service.stop() } }

        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(
                sampleRate: 48_000,
                samples: [0.25, 0.25, 0.25, 0.25]
            ))
        systemCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 1))

        XCTAssertFalse(telemetry.snapshot().contains { $0.name == .micStallDetected })
    }

    func testEmitsSourceInterruptedWhenMicrophoneStallsInDualSourceMode() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        microphone.emitStall(
            .captureRuntimeFailure("microphone capture started but delivered no buffers within 2 seconds"))

        var iterator = events.makeAsyncIterator()
        let emitted = await iterator.next()
        guard case let .sourceInterrupted(source, error)? = emitted else {
            XCTFail("Expected .sourceInterrupted event, got \(String(describing: emitted))")
            return
        }
        XCTAssertEqual(source, .microphone)
        guard case .captureRuntimeFailure(let message) = error else {
            XCTFail("Expected captureRuntimeFailure, got \(error)")
            return
        }
        XCTAssertTrue(message.contains("microphone capture started"))
    }

    func testEmitsRuntimeErrorWhenMicrophoneStallsInMicrophoneOnlyMode() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() },
            sourceModeProvider: { .microphoneOnly }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        microphone.emitStall(
            .captureRuntimeFailure("microphone capture started but delivered no buffers within 2 seconds")
        )

        var iterator = events.makeAsyncIterator()
        let emitted = await iterator.next()
        guard case let .error(error)? = emitted else {
            XCTFail("Expected .error event, got \(String(describing: emitted))")
            return
        }
        guard case .captureRuntimeFailure(let message) = error else {
            XCTFail("Expected captureRuntimeFailure, got \(error)")
            return
        }
        XCTAssertTrue(message.contains("microphone capture started"))
    }

    func testStartReturnsVPIOSuccessReportWhenAvailable() async throws {
        let microphone = MockMeetingMicrophoneCapture(
            startHandler: { mode in
                XCTAssertEqual(mode, .vpioPreferred)
                return MeetingMicrophoneCaptureStartReport(
                    requestedMode: .vpioPreferred,
                    effectiveMode: .vpio
                )
            }
        )
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() },
            micProcessingMode: .vpioPreferred
        )

        let report = try await service.start()
        await service.stop()

        XCTAssertEqual(report.microphone.requestedMode, .vpioPreferred)
        XCTAssertEqual(report.microphone.effectiveMode, .vpio)
        XCTAssertEqual(microphone.requestedModes, [.vpioPreferred])
    }

    func testStartReturnsRawFallbackReportForVPIOPreferredFailure() async throws {
        let microphone = MockMeetingMicrophoneCapture(
            startHandler: { mode in
                XCTAssertEqual(mode, .vpioPreferred)
                return MeetingMicrophoneCaptureStartReport(
                    requestedMode: .vpioPreferred,
                    effectiveMode: .raw
                )
            }
        )
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() },
            micProcessingMode: .vpioPreferred
        )

        let report = try await service.start()
        await service.stop()

        XCTAssertTrue(report.microphone.fellBackToRaw)
        XCTAssertEqual(report.microphone.effectiveMode, .raw)
    }

    func testStartThrowsWhenVPIOIsRequiredAndUnavailable() async {
        let microphone = MockMeetingMicrophoneCapture(
            startHandler: { mode in
                XCTAssertEqual(mode, .vpioRequired)
                throw MeetingAudioError.microphoneProcessingUnavailable(
                    mode: .vpioRequired,
                    reason: "simulated failure"
                )
            }
        )
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() },
            micProcessingMode: .vpioRequired
        )

        do {
            _ = try await service.start()
            XCTFail("Expected start to throw")
        } catch let error as MeetingAudioError {
            guard case .microphoneProcessingUnavailable(let mode, _) = error else {
                XCTFail("Expected microphoneProcessingUnavailable, got \(error)")
                return
            }
            XCTAssertEqual(mode, .vpioRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmitsRuntimeErrorEventWhenMicrophoneBufferCopyFails() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        let invalidBuffer = try XCTUnwrap(makeInterleavedFloat64StereoBuffer(samples: [0.5, 0.5]))
        microphone.emit(buffer: invalidBuffer, time: AVAudioTime(hostTime: 1))

        var iterator = events.makeAsyncIterator()
        let emitted = await iterator.next()
        guard case let .error(error)? = emitted else {
            XCTFail("Expected runtime error event, got \(String(describing: emitted))")
            return
        }

        guard case .captureRuntimeFailure = error else {
            XCTFail("Expected captureRuntimeFailure, got \(error)")
            return
        }
    }

    func testEmitsRuntimeErrorEventWhenNonInterleavedMicrophoneBufferCopyFails() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        let invalidBuffer = try XCTUnwrap(makeNonInterleavedFloat64MonoBuffer(frames: 4))
        microphone.emit(buffer: invalidBuffer, time: AVAudioTime(hostTime: 1))

        var iterator = events.makeAsyncIterator()
        let emitted = await iterator.next()
        guard case let .error(error)? = emitted else {
            XCTFail("Expected runtime error event, got \(String(describing: emitted))")
            return
        }

        guard case .captureRuntimeFailure = error else {
            XCTFail("Expected captureRuntimeFailure, got \(error)")
            return
        }
    }

    func testEmitsSourceInterruptedForNonRecoverableSystemFailureInDualSourceMode() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        systemCapture.emitStall(.captureRuntimeFailure("system audio capture stopped unexpectedly"))

        var iterator = events.makeAsyncIterator()
        let emitted = await iterator.next()
        guard case let .sourceInterrupted(source, error)? = emitted else {
            XCTFail("Expected .sourceInterrupted event, got \(String(describing: emitted))")
            return
        }
        XCTAssertEqual(source, .system)
        guard case .captureRuntimeFailure(let message) = error else {
            XCTFail("Expected captureRuntimeFailure, got \(error)")
            return
        }
        XCTAssertTrue(message.contains("stopped unexpectedly"))
    }

    func testRecoversSystemCaptureWithFreshInstanceAndDeliversReplacementBuffer() async throws {
        let recoveryStarted = expectation(description: "system recovery starts")
        let replacementStarted = expectation(description: "replacement system capture starts")
        let replacementBufferDelivered = expectation(description: "replacement buffer is delivered")
        let sourceRecovered = expectation(description: "system source recovers")
        let terminalInterruption = expectation(description: "system source is not terminally interrupted")
        terminalInterruption.isInverted = true
        let microphone = MockMeetingMicrophoneCapture()
        let stalledCapture = MockMeetingSystemAudioCapture()
        let replacementCapture = MockMeetingSystemAudioCapture(
            startExpectation: replacementStarted
        )
        let captures = SystemAudioCaptureFactorySequence([stalledCapture, replacementCapture])
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero]
        )
        addTeardownBlock {
            await service.stop()
        }

        _ = try await service.start { event in
            switch event {
            case .sourceRecoveryStarted(source: .system, error: .systemAudioStalled):
                recoveryStarted.fulfill()
            case .systemBuffer:
                replacementBufferDelivered.fulfill()
            case .sourceRecovered(source: .system):
                sourceRecovered.fulfill()
            case .sourceInterrupted(source: .system, error: _):
                terminalInterruption.fulfill()
            default:
                break
            }
        }
        stalledCapture.emitStall(
            .systemAudioStalled(.bufferGap(seconds: 6))
        )

        await fulfillment(
            of: [recoveryStarted, replacementStarted],
            timeout: 1.0,
            enforceOrder: true
        )
        let buffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25]))
        replacementCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 42))
        await fulfillment(
            of: [replacementBufferDelivered, sourceRecovered],
            timeout: 1.0,
            enforceOrder: true
        )
        await fulfillment(of: [terminalInterruption], timeout: 0.02)

        XCTAssertEqual(captures.makeCallCount, 2)
        XCTAssertEqual(stalledCapture.startCallCount, 1)
        XCTAssertEqual(stalledCapture.stopCallCount, 1)
        XCTAssertEqual(replacementCapture.startCallCount, 1)
        XCTAssertEqual(microphone.stopCallCount, 0)
    }

    func testUnexpectedSystemStreamStopUsesFreshCaptureRecovery() async throws {
        let replacementStarted = expectation(description: "replacement system capture starts")
        let sourceRecovered = expectation(description: "system source recovers")
        let stalledCapture = MockMeetingSystemAudioCapture()
        let replacementCapture = MockMeetingSystemAudioCapture(
            startExpectation: replacementStarted
        )
        let captures = SystemAudioCaptureFactorySequence([stalledCapture, replacementCapture])
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero]
        )
        addTeardownBlock { await service.stop() }

        _ = try await service.start { event in
            if case .sourceRecovered(source: .system) = event {
                sourceRecovered.fulfill()
            }
        }
        stalledCapture.emitStall(
            .systemAudioStreamStopped("ScreenCaptureKit stopped the stream")
        )

        await fulfillment(of: [replacementStarted], timeout: 1.0)
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        replacementCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 43))
        await fulfillment(of: [sourceRecovered], timeout: 1.0)

        XCTAssertEqual(captures.makeCallCount, 2)
        XCTAssertEqual(stalledCapture.stopCallCount, 1)
        XCTAssertEqual(replacementCapture.startCallCount, 1)
    }

    func testNonRecoverableSystemFailureRetiresGenerationBeforeAwaitingStop() async throws {
        let terminalInterruption = expectation(description: "terminal system interruption")
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = BlockingStopMeetingSystemAudioCapture()
        let systemBufferCount = FactoryInvocationBox()
        let terminalCount = FactoryInvocationBox()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )
        addTeardownBlock { await service.stop() }

        _ = try await service.start { event in
            switch event {
            case .systemBuffer:
                systemBufferCount.increment()
            case .sourceInterrupted(source: .system, error: _):
                terminalCount.increment()
                terminalInterruption.fulfill()
            default:
                break
            }
        }
        let retiredCallbacks = try XCTUnwrap(systemCapture.retainedCallbacks)
        systemCapture.emitStall(
            .captureRuntimeFailure("system audio capture stopped unexpectedly")
        )

        for _ in 0..<20 where systemCapture.stopCallCount == 0 && terminalCount.get() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(systemCapture.stopCallCount, 1)
        XCTAssertEqual(terminalCount.get(), 0, "terminal publication must await capture teardown")

        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        retiredCallbacks.handler(buffer, AVAudioTime(hostTime: 44))
        retiredCallbacks.stallObserver?(
            .captureRuntimeFailure("late retired callback")
        )
        systemCapture.releaseStop()

        await fulfillment(of: [terminalInterruption], timeout: 1.0)
        XCTAssertEqual(systemBufferCount.get(), 0)
        XCTAssertEqual(terminalCount.get(), 1)
        XCTAssertEqual(systemCapture.stopCallCount, 1)
        XCTAssertEqual(microphone.stopCallCount, 0)
    }

    func testRecoveryRetriesFailureDeliveredAfterReplacementFirstBuffer() async throws {
        let firstReplacementStarted = expectation(description: "first replacement starts")
        let secondReplacementStarted = expectation(description: "second replacement starts")
        let sourceRecovered = expectation(description: "second replacement recovers")
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        let stalledCapture = MockMeetingSystemAudioCapture()
        let firstReplacement = FirstBufferThenFailureSystemAudioCapture(
            buffer: buffer,
            failure: .systemAudioStalled(.bufferGap(seconds: 6)),
            startExpectation: firstReplacementStarted
        )
        let secondReplacement = MockMeetingSystemAudioCapture(
            startExpectation: secondReplacementStarted
        )
        let captures = SystemAudioCaptureFactorySequence([
            stalledCapture,
            firstReplacement,
            secondReplacement,
        ])
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero, .zero]
        )
        addTeardownBlock { await service.stop() }

        _ = try await service.start { event in
            if case .sourceRecovered(source: .system) = event {
                sourceRecovered.fulfill()
            }
        }
        stalledCapture.emitStall(.systemAudioStalled(.bufferGap(seconds: 6)))

        await fulfillment(
            of: [firstReplacementStarted, secondReplacementStarted],
            timeout: 1.0,
            enforceOrder: true
        )
        secondReplacement.emit(buffer: buffer, time: AVAudioTime(hostTime: 2))
        await fulfillment(of: [sourceRecovered], timeout: 1.0)

        XCTAssertEqual(firstReplacement.stopCallCount, 1)
        XCTAssertEqual(secondReplacement.startCallCount, 1)
    }

    func testRecoveryTerminatesWhenReplacementReportsNonRecoverableFailureAfterFirstBuffer() async throws {
        let firstReplacementStarted = expectation(description: "first replacement starts")
        let secondReplacementStarted = expectation(description: "second replacement does not start")
        secondReplacementStarted.isInverted = true
        let terminalInterruption = expectation(description: "system interruption is terminal")
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        let stalledCapture = MockMeetingSystemAudioCapture()
        let firstReplacement = FirstBufferThenFailureSystemAudioCapture(
            buffer: buffer,
            failure: .captureRuntimeFailure("replacement failed permanently"),
            startExpectation: firstReplacementStarted
        )
        let secondReplacement = MockMeetingSystemAudioCapture(
            startExpectation: secondReplacementStarted
        )
        let captures = SystemAudioCaptureFactorySequence([
            stalledCapture,
            firstReplacement,
            secondReplacement,
        ])
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero, .zero]
        )
        addTeardownBlock { await service.stop() }

        _ = try await service.start { event in
            if case .sourceInterrupted(source: .system, error: .captureRuntimeFailure) = event {
                terminalInterruption.fulfill()
            }
        }
        stalledCapture.emitStall(.systemAudioStalled(.bufferGap(seconds: 6)))

        await fulfillment(
            of: [firstReplacementStarted, terminalInterruption],
            timeout: 1.0,
            enforceOrder: true
        )
        await fulfillment(of: [secondReplacementStarted], timeout: 0.02)

        XCTAssertEqual(captures.makeCallCount, 2)
        XCTAssertEqual(firstReplacement.stopCallCount, 1)
        XCTAssertEqual(secondReplacement.startCallCount, 0)
    }

    func testRetriesWhenReplacementStartsButStallsBeforeFirstBuffer() async throws {
        let recoveryStarted = expectation(description: "system recovery starts")
        let silentReplacementStarted = expectation(description: "silent replacement starts")
        let readyReplacementStarted = expectation(description: "fresh replacement starts")
        let sourceRecovered = expectation(description: "fresh replacement becomes ready")
        let terminalInterruption = expectation(description: "system source is not terminally interrupted")
        terminalInterruption.isInverted = true
        let stalledCapture = MockMeetingSystemAudioCapture()
        let silentReplacement = MockMeetingSystemAudioCapture(
            startExpectation: silentReplacementStarted
        )
        let readyReplacement = MockMeetingSystemAudioCapture(
            startExpectation: readyReplacementStarted
        )
        let captures = SystemAudioCaptureFactorySequence([
            stalledCapture,
            silentReplacement,
            readyReplacement,
        ])
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero, .zero]
        )
        addTeardownBlock {
            await service.stop()
        }

        _ = try await service.start(sourceMode: .systemOnly) { event in
            switch event {
            case .sourceRecoveryStarted(source: .system, error: _):
                recoveryStarted.fulfill()
            case .sourceRecovered(source: .system):
                sourceRecovered.fulfill()
            case .error:
                terminalInterruption.fulfill()
            default:
                break
            }
        }
        stalledCapture.emitStall(.systemAudioStalled(.bufferGap(seconds: 6)))
        await fulfillment(
            of: [recoveryStarted, silentReplacementStarted],
            timeout: 1,
            enforceOrder: true
        )

        silentReplacement.emitStall(
            .systemAudioStalled(.firstBufferTimeout(seconds: 2))
        )
        await fulfillment(of: [readyReplacementStarted], timeout: 1)
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        readyReplacement.emit(buffer: buffer, time: AVAudioTime(hostTime: 44))

        await fulfillment(of: [sourceRecovered], timeout: 1)
        await fulfillment(of: [terminalInterruption], timeout: 0.02)
        XCTAssertEqual(captures.makeCallCount, 3)
        XCTAssertEqual(stalledCapture.stopCallCount, 1)
        XCTAssertEqual(silentReplacement.stopCallCount, 1)
        XCTAssertEqual(readyReplacement.stopCallCount, 0)
    }

    func testEmitsTerminalSystemInterruptionOnlyAfterRecoveryAttemptsAreExhausted() async throws {
        let recoveryStarted = expectation(description: "system recovery starts")
        let firstAttemptStarted = expectation(description: "first recovery attempt starts")
        let secondAttemptStarted = expectation(description: "second recovery attempt starts")
        let terminalInterruption = expectation(description: "terminal interruption is emitted")
        let sourceRecovered = expectation(description: "system source does not recover")
        sourceRecovered.isInverted = true

        let microphone = MockMeetingMicrophoneCapture()
        let stalledCapture = MockMeetingSystemAudioCapture()
        let firstFailedCapture = MockMeetingSystemAudioCapture(
            startExpectation: firstAttemptStarted,
            startError: .systemAudioCaptureFailed("route is still changing")
        )
        let secondFailedCapture = MockMeetingSystemAudioCapture(
            startExpectation: secondAttemptStarted,
            startError: .systemAudioCaptureFailed("route is still changing")
        )
        let captures = SystemAudioCaptureFactorySequence([
            stalledCapture,
            firstFailedCapture,
            secondFailedCapture,
        ])
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero, .zero]
        )
        addTeardownBlock {
            await service.stop()
        }

        _ = try await service.start { event in
            switch event {
            case .sourceRecoveryStarted(source: .system, error: .systemAudioStalled):
                recoveryStarted.fulfill()
            case .sourceRecovered(source: .system):
                sourceRecovered.fulfill()
            case .sourceInterrupted(source: .system, error: .systemAudioStalled):
                terminalInterruption.fulfill()
            default:
                break
            }
        }
        stalledCapture.emitStall(.systemAudioStalled(.bufferGap(seconds: 6)))

        await fulfillment(
            of: [
                recoveryStarted,
                firstAttemptStarted,
                secondAttemptStarted,
                terminalInterruption,
            ],
            timeout: 1.0,
            enforceOrder: true
        )
        await fulfillment(of: [sourceRecovered], timeout: 0.02)

        XCTAssertEqual(captures.makeCallCount, 3)
        XCTAssertEqual(stalledCapture.stopCallCount, 1)
        XCTAssertEqual(firstFailedCapture.stopCallCount, 1)
        XCTAssertEqual(secondFailedCapture.stopCallCount, 1)
        XCTAssertEqual(microphone.stopCallCount, 0)
    }

    func testCoalescesDuplicateSystemStallSignalsIntoOneRecovery() async throws {
        let recoveryStarted = expectation(description: "one system recovery starts")
        recoveryStarted.assertForOverFulfill = true
        let replacementStarted = expectation(description: "one replacement starts")
        replacementStarted.assertForOverFulfill = true
        let sourceRecovered = expectation(description: "system source recovers")
        sourceRecovered.assertForOverFulfill = true

        let stalledCapture = MockMeetingSystemAudioCapture()
        let replacementCapture = MockMeetingSystemAudioCapture(
            startExpectation: replacementStarted
        )
        let captures = SystemAudioCaptureFactorySequence([stalledCapture, replacementCapture])
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero]
        )
        addTeardownBlock {
            await service.stop()
        }

        _ = try await service.start { event in
            switch event {
            case .sourceRecoveryStarted(source: .system, error: _):
                recoveryStarted.fulfill()
            case .sourceRecovered(source: .system):
                sourceRecovered.fulfill()
            default:
                break
            }
        }
        let stall = MeetingAudioError.systemAudioStalled(.bufferGap(seconds: 6))
        stalledCapture.emitStall(stall)
        stalledCapture.emitStall(stall)

        await fulfillment(
            of: [recoveryStarted, replacementStarted],
            timeout: 1.0,
            enforceOrder: true
        )
        let buffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25]))
        replacementCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 43))
        await fulfillment(of: [sourceRecovered], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(captures.makeCallCount, 2)
        XCTAssertEqual(stalledCapture.stopCallCount, 1)
        XCTAssertEqual(replacementCapture.startCallCount, 1)
    }

    func testStopDuringSystemRecoveryPreventsLateReplacementRevival() async throws {
        let recoveryStarted = expectation(description: "system recovery starts")
        let sourceRecovered = expectation(description: "stopped source does not recover")
        sourceRecovered.isInverted = true
        let terminalInterruption = expectation(description: "stopped source is not terminally interrupted")
        terminalInterruption.isInverted = true

        let microphone = MockMeetingMicrophoneCapture()
        let stalledCapture = MockMeetingSystemAudioCapture()
        let blockingReplacement = BlockingMeetingSystemAudioCapture()
        let nextSessionCapture = MockMeetingSystemAudioCapture()
        let captures = SystemAudioCaptureFactorySequence([
            stalledCapture,
            blockingReplacement,
            nextSessionCapture,
        ])
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero]
        )

        _ = try await service.start { event in
            switch event {
            case .sourceRecoveryStarted(source: .system, error: _):
                recoveryStarted.fulfill()
            case .sourceRecovered(source: .system):
                sourceRecovered.fulfill()
            case .sourceInterrupted(source: .system, error: _):
                terminalInterruption.fulfill()
            default:
                break
            }
        }

        stalledCapture.emitStall(.systemAudioStalled(.bufferGap(seconds: 6)))
        await fulfillment(of: [recoveryStarted], timeout: 1.0)
        await blockingReplacement.waitForStartCall()

        let completion = CompletionFlag()
        let stopTask = Task {
            await service.stop()
            completion.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completion.isCompleted)

        blockingReplacement.releaseStart()
        await stopTask.value
        XCTAssertTrue(completion.isCompleted)
        await fulfillment(of: [sourceRecovered, terminalInterruption], timeout: 0.02)

        XCTAssertEqual(stalledCapture.stopCallCount, 1)
        XCTAssertEqual(blockingReplacement.stopCallCount, 1)
        XCTAssertEqual(microphone.stopCallCount, 1)

        _ = try await service.start(sourceMode: .systemOnly)
        XCTAssertEqual(captures.makeCallCount, 3)
        XCTAssertEqual(nextSessionCapture.startCallCount, 1)
        await service.stop()
    }

    func testStopWhileRecoveryWaitsForFirstBufferRetiresReplacementCallbacks() async throws {
        let recoveryStarted = expectation(description: "system recovery starts")
        let replacementStarted = expectation(description: "replacement starts")
        let stalledCapture = MockMeetingSystemAudioCapture()
        let waitingReplacement = MockMeetingSystemAudioCapture(
            startExpectation: replacementStarted
        )
        let nextSessionCapture = MockMeetingSystemAudioCapture()
        let captures = SystemAudioCaptureFactorySequence([
            stalledCapture,
            waitingReplacement,
            nextSessionCapture,
        ])
        let retiredSessionEvents = FactoryInvocationBox()
        let nextSessionBuffers = FactoryInvocationBox()
        let service = MeetingAudioCaptureService(
            microphoneCapture: MockMeetingMicrophoneCapture(),
            systemAudioCaptureFactory: { try captures.make() },
            systemAudioRecoveryDelays: [.zero]
        )

        _ = try await service.start(sourceMode: .systemOnly) { event in
            switch event {
            case .sourceRecoveryStarted(source: .system, error: _):
                recoveryStarted.fulfill()
            case .sourceRecovered, .sourceInterrupted, .error:
                retiredSessionEvents.increment()
            default:
                break
            }
        }
        stalledCapture.emitStall(.systemAudioStalled(.bufferGap(seconds: 6)))
        await fulfillment(
            of: [recoveryStarted, replacementStarted],
            timeout: 1,
            enforceOrder: true
        )
        let retiredCallbacks = try XCTUnwrap(waitingReplacement.retainedCallbacks(forStartAt: 0))

        await service.stop()
        XCTAssertEqual(waitingReplacement.stopCallCount, 1)
        XCTAssertEqual(retiredSessionEvents.get(), 0)

        _ = try await service.start(sourceMode: .systemOnly) { event in
            if case .systemBuffer = event {
                nextSessionBuffers.increment()
            }
        }
        let buffer = try XCTUnwrap(
            makeInterleavedFloatStereoBuffer(samples: [0.25, -0.25])
        )
        retiredCallbacks.handler(buffer, AVAudioTime(hostTime: 45))
        retiredCallbacks.stallObserver?(
            .systemAudioStalled(.firstBufferTimeout(seconds: 2))
        )
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(retiredSessionEvents.get(), 0)
        XCTAssertEqual(nextSessionBuffers.get(), 0)
        nextSessionCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 46))
        XCTAssertEqual(nextSessionBuffers.get(), 1)
        XCTAssertEqual(captures.makeCallCount, 3)
        await service.stop()
    }

    func testEmitsRuntimeErrorForNonRecoverableSystemFailureInSystemOnlyMode() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            sourceModeProvider: { .systemOnly }
        )
        addTeardownBlock {
            await service.stop()
        }

        let events = await service.events
        _ = try await service.start()
        systemCapture.emitStall(.captureRuntimeFailure("system audio capture stopped unexpectedly"))

        var iterator = events.makeAsyncIterator()
        let emitted = await iterator.next()
        guard case let .error(error)? = emitted else {
            XCTFail("Expected .error event, got \(String(describing: emitted))")
            return
        }
        guard case .captureRuntimeFailure(let message) = error else {
            XCTFail("Expected captureRuntimeFailure, got \(error)")
            return
        }
        XCTAssertTrue(message.contains("stopped unexpectedly"))
    }

    private func makeInterleavedFloatStereoBuffer(
        sampleRate: Double = 16_000,
        samples: [Float]
    ) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: true
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count / 2)
            )
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count / 2)
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData else { return nil }
        let destination = data.assumingMemoryBound(to: Float.self)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            destination.update(from: baseAddress, count: samples.count)
        }
        return buffer
    }

    private func makeInterleavedFloat64StereoBuffer(samples: [Double]) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat64,
                sampleRate: 16_000,
                channels: 2,
                interleaved: true
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count / 2)
            )
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count / 2)
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData else { return nil }
        let destination = data.assumingMemoryBound(to: Double.self)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            destination.update(from: baseAddress, count: samples.count)
        }
        return buffer
    }

    private func makeNonInterleavedFloat64MonoBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat64,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else {
            return nil
        }

        buffer.frameLength = frames
        return buffer
    }
}

private final class MockMeetingMicrophoneCapture: MeetingMicrophoneCapturing, @unchecked Sendable {
    private var handler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private var retainedStartCallbacks: [(handler: AudioBufferHandler, stallObserver: StallObserver?)] = []
    private let startHandler: (MeetingMicProcessingMode) throws -> MeetingMicrophoneCaptureStartReport
    private(set) var requestedModes: [MeetingMicProcessingMode] = []
    private(set) var stopCallCount = 0

    init(
        startHandler: @escaping (MeetingMicProcessingMode) throws -> MeetingMicrophoneCaptureStartReport = { _ in
            MeetingMicrophoneCaptureStartReport(
                requestedMode: .vpioPreferred,
                effectiveMode: .vpio
            )
        }
    ) {
        self.startHandler = startHandler
    }

    func start(
        processingMode: MeetingMicProcessingMode,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) async throws -> MeetingMicrophoneCaptureStartReport {
        self.handler = handler
        self.stallObserver = onStall
        retainedStartCallbacks.append((handler, onStall))
        requestedModes.append(processingMode)
        return try startHandler(processingMode)
    }

    func stop() async {
        stopCallCount += 1
        handler = nil
        stallObserver = nil
    }

    func emit(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        handler?(buffer, time)
    }

    func emitStall(_ error: MeetingAudioError) {
        stallObserver?(error)
    }

    func retainedCallbacks(
        forStartAt index: Int
    ) -> (handler: AudioBufferHandler, stallObserver: StallObserver?)? {
        guard retainedStartCallbacks.indices.contains(index) else { return nil }
        return retainedStartCallbacks[index]
    }
}

private final class MockMeetingSystemAudioCapture: MeetingSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private var retainedStartCallbacks: [(handler: AudioBufferHandler, stallObserver: StallObserver?)] = []
    private let startExpectation: XCTestExpectation?
    private let startError: MeetingAudioError?
    private var startCallCountStorage = 0
    private var stopCallCountStorage = 0

    init(
        startExpectation: XCTestExpectation? = nil,
        startError: MeetingAudioError? = nil
    ) {
        self.startExpectation = startExpectation
        self.startError = startError
    }

    var startCallCount: Int {
        lock.withLock { startCallCountStorage }
    }

    var stopCallCount: Int {
        lock.withLock { stopCallCountStorage }
    }

    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        lock.withLock {
            startCallCountStorage += 1
            if startError == nil {
                self.handler = handler
                self.stallObserver = onStall
                retainedStartCallbacks.append((handler, onStall))
            }
        }
        startExpectation?.fulfill()
        if let startError {
            throw startError
        }
    }

    func stop() async {
        lock.withLock {
            stopCallCountStorage += 1
            handler = nil
            stallObserver = nil
        }
    }

    func emit(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let handler = lock.withLock { self.handler }
        handler?(buffer, time)
    }

    func emitStall(_ error: MeetingAudioError) {
        let stallObserver = lock.withLock { self.stallObserver }
        stallObserver?(error)
    }

    func retainedCallbacks(
        forStartAt index: Int
    ) -> (handler: AudioBufferHandler, stallObserver: StallObserver?)? {
        lock.withLock {
            guard retainedStartCallbacks.indices.contains(index) else { return nil }
            return retainedStartCallbacks[index]
        }
    }
}

private final class FirstBufferThenFailureSystemAudioCapture: MeetingSystemAudioCapturing, @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let failure: MeetingAudioError
    private let startExpectation: XCTestExpectation
    private let lock = NSLock()
    private var stopCallCountStorage = 0

    init(
        buffer: AVAudioPCMBuffer,
        failure: MeetingAudioError,
        startExpectation: XCTestExpectation
    ) {
        self.buffer = buffer
        self.failure = failure
        self.startExpectation = startExpectation
    }

    var stopCallCount: Int {
        lock.withLock { stopCallCountStorage }
    }

    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        startExpectation.fulfill()
        handler(buffer, AVAudioTime(hostTime: 1))
        onStall?(failure)
    }

    func stop() async {
        lock.withLock { stopCallCountStorage += 1 }
    }
}

private final class BlockingStopMeetingSystemAudioCapture: MeetingSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: (handler: AudioBufferHandler, stallObserver: StallObserver?)?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopReleased = false
    private var stopCallCountStorage = 0

    var retainedCallbacks: (handler: AudioBufferHandler, stallObserver: StallObserver?)? {
        lock.withLock { callbacks }
    }

    var stopCallCount: Int {
        lock.withLock { stopCallCountStorage }
    }

    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        lock.withLock {
            callbacks = (handler, onStall)
        }
    }

    func stop() async {
        let shouldWait = lock.withLock {
            stopCallCountStorage += 1
            return !stopReleased
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if stopReleased {
                    return true
                }
                stopContinuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func emitStall(_ error: MeetingAudioError) {
        let observer = lock.withLock { callbacks?.stallObserver }
        observer?(error)
    }

    func releaseStop() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            stopReleased = true
            let continuation = stopContinuation
            stopContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class SystemAudioCaptureFactorySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let captures: [any MeetingSystemAudioCapturing]
    private var nextIndex = 0

    init(_ captures: [any MeetingSystemAudioCapturing]) {
        self.captures = captures
    }

    var makeCallCount: Int {
        lock.withLock { nextIndex }
    }

    func make() throws -> any MeetingSystemAudioCapturing {
        try lock.withLock {
            guard nextIndex < captures.count else {
                throw MeetingAudioError.systemAudioCaptureFailed("test capture factory exhausted")
            }
            defer { nextIndex += 1 }
            return captures[nextIndex]
        }
    }
}

private final class BlockingMeetingMicrophoneCapture: MeetingMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startCallCount = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stopCallCountStorage = 0
    private var stoppedAttemptIDs = Set<Int>()
    private var handlers: [Int: AudioBufferHandler] = [:]
    private var activeAttemptID: Int?

    var stopCallCount: Int {
        lock.withLock { stopCallCountStorage }
    }

    var isRunning: Bool {
        lock.withLock { activeAttemptID != nil }
    }

    func start(
        processingMode: MeetingMicProcessingMode,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) async throws -> MeetingMicrophoneCaptureStartReport {
        let startSnapshot = lock.withLock {
            () -> (attemptID: Int, waiters: [CheckedContinuation<Void, Never>]) in
            startCallCount += 1
            handlers[startCallCount] = handler
            let satisfied = startWaiters.filter { $0.count <= startCallCount }.map(\.continuation)
            startWaiters.removeAll { $0.count <= startCallCount }
            return (startCallCount, satisfied)
        }
        startSnapshot.waiters.forEach { $0.resume() }
        if startSnapshot.attemptID == 1 {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    startContinuation = continuation
                }
            }
        }
        let wasStopped = lock.withLock {
            guard !stoppedAttemptIDs.contains(startSnapshot.attemptID) else {
                handlers[startSnapshot.attemptID] = nil
                return true
            }
            activeAttemptID = startSnapshot.attemptID
            return false
        }
        if wasStopped {
            throw CancellationError()
        }
        return MeetingMicrophoneCaptureStartReport(
            requestedMode: processingMode,
            effectiveMode: .raw
        )
    }

    func stop() async {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stopCallCountStorage += 1
            let stoppedAttemptID = startCallCount
            stoppedAttemptIDs.insert(stoppedAttemptID)
            handlers[stoppedAttemptID] = nil
            if activeAttemptID == stoppedAttemptID {
                activeAttemptID = nil
            }
            let satisfied =
                stopWaiters
                .filter { $0.count <= stopCallCountStorage }
                .map(\.continuation)
            stopWaiters.removeAll { $0.count <= stopCallCountStorage }
            return satisfied
        }
        waiters.forEach { $0.resume() }
    }

    func waitForStartCall(count: Int = 1) async {
        let shouldWait = lock.withLock { startCallCount < count }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if startCallCount >= count {
                    continuation.resume()
                } else {
                    startWaiters.append((count, continuation))
                }
            }
        }
    }

    func waitForStopCall(count: Int = 1) async {
        let shouldWait = lock.withLock { stopCallCountStorage < count }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if stopCallCountStorage >= count {
                    continuation.resume()
                } else {
                    stopWaiters.append((count, continuation))
                }
            }
        }
    }

    func emitActiveBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let handler = lock.withLock {
            activeAttemptID.flatMap { handlers[$0] }
        }
        handler?(buffer, time)
    }

    func releaseStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class BlockingMeetingSystemAudioCapture: MeetingSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startCallCountStorage = 0
    private var stopCallCountStorage = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var stopCallCount: Int { lock.withLock { stopCallCountStorage } }

    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            startCallCountStorage += 1
            let satisfied = startWaiters.filter { $0.count <= startCallCountStorage }.map(\.continuation)
            startWaiters.removeAll { $0.count <= startCallCountStorage }
            return satisfied
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            lock.withLock {
                startContinuation = continuation
            }
        }
    }

    func stop() async {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stopCallCountStorage += 1
            let satisfied =
                stopWaiters
                .filter { $0.count <= stopCallCountStorage }
                .map(\.continuation)
            stopWaiters.removeAll { $0.count <= stopCallCountStorage }
            return satisfied
        }
        waiters.forEach { $0.resume() }
    }

    func waitForStartCall(count: Int = 1) async {
        let shouldWait = lock.withLock { startCallCountStorage < count }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if startCallCountStorage >= count {
                    continuation.resume()
                } else {
                    startWaiters.append((count, continuation))
                }
            }
        }
    }

    func waitForStopCall(count: Int = 1) async {
        let shouldWait = lock.withLock { stopCallCountStorage < count }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if stopCallCountStorage >= count {
                    continuation.resume()
                } else {
                    stopWaiters.append((count, continuation))
                }
            }
        }
    }

    func releaseStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class FailingStartBlockingStopCapture: MeetingSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopCalled = false

    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        throw MeetingAudioError.unsupportedPlatform
    }

    func stop() async {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stopCalled = true
            let waiters = stopWaiters
            stopWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            lock.withLock {
                stopContinuation = continuation
            }
        }
    }

    func waitForStopCall() async {
        let shouldWait = lock.withLock { !stopCalled }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if stopCalled {
                    continuation.resume()
                } else {
                    stopWaiters.append(continuation)
                }
            }
        }
    }

    func releaseStop() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = stopContinuation
            stopContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class FailureDuringStartSystemAudioCapture: MeetingSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: MeetingAudioError
    private var stopCallCountStorage = 0

    init(failure: MeetingAudioError) {
        self.failure = failure
    }

    var stopCallCount: Int {
        lock.withLock { stopCallCountStorage }
    }

    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        onStall?(failure)
    }

    func stop() async {
        lock.withLock { stopCallCountStorage += 1 }
    }
}

private actor CapturedPCMBuffer {
    private var buffer: AVAudioPCMBuffer?

    func store(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func value() -> AVAudioPCMBuffer? {
        buffer
    }
}

private actor CapturedMeetingCaptureEvents {
    private var microphoneBufferCount = 0
    private var systemBufferCount = 0

    func append(_ event: MeetingAudioCaptureEvent) {
        switch event {
        case .microphoneBuffer:
            microphoneBufferCount += 1
        case .systemBuffer:
            systemBufferCount += 1
        case .microphoneHealth:
            break
        case .sourceRecoveryStarted:
            break
        case .sourceRecovered:
            break
        case .sourceInterrupted:
            break
        case .error:
            break
        }
    }

    func values() -> (microphoneBufferCount: Int, systemBufferCount: Int) {
        (microphoneBufferCount, systemBufferCount)
    }
}
