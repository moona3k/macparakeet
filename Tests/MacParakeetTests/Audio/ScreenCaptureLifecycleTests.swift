import Foundation
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import MacParakeetCore

final class ScreenCaptureLifecycleTests: XCTestCase {
    func testSystemAudioStreamStopDispositionOnlyTreatsScreenCaptureKitUserStopAsIntentional() {
        XCTAssertEqual(
            SystemAudioStreamStopDisposition.classify(
                errorDomain: SCStreamErrorDomain,
                errorCode: SCStreamError.Code.userStopped.rawValue
            ),
            .userStopped
        )
        XCTAssertEqual(
            SystemAudioStreamStopDisposition.classify(
                errorDomain: SCStreamErrorDomain,
                errorCode: SCStreamError.Code.internalError.rawValue
            ),
            .unexpected
        )
        XCTAssertEqual(
            SystemAudioStreamStopDisposition.classify(
                errorDomain: "test.error",
                errorCode: SCStreamError.Code.userStopped.rawValue
            ),
            .unexpected
        )
    }

    func testStartCompletionReturnsNormally() async throws {
        let session = FakeScreenCaptureLifecycleSession()
        let lifecycle = ScreenCaptureLifecycleController(
            session: session,
            startTimeoutSeconds: 1,
            stopTimeoutSeconds: 1
        )

        let task = Task { try await lifecycle.start() }
        await session.waitForStartCall()
        session.completeStart()

        try await task.value
        XCTAssertEqual(session.stopCallCount, 0)
    }

    func testStartFrameworkErrorPropagates() async throws {
        let session = FakeScreenCaptureLifecycleSession()
        let lifecycle = ScreenCaptureLifecycleController(
            session: session,
            startTimeoutSeconds: 1,
            stopTimeoutSeconds: 1
        )

        let task = Task { try await lifecycle.start() }
        await session.waitForStartCall()
        session.completeStart(error: TestLifecycleError.framework)

        do {
            try await task.value
            XCTFail("Expected framework error")
        } catch TestLifecycleError.framework {
            // Expected.
        }
    }

    func testStartTimeoutThenLateSuccessActivelyStopsStream() async throws {
        let session = FakeScreenCaptureLifecycleSession()
        let lifecycle = ScreenCaptureLifecycleController(
            session: session,
            startTimeoutSeconds: 0.02,
            stopTimeoutSeconds: 0.02
        )

        do {
            try await lifecycle.start()
            XCTFail("Expected start timeout")
        } catch CaptureLifecycleDeadlineError.startTimedOut {
            // Expected.
        }

        session.completeStart()
        await session.waitForStopCall()
        XCTAssertEqual(session.stopCallCount, 1)
    }

    func testCancelledStartThenLateSuccessActivelyStopsStream() async throws {
        let session = FakeScreenCaptureLifecycleSession()
        let lifecycle = ScreenCaptureLifecycleController(
            session: session,
            startTimeoutSeconds: 1,
            stopTimeoutSeconds: 0.02
        )

        let task = Task { try await lifecycle.start() }
        await session.waitForStartCall()
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        session.completeStart()
        await session.waitForStopCall()
        XCTAssertEqual(session.stopCallCount, 1)
    }

