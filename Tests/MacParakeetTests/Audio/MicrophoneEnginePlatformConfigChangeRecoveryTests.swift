import AVFoundation
import os
import XCTest
@testable import MacParakeetCore

/// Tests for `AVAudioEngineMicrophonePlatform`'s self-healing behaviour when
/// `AVAudioEngine` stops itself after an `AVAudioEngineConfigurationChange`
/// notification (default-input change, sample-rate change, etc.).
///
/// These tests use the internal `engineStarter` seam so no real audio hardware
/// is needed. A never-actually-started `AVAudioEngine` reports
/// `isRunning == false` — the same signature a HAL reconfiguration leaves on a
/// live engine — so the four recovery gates are exercisable without hardware.
///
/// Queue-ordering guarantee exploited by the "no recovery" assertions: the
/// configuration-change observer posts its work to `queue.async`. The public
/// `isEngineRunning` accessor calls `queue.sync { running }`. Because
/// `queue.async` enqueues before the subsequent `queue.sync` executes, reading
/// `isEngineRunning` after posting a notification is a reliable "flush"
/// — the async recovery block is guaranteed to have run before the sync read
/// returns.
final class MicrophoneEnginePlatformConfigChangeRecoveryTests: XCTestCase {

    // MARK: - Test 1

    /// Starting the engine and then posting a configuration-change notification
    /// for the live engine causes the starter to be invoked a second time with
    /// the ORIGINAL vpio/bufferSize parameters and a DIFFERENT (freshly created)
    /// engine instance, and leaves the platform running.
    func testConfigurationChangeWhileRunningRestartsEngine() throws {
        // Arrange: capture each engine instance and the call parameters.
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let vpioLock = OSAllocatedUnfairLock(initialState: [Bool]())
        let bufferSizeLock = OSAllocatedUnfairLock(initialState: [AVAudioFrameCount]())
        let recoveryExpectation = expectation(description: "engineStarter invoked for recovery")
        let recoveryBuffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            engineStarter: { engine, vpio, bufferSize, tapHandler in
                let engines = enginesLock.withLock { engines -> [AVAudioEngine] in
                    engines.append(engine)
                    return engines
                }
                vpioLock.withLock { arr in arr.append(vpio) }
                bufferSizeLock.withLock { arr in arr.append(bufferSize) }
                if engines.count == 2 {
                    tapHandler(recoveryBuffer.buffer, AVAudioTime(hostTime: 1))
                    recoveryExpectation.fulfill()
                }
            }
        )
        defer { platform.stopEngine() }

        // Act: first start.
        try platform.configureAndStart(vpioEnabled: true, bufferSize: 512, tapHandler: { _, _ in })

        let capturedEngines = enginesLock.withLock { engines in engines }
        XCTAssertEqual(capturedEngines.count, 1, "engineStarter should have been called once after first start")
        let firstEngine = capturedEngines[0]

