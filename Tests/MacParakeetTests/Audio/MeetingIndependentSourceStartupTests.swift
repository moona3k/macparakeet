import AVFAudio
import XCTest
@testable import MacParakeetCore

final class MeetingIndependentSourceStartupTests: XCTestCase {
    func testSystemStartsAndStopSettlesWhileMicrophoneStartAndStopRemainPending() async throws {
        let microphone = ContainmentMicrophone(holdStart: true)
        defer { microphone.releaseStart() }
        let system = ContainmentSystemAudio()
        let service = makeService(microphone: microphone, system: system)
        let report = try await containmentBeforeDeadline { try await service.start() }
        XCTAssertEqual(report.microphoneState, .starting)
        XCTAssertEqual(report.systemState, .ready)
        try await containmentBeforeDeadline { await service.stop() }
        XCTAssertFalse(microphone.startSettled)
        XCTAssertEqual(system.stopCount, 1)
    }

    func testReplacementSystemAndCombinedSessionsBypassOccupiedMicrophone() async throws {
        let microphone = ContainmentMicrophone(holdStart: true)
        defer { microphone.releaseStart() }
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { ContainmentSystemAudio() },
            startupTimeout: .milliseconds(150)
        )
        _ = try await containmentBeforeDeadline { try await service.start() }
        try await containmentBeforeDeadline { await service.stop() }
        let systemReport = try await containmentBeforeDeadline { try await service.start(sourceMode: .systemOnly) }
        XCTAssertEqual(systemReport.systemState, .ready)
        try await containmentBeforeDeadline { await service.stop() }
        let combinedReport = try await containmentBeforeDeadline { try await service.start() }
        XCTAssertEqual(combinedReport.microphoneState, .unavailable)
        XCTAssertEqual(combinedReport.systemState, .ready)
        XCTAssertEqual(microphone.startCount, 1)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testMicrophoneOnlyFailsPromptlyWhileOldMicrophoneLeaseRemainsOccupied() async throws {
        let microphone = ContainmentMicrophone(holdStart: true)
        defer { microphone.releaseStart() }
        let service = makeService(microphone: microphone, system: ContainmentSystemAudio())
        _ = try await containmentBeforeDeadline { try await service.start() }
        try await containmentBeforeDeadline { await service.stop() }
        do {
            _ = try await containmentBeforeDeadline { try await service.start(sourceMode: .microphoneOnly) }
            XCTFail("A pending native microphone lease cannot be replaced")
        } catch MeetingAudioError.microphoneCleanupPending {
            XCTAssertEqual(microphone.startCount, 1)
            XCTAssertEqual(
                MeetingAudioError.microphoneCleanupPending.errorDescription,
                "The microphone is still finishing an earlier operation."
            )
        }
    }

    func testLateMicrophoneReportAndBuffersCannotReachReplacementSession() async throws {
        let microphone = ContainmentMicrophone(holdStart: true)
        defer { microphone.releaseStart() }
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { ContainmentSystemAudio() },
            startupTimeout: .milliseconds(150)
        )
        _ = try await containmentBeforeDeadline { try await service.start() }
        try await containmentBeforeDeadline { await service.stop() }
        let replacement = ContainmentEvents()
        _ = try await containmentBeforeDeadline {
            try await service.start(sourceMode: .systemOnly) { replacement.append($0) }
        }
        microphone.releaseStart()
        try await waitUntil { microphone.startSettled }
        microphone.emitRetainedBuffer()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(replacement.microphoneBuffers, 0)
        XCTAssertEqual(replacement.microphoneReports, 0)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testBothSourcesHangingReachDeadlineAndLateCompletionCannotReviveSession() async throws {
        let microphone = ContainmentMicrophone(holdStart: true)
        let system = ContainmentSystemAudio(holdStart: true)
        defer { microphone.releaseStart(); system.releaseStart() }
        let events = ContainmentEvents()
        let service = makeService(microphone: microphone, system: system)
        do {
            _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
            XCTFail("No source delivered a usable frame")
        } catch MeetingAudioError.captureStartupTimedOut {
            // Expected, without settling the native microphone call.
        }
        let before = events.totalCount
        microphone.releaseStart()
        system.releaseStart()
        try await waitUntil { microphone.startSettled }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(events.totalCount, before)
    }