    func testCancellationBeforeStartRegistrationPreventsCaptureStart() async throws {
        let session = FakeScreenCaptureLifecycleSession()
        let lifecycle = ScreenCaptureLifecycleController(
            session: session,
            startTimeoutSeconds: 0.02,
            stopTimeoutSeconds: 0.02
        )

        lifecycle.cancelPendingStart()

        do {
            try await lifecycle.start()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(session.startCallCount, 0)
    }

    func testStopTimeoutReturnsAndLateCompletionDoesNotResumeAgain() async throws {
        let session = FakeScreenCaptureLifecycleSession()
        let lifecycle = ScreenCaptureLifecycleController(
            session: session,
            startTimeoutSeconds: 1,
            stopTimeoutSeconds: 0.02
        )

        let outcome = await lifecycle.stop()
        XCTAssertEqual(outcome, .timedOut)

        session.completeStop()
        session.completeStop()
        XCTAssertEqual(session.stopCallCount, 1)
    }

    func testWholeStartAttemptTimesOutEvenWhenOperationNeverReturns() async throws {
        let gate = AsyncOperationGate()

        do {
            try await BoundedCaptureStartAttempt.run(timeoutSeconds: 0.02) {
                await gate.wait()
            }
            XCTFail("Expected whole-attempt timeout")
        } catch CaptureLifecycleDeadlineError.startTimedOut {
            // Expected.
        }

        gate.release()
    }

    func testTimedOutStartDoesNotRetainLifecycleThroughMissingCallback() async {
        let session = FakeScreenCaptureLifecycleSession()
        weak var weakLifecycle: ScreenCaptureLifecycleController?

        do {
            let lifecycle = ScreenCaptureLifecycleController(
                session: session,
                startTimeoutSeconds: 0.02,
                stopTimeoutSeconds: 0.02
            )
            weakLifecycle = lifecycle

            do {
                try await lifecycle.start()
                XCTFail("Expected start timeout")
            } catch CaptureLifecycleDeadlineError.startTimedOut {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNil(weakLifecycle)
    }

    func testLateSuccessAfterLifecycleReleaseStillStopsLiveSession() async {
        let session = FakeScreenCaptureLifecycleSession()
        var lifecycle: ScreenCaptureLifecycleController? = ScreenCaptureLifecycleController(
            session: session,
            startTimeoutSeconds: 0.02,
            stopTimeoutSeconds: 0.02
        )
        weak var weakLifecycle: ScreenCaptureLifecycleController?
        weakLifecycle = lifecycle

        do {
            try await lifecycle?.start()
            XCTFail("Expected start timeout")
        } catch CaptureLifecycleDeadlineError.startTimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        lifecycle = nil
        XCTAssertNil(weakLifecycle)

        session.completeStart()
        await session.waitForStopCall()
        XCTAssertEqual(session.stopCallCount, 1)
    }

    func testSystemAudioStreamLifecycleKeepsRestartClosedUntilStopFinishes() throws {
        var lifecycle = SystemAudioStreamLifecycleState()
        let attemptID = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.markRunning(attemptID: attemptID))

        XCTAssertEqual(lifecycle.beginStop(), attemptID)
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertNil(lifecycle.beginStart())

        lifecycle.finishStop(attemptID: attemptID)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertNotNil(lifecycle.beginStart())
    }

    func testStaleFailedStartCannotStopOrSettleReplacementAttempt() throws {
        var lifecycle = SystemAudioStreamLifecycleState()
        let staleAttemptID = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertEqual(
            lifecycle.beginStop(expectedAttemptID: staleAttemptID),
            staleAttemptID
        )
        lifecycle.finishStop(attemptID: staleAttemptID)

        let replacementAttemptID = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertNotEqual(replacementAttemptID, staleAttemptID)
        XCTAssertNil(lifecycle.beginStop(expectedAttemptID: staleAttemptID))

        lifecycle.finishStop(attemptID: staleAttemptID)
        XCTAssertTrue(lifecycle.ownsStarting(replacementAttemptID))
    }
}

private enum TestLifecycleError: Error {
    case framework
}

private final class FakeScreenCaptureLifecycleSession: ScreenCaptureLifecycleSession, @unchecked Sendable {
    private let lock = NSLock()
    private var startCompletion: ((Error?) -> Void)?
    private var stopCompletion: ((Error?) -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func startCapture(completionHandler: @escaping (Error?) -> Void) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            startCallCount += 1
            startCompletion = completionHandler
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func stopCapture(completionHandler: @escaping (Error?) -> Void) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stopCallCount += 1
            stopCompletion = completionHandler
            let waiters = stopWaiters
            stopWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func makeLateStartStopAction() -> @Sendable () -> Void {
        { [weak self] in
            self?.stopCapture { _ in }
        }
    }

    func waitForStartCall() async {
        let shouldWait = lock.withLock { startCallCount == 0 }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if startCallCount > 0 {
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                }
            }
        }
    }

    func waitForStopCall() async {
        let shouldWait = lock.withLock { stopCallCount == 0 }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if stopCallCount > 0 {
                    continuation.resume()
                } else {
                    stopWaiters.append(continuation)
                }
            }
        }
    }

    func completeStart(error: Error? = nil) {
        let completion = lock.withLock { startCompletion }
        completion?(error)
    }

    func completeStop(error: Error? = nil) {
        let completion = lock.withLock { stopCompletion }
        completion?(error)
    }
}

private actor AsyncOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    nonisolated func release() {
        Task { await releaseFromActor() }
    }

    private func releaseFromActor() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
