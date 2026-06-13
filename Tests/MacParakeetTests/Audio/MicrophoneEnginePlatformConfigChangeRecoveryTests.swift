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

        let platform = AVAudioEngineMicrophonePlatform(
            engineStarter: { engine, vpio, bufferSize, _ in
                let engines = enginesLock.withLock { engines -> [AVAudioEngine] in
                    engines.append(engine)
                    return engines
                }
                vpioLock.withLock { arr in arr.append(vpio) }
                bufferSizeLock.withLock { arr in arr.append(bufferSize) }
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

    /// When the recovery attempt itself throws, the platform is left with
    /// `running == false`. A subsequent notification post must NOT trigger
    /// another attempt (no retry loop), and exactly 2 starter invocations
    /// occur in total.
    func testFailedRecoveryLeavesEngineStopped() throws {
        // Arrange: capture engine instances and count invocations.
        let enginesLock = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let invocationLock = OSAllocatedUnfairLock(initialState: 0)

        let firstStartExpectation = expectation(description: "first engineStarter call succeeds")
        let recoveryAttemptExpectation = expectation(description: "second engineStarter call (recovery throws)")
        // Inverted: must NOT be fulfilled by a third call.
        let noThirdCallExpectation = expectation(description: "third engineStarter call must not happen")
        noThirdCallExpectation.isInverted = true

        let platform = AVAudioEngineMicrophonePlatform(
            engineStarter: { engine, _, _, _ in
                let count = invocationLock.withLock { c -> Int in
                    c += 1
                    return c
                }
                enginesLock.withLock { arr in arr.append(engine) }
                switch count {
                case 1:
                    firstStartExpectation.fulfill()
                case 2:
                    recoveryAttemptExpectation.fulfill()
                    throw AVAudioEngineMicrophonePlatformError.noDeviceAvailable
                default:
                    noThirdCallExpectation.fulfill()
                }
            }
        )
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
        wait(for: [recoveryAttemptExpectation], timeout: 2.0)

        // Platform must be stopped (recovery failed).
        XCTAssertFalse(platform.isEngineRunning, "failed recovery must leave platform stopped")
        XCTAssertEqual(invocationLock.withLock { c in c }, 2, "exactly 2 starter invocations total")

        // Post again — running == false so gate 1 suppresses any further attempt.
        // The previously-registered observer was also removed when tearDownLocked
        // ran during the failed recovery, so the production object-match gate
        // additionally suppresses it.
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: firstEngine
        )
        // Flush the queue by reading isEngineRunning (queue.sync).
        _ = platform.isEngineRunning
        // Short wait for the inverted expectation to confirm no third call.
        wait(for: [noThirdCallExpectation], timeout: 0.3)
        XCTAssertEqual(
            invocationLock.withLock { c in c },
            2,
            "still exactly 2 invocations after second notification"
        )
    }
}
