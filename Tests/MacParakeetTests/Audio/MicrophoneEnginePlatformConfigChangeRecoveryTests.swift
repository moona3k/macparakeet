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

    func testRunningConfigurationChangeNotifiesInputRouteConsumers() throws {
        let routeChange = expectation(description: "route consumers are notified")
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())
        let token = NotificationCenter.default.addObserver(
            forName: .macParakeetMicrophoneSelectionDidChange,
            object: nil,
            queue: nil
        ) { _ in
            routeChange.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [],
            engineStarter: { _, _, _, tapHandler in
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
            }
        )
        defer { platform.stopEngine() }
        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: platform.preparedEngineStateForTesting.engine
        )

        wait(for: [routeChange], timeout: 0.5)
    }

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
                tapHandler(recoveryBuffer.buffer, AVAudioTime(hostTime: UInt64(engines.count)))
                if engines.count == 2 {
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            engineStarter: { _, _, _, tapHandler in
                invocationLock.withLock { count in count += 1 }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
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
                    tapHandler(recoveryBuffer.buffer, AVAudioTime(hostTime: 1))
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0.2],
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 1 {
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                }
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0],
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: UInt64(count)))
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0, 0],
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                guard count == 1 else {
                    throw AVAudioEngineMicrophonePlatformError.noDeviceAvailable
                }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0],
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 1 || count == 3 {
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: UInt64(count)))
                }
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [],
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 1 {
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                }
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0],
            startupReadinessTimeout: 5,
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                if count == 1 {
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                } else if count == 2 {
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

        let stopStartedAt = ContinuousClock.now
        platform.stopEngine()
        let stopDuration = stopStartedAt.duration(to: .now)
        wait(for: [unexpectedRetry, unexpectedStop], timeout: 0.15)

        XCTAssertLessThan(
            stopDuration,
            .seconds(1),
            "stop must cancel the readiness wait instead of blocking for its five-second timeout"
        )
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
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [0, 0],
            engineStarter: { engine, _, _, tapHandler in
                let count = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                switch count {
                case 1:
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                case 2:
                    secondAttempt.fulfill()
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 2))
                    NotificationCenter.default.post(
                        name: .AVAudioEngineConfigurationChange,
                        object: engine
                    )
                case 3:
                    thirdAttempt.fulfill()
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 3))
                    NotificationCenter.default.post(
                        name: .AVAudioEngineConfigurationChange,
                        object: engine
                    )
                case 4:
                    fourthAttempt.fulfill()
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 4))
                    NotificationCenter.default.post(
                        name: .AVAudioEngineConfigurationChange,
                        object: engine
                    )
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

        let firstEngine = enginesLock.withLock { $0[0] }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )
        wait(
            for: [secondAttempt, thirdAttempt, fourthAttempt, exhausted, unexpectedFifthAttempt],
            timeout: 1
        )

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 4)
    }

    /// A route change can leave AVAudioEngine claiming it is running after a
    /// few tap callbacks, while no further audio arrives. Recover that stalled
    /// callback stream on a fresh engine even without another configuration
    /// notification.
    func testCallbackStallAfterFirstBufferRestartsFreshEngine() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let recoveryExpectation = expectation(description: "callback stall starts recovery")
        let recoveryBuffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [],
            callbackStallTimeout: 0.02,
            callbackStallCheckInterval: 0.005,
            engineStarter: { engine, _, _, tapHandler in
                let invocation = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                enginesLock.withLock { $0.append(engine) }
                tapHandler(recoveryBuffer.buffer, AVAudioTime(hostTime: UInt64(invocation)))
                if invocation == 2 {
                    recoveryExpectation.fulfill()
                }
            }
        )
        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        wait(for: [recoveryExpectation], timeout: 1)
        XCTAssertTrue(platform.isEngineRunning)
        platform.stopEngine()

        let engines = enginesLock.withLock { $0 }
        XCTAssertEqual(engines.count, 2, "initial start + callback-stall recovery")
        guard engines.count == 2 else { return }
        XCTAssertFalse(engines[0] === engines[1], "recovery must rebuild the engine")
    }

    func testContinuousCallbackActivityDoesNotRecoverPastStallTimeout() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let unexpectedRecovery = expectation(description: "callback activity remains healthy")
        unexpectedRecovery.isInverted = true
        let tapHandlerLock = OSAllocatedUnfairLock<
            (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        >(initialState: nil)
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            callbackStallTimeout: 1,
            callbackStallCheckInterval: 0.02,
            engineStarter: { _, _, _, tapHandler in
                let invocation = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                tapHandlerLock.withLock { $0 = tapHandler }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: UInt64(invocation)))
                if invocation == 2 {
                    unexpectedRecovery.fulfill()
                }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        let installedTapHandler = try XCTUnwrap(tapHandlerLock.withLock { $0 })
        for callback in 2...150 {
            Thread.sleep(forTimeInterval: 0.01)
            installedTapHandler(
                buffer.buffer,
                AVAudioTime(hostTime: UInt64(callback))
            )
        }

        wait(for: [unexpectedRecovery], timeout: 0.01)
        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 1)
    }

    func testStopEngineCancelsCallbackStallDetection() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            callbackStallTimeout: 0.02,
            callbackStallCheckInterval: 0.005,
            engineStarter: { _, _, _, tapHandler in
                invocationLock.withLock { $0 += 1 }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
            }
        )

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )
        platform.stopEngine()
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 1)
    }

    func testCallbackStallRecoveryFailureReportsUnexpectedStop() throws {
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)
        let buffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer())
        let unexpectedStop = expectation(description: "failed callback-stall recovery is terminal")

        let platform = AVAudioEngineMicrophonePlatform(
            recoveryRetryDelays: [],
            callbackStallTimeout: 0.02,
            callbackStallCheckInterval: 0.005,
            engineStarter: { _, _, _, tapHandler in
                let invocation = invocationLock.withLock { value -> Int in
                    value += 1
                    return value
                }
                guard invocation == 1 else {
                    throw AVAudioEngineMicrophonePlatformError.noDeviceAvailable
                }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
            }
        )
        platform.setUnexpectedStopHandler {
            unexpectedStop.fulfill()
        }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        wait(for: [unexpectedStop], timeout: 1)
        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationLock.withLock { $0 }, 2)
    }

    func testSustainedBluetoothZeroFilledCallbacksRecoverThroughFallbackRoute() throws {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let deliveredBufferCount = OSAllocatedUnfairLock(initialState: 0)
        let currentDeviceID = OSAllocatedUnfairLock<AudioDeviceID?>(initialState: nil)
        let uptimeNanoseconds = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let initialTapHandler = OSAllocatedUnfairLock<
            (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        >(initialState: nil)
        let zeroBuffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer(nonZero: false))
        let signalBuffer = UncheckedSendableAudioPCMBuffer(
            makeRecoveryTestBuffer(nonZero: true)
        )

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [
                    MeetingInputDeviceAttempt(
                        source: .selected(uid: "bluetooth"),
                        deviceID: 10
                    ),
                    MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20),
                ]
            },
            inputDeviceSetter: { deviceID, _ in
                currentDeviceID.withLock { $0 = deviceID }
                return true
            },
            recoveryRetryDelays: [],
            startupReadinessTimeout: 0,
            bluetoothInputState: { $0 == 10 },
            callbackUptimeProvider: { uptimeNanoseconds.withLock { $0 } },
            callbackStallTimeout: 1,
            zeroFilledTimeout: 0.02,
            callbackStallCheckInterval: 0,
            engineStarter: { _, _, _, tapHandler in
                let invocation = invocationCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                let deviceID = currentDeviceID.withLock { $0 }
                switch (invocation, deviceID) {
                case (1, 10):
                    initialTapHandler.withLock { $0 = tapHandler }
                    tapHandler(signalBuffer.buffer, AVAudioTime(hostTime: 1))
                case (2, 10):
                    tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 2))
                case (3, 20):
                    tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 3))
                default:
                    XCTFail("Unexpected start attempt \(invocation) for device \(String(describing: deviceID))")
                }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in
                deliveredBufferCount.withLock { $0 += 1 }
            }
        )
        let tapHandler = try XCTUnwrap(initialTapHandler.withLock { $0 })

        for hostTime in 2...12 {
            uptimeNanoseconds.withLock { $0 = UInt64(hostTime) * 5_000_000 }
            tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: UInt64(hostTime)))
        }
        platform.checkCallbackLivenessNowForTesting()

        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertEqual(invocationCount.withLock { $0 }, 3)
        XCTAssertEqual(
            deliveredBufferCount.withLock { $0 },
            2,
            "Bluetooth zero-filled buffers must not reach consumers"
        )
        XCTAssertEqual(
            platform.lastSucceededAttempt,
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)
        )
    }

    /// A replacement's first usable buffer is only readiness, not proof that
    /// the route has recovered durably. Repeated short-lived starts must consume
    /// one bounded episode instead of resetting the budget forever.
    func testRepeatedOneBufferThenBluetoothZeroExhaustsSingleRecoveryEpisode() throws {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let currentTapHandler = OSAllocatedUnfairLock<
            (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        >(initialState: nil)
        let uptimeNanoseconds = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let unexpectedStop = expectation(description: "unstable recovery is exhausted")
        let zeroBuffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer(nonZero: false))
        let signalBuffer = UncheckedSendableAudioPCMBuffer(
            makeRecoveryTestBuffer(nonZero: true)
        )

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [MeetingInputDeviceAttempt(source: .selected(uid: "bluetooth"), deviceID: 10)]
            },
            inputDeviceSetter: { _, _ in true },
            recoveryRetryDelays: [],
            startupReadinessTimeout: 0,
            bluetoothInputState: { $0 == 10 },
            callbackUptimeProvider: { uptimeNanoseconds.withLock { $0 } },
            callbackStallTimeout: 1,
            zeroFilledTimeout: 0.02,
            callbackStallCheckInterval: 0,
            engineStarter: { _, _, _, tapHandler in
                let invocation = invocationCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                currentTapHandler.withLock { $0 = tapHandler }
                tapHandler(signalBuffer.buffer, AVAudioTime(hostTime: UInt64(invocation)))
            }
        )
        platform.setUnexpectedStopHandler {
            unexpectedStop.fulfill()
        }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        for cycle in 0..<2 {
            let tapHandler = try XCTUnwrap(currentTapHandler.withLock { $0 })
            let base = UInt64(cycle) * 50_000_000
            uptimeNanoseconds.withLock { $0 = base + 5_000_000 }
            tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: base + 1))
            uptimeNanoseconds.withLock { $0 = base + 30_000_000 }
            tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: base + 2))
            platform.checkCallbackLivenessNowForTesting()
        }

        wait(for: [unexpectedStop], timeout: 1)
        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(
            invocationCount.withLock { $0 },
            2,
            "the replacement may start once, but its short-lived success must not create a new episode"
        )
    }

    func testHealthyRecoveryCompletesProbationBeforeLaterFailureStartsNewEpisode() throws {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let currentTapHandler = OSAllocatedUnfairLock<
            (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        >(initialState: nil)
        let uptimeNanoseconds = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let unexpectedStop = expectation(description: "healthy recovery keeps future budget")
        unexpectedStop.isInverted = true
        let zeroBuffer = UncheckedSendableAudioPCMBuffer(makeRecoveryTestBuffer(nonZero: false))
        let signalBuffer = UncheckedSendableAudioPCMBuffer(
            makeRecoveryTestBuffer(nonZero: true)
        )

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [MeetingInputDeviceAttempt(source: .selected(uid: "bluetooth"), deviceID: 10)]
            },
            inputDeviceSetter: { _, _ in true },
            recoveryRetryDelays: [],
            startupReadinessTimeout: 0,
            bluetoothInputState: { $0 == 10 },
            callbackUptimeProvider: { uptimeNanoseconds.withLock { $0 } },
            callbackStallTimeout: 1,
            zeroFilledTimeout: 0.02,
            callbackStallCheckInterval: 0,
            engineStarter: { _, _, _, tapHandler in
                let invocation = invocationCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                currentTapHandler.withLock { $0 = tapHandler }
                tapHandler(signalBuffer.buffer, AVAudioTime(hostTime: UInt64(invocation)))
            }
        )
        platform.setUnexpectedStopHandler {
            unexpectedStop.fulfill()
        }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        let firstTapHandler = try XCTUnwrap(currentTapHandler.withLock { $0 })
        uptimeNanoseconds.withLock { $0 = 5_000_000 }
        firstTapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 1))
        uptimeNanoseconds.withLock { $0 = 30_000_000 }
        firstTapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 2))
        platform.checkCallbackLivenessNowForTesting()
        XCTAssertEqual(invocationCount.withLock { $0 }, 2)

        let recoveredTapHandler = try XCTUnwrap(currentTapHandler.withLock { $0 })
        uptimeNanoseconds.withLock { $0 = 500_000_000 }
        recoveredTapHandler(signalBuffer.buffer, AVAudioTime(hostTime: 3))
        platform.checkCallbackLivenessNowForTesting()
        uptimeNanoseconds.withLock { $0 = 1_100_000_000 }
        recoveredTapHandler(signalBuffer.buffer, AVAudioTime(hostTime: 4))
        platform.checkCallbackLivenessNowForTesting()

        uptimeNanoseconds.withLock { $0 = 1_105_000_000 }
        recoveredTapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 5))
        uptimeNanoseconds.withLock { $0 = 1_130_000_000 }
        recoveredTapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 6))
        platform.checkCallbackLivenessNowForTesting()

        wait(for: [unexpectedStop], timeout: 0.05)
        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertEqual(
            invocationCount.withLock { $0 },
            3,
            "a replacement that survived probation must earn a fresh future episode"
        )
    }
}

private func makeRecoveryTestBuffer(nonZero: Bool = true) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
    buffer.frameLength = 32
    if nonZero {
        buffer.floatChannelData?[0][0] = 0.001
    }
    return buffer
}
