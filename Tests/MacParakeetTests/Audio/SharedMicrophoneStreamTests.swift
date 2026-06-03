import AVFoundation
import XCTest
@testable import MacParakeetCore

final class SharedMicrophoneStreamTests: XCTestCase {
    private var platform: MockMicrophonePlatform!
    private var stream: SharedMicrophoneStream!

    override func setUp() {
        super.setUp()
        platform = MockMicrophonePlatform()
        stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
    }

    override func tearDown() {
        stream = nil
        platform = nil
        super.tearDown()
    }

    // MARK: - Engine lifecycle

    func testFirstSubscriberStartsEngine() async throws {
        let token = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 1)
        XCTAssertTrue(diag.engineRunning)
        XCTAssertFalse(diag.vpioEngaged)
        XCTAssertFalse(stream.isVPIOEngaged)
        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(platform.configureAndStartCalls.first?.vpioEnabled, false)
        XCTAssertEqual(platform.stopEngineCallCount, 0)

        await stream.unsubscribe(token)
    }

    func testLastSubscriberStopsEngine() async throws {
        let token = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        await stream.unsubscribe(token)

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 0)
        XCTAssertFalse(diag.engineRunning)
        XCTAssertEqual(platform.stopEngineCallCount, 1)
    }

    func testMiddleSubscriberLeavingDoesNotStopEngine() async throws {
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        await stream.unsubscribe(t1)
        XCTAssertEqual(platform.stopEngineCallCount, 0)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 1)

        await stream.unsubscribe(t2)
        XCTAssertEqual(platform.stopEngineCallCount, 1)
    }

    func testUnsubscribeUnknownTokenIsNoOp() async {
        let bogus = SharedMicrophoneStream.SubscriberToken()
        await stream.unsubscribe(bogus)
        XCTAssertEqual(platform.stopEngineCallCount, 0)
        XCTAssertEqual(platform.configureAndStartCalls.count, 0)
    }

    // MARK: - VPIO arbitration

    func testVPIOSubscriberStartsEngineWithVPIOOn() async throws {
        let token = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(platform.configureAndStartCalls.first?.vpioEnabled, true)
        XCTAssertTrue(stream.diagnostics.vpioEngaged)
        XCTAssertTrue(stream.isVPIOEngaged)

        await stream.unsubscribe(token)
    }

    func testVPIOPromotesWhenNoBlockerPresent() async throws {
        // Start with no subscribers. Sub 1 wants VPIO → engine starts with VPIO.
        // Sub 2 (non-VPIO) joins → no engine change.
        let t1 = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.count, 1, "Non-VPIO sub joining a VPIO engine must not reconfigure")
        XCTAssertTrue(stream.diagnostics.vpioEngaged)

        await stream.unsubscribe(t1)
        await stream.unsubscribe(t2)
    }

    func testVPIODeferredWhenNonVPIOInFlight() async throws {
        // Sub 1 joins as non-VPIO → engine raw.
        // Sub 2 wants VPIO → must defer until Sub 1 leaves.
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(platform.configureAndStartCalls.first?.vpioEnabled, false)
        XCTAssertFalse(stream.diagnostics.vpioEngaged)
        XCTAssertTrue(stream.diagnostics.vpioDeferred)
        XCTAssertEqual(stream.diagnostics.vpioDeferralCount, 1)

        await stream.unsubscribe(t1)
        await stream.unsubscribe(t2)
    }

    func testDeferredVPIOEngagesWhenNonVPIOLeaves() async throws {
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        XCTAssertFalse(stream.diagnostics.vpioEngaged)
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        await stream.unsubscribe(t1)

        // Now VPIO should engage (reconfigure-to-VPIO platform call).
        XCTAssertEqual(platform.configureAndStartCalls.count, 2)
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, true)
        XCTAssertTrue(stream.diagnostics.vpioEngaged)
        XCTAssertFalse(stream.diagnostics.vpioDeferred)

        await stream.unsubscribe(t2)
        XCTAssertEqual(platform.stopEngineCallCount, 1)
    }

    func testPassiveWarmSubscriberDoesNotBlockVPIOPromotion() async throws {
        let warm = try await stream.subscribe(
            wantsVPIO: false,
            blocksVPIOPromotion: false
        ) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, false)
        XCTAssertEqual(stream.diagnostics.passiveSubscriberCount, 1)

        let vpio = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.count, 2)
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, true)
        XCTAssertTrue(stream.diagnostics.vpioEngaged)
        XCTAssertFalse(stream.diagnostics.vpioDeferred)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 2)

        await stream.unsubscribe(warm)
        await stream.unsubscribe(vpio)
    }

    func testActiveNonVPIOSubscriberStillBlocksVPIOWhenPassiveWarmSubscriberExists() async throws {
        let warm = try await stream.subscribe(
            wantsVPIO: false,
            blocksVPIOPromotion: false
        ) { _, _ in }
        let active = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let vpio = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertFalse(stream.diagnostics.vpioEngaged)
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        await stream.unsubscribe(warm)
        XCTAssertTrue(stream.diagnostics.vpioDeferred, "active raw subscriber should still block promotion")

        await stream.unsubscribe(active)
        XCTAssertEqual(platform.configureAndStartCalls.count, 2)
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, true)
        XCTAssertTrue(stream.diagnostics.vpioEngaged)

        await stream.unsubscribe(vpio)
    }

    func testVPIOLeavingOnlyPassiveWarmSubscriberRestartsRawEngine() async throws {
        let warm = try await stream.subscribe(
            wantsVPIO: false,
            blocksVPIOPromotion: false
        ) { _, _ in }
        let vpio = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.map(\.vpioEnabled), [false, true])
        XCTAssertTrue(stream.diagnostics.vpioEngaged)

        await stream.unsubscribe(vpio)

        XCTAssertEqual(platform.configureAndStartCalls.map(\.vpioEnabled), [false, true, false])
        XCTAssertFalse(stream.diagnostics.vpioEngaged)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 1)
        XCTAssertEqual(stream.diagnostics.passiveSubscriberCount, 1)

        await stream.unsubscribe(warm)
    }

    func testPassiveRestartRequestDefersUntilActiveSubscriberLeaves() async throws {
        let warm = try await stream.subscribe(
            wantsVPIO: false,
            blocksVPIOPromotion: false
        ) { _, _ in }
        let active = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        await stream.restartPassiveSubscribers()

        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 2)

        await stream.unsubscribe(active)

        XCTAssertEqual(platform.configureAndStartCalls.map(\.vpioEnabled), [false, false])
        XCTAssertEqual(stream.diagnostics.subscriberCount, 1)
        XCTAssertEqual(stream.diagnostics.passiveSubscriberCount, 1)

        await stream.unsubscribe(warm)
    }

    func testDeferredVPIOClearsWhenVPIOSubscriberLeavesBeforePromotion() async throws {
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        await stream.unsubscribe(t2)

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 1)
        XCTAssertTrue(diag.engineRunning)
        XCTAssertFalse(diag.vpioEngaged)
        XCTAssertFalse(diag.vpioDeferred)
        XCTAssertEqual(platform.configureAndStartCalls.count, 1)

        await stream.unsubscribe(t1)
    }

    func testVPIOSubscriberJoinsRunningRawEngineWithoutBlocker() async throws {
        // Edge case: there's no rule that says "non-VPIO + VPIO = always defer."
        // If a non-VPIO sub starts, then leaves, then a VPIO sub joins, the
        // engine reconfigures. But what if a non-VPIO sub starts the engine,
        // *immediately* leaves before any VPIO sub joins, then a VPIO sub
        // joins? Engine should already be stopped, so the VPIO sub becomes
        // the first subscriber and starts a fresh VPIO engine.
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        await stream.unsubscribe(t1)
        XCTAssertEqual(platform.stopEngineCallCount, 1)

        let t2 = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        XCTAssertEqual(platform.configureAndStartCalls.count, 2)
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, true)
        XCTAssertTrue(stream.diagnostics.vpioEngaged)
        await stream.unsubscribe(t2)
    }

    func testVPIOIsStickyWhenVPIOSubscriberLeavesButNonVPIORemains() async throws {
        // Sub 1 (VPIO) → engine VPIO.
        // Sub 2 (non-VPIO) → joins, engine still VPIO.
        // Sub 1 leaves → VPIO stays on (sticky), engine NOT reconfigured.
        let t1 = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        XCTAssertEqual(platform.configureAndStartCalls.count, 1)

        await stream.unsubscribe(t1)
        XCTAssertEqual(platform.configureAndStartCalls.count, 1, "VPIO must not disengage mid-session")
        XCTAssertEqual(platform.stopEngineCallCount, 0)
        XCTAssertTrue(stream.diagnostics.vpioEngaged)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 1)

        await stream.unsubscribe(t2)
        XCTAssertEqual(platform.stopEngineCallCount, 1)
    }

    func testMultipleVPIOSubscribersOnlyConfigureOnce() async throws {
        let t1 = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        let t3 = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 3)

        await stream.unsubscribe(t1)
        await stream.unsubscribe(t2)
        await stream.unsubscribe(t3)
        XCTAssertEqual(platform.stopEngineCallCount, 1)
    }

    func testDeferralCounterIncrementsPerEvent() async throws {
        // Sub A non-VPIO. Sub B VPIO defers (counter=1). Sub C VPIO also
        // defers but doesn't increment because vpioDeferred is already true.
        // Wait — does it? The current contract is "increment when this VPIO
        // subscriber's request is what triggers a deferral." A second VPIO
        // sub joining while already-deferred increments because each
        // *request* was deferred. Adjust the test if we change that.
        let a = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        _ = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        XCTAssertEqual(stream.diagnostics.vpioDeferralCount, 1)

        _ = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        XCTAssertEqual(stream.diagnostics.vpioDeferralCount, 2, "Each VPIO request that hits a deferral counts")

        await stream.unsubscribe(a)
        XCTAssertTrue(stream.diagnostics.vpioEngaged)
    }

    // MARK: - Failure rollback

    func testEngineStartFailureRollsBackState() async {
        platform.configureAndStartError = MockError.simulatedFailure
        do {
            _ = try await stream.subscribe(wantsVPIO: false) { _, _ in }
            XCTFail("Expected subscribe to throw")
        } catch let SharedMicrophoneStream.SubscribeError.engineStartFailed(message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 0)
        XCTAssertFalse(diag.engineRunning)
        XCTAssertFalse(diag.vpioEngaged)
    }

    func testEngineStartFailureDoesNotAffectOtherSubscribers() async throws {
        // Sub 1 succeeds. Configure platform to fail on next call. Sub 2's
        // join is non-VPIO so doesn't trigger an engine call, so it should
        // succeed. (This validates that .none-action subscribes don't go
        // through the failure path at all.)
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        platform.configureAndStartError = MockError.simulatedFailure
        let t2 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        XCTAssertEqual(stream.diagnostics.subscriberCount, 2)

        await stream.unsubscribe(t1)
        await stream.unsubscribe(t2)
    }

    func testDeferredVPIOPromotionFailureFiresEngineDeathCallbacks() async throws {
        // When the deferred-VPIO promotion sequence fails on unsubscribe, the
        // engine is dead. Remaining subscribers must be told via their
        // `onEngineDeath` callback (off-lock, off the engine queue) so they
        // can surface a stall — diagnostics-polling alone is too quiet.
        let leavingDeath = TestCounter()
        let stayingDeath = TestCounter()

        let t1 = try await stream.subscribe(
            wantsVPIO: false,
            onEngineDeath: { leavingDeath.increment() }
        ) { _, _ in }
        let t2 = try await stream.subscribe(
            wantsVPIO: true,
            onEngineDeath: { stayingDeath.increment() }
        ) { _, _ in }
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        platform.configureAndStartError = MockError.simulatedFailure
        await stream.unsubscribe(t1)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(leavingDeath.value, 0, "The unsubscribed subscriber must not get the death callback")
        XCTAssertEqual(stayingDeath.value, 1, "The remaining subscriber observes engine death once")

        await stream.unsubscribe(t2)
    }

    func testEngineDeathCallbackOptionalForBackwardsCompat() async throws {
        // Subscribers that don't pass onEngineDeath must keep working — the
        // promotion failure handles `nil` callbacks without trying to fire
        // them.
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        platform.configureAndStartError = MockError.simulatedFailure
        await stream.unsubscribe(t1)

        XCTAssertFalse(stream.diagnostics.engineRunning)
        await stream.unsubscribe(t2)
    }

    func testDeferredVPIOPromotionFailureInvalidatesSubscribers() async throws {
        // The reconfigure-to-VPIO action is reachable only via the
        // unsubscribe path: a deferred VPIO subscriber gets promoted when
        // the last non-VPIO subscriber leaves. If the platform's
        // reconfigure fails, the engine has already been torn down inside
        // `configureAndStart` before the VPIO start failed — so it's
        // *stopped*, not running. Remaining subscriptions are invalidated
        // after their engine-death callbacks are captured so stale handlers
        // cannot be resurrected by a later subscribe.
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let t2 = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        platform.configureAndStartError = MockError.simulatedFailure
        await stream.unsubscribe(t1)

        // Reconfigure was attempted (call count went up) but failed.
        XCTAssertEqual(platform.configureAndStartCalls.count, 2)

        let diag = stream.diagnostics
        XCTAssertFalse(diag.vpioEngaged, "vpioEngaged must roll back when reconfigure fails")
        XCTAssertFalse(diag.engineRunning, "Engine is stopped after configureAndStart tore it down before throwing")
        XCTAssertEqual(diag.subscriberCount, 0, "Dead-engine subscribers are invalidated")
        XCTAssertFalse(diag.vpioDeferred, "No deferral remains after subscriptions are invalidated")

        await stream.unsubscribe(t2)
    }

    func testSubscribeAfterDeferredPromotionFailureStartsFreshEngine() async throws {
        let t1 = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        _ = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        platform.configureAndStartError = MockError.simulatedFailure
        await stream.unsubscribe(t1)

        XCTAssertFalse(stream.diagnostics.engineRunning)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0)

        platform.configureAndStartError = nil
        let token = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 1)
        XCTAssertTrue(diag.engineRunning)
        XCTAssertFalse(diag.vpioEngaged)
        XCTAssertEqual(platform.configureAndStartCalls.count, 3, "Fresh subscribe must restart the dead engine")
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, false)

        await stream.unsubscribe(token)
    }

    func testRecoveryAfterFirstSubscribeFailure() async throws {
        // Validates that a failed subscribe leaves clean state for the
        // next subscribe attempt — the foundation property that the
        // BLOCKER fix preserves under serialization.
        platform.configureAndStartError = MockError.simulatedFailure
        do {
            _ = try await stream.subscribe(wantsVPIO: false) { _, _ in }
            XCTFail("Expected first subscribe to throw")
        } catch SharedMicrophoneStream.SubscribeError.engineStartFailed {
            // expected
        }

        // Clear the failure and re-subscribe.
        platform.configureAndStartError = nil
        let token = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 1)
        XCTAssertTrue(diag.engineRunning)
        XCTAssertEqual(platform.configureAndStartCalls.count, 2, "Each retry attempts the platform call")

        await stream.unsubscribe(token)
    }

    func testConcurrentSubscribesSerializeCleanly() async throws {
        // With operations fully serialized through engineQueue, two
        // concurrent subscribes should never see each other's optimistic
        // mid-failure state. Both succeed, only one engine starts.
        async let r1: SharedMicrophoneStream.SubscriberToken = stream.subscribe(wantsVPIO: false) { _, _ in }
        async let r2: SharedMicrophoneStream.SubscriberToken = stream.subscribe(wantsVPIO: false) { _, _ in }

        let t1 = try await r1
        let t2 = try await r2

        XCTAssertNotEqual(t1, t2)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 2)
        XCTAssertEqual(platform.configureAndStartCalls.count, 1, "Only the first subscriber starts the engine")

        await stream.unsubscribe(t1)
        await stream.unsubscribe(t2)
        XCTAssertEqual(platform.stopEngineCallCount, 1)
    }

    func testConcurrentSubscribeFailuresLeaveCleanState() async {
        // Every attempt tries the platform fresh because each rollback
        // reverts to "no subscribers, engine off." Both should fail, but
        // state must be consistent — no orphaned tokens, no leaked
        // engineRunning=true.
        platform.configureAndStartError = MockError.simulatedFailure

        async let r1 = subscribeResult(wantsVPIO: false)
        async let r2 = subscribeResult(wantsVPIO: false)

        let results = await [r1, r2]
        XCTAssertTrue(results.allSatisfy {
            if case .failure = $0 { return true } else { return false }
        }, "Both concurrent subscribes should fail when platform is broken")

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 0, "No orphaned subscribers")
        XCTAssertFalse(diag.engineRunning, "engineRunning must not leak true")
        XCTAssertFalse(diag.vpioDeferred)
    }

    private func subscribeResult(wantsVPIO: Bool) async -> Result<SharedMicrophoneStream.SubscriberToken, Error> {
        do {
            let token = try await stream.subscribe(wantsVPIO: wantsVPIO) { _, _ in }
            return .success(token)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Fan-out

    func testFanOutDeliversToAllSubscribers() async throws {
        let received1 = TestCounter()
        let received2 = TestCounter()
        _ = try await stream.subscribe(wantsVPIO: false) { _, _ in received1.increment() }
        _ = try await stream.subscribe(wantsVPIO: false) { _, _ in received2.increment() }

        let buffer = makeSilentBuffer()
        let time = AVAudioTime(hostTime: 0)
        platform.deliverBuffer(buffer, time: time)

        XCTAssertEqual(received1.value, 1)
        XCTAssertEqual(received2.value, 1)

        platform.deliverBuffer(buffer, time: time)
        XCTAssertEqual(received1.value, 2)
        XCTAssertEqual(received2.value, 2)
    }

    func testFanOutStopsAfterUnsubscribe() async throws {
        let counter = TestCounter()
        let token = try await stream.subscribe(wantsVPIO: false) { _, _ in counter.increment() }

        let buffer = makeSilentBuffer()
        let time = AVAudioTime(hostTime: 0)
        platform.deliverBuffer(buffer, time: time)
        XCTAssertEqual(counter.value, 1)

        await stream.unsubscribe(token)
        // After unsubscribe, the engine has stopped — but if anyone called
        // the tap handler post-stop (which wouldn't happen in production
        // because the engine stops first), no subscriber receives anything.
        // Re-subscribe to bring the engine back, deliver, confirm only the
        // new subscriber sees it.
        let counter2 = TestCounter()
        _ = try await stream.subscribe(wantsVPIO: false) { _, _ in counter2.increment() }
        platform.deliverBuffer(buffer, time: time)
        XCTAssertEqual(counter.value, 1, "Stale handler must not fire after unsubscribe")
        XCTAssertEqual(counter2.value, 1)
    }

    // MARK: - Diagnostics

    func testDiagnosticsReflectVPIOSubscriberCount() async throws {
        _ = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        _ = try await stream.subscribe(wantsVPIO: true) { _, _ in }
        _ = try await stream.subscribe(wantsVPIO: true) { _, _ in }

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 3)
        XCTAssertEqual(diag.vpioSubscriberCount, 2)
    }
}