        // Post the configuration-change notification for the live engine.
        // A never-started AVAudioEngine has isRunning == false, which
        // satisfies gate 3 of the four-gate check without real hardware.
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )

        // Wait for the recovery queue block to run and invoke the starter a
        // second time.
        wait(for: [recoveryExpectation], timeout: 2.0)

        // Assert: exactly 2 starter invocations.
        let engines = enginesLock.withLock { arr in arr }
        XCTAssertEqual(engines.count, 2, "starter should be invoked exactly twice (initial + recovery)")

        // The second invocation must use a DIFFERENT engine instance
        // (tearDownLocked replaced it during the recovery path).
        XCTAssertFalse(
            engines[0] === engines[1],
            "recovery must use a fresh engine instance, not the stalled one"
        )

        // Parameters must match the original configureAndStart call (VPIO stickiness).
        let capturedVpio = vpioLock.withLock { arr in arr }
        XCTAssertEqual(capturedVpio, [true, true], "recovery must replay the original vpioEnabled")

        let capturedBufferSizes = bufferSizeLock.withLock { arr in arr }
        XCTAssertEqual(
            capturedBufferSizes,
            [512, 512],
            "recovery must replay the original bufferSize"
        )

        // Platform must be running after successful recovery.
        XCTAssertTrue(platform.isEngineRunning, "platform should report running after recovery")
    }

    // MARK: - Test 2

    /// After an explicit `stopEngine()`, posting a configuration-change
    /// notification must NOT trigger any additional starter invocation, and the
    /// platform must remain stopped.
    func testConfigurationChangeAfterStopEngineDoesNotRestart() throws {
        // Arrange: count starter invocations.
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)

        let platform = AVAudioEngineMicrophonePlatform(
            engineStarter: { _, _, _, _ in
                invocationLock.withLock { count in count += 1 }
            }
        )

        // Start then stop.
        try platform.configureAndStart(vpioEnabled: false, bufferSize: 1024, tapHandler: { _, _ in })
        XCTAssertEqual(invocationLock.withLock { count in count }, 1)
        platform.stopEngine()
        XCTAssertFalse(platform.isEngineRunning)

        // Post a notification for an arbitrary engine.  The configuration-change
        // observer is registered with `object: audioEngine` and removed on
        // teardown, so the production notification will not route to the
        // platform's handler. We additionally post for a fresh engine to confirm
        // the gate-1 check (`running == false`) also suppresses any stale
        // queue.async blocks.
        let staleEngine = AVAudioEngine()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: staleEngine
        )

        // `isEngineRunning` calls `queue.sync { running }`.  Because the
        // notification handler enqueues work via `queue.async`, the sync read
        // is guaranteed to happen AFTER any queued recovery block — so this
        // single call flushes the queue without a sleep.
        XCTAssertFalse(platform.isEngineRunning, "platform must remain stopped after explicit stop")
        XCTAssertEqual(
            invocationLock.withLock { count in count },
            1,
            "starter must be called exactly once (initial start only)"
        )
    }

    // MARK: - Test 3

    /// A transient configuration-change recovery failure must not permanently
    /// kill a live capture. The platform retries with a fresh engine and the
    /// original start parameters, then returns to running once the route has
    /// settled.
    func testFailedRecoveryRetriesAndEventuallyRestartsEngine() throws {
        // Arrange: capture engine instances and count invocations.
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let routeSnapshotCount = OSAllocatedUnfairLock(initialState: 0)
        let vpioLock = OSAllocatedUnfairLock(initialState: [Bool]())
        let bufferSizeLock = OSAllocatedUnfairLock(initialState: [AVAudioFrameCount]())

        let firstStartExpectation = expectation(description: "first engineStarter call succeeds")
        let recoveryAttemptExpectation = expectation(description: "second engineStarter call (recovery throws)")
        let retryExpectation = expectation(description: "third engineStarter call succeeds")
        let unexpectedExtraRetry = expectation(description: "ready recovery does not retry again")
        unexpectedExtraRetry.isInverted = true
        let unexpectedStop = expectation(description: "ready recovery is not terminally stopped")
        unexpectedStop.isInverted = true
        let recoveryBuffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                routeSnapshotCount.withLock { $0 += 1 }
                return []
            },
            recoveryRetryDelays: [0],
            recoveryReadinessTimeout: 0.02,
            engineStarter: { engine, vpio, bufferSize, tapHandler in
                let count = invocationLock.withLock { c -> Int in
                    c += 1
                    return c
                }
                enginesLock.withLock { arr in arr.append(engine) }
                vpioLock.withLock { $0.append(vpio) }
                bufferSizeLock.withLock { $0.append(bufferSize) }
                switch count {
                case 1:
                    firstStartExpectation.fulfill()
                case 2:
                    recoveryAttemptExpectation.fulfill()
                    throw AVAudioEngineMicrophonePlatformError.noDeviceAvailable
                case 3:
                    tapHandler(recoveryBuffer.buffer, AVAudioTime(hostTime: 1))
                    retryExpectation.fulfill()
                default:
                    unexpectedExtraRetry.fulfill()
                }
            }
        )
        platform.setUnexpectedStopHandler {
            unexpectedStop.fulfill()
        }
        defer { platform.stopEngine() }

        // Act: first start succeeds.
        try platform.configureAndStart(vpioEnabled: false, bufferSize: 256, tapHandler: { _, _ in })
        wait(for: [firstStartExpectation], timeout: 1.0)

        let firstEngine = enginesLock.withLock { arr in arr }[0]

        // Post the notification for the live engine — triggers recovery (call 2, throws).
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )
        wait(for: [recoveryAttemptExpectation, retryExpectation], timeout: 2.0)
        wait(for: [unexpectedExtraRetry, unexpectedStop], timeout: 0.08)

        XCTAssertTrue(platform.isEngineRunning, "a transient recovery failure must not kill capture")
        XCTAssertEqual(invocationLock.withLock { c in c }, 3, "initial start + failed recovery + retry")

        let engines = enginesLock.withLock { arr in arr }
        XCTAssertEqual(engines.count, 3)
        guard engines.count == 3 else { return }
        XCTAssertFalse(engines[0] === engines[1])
        XCTAssertFalse(engines[1] === engines[2])
        XCTAssertEqual(vpioLock.withLock { $0 }, [false, false, false])
        XCTAssertEqual(bufferSizeLock.withLock { $0 }, [256, 256, 256])
        XCTAssertEqual(
            routeSnapshotCount.withLock { $0 },
            3,
            "every attempt must resolve the current input route again"
        )
    }

    // MARK: - Test 4

    /// Explicit Stop owns cancellation even while the physical engine is down
    /// between recovery attempts. A queued retry must never resurrect capture.
    func testStopEngineCancelsPendingRecoveryRetry() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let failedRecoveryExpectation = expectation(description: "immediate recovery fails")
        let unexpectedRetryExpectation = expectation(description: "cancelled retry must not run")
        unexpectedRetryExpectation.isInverted = true

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0.2],
            engineStarter: { engine, _, _, _ in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 2 {
                    failedRecoveryExpectation.fulfill()
                    throw AVAudioEngineMicrophonePlatformError.noDeviceAvailable
                }
                if count > 2 {
                    unexpectedRetryExpectation.fulfill()
                }
            }
        )

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )
        let firstEngine = enginesLock.withLock { $0[0] }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )
        wait(for: [failedRecoveryExpectation], timeout: 1.0)

        platform.stopEngine()
        wait(for: [unexpectedRetryExpectation], timeout: 0.3)

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 2)
    }

    // MARK: - Test 5

    /// A burst of stale notifications for the same failed engine coalesces via
    /// engine identity: replacing it once must not start parallel episodes.
    func testConfigurationChangeBurstDoesNotCreateRestartStorm() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let recoveryExpectation = expectation(description: "one recovery")
        let unexpectedExtraRecovery = expectation(description: "no extra recovery")
        unexpectedExtraRecovery.isInverted = true

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0],
            engineStarter: { engine, _, _, _ in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 2 {
                    recoveryExpectation.fulfill()
                } else if count > 2 {
                    unexpectedExtraRecovery.fulfill()
                }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )
        let firstEngine = enginesLock.withLock { $0[0] }
        for _ in 0..<5 {
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: firstEngine
            )
        }

        wait(for: [recoveryExpectation, unexpectedExtraRecovery], timeout: 1)
        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 2)
    }

    // MARK: - Test 6

    /// Once the bounded retry schedule is exhausted, ownership receives one
    /// terminal callback so it can invalidate subscriptions and surface the
    /// interruption instead of retaining a logically running ghost stream.
    func testRecoveryExhaustionReportsUnexpectedStopOnce() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let unexpectedStopCount = OSAllocatedUnfairLock(initialState: 0)
        let unexpectedStopExpectation = expectation(description: "unexpected stop reported")

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0, 0],
            engineStarter: { engine, _, _, _ in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                guard count == 1 else {
                    throw AVAudioEngineMicrophonePlatformError.noDeviceAvailable
                }
            }
        )
        platform.setUnexpectedStopHandler {
            unexpectedStopCount.withLock { $0 += 1 }
            unexpectedStopExpectation.fulfill()
        }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: true,
            bufferSize: 512,
            tapHandler: { _, _ in }
        )
        let firstEngine = enginesLock.withLock { $0[0] }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )

        wait(for: [unexpectedStopExpectation], timeout: 1.0)
        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(
            invocationLock.withLock { $0 },
            4,
            "initial start + immediate recovery + two scheduled retries"
        )
        XCTAssertEqual(unexpectedStopCount.withLock { $0 }, 1)
    }

    func testRecoveryStartWithoutFirstBufferRetriesFreshEngine() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let retryExpectation = expectation(description: "silent replacement is retired and retried")

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0],
            recoveryReadinessTimeout: 0.02,
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 3 {
                    retryExpectation.fulfill()
                }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )
        let firstEngine = enginesLock.withLock { $0[0] }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )

        wait(for: [retryExpectation], timeout: 1.0)

        let engines = enginesLock.withLock { $0 }
        XCTAssertEqual(engines.count, 3, "initial start + silent replacement + retry")
        XCTAssertFalse(engines[1] === engines[2], "the retry must use a fresh engine")
    }

    func testRecoveryStartWithoutFirstBufferEventuallyReportsUnexpectedStop() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let unexpectedStopExpectation = expectation(description: "silent recovery exhausts")

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [],
            recoveryReadinessTimeout: 0.02,
            engineStarter: { engine, _, _, _ in
                invocationLock.withLock { $0 += 1 }
                enginesLock.withLock { $0.append(engine) }
            }
        )
        platform.setUnexpectedStopHandler {
            unexpectedStopExpectation.fulfill()
        }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )
        let firstEngine = enginesLock.withLock { $0[0] }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )

        wait(for: [unexpectedStopExpectation], timeout: 1.0)

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 2, "initial start + one silent recovery")
    }

    func testStopEngineCancelsSilentRecoveryReadinessTimeout() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let silentRecoveryStarted = expectation(description: "silent recovery starts")
        let unexpectedRetry = expectation(description: "stop prevents readiness retry")
        unexpectedRetry.isInverted = true
        let unexpectedStop = expectation(description: "stop is not terminal engine death")
        unexpectedStop.isInverted = true

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0],
            recoveryReadinessTimeout: 0.05,
            engineStarter: { engine, _, _, _ in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 2 {
                    silentRecoveryStarted.fulfill()
                } else if count > 2 {
                    unexpectedRetry.fulfill()
                }
            }
        )
        platform.setUnexpectedStopHandler {
            unexpectedStop.fulfill()
        }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )
        let firstEngine = enginesLock.withLock { $0[0] }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )
        wait(for: [silentRecoveryStarted], timeout: 1.0)

        platform.stopEngine()
        wait(for: [unexpectedRetry, unexpectedStop], timeout: 0.15)

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 2)
    }

    func testConfigurationChangesDuringRecoveryDoNotReplenishRetryBudget() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let secondAttempt = expectation(description: "immediate recovery attempt")
        let thirdAttempt = expectation(description: "first scheduled retry")
        let fourthAttempt = expectation(description: "second scheduled retry")
        let unexpectedFifthAttempt = expectation(description: "retry budget must remain bounded")
        unexpectedFifthAttempt.isInverted = true
        let exhausted = expectation(description: "bounded recovery exhausts")

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0, 0],
            recoveryReadinessTimeout: 5,
            engineStarter: { engine, _, _, _ in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                switch count {
                case 2:
                    secondAttempt.fulfill()
                case 3:
                    thirdAttempt.fulfill()
                case 4:
                    fourthAttempt.fulfill()
                case 5...:
                    unexpectedFifthAttempt.fulfill()
                default:
                    break
                }
            }
        )
        platform.setUnexpectedStopHandler {
            exhausted.fulfill()
        }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        func interruptCurrentEngine(
            thenWaitFor expectation: XCTestExpectation
        ) {
            let engine = enginesLock.withLock { $0.last! }
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
            wait(for: [expectation], timeout: 1)
            _ = platform.isEngineRunning
        }

        interruptCurrentEngine(thenWaitFor: secondAttempt)
        interruptCurrentEngine(thenWaitFor: thirdAttempt)
        interruptCurrentEngine(thenWaitFor: fourthAttempt)

        let finalEngine = enginesLock.withLock { $0.last! }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: finalEngine
        )
        wait(for: [exhausted, unexpectedFifthAttempt], timeout: 1)

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 4)
    }
}

private func makeRecoveryTestBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
    buffer.frameLength = 32
    return buffer
}
