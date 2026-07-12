import AVFoundation
import CoreAudio
import os
import XCTest
@testable import MacParakeetCore

/// Integration tests that drive the real `AVAudioEngineMicrophonePlatform`
/// against a real microphone, verifying the contract `SharedMicrophoneStream`
/// is supposed to enforce per ADR-015 and PR #189:
///
///   Subscribe → buffers arrive within deadline, regardless of prior state.
///
/// These complement the existing mock-based `SharedMicrophoneStreamTests`,
/// which exercise orchestration but cannot reach the real macOS HAL where
/// the `2026-05-03` silent-tap-stall bug lives. See:
///   - `journal/2026-05-03-dictation-silent-stall.md` (diagnosis)
///   - `plans/active/2026-05-dictation-stall-integration-tests.md` (this plan)
///   - PR #210 (passive instrumentation that paired with this work)
///
/// ## Running
///
/// Default `swift test` skips this suite. To run:
///
/// ```
/// MACPARAKEET_HARDWARE_TESTS=1 swift test \
///     --filter MicrophoneEngineRealPlatformTests
/// ```
///
/// The 3-minute idle-gap test is additionally gated on
/// `MACPARAKEET_SLOW_HARDWARE_TESTS=1` so a normal hardware run stays under
/// ~30 seconds.
///
/// The tests that mutate system audio state have their own gates:
/// `MACPARAKEET_STRESS_HARDWARE_TESTS=1` for long cycle stress and
/// `MACPARAKEET_HAL_MUTATION_TESTS=1` for default-input switching.
///
/// ## Why these can't run in CI
///
/// Real microphone access requires TCC permission for the test runner and a
/// live (or virtual) input device on the host. Headless CI has neither.
/// Wiring this into CI would mean per-runner mic provisioning plus
/// non-deterministic outputs — both bigger problems than this suite solves.
final class MicrophoneEngineRealPlatformTests: XCTestCase {

    /// First-buffer deadline. Production captures show 100–200 ms first-buffer
    /// latency on a healthy system; 1 s is a 5× safety margin.
    private static let firstBufferDeadline: TimeInterval = 1.0

    /// Production buffer size used by both dictation and meeting recording.
    private static let bufferSize: AVAudioFrameCount = 4096

    private static let halMutationBufferDeadline: TimeInterval = 2.0
    private static let halMutationDeviceDeadline: TimeInterval = 5.0

