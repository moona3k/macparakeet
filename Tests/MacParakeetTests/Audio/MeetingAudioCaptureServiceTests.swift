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

        let interleaved = try XCTUnwrap(makeInterleavedFloatStereoBuffer(samples: [
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

        let burstBuffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(
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

        let buffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(
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

        let buffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(
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

        let buffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(
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
        defer { Task { await service.stop() } }

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

        let buffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(
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

        let buffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(
            sampleRate: 48_000,
            samples: [0.25, 0.25, 0.25, 0.25]
        ))
        systemCapture.emit(buffer: buffer, time: AVAudioTime(hostTime: 1))

        XCTAssertFalse(telemetry.snapshot().contains { $0.name == .micStallDetected })
    }

    func testEmitsRuntimeErrorEventWhenMicrophoneStalls() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { MockMeetingSystemAudioCapture() }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        microphone.emitStall(.captureRuntimeFailure("microphone capture started but delivered no buffers within 2 seconds"))

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

    func testEmitsSourceInterruptedWhenSystemCaptureStallsInMicrophoneAndSystemMode() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        systemCapture.emitStall(.captureRuntimeFailure("system audio stream stopped delivering buffers (gap 6.0s)"))

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
        XCTAssertTrue(message.contains("stopped delivering buffers"))
    }

    func testEmitsRuntimeErrorWhenSystemCaptureStallsInSystemOnlyMode() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemCapture = MockMeetingSystemAudioCapture()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { systemCapture },
            sourceModeProvider: { .systemOnly }
        )

        let events = await service.events
        _ = try await service.start()
        defer { Task { await service.stop() } }

        systemCapture.emitStall(.captureRuntimeFailure("system audio stream stopped delivering buffers (gap 6.0s)"))

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
        XCTAssertTrue(message.contains("stopped delivering buffers"))
    }

    private func makeInterleavedFloatStereoBuffer(
        sampleRate: Double = 16_000,
        samples: [Float]
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count / 2)
        ) else {
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
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: 16_000,
            channels: 2,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count / 2)
        ) else {
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
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }

        buffer.frameLength = frames
        return buffer
    }
}

private final class MockMeetingMicrophoneCapture: MeetingMicrophoneCapturing, @unchecked Sendable {
    private var handler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private let startHandler: (MeetingMicProcessingMode) throws -> MeetingMicrophoneCaptureStartReport
    private(set) var requestedModes: [MeetingMicProcessingMode] = []

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
        requestedModes.append(processingMode)
        return try startHandler(processingMode)
    }

    func stop() {
        handler = nil
        stallObserver = nil
    }

    func emit(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        handler?(buffer, time)
    }

    func emitStall(_ error: MeetingAudioError) {
        stallObserver?(error)
    }
}

private final class MockMeetingSystemAudioCapture: MeetingSystemAudioCapturing, @unchecked Sendable {
    private var handler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private(set) var startCallCount = 0

    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        startCallCount += 1
        self.handler = handler
        self.stallObserver = onStall
    }

    func stop() async {
        handler = nil
        stallObserver = nil
    }

    func emit(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        handler?(buffer, time)
    }

    func emitStall(_ error: MeetingAudioError) {
        stallObserver?(error)
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