    func testSystemStartupFailurePreservesWorkingMicrophone() async throws {
        let microphone = ContainmentMicrophone()
        let system = ContainmentSystemAudio(startError: .screenRecordingPermissionDenied)
        let service = makeService(microphone: microphone, system: system)
        let events = ContainmentEvents()
        let report = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        XCTAssertEqual(report.microphoneState, .ready)
        try await waitUntil { events.microphoneReports == 1 }
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testUsableBufferFollowedByStartupFailureRemainsARealCapture() async throws {
        let system = ContainmentSystemAudio(failureAfterBuffer: .systemAudioStreamStopped("during start"))
        let service = makeService(microphone: ContainmentMicrophone(), system: system)
        let events = ContainmentEvents()
        _ = try await containmentBeforeDeadline {
            try await service.start(sourceMode: .systemOnly) { events.append($0) }
        }
        XCTAssertEqual(events.systemBuffers, 1)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testLateMicrophoneJoiningLiveSessionPublishesProcessingReport() async throws {
        let microphone = ContainmentMicrophone(holdStart: true)
        defer { microphone.releaseStart() }
        let service = makeService(microphone: microphone, system: ContainmentSystemAudio())
        let events = ContainmentEvents()
        let report = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        XCTAssertFalse(report.microphoneStarted)
        microphone.releaseStart()
        try await waitUntil { events.microphoneReports == 1 }
        XCTAssertEqual(events.microphoneBuffers, 1)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testSourceSelectionPrecedesEveryBuffer() async throws {
        let events = ContainmentEvents()
        let service = makeService(microphone: ContainmentMicrophone(), system: ContainmentSystemAudio())
        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        XCTAssertTrue(events.selectionWasFirst)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testReentrantSourceFailureCannotTurnAnEmittedBufferIntoEmptyStartup() async throws {
        let system = ContainmentSystemAudio()
        let service = makeService(microphone: ContainmentMicrophone(), system: system)
        let events = ContainmentEvents()
        _ = try await containmentBeforeDeadline {
            try await service.start(sourceMode: .systemOnly) { event in
                events.append(event)
                if case .systemBuffer = event {
                    system.emitFailure(.systemAudioStreamStopped("reentrant first-buffer failure"))
                }
            }
        }
        XCTAssertEqual(events.systemBuffers, 1)
        XCTAssertEqual(events.runtimeErrors, 1)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testCompletedNativeSetupWithoutBuffersStillReachesStartupDeadline() async throws {
        let system = ContainmentSystemAudio(emitsStartupBuffer: false)
        let service = makeService(microphone: ContainmentMicrophone(), system: system)
        do {
            _ = try await containmentBeforeDeadline { try await service.start(sourceMode: .systemOnly) }
            XCTFail("Native setup alone does not establish usable capture")
        } catch MeetingAudioError.captureStartupTimedOut {
            XCTAssertEqual(system.stopCount, 1)
        }
    }

    func testEmptyFirstCallbackDoesNotPreventLaterUsableSilentBuffer() async throws {
        let system = ContainmentSystemAudio(emitsEmptyBufferFirst: true)
        let service = makeService(microphone: ContainmentMicrophone(), system: system)
        let events = ContainmentEvents()
        let report = try await containmentBeforeDeadline {
            try await service.start(sourceMode: .systemOnly) { events.append($0) }
        }
        XCTAssertEqual(report.systemState, .ready)
        XCTAssertEqual(events.systemBuffers, 1)
        XCTAssertEqual(events.runtimeErrors, 0)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testStopBeforeNativeStartEntersStillCleansItsLateSuccessfulStart() async throws {
        let microphone = DeferredEnteringMicrophone()
        defer { microphone.releaseStart() }
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { ContainmentSystemAudio() },
            startupTimeout: .milliseconds(150)
        )
        _ = try await containmentBeforeDeadline { try await service.start() }
        try await waitUntil { microphone.startCalled }
        try await containmentBeforeDeadline { await service.stop() }
        try await waitUntil { microphone.stopCount == 1 }
        _ = try await containmentBeforeDeadline { try await service.start(sourceMode: .systemOnly) }
        microphone.releaseStart()
        try await waitUntil { microphone.stopCount == 2 }
        XCTAssertFalse(microphone.isRunning)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testRecoveredFirstSystemBufferCannotBeOverwrittenByOriginalStartupDeadline() async throws {
        let stalled = ContainmentSystemAudio(emitsStartupBuffer: false)
        let replacement = ContainmentSystemAudio()
        let captures = ContainmentSystemSequence(first: stalled, replacement: replacement)
        let service = MeetingAudioCaptureService(
            microphoneCapture: ContainmentMicrophone(),
            systemAudioCaptureFactory: { captures.make() },
            systemAudioRecoveryDelays: [.zero],
            startupTimeout: .milliseconds(150)
        )
        let events = ContainmentEvents()
        _ = try await containmentBeforeDeadline { try await service.start { events.append($0) } }
        try await containmentBeforeDeadline {
            while await service.isSystemAudioStartPending {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        stalled.emitFailure(.systemAudioStalled(.firstBufferTimeout(seconds: 2)))
        try await waitUntil { events.systemRecoveries == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(events.lastSystemStartupState, .ready)
        try await containmentBeforeDeadline { await service.stop() }
    }

    func testRuntimeFailureAfterNativeSetupCanRecoverWhileOuterStartStillAwaitsAudio() async throws {
        let stalled = ContainmentSystemAudio(emitsStartupBuffer: false)
        let replacement = ContainmentSystemAudio()
        let captures = ContainmentSystemSequence(first: stalled, replacement: replacement)
        let service = MeetingAudioCaptureService(
            microphoneCapture: ContainmentMicrophone(),
            systemAudioCaptureFactory: { captures.make() },
            systemAudioRecoveryDelays: [.zero],
            startupTimeout: .seconds(1)
        )
        let events = ContainmentEvents()
        let start = Task {
            try await service.start(sourceMode: .systemOnly) { events.append($0) }
        }
        defer { start.cancel() }
        try await waitUntil { captures.makeCount == 1 }
        try await containmentBeforeDeadline {
            while await service.isSystemAudioStartPending {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        // No source has emitted audio, so the outer start cannot have settled.
        // The native setup latch has promoted: this is a runtime source loss.
        XCTAssertEqual(events.systemBuffers, 0)
        stalled.emitFailure(.systemAudioStalled(.firstBufferTimeout(seconds: 2)))
        let report = try await containmentBeforeDeadline { try await start.value }
        XCTAssertEqual(report.systemState, .ready)
        try await waitUntil { events.systemRecoveries == 1 }
        XCTAssertEqual(captures.makeCount, 2)
        try await containmentBeforeDeadline { await service.stop() }
    }

    private func makeService(
        microphone: ContainmentMicrophone,
        system: ContainmentSystemAudio
    ) -> MeetingAudioCaptureService {
        MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioCaptureFactory: { system },
            startupTimeout: .milliseconds(150)
        )
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        try await containmentBeforeDeadline {
            while !predicate() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}

private enum ContainmentTestError: Error { case deadline }

func containmentBeforeDeadline<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let result = ContainmentResult<T>()
    let task = Task {
        do { result.resolve(.success(try await operation())) } catch { result.resolve(.failure(error)) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        result.resolve(.failure(ContainmentTestError.deadline))
        task.cancel()
    }
    return try await result.wait()
}

private final class ContainmentResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func resolve(_ result: Result<T, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<T, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(with: result)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<T, Error>? in
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}

private final class ContainmentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(held: Bool) { released = !held }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiters = lock.withLock {
            released = true
            defer { self.waiters.removeAll() }
            return self.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Deliberately allows an async start to enter native state after Stop has
/// already returned from an idle microphone. The service must clean that late
/// successful start before permitting reuse of its microphone lease.
private final class DeferredEnteringMicrophone: MeetingMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = ContainmentGate(held: true)
    private var called = false
    private var running = false
    private var stops = 0
    var startCalled: Bool { lock.withLock { called } }
    var isRunning: Bool { lock.withLock { running } }
    var stopCount: Int { lock.withLock { stops } }
    func releaseStart() { gate.release() }
    func start(
        processingMode: MeetingMicProcessingMode,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) async throws -> MeetingMicrophoneCaptureStartReport {
        lock.withLock { called = true }
        await gate.wait()
        lock.withLock { running = true }
        handler(containmentBuffer(), AVAudioTime(hostTime: 1))
        return MeetingMicrophoneCaptureStartReport(requestedMode: processingMode, effectiveMode: .raw)
    }
    func stop() async {
        lock.withLock {
            stops += 1; running = false
        }
    }
}

private func containmentBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    buffer.floatChannelData![0].initialize(repeating: 0, count: 480)
    return buffer
}

final class ContainmentMicrophone: MeetingMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: ContainmentGate
    private let settlement = ContainmentGate(held: true)
    private var handler: AudioBufferHandler?
    private var starts = 0
    private var settled = false
    private var stopped = false
    init(holdStart: Bool = false) { gate = ContainmentGate(held: holdStart) }
    var startCount: Int { lock.withLock { starts } }
    var startSettled: Bool { lock.withLock { settled } }
    func releaseStart() { gate.release() }
    func emitRetainedBuffer() {
        let callback = lock.withLock { handler }
        callback?(containmentBuffer(), AVAudioTime(hostTime: 1))
    }
    func start(
        processingMode: MeetingMicProcessingMode,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) async throws -> MeetingMicrophoneCaptureStartReport {
        lock.withLock {
            starts += 1; self.handler = handler
        }
        await gate.wait()
        defer { lock.withLock { settled = true }; settlement.release() }
        if lock.withLock({ stopped }) { throw CancellationError() }
        handler(containmentBuffer(), AVAudioTime(hostTime: 1))
        return MeetingMicrophoneCaptureStartReport(requestedMode: processingMode, effectiveMode: .raw)
    }
    func stop() async {
        lock.withLock { stopped = true }
        await settlement.wait()
    }
}

final class ContainmentSystemAudio: MeetingSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: ContainmentGate
    private let startError: MeetingAudioError?
    private let failureAfterBuffer: MeetingAudioError?
    private let emitsStartupBuffer: Bool
    private let emitsEmptyBufferFirst: Bool
    private var stallObserver: StallObserver?
    private var stops = 0
    init(
        holdStart: Bool = false,
        startError: MeetingAudioError? = nil,
        failureAfterBuffer: MeetingAudioError? = nil,
        emitsStartupBuffer: Bool = true,
        emitsEmptyBufferFirst: Bool = false
    ) {
        gate = ContainmentGate(held: holdStart)
        self.startError = startError
        self.failureAfterBuffer = failureAfterBuffer
        self.emitsStartupBuffer = emitsStartupBuffer
        self.emitsEmptyBufferFirst = emitsEmptyBufferFirst
    }
    var stopCount: Int { lock.withLock { stops } }
    func releaseStart() { gate.release() }
    func emitFailure(_ error: MeetingAudioError) {
        let observer = lock.withLock { stallObserver }
        observer?(error)
    }
    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws {
        lock.withLock { stallObserver = onStall }
        await gate.wait()
        if let startError { throw startError }
        if emitsEmptyBufferFirst {
            let empty = containmentBuffer()
            empty.frameLength = 0
            handler(empty, AVAudioTime(hostTime: 1))
        }
        if emitsStartupBuffer { handler(containmentBuffer(), AVAudioTime(hostTime: 1)) }
        if let failureAfterBuffer { onStall?(failureAfterBuffer) }
    }
    func stop() async { lock.withLock { stops += 1 } }
}

private final class ContainmentSystemSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let first: ContainmentSystemAudio
    private let replacement: ContainmentSystemAudio
    private var usedFirst = false
    private var count = 0
    var makeCount: Int { lock.withLock { count } }
    init(first: ContainmentSystemAudio, replacement: ContainmentSystemAudio) {
        self.first = first
        self.replacement = replacement
    }
    func make() -> ContainmentSystemAudio {
        lock.withLock {
            count += 1
            defer { usedFirst = true }
            return usedFirst ? replacement : first
        }
    }
}

private final class ContainmentEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeetingAudioCaptureEvent] = []
    var totalCount: Int { lock.withLock { events.count } }
    var microphoneBuffers: Int {
        lock.withLock { events.filter { if case .microphoneBuffer = $0 { true } else { false } }.count }
    }
    var systemBuffers: Int {
        lock.withLock { events.filter { if case .systemBuffer = $0 { true } else { false } }.count }
    }
    var microphoneReports: Int {
        lock.withLock { events.filter { if case .microphoneStarted = $0 { true } else { false } }.count }
    }
    var runtimeErrors: Int {
        lock.withLock { events.filter { if case .error = $0 { true } else { false } }.count }
    }
    var systemRecoveries: Int {
        lock.withLock { events.filter { if case .sourceRecovered(.system) = $0 { true } else { false } }.count }
    }
    var lastSystemStartupState: MeetingAudioCaptureSourceStartupState? {
        lock.withLock {
            for event in events.reversed() {
                if case .sourceStartupState(.system, let state) = event { return state }
            }
            return nil
        }
    }
    var selectionWasFirst: Bool {
        lock.withLock { if case .captureStarting? = events.first { true } else { false } }
    }
    func append(_ event: MeetingAudioCaptureEvent) { lock.withLock { events.append(event) } }
}