    private var platform: AVAudioEngineMicrophonePlatform!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPARAKEET_HARDWARE_TESTS"] == "1",
            "Set MACPARAKEET_HARDWARE_TESTS=1 to run real-platform integration tests."
        )
        platform = AVAudioEngineMicrophonePlatform()
    }

    override func tearDown() async throws {
        platform?.stopEngine()
        platform = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Cold-start case: a fresh `AVAudioEngineMicrophonePlatform` in a fresh
    /// process must deliver buffers within the deadline. If this fails, the
    /// platform itself is broken and the bug doesn't even need a transition
    /// to manifest.
    func testColdStartDeliversBuffers() async throws {
        let count = try await subscribeAndAwaitFirstBuffer(vpioEnabled: false)
        XCTAssertGreaterThan(
            count, 0,
            "Cold-start subscribe should deliver at least one buffer within \(Self.firstBufferDeadline)s."
        )
    }

    /// Cycle case: subscribe → stop → subscribe. Exercises the engine
    /// teardown/recreate path that PR #189 introduced. The bug hypothesis is
    /// that the freshly-created `AVAudioEngine` reports `isRunning = true`
    /// from `start()` but the HAL hasn't actually attached yet.
    func testPostCycleDeliversBuffers() async throws {
        _ = try await subscribeAndAwaitFirstBuffer(vpioEnabled: false)
        platform.stopEngine()

        let count = try await subscribeAndAwaitFirstBuffer(vpioEnabled: false)
        XCTAssertGreaterThan(
            count, 0,
            "Subscribe immediately after stop should deliver buffers — engine recreate must not lose the input chain."
        )
    }

    /// Prepared-start case: pay device/format setup while stopped, then verify
    /// the matching start produces real input buffers through the prepared tap.
    func testPreparedStartDeliversBuffers() async throws {
        platform.stopEngine()
        platform = try makePreparablePlatform()
        let preparedHandlerCounter = OSAllocatedUnfairLock(initialState: 0)
        let activeHandlerCounter = OSAllocatedUnfairLock(initialState: 0)
        let preparedHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { _, _ in
            preparedHandlerCounter.withLock { $0 += 1 }
        }
        let activeHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { _, _ in
            activeHandlerCounter.withLock { $0 += 1 }
        }

        platform.prepare(
            vpioEnabled: false,
            bufferSize: Self.bufferSize,
            tapHandler: preparedHandler
        )

        let configureStartedAt = ContinuousClock.now
        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: Self.bufferSize,
            tapHandler: activeHandler
        )
        let configureDuration = configureStartedAt.duration(to: .now)
        XCTAssertLessThan(
            configureDuration,
            .milliseconds(500),
            "Prepared configure should use the start-only fast path, not the full cold path."
        )

        let count = try await awaitCounterIncrease(
            counter: activeHandlerCounter,
            from: 0,
            timeout: Self.firstBufferDeadline
        )
        XCTAssertGreaterThan(count, 0, "A matching prepared start should deliver microphone buffers.")
        XCTAssertEqual(
            preparedHandlerCounter.withLock { $0 },
            0,
            "Prepared starts must dispatch through the latest configureAndStart handler."
        )
    }

    /// Core Audio can renegotiate the input chain while a stopped engine is
    /// waiting for key-down. The configuration observer must discard that
    /// preparation so the next start cannot reuse a stale tap format.
    func testConfigurationChangeDiscardsPreparedEngine() throws {
        platform.stopEngine()
        platform = try makePreparablePlatform()

        platform.prepare(
            vpioEnabled: false,
            bufferSize: Self.bufferSize,
            tapHandler: { _, _ in }
        )
        let before = platform.preparedEngineStateForTesting
        XCTAssertTrue(before.prepared)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: before.engine
        )
        _ = platform.isEngineRunning  // queue sync flushes observer invalidation

        let after = platform.preparedEngineStateForTesting
        XCTAssertFalse(after.prepared)
        XCTAssertFalse(
            before.engine === after.engine,
            "A configuration change must replace the stale prepared engine."
        )
    }

    /// The observer must cover the preparation work itself, not only the idle
    /// interval after preparation completes. Simulate Core Audio renegotiating
    /// immediately after device selection and verify the result is never
    /// published as reusable.
    func testConfigurationChangeDuringPreparationDiscardsEngine() throws {
        platform.stopEngine()

        let builtInDeviceID = AudioDeviceManager.builtInMicrophone()
        let deviceID = builtInDeviceID ?? AudioDeviceManager.defaultInputDevice()
        guard let deviceID else {
            throw XCTSkip("Need a resolved input device for stopped-engine preparation.")
        }
        guard AudioDeviceManager.bluetoothInputState(deviceID) == false else {
            throw XCTSkip(
                "Stopped-engine preparation is intentionally disabled for Bluetooth or unresolved inputs."
            )
        }
        let source: MeetingInputDeviceAttempt.Source = builtInDeviceID == nil ? .systemDefault : .builtIn
        let attempt = MeetingInputDeviceAttempt(source: source, deviceID: deviceID)
        platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: { [attempt] in [attempt] },
            inputDeviceSetter: { deviceID, engine in
                guard AudioDeviceManager.setInputDevice(deviceID, on: engine) else { return false }
                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange,
                    object: engine
                )
                return true
            }
        )

        platform.prepare(
            vpioEnabled: false,
            bufferSize: Self.bufferSize,
            tapHandler: { _, _ in }
        )
        _ = platform.isEngineRunning  // flush queued observer work

        XCTAssertFalse(
            platform.preparedEngineStateForTesting.prepared,
            "A configuration change during preparation must prevent prepared-engine reuse."
        )
    }

    /// Mismatch case: a prepared tap must be torn down before falling back to
    /// full configuration, otherwise AVAudioEngine rejects the second tap.
    func testPreparedStartWithDifferentBufferSizeFallsBackCleanly() async throws {
        platform.stopEngine()
        platform = try makePreparablePlatform()
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let handler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { _, _ in
            counter.withLock { $0 += 1 }
        }

        platform.prepare(
            vpioEnabled: false,
            bufferSize: Self.bufferSize,
            tapHandler: handler
        )

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: Self.bufferSize / 2,
            tapHandler: handler
        )

        let count = try await awaitCounterIncrease(
            counter: counter,
            from: 0,
            timeout: Self.firstBufferDeadline
        )
        XCTAssertGreaterThan(count, 0, "A mismatched prepared start should fall back and deliver buffers.")
    }

    /// VPIO transition case: subscribe with VPIO enabled (simulates meeting
    /// recording starting), then with VPIO disabled (simulates dictation).
    /// This is the path the journal originally suspected before the
    /// invariant framing widened the hypothesis.
    func testPostVPIODeliversBuffers() async throws {
        _ = try await subscribeAndAwaitFirstBuffer(vpioEnabled: true)
        platform.stopEngine()

        let count = try await subscribeAndAwaitFirstBuffer(vpioEnabled: false)
        XCTAssertGreaterThan(
            count, 0,
            "Subscribe after VPIO teardown should deliver buffers — coreaudiod's VPAU aggregate must release cleanly."
        )
    }

    /// Product-path concurrency case: meeting mic subscribes first with VPIO,
    /// then dictation joins as a non-VPIO subscriber. This drives the real
    /// `SharedMicrophoneStream` and verifies both subscribers keep seeing
    /// buffers from the single VPIO engine.
    func testConcurrentVPIODeliversBuffersToLateNonVPIOSubscriber() async throws {
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: Self.bufferSize)
        let vpioCounter = OSAllocatedUnfairLock(initialState: 0)
        let dictationCounter = OSAllocatedUnfairLock(initialState: 0)
        var tokens: [SharedMicrophoneStream.SubscriberToken] = []

        do {
            let vpioToken = try await stream.subscribe(wantsVPIO: true) { _, _ in
                vpioCounter.withLock { $0 += 1 }
            }
            tokens.append(vpioToken)

            let firstVPIOCount = try await awaitCounterIncrease(
                counter: vpioCounter,
                from: 0,
                timeout: Self.firstBufferDeadline
            )
            XCTAssertGreaterThan(firstVPIOCount, 0, "VPIO subscriber should receive buffers.")
            XCTAssertTrue(stream.diagnostics.vpioEngaged)

            let dictationToken = try await stream.subscribe(wantsVPIO: false) { _, _ in
                dictationCounter.withLock { $0 += 1 }
            }
            tokens.append(dictationToken)

            let dictationCount = try await awaitCounterIncrease(
                counter: dictationCounter,
                from: 0,
                timeout: Self.firstBufferDeadline
            )
            XCTAssertGreaterThan(
                dictationCount,
                0,
                "Non-VPIO subscriber joining an active VPIO engine should receive buffers."
            )

            let secondVPIOCount = try await awaitCounterIncrease(
                counter: vpioCounter,
                from: firstVPIOCount,
                timeout: Self.firstBufferDeadline
            )
            XCTAssertGreaterThan(
                secondVPIOCount,
                firstVPIOCount,
                "Existing VPIO subscriber should keep receiving buffers after dictation joins."
            )
            XCTAssertEqual(stream.diagnostics.subscriberCount, 2)
        } catch {
            await unsubscribeAll(&tokens, from: stream)
            throw error
        }

        await unsubscribeAll(&tokens, from: stream)
    }

    /// Edge-path concurrency case: dictation subscribes first, a meeting wants
    /// VPIO while dictation is still in flight, then dictation leaves and the
    /// remaining meeting subscriber must survive the raw -> VPIO promotion.
    func testDeferredVPIOPromotionDeliversBuffersAfterRawSubscriberLeaves() async throws {
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: Self.bufferSize)
        let dictationCounter = OSAllocatedUnfairLock(initialState: 0)
        let vpioCounter = OSAllocatedUnfairLock(initialState: 0)
        var tokens: [SharedMicrophoneStream.SubscriberToken] = []

        do {
            let dictationToken = try await stream.subscribe(wantsVPIO: false) { _, _ in
                dictationCounter.withLock { $0 += 1 }
            }
            tokens.append(dictationToken)

            _ = try await awaitCounterIncrease(
                counter: dictationCounter,
                from: 0,
                timeout: Self.firstBufferDeadline
            )

            let vpioToken = try await stream.subscribe(wantsVPIO: true) { _, _ in
                vpioCounter.withLock { $0 += 1 }
            }
            tokens.append(vpioToken)

            XCTAssertFalse(stream.diagnostics.vpioEngaged)
            XCTAssertTrue(stream.diagnostics.vpioDeferred)

            let deferredVPIOCount = try await awaitCounterIncrease(
                counter: vpioCounter,
                from: 0,
                timeout: Self.firstBufferDeadline
            )
            XCTAssertGreaterThan(
                deferredVPIOCount,
                0,
                "Deferred VPIO subscriber should still receive raw-engine buffers."
            )

            await stream.unsubscribe(dictationToken)
            tokens.removeAll { $0 == dictationToken }

            XCTAssertTrue(stream.diagnostics.vpioEngaged)
            XCTAssertFalse(stream.diagnostics.vpioDeferred)

            let promotedVPIOCount = try await awaitCounterIncrease(
                counter: vpioCounter,
                from: deferredVPIOCount,
                timeout: Self.firstBufferDeadline
            )
            XCTAssertGreaterThan(
                promotedVPIOCount,
                deferredVPIOCount,
                "Remaining VPIO subscriber should keep receiving buffers after promotion."
            )
        } catch {
            await unsubscribeAll(&tokens, from: stream)
            throw error
        }

        await unsubscribeAll(&tokens, from: stream)
    }

    /// Stress: 10 back-to-back subscribe/stop cycles. If any one cycle fails
    /// to deliver buffers, surface which cycle. Catches timing-flaky variants
    /// of the bug that pass single-shot tests.
    func testStressTenCycles() async throws {
        for cycle in 0..<10 {
            let count = try await subscribeAndAwaitFirstBuffer(vpioEnabled: false)
            XCTAssertGreaterThan(
                count, 0,
                "Cycle \(cycle) should deliver buffers within \(Self.firstBufferDeadline)s."
            )
            platform.stopEngine()
        }
    }

    /// Heavier opt-in stress: repeat the product-path shared stream lifecycle
    /// while alternating raw and VPIO starts. This is intentionally separate
    /// from the normal hardware gate so routine local runs stay short.
    func testStressFiftySharedStreamCycles() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPARAKEET_STRESS_HARDWARE_TESTS"] == "1",
            "Set MACPARAKEET_STRESS_HARDWARE_TESTS=1 to run long shared-stream stress."
        )

        let stream = SharedMicrophoneStream(platform: platform, bufferSize: Self.bufferSize)
        var tokens: [SharedMicrophoneStream.SubscriberToken] = []

        do {
            for cycle in 0..<50 {
                let wantsVPIO = cycle % 2 == 0
                let counter = OSAllocatedUnfairLock(initialState: 0)
                let token = try await stream.subscribe(wantsVPIO: wantsVPIO) { _, _ in
                    counter.withLock { $0 += 1 }
                }
                tokens.append(token)

                let count = try await awaitCounterIncrease(
                    counter: counter,
                    from: 0,
                    timeout: Self.firstBufferDeadline
                )
                XCTAssertGreaterThan(
                    count,
                    0,
                    "Shared-stream stress cycle \(cycle) should deliver buffers within \(Self.firstBufferDeadline)s."
                )

                await stream.unsubscribe(token)
                tokens.removeAll { $0 == token }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            await unsubscribeAll(&tokens, from: stream)
            throw error
        }

        await unsubscribeAll(&tokens, from: stream)
    }

    /// HAL mutation case: while the shared stream is running, switch the
    /// system default input device away and back, then assert buffers still
    /// arrive. This is the closest active reproducer for the field signature
    /// where Core Audio configuration changed around the stall window.
    ///
    /// Gated separately because it changes the user's default microphone.
    func testDefaultInputSwitchWhileSharedStreamRunningKeepsDeliveringBuffers() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPARAKEET_HAL_MUTATION_TESTS"] == "1",
            "Set MACPARAKEET_HAL_MUTATION_TESTS=1 to run default-input mutation."
        )

        guard let originalDefault = AudioDeviceManager.defaultInputDevice(),
            let alternate = alternateInputDevice(excluding: originalDefault)
        else {
            throw XCTSkip("Need at least two input devices to run default-input mutation.")
        }

        let stream = SharedMicrophoneStream(platform: platform, bufferSize: Self.bufferSize)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        var tokens: [SharedMicrophoneStream.SubscriberToken] = []

        do {
            let token = try await stream.subscribe(wantsVPIO: false) { _, _ in
                counter.withLock { $0 += 1 }
            }
            tokens.append(token)

            _ = try await awaitCounterIncrease(
                counter: counter,
                from: 0,
                timeout: Self.firstBufferDeadline
            )

            try setSystemDefaultInputDevice(alternate.id)
            try await waitForDefaultInputDevice(
                alternate.id,
                timeout: Self.halMutationDeviceDeadline
            )

            let switchedBaseline = counter.withLock { $0 }
            let switchedCount = try await awaitCounterIncrease(
                counter: counter,
                from: switchedBaseline,
                timeout: Self.halMutationBufferDeadline
            )
            XCTAssertGreaterThan(
                switchedCount,
                switchedBaseline,
                "Shared stream should keep delivering buffers after default-input switch."
            )

            try setSystemDefaultInputDevice(originalDefault)
            try await waitForDefaultInputDevice(
                originalDefault,
                timeout: Self.halMutationDeviceDeadline
            )

            let restoredBaseline = counter.withLock { $0 }
            let restoredCount = try await awaitCounterIncrease(
                counter: counter,
                from: restoredBaseline,
                timeout: Self.halMutationBufferDeadline
            )
            XCTAssertGreaterThan(
                restoredCount,
                restoredBaseline,
                "Shared stream should keep delivering buffers after restoring default input."
            )
        } catch {
            try? setSystemDefaultInputDevice(originalDefault)
            await unsubscribeAll(&tokens, from: stream)
            throw error
        }

        try? setSystemDefaultInputDevice(originalDefault)
        await unsubscribeAll(&tokens, from: stream)
    }

    /// Idle-gap case: matches the wall-clock signature of the journal-reported
    /// stall (2:42 idle gap before the failure). Coreaudiod state during long
    /// idle is the leading suspect; tests with shorter gaps may not surface it.
    ///
    /// Gated separately because it sleeps 3 minutes wall-clock.
    func testIdleGapDeliversBuffers() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPARAKEET_SLOW_HARDWARE_TESTS"] == "1",
            "Set MACPARAKEET_SLOW_HARDWARE_TESTS=1 to run the 3-minute idle-gap test."
        )

        _ = try await subscribeAndAwaitFirstBuffer(vpioEnabled: false)
        platform.stopEngine()

        try await Task.sleep(for: .seconds(180))

        let count = try await subscribeAndAwaitFirstBuffer(vpioEnabled: false)
        XCTAssertGreaterThan(
            count, 0,
            "Subscribe after 3-min idle should deliver buffers — coreaudiod state during long idle must not break the input chain."
        )
    }

    // MARK: - Helpers

    /// Configure the platform, install a counting tap, and return the buffer
    /// count seen by the deadline. Throws if `configureAndStart` itself fails
    /// (e.g. mic permission denied) — tests should propagate that.
    private func subscribeAndAwaitFirstBuffer(vpioEnabled: Bool) async throws -> Int {
        let counter = OSAllocatedUnfairLock(initialState: 0)

        try platform.configureAndStart(
            vpioEnabled: vpioEnabled,
            bufferSize: Self.bufferSize
        ) { _, _ in
            counter.withLock { $0 += 1 }
        }

        return try await awaitCounterIncrease(
            counter: counter,
            from: 0,
            timeout: Self.firstBufferDeadline
        )
    }

    private func makePreparablePlatform() throws -> AVAudioEngineMicrophonePlatform {
        let builtInDeviceID = AudioDeviceManager.builtInMicrophone()
        let deviceID = builtInDeviceID ?? AudioDeviceManager.defaultInputDevice()
        guard let deviceID else {
            throw XCTSkip("Need a resolved input device for stopped-engine preparation.")
        }
        guard AudioDeviceManager.bluetoothInputState(deviceID) == false else {
            throw XCTSkip(
                "Stopped-engine preparation is intentionally disabled for Bluetooth or unresolved inputs."
            )
        }
        let source: MeetingInputDeviceAttempt.Source = builtInDeviceID == nil ? .systemDefault : .builtIn
        let attempt = MeetingInputDeviceAttempt(source: source, deviceID: deviceID)
        return AVAudioEngineMicrophonePlatform(deviceAttemptsBuilder: { [attempt] in [attempt] })
    }

    /// Poll the counter every 20 ms until it increases past `baseline` or the
    /// deadline passes. Returns the final count. Polling beats
    /// `XCTestExpectation` here because the tap closure is `@Sendable` and
    /// must remain so — expectations under Swift 6 strict concurrency add
    /// ceremony for no diagnostic gain.
    private func awaitCounterIncrease(
        counter: OSAllocatedUnfairLock<Int>,
        from baseline: Int,
        timeout: TimeInterval
    ) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            let n = counter.withLock { $0 }
            if n > baseline { return n }
            try await Task.sleep(for: .milliseconds(20))
        }
        return counter.withLock { $0 }
    }

    private func unsubscribeAll(
        _ tokens: inout [SharedMicrophoneStream.SubscriberToken],
        from stream: SharedMicrophoneStream
    ) async {
        while let token = tokens.popLast() {
            await stream.unsubscribe(token)
        }
    }

    private func alternateInputDevice(
        excluding original: AudioDeviceID
    ) -> AudioDeviceManager.InputDevice? {
        let candidates = AudioDeviceManager.inputDevices().filter { $0.id != original }
        return candidates.first(where: { $0.isBuiltIn })
            ?? candidates.first(where: { $0.transportType != kAudioDeviceTransportTypeAggregate })
            ?? candidates.first
    }

    private func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        guard status == noErr else {
            throw XCTSkip("Set default input failed with OSStatus \(status).")
        }
    }

    private func waitForDefaultInputDevice(
        _ expected: AudioDeviceID,
        timeout: TimeInterval
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if AudioDeviceManager.defaultInputDevice() == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("Default input mutation was not observable for device \(expected).")
    }
}