// MARK: - Test doubles

private final class MockMicrophonePlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    struct ConfigureCall: Equatable {
        let vpioEnabled: Bool
        let bufferSize: AVAudioFrameCount
    }

    private let lock = NSLock()
    private var _isRunning = false
    private var _configureCalls: [ConfigureCall] = []
    private var _stopCount = 0
    private var _tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var configureAndStartError: Error?

    var isEngineRunning: Bool {
        lock.withLock { _isRunning }
    }

    var inputFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
    }

    var configureAndStartCalls: [ConfigureCall] {
        lock.withLock { _configureCalls }
    }

    var stopEngineCallCount: Int {
        lock.withLock { _stopCount }
    }

    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        // Record the attempt regardless of outcome — production code calls
        // platform.configureAndStart with the same args whether it succeeds
        // or fails, and tests need to assert the attempt was made.
        let injectedError: Error? = lock.withLock {
            _configureCalls.append(ConfigureCall(vpioEnabled: vpioEnabled, bufferSize: bufferSize))
            return configureAndStartError
        }
        if let injectedError {
            throw injectedError
        }
        lock.withLock {
            _isRunning = true
            _tapHandler = tapHandler
        }
    }

    func stopEngine() {
        lock.withLock {
            _stopCount += 1
            _isRunning = false
            _tapHandler = nil
        }
    }

    /// Test hook — synchronously deliver a buffer through the installed tap.
    /// Mirrors what the real platform's render thread does.
    func deliverBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let handler = lock.withLock { _tapHandler }
        handler?(buffer, time)
    }
}

private enum MockError: Error {
    case simulatedFailure
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private func makeSilentBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    buffer.frameLength = 256
    return buffer
}
