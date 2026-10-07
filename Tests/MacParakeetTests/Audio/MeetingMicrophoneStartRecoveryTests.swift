import AVFAudio
import XCTest
@testable import MacParakeetCore

/// Issue #1223: a combined meeting whose microphone fails to start keeps
/// saving system audio and retries the microphone for the rest of the session.
final class MeetingMicrophoneStartRecoveryTests: XCTestCase {
    func testFailedMicrophoneStartRetriesAndJoinsLiveSession() async throws {
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .succeed])
        let service = makeService(microphone: microphone)
        let events = RecoveryEvents()

        let report = try await containmentBeforeDeadline { try await service.start { events.append($0) } }

        XCTAssertEqual(report.microphoneState, .unavailable)
        XCTAssertEqual(report.systemState, .ready)
        try await waitUntil { events.microphoneReports == 1 }
        XCTAssertEqual(events.lastMicrophoneStartupState, .ready)
        XCTAssertEqual(microphone.startCount, 2)
        let recoveryActive = await service.isMicrophoneRecoveryActive
        XCTAssertFalse(recoveryActive)

        microphone.emitBuffer()
        try await waitUntil { events.microphoneBuffers == 1 }
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testBuffersFromAnUnpromotedRecoveryAttemptNeverReachTheMeeting() async throws {
        // The scripted start emits a buffer before returning. That buffer
        // predates promotion and must be dropped; later buffers flow.
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .succeed])
        let service = makeService(microphone: microphone)
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await waitUntil { events.microphoneReports == 1 }

        XCTAssertEqual(events.microphoneBuffers, 0)
        microphone.emitBuffer()
        try await waitUntil { events.microphoneBuffers == 1 }
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testRetriesContinueAtSteadyIntervalUntilMicrophoneStarts() async throws {
        let failure = ScriptedMicrophone.Step.fail(.audioEngineStartFailed("-10868"))
        let microphone = ScriptedMicrophone([failure, failure, failure, .succeed])
        let service = makeService(
            microphone: microphone,
            schedule: schedule(delays: [.milliseconds(5)], steadyInterval: .milliseconds(5))
        )
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }

        try await waitUntil { events.microphoneReports == 1 }
        XCTAssertEqual(microphone.startCount, 4)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testRecoveryStartThatStallsBeforeDeliveringAudioIsStoppedAndRetried() async throws {
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .succeed])
        let service = makeService(microphone: microphone)
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await waitUntil { events.microphoneReports == 1 }
        let stopsBeforeStall = microphone.stopCount

        microphone.emitStall()

        try await waitUntil { events.microphoneReports == 2 }
        XCTAssertEqual(microphone.startCount, 3)
        XCTAssertGreaterThan(microphone.stopCount, stopsBeforeStall)
        XCTAssertEqual(events.lastMicrophoneStartupState, .ready)
        microphone.emitBuffer()
        try await waitUntil { events.microphoneBuffers == 1 }
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testFirstStartThatStallsBeforeDeliveringAudioIsStoppedAndRetried() async throws {
        let microphone = ScriptedMicrophone([.succeedWithoutAudio, .succeed])
        let service = makeService(microphone: microphone)
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await waitUntil { events.microphoneReports == 1 }
        let stopsBeforeStall = microphone.stopCount

        microphone.emitStall()

        try await waitUntil { events.microphoneReports == 2 }
        XCTAssertEqual(microphone.startCount, 2)
        XCTAssertGreaterThan(microphone.stopCount, stopsBeforeStall)
        microphone.emitBuffer()
        try await waitUntil { events.microphoneBuffers == 1 }
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testStallAfterDeliveredAudioIsNotRetried() async throws {
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .succeed])
        let service = makeService(microphone: microphone)
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await waitUntil { events.microphoneReports == 1 }
        microphone.emitBuffer()
        try await waitUntil { events.microphoneBuffers == 1 }
        let stopsBeforeStall = microphone.stopCount

        microphone.emitStall()

        try await waitUntil { events.microphoneInterruptions == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(microphone.startCount, 2)
        XCTAssertEqual(microphone.stopCount, stopsBeforeStall)
        XCTAssertEqual(events.lastMicrophoneStartupState, .unavailable)
        let recoveryActive = await service.isMicrophoneRecoveryActive
        XCTAssertFalse(recoveryActive)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testRouteChangeShortensTheRetryWait() async throws {
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .succeed])
        let routes = RouteChangeSource()
        let service = makeService(
            microphone: microphone,
            schedule: schedule(delays: [.seconds(60)], steadyInterval: .seconds(60)),
            routeChanges: routes
        )
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await waitUntilAsync { await service.isMicrophoneRecoveryActive }
        try await waitUntil { routes.subscriberCount > 0 }
        routes.post()

        try await waitUntil { events.microphoneReports == 1 }
        XCTAssertEqual(microphone.startCount, 2)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testStopCancelsPendingRecoveryWithoutAnotherStart() async throws {
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .succeed])
        let service = makeService(
            microphone: microphone,
            schedule: schedule(delays: [.milliseconds(300)], steadyInterval: .seconds(60))
        )

        _ = try await containmentBeforeDeadline { try await service.start() }
        try await containmentBeforeDeadline { await service.stop() }
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(microphone.startCount, 1)
        let recoveryActive = await service.isMicrophoneRecoveryActive
        XCTAssertFalse(recoveryActive)
    }

    func testRecoveryStartThatSucceedsAfterStopIsStoppedAgain() async throws {
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .hold])
        defer { microphone.releaseHeldStart() }
        let service = makeService(microphone: microphone)
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await waitUntil { microphone.startCount == 2 }
        try await containmentBeforeDeadline { await service.stop() }
        let stopsBeforeRelease = microphone.stopCount

        microphone.releaseHeldStart()
        try await waitUntil { microphone.stopCount > stopsBeforeRelease }
        XCTAssertFalse(microphone.isRunning)
        XCTAssertEqual(events.microphoneReports, 0)
        try await waitUntilAsync { await !service.isMicrophoneLeaseHeld }
    }

    func testCombinedMeetingRetriesAfterEarlierMeetingReleasesTheMicrophone() async throws {
        // An earlier meeting's native start is still pending, so the new
        // meeting starts with its microphone unavailable. Once that call
        // settles and is cleaned up, the retry claims the microphone.
        let microphone = ScriptedMicrophone([.hold, .succeed])
        defer { microphone.releaseHeldStart() }
        let service = makeService(microphone: microphone)

        _ = try await containmentBeforeDeadline { try await service.start() }
        try await containmentBeforeDeadline { await service.stop() }

        let events = RecoveryEvents()
        let report = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        XCTAssertEqual(report.microphoneState, .unavailable)

        microphone.releaseHeldStart()
        try await waitUntil { events.microphoneReports == 1 }
        XCTAssertEqual(microphone.startCount, 2)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testPermissionDenialIsNotRetried() async throws {
        let microphone = ScriptedMicrophone([.fail(.microphonePermissionDenied), .succeed])
        let service = makeService(microphone: microphone)

        let report = try await containmentBeforeDeadline { try await service.start() }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(report.microphoneState, .unavailable)
        XCTAssertEqual(microphone.startCount, 1)
        let recoveryActive = await service.isMicrophoneRecoveryActive
        XCTAssertFalse(recoveryActive)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testMicrophoneOnlyMeetingDoesNotRetry() async throws {
        let microphone = ScriptedMicrophone([.fail(.audioEngineStartFailed("-10868")), .succeed])
        let service = makeService(microphone: microphone)

        do {
            _ = try await containmentBeforeDeadline { try await service.start(sourceMode: .microphoneOnly) }
            XCTFail("A microphone-only meeting without audio cannot start")
        } catch MeetingAudioError.audioEngineStartFailed {
            // Expected: the only selected source failed.
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(microphone.startCount, 1)
    }

    func testSystemLossWhileMicrophoneRetriesStillEndsCapture() async throws {
        let microphone = ScriptedMicrophone(repeating: .fail(.audioEngineStartFailed("-10868")))
        let system = ContainmentSystemAudio()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { system },
            systemAudioRecoveryDelays: [],
            microphoneRecoverySchedule: schedule(delays: [.seconds(60)], steadyInterval: .seconds(60)),
            microphoneRouteChanges: { AsyncStream { _ in } },
            startupTimeout: .milliseconds(150)
        )
        let events = RecoveryEvents()

        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await containmentBeforeDeadline {
            while await service.isSystemAudioStartPending {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        system.emitFailure(.systemAudioStreamStopped("route change"))

        // The microphone stays unavailable during retries, so losing the only
        // live source is still reported for the recording to stop.
        try await waitUntil { events.systemInterruptions == 1 }
        XCTAssertEqual(events.lastMicrophoneStartupState, .unavailable)
        try await containmentBeforeDeadline { await service.stop() }
    }

    // MARK: - Helpers

    private func schedule(
        delays: [Duration] = [.milliseconds(5)],
        steadyInterval: Duration = .milliseconds(5)
    ) -> MeetingAudioCaptureService.MicrophoneRecoverySchedule {
        MeetingAudioCaptureService.MicrophoneRecoverySchedule(
            delays: delays,
            steadyInterval: steadyInterval,
            routeChangeQuietPeriod: .zero,
            routeChangeDebounce: .milliseconds(5)
        )
    }

    private func makeService(
        microphone: ScriptedMicrophone,
        schedule: MeetingAudioCaptureService.MicrophoneRecoverySchedule? = nil,
        routeChanges: RouteChangeSource = RouteChangeSource()
    ) -> MeetingAudioCaptureService {
        MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { ContainmentSystemAudio() },
            microphoneRecoverySchedule: schedule ?? self.schedule(),
            microphoneRouteChanges: { routeChanges.stream() },
            startupTimeout: .milliseconds(150)
        )
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        try await containmentBeforeDeadline {
            while !predicate() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }

    private func waitUntilAsync(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        try await containmentBeforeDeadline {
            while await !predicate() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}

/// Plays one scripted outcome per `start`, then repeats the last step.
private final class ScriptedMicrophone: MeetingMicrophoneCapturing, @unchecked Sendable {
    enum Step {
        case succeed
        case fail(MeetingAudioError)
        /// Waits for `releaseHeldStart()`, then succeeds, even after Stop.
        case hold
        /// Succeeds without the buffer `.succeed` emits before returning.
        case succeedWithoutAudio
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var handler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private var starts = 0
    private var stops = 0
    private var running = false
    private var heldStart: CheckedContinuation<Void, Never>?
    private var holdReleased = false

    init(_ steps: [Step]) {
        self.steps = steps
    }

    convenience init(repeating step: Step) {
        self.init([step])
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var isRunning: Bool { lock.withLock { running } }

    func emitBuffer() {
        let callback = lock.withLock { handler }
        callback?(recoveryTestBuffer(), AVAudioTime(hostTime: 1))
    }

    func emitStall() {
        let observer = lock.withLock { stallObserver }
        observer?(.captureRuntimeFailure("microphone capture started but delivered no buffers within 2 seconds"))
    }

    func releaseHeldStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdReleased = true
            defer { heldStart = nil }
            return heldStart
        }
        continuation?.resume()
    }

    func start(
        processingMode: MeetingMicProcessingMode,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) async throws -> MeetingMicrophoneCaptureStartReport {
        let step = lock.withLock { () -> Step in
            starts += 1
            self.handler = handler
            stallObserver = onStall
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        var emitsBuffer = true
        switch step {
        case .fail(let error):
            throw error
        case .hold:
            await withCheckedContinuation { continuation in
                let released = lock.withLock { () -> Bool in
                    if holdReleased { return true }
                    heldStart = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        case .succeed:
            break
        case .succeedWithoutAudio:
            emitsBuffer = false
        }
        lock.withLock { running = true }
        if emitsBuffer {
            handler(recoveryTestBuffer(), AVAudioTime(hostTime: 1))
        }
        return MeetingMicrophoneCaptureStartReport(requestedMode: processingMode, effectiveMode: .raw)
    }

    func stop() async {
        lock.withLock {
            stops += 1
            running = false
        }
    }
}

private final class RouteChangeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    var subscriberCount: Int { lock.withLock { continuations.count } }

    func stream() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func post() {
        let current = lock.withLock { Array(continuations.values) }
        current.forEach { $0.yield() }
    }
}

private final class RecoveryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeetingAudioCaptureEvent] = []

    func append(_ event: MeetingAudioCaptureEvent) { lock.withLock { events.append(event) } }

    var microphoneReports: Int {
        lock.withLock { events.filter { if case .microphoneStarted = $0 { true } else { false } }.count }
    }

    var microphoneBuffers: Int {
        lock.withLock { events.filter { if case .microphoneBuffer = $0 { true } else { false } }.count }
    }

    var microphoneInterruptions: Int {
        lock.withLock {
            events.filter { if case .sourceInterrupted(.microphone, _) = $0 { true } else { false } }.count
        }
    }

    var systemInterruptions: Int {
        lock.withLock {
            events.filter { if case .sourceInterrupted(.system, _) = $0 { true } else { false } }.count
        }
    }

    var lastMicrophoneStartupState: MeetingAudioCaptureSourceStartupState? {
        lock.withLock {
            for event in events.reversed() {
                if case .sourceStartupState(.microphone, let state) = event { return state }
            }
            return nil
        }
    }
}

private func recoveryTestBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    buffer.floatChannelData![0].initialize(repeating: 0, count: 480)
    return buffer
}
