import AVFoundation
import Foundation
import os
import XCTest
@testable import MacParakeetCore

final class SharedMicrophoneQueueDiagnosticsTests: XCTestCase {
    override func tearDown() {
        Observability.resetCaptureCorrelation()
        super.tearDown()
    }

    func testBlockedPreparationReportsQueuedWorkflowAndFinishesBeforeNativeStartReturns() async throws {
        let prepareEntered = expectation(description: "Idle preparation entered")
        let startEntered = expectation(description: "Native start entered")
        let checkpoint = expectation(description: "Queued subscription checkpoint")
        let terminal = expectation(description: "Subscription entered shared engine queue")
        let releasePrepare = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        defer {
            releasePrepare.signal()
            releaseStart.signal()
        }
        let platform = QueueDiagnosticPlatform(
            prepare: {
                prepareEntered.fulfill()
                _ = releasePrepare.wait(timeout: .now() + 5)
            },
            start: {
                startEntered.fulfill()
                _ = releaseStart.wait(timeout: .now() + 5)
            }
        )
        let output = QueueDiagnosticOutput()
        let stream = SharedMicrophoneStream(
            platform: platform,
            makeQueueWaitDiagnostics: { wantsVPIO, bufferSize in
                AudioEngineLifecycleDiagnostics(
                    operation: .start, scope: .sharedSubscriptionQueue,
                    vpioEnabled: wantsVPIO, bufferSize: bufferSize,
                    slowThreshold: 0.03,
                    sink: { snapshot in
                        output.append(snapshot)
                        if snapshot.outcome == .slow { checkpoint.fulfill() }
                        if snapshot.outcome == .success { terminal.fulfill() }
                    }
                )
            }
        )
        stream.prewarmDictation()
        await fulfillment(of: [prepareEntered], timeout: 3)

        let meeting = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .meeting)
        Observability.beginCaptureCorrelation(meeting)
        let subscription = Task { try await stream.subscribe(wantsVPIO: false) { _, _ in } }
        await fulfillment(of: [checkpoint], timeout: 3)
        XCTAssertEqual(platform.startCount, 0, "The checkpoint must precede native microphone startup")
        XCTAssertEqual(output.snapshots.count, 1)
        let slow = try XCTUnwrap(output.snapshots.first)
        XCTAssertEqual(slow.scope, .sharedSubscriptionQueue)
        XCTAssertEqual(slow.phase, .queueWait)
        XCTAssertEqual(slow.outcome, .slow)
        XCTAssertEqual(slow.workflowID, meeting.workflowID)
        XCTAssertEqual(slow.consumer, "meeting")

        let dictation = ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: .dictation)
        Observability.beginCaptureCorrelation(dictation)
        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        releasePrepare.signal()
        await fulfillment(of: [startEntered, terminal], timeout: 3)
        XCTAssertFalse(platform.isEngineRunning, "Queue completion must not wait for native startup")
        let snapshots = output.snapshots
        XCTAssertEqual(snapshots.map(\.outcome), [.slow, .success])
        XCTAssertEqual(Set(snapshots.map(\.attemptID)).count, 1)
        XCTAssertTrue(snapshots.allSatisfy { $0.workflowID == meeting.workflowID && $0.consumer == "meeting" })
        XCTAssertTrue(snapshots.allSatisfy { $0.phase == .queueWait && $0.attemptCount == 0 })
        XCTAssertEqual(Observability.currentCaptureCorrelation, dictation)

        releaseStart.signal()
        let token = try await subscription.value
        await stream.unsubscribe(token)
    }

    func testFastSubscriptionQueueWaitDoesNotEmitSnapshots() async throws {
        let output = QueueDiagnosticOutput()
        let recorder = OSAllocatedUnfairLock<AudioEngineLifecycleDiagnostics?>(initialState: nil)
        let platform = QueueDiagnosticPlatform()
        let stream = SharedMicrophoneStream(
            platform: platform,
            makeQueueWaitDiagnostics: { wantsVPIO, bufferSize in
                let observer = AudioEngineLifecycleDiagnostics(
                    operation: .start, scope: .sharedSubscriptionQueue,
                    vpioEnabled: wantsVPIO, bufferSize: bufferSize,
                    now: { 0 }, automaticallySchedule: false,
                    sink: { output.append($0) }
                )
                recorder.withLock { $0 = observer }
                return observer
            }
        )
        let token = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        let observer = try XCTUnwrap(recorder.withLock { $0 })
        await observer.flushPendingEmissions()
        XCTAssertTrue(output.snapshots.isEmpty)
        XCTAssertEqual(platform.startCount, 1)
        await stream.unsubscribe(token)
    }

    func testPassiveWarmSubscriptionDoesNotCreateUserQueueObserver() async throws {
        let creations = OSAllocatedUnfairLock(initialState: 0)
        let stream = SharedMicrophoneStream(
            platform: QueueDiagnosticPlatform(),
            makeQueueWaitDiagnostics: { wantsVPIO, bufferSize in
                creations.withLock { $0 += 1 }
                return AudioEngineLifecycleDiagnostics(
                    operation: .start, scope: .sharedSubscriptionQueue,
                    vpioEnabled: wantsVPIO, bufferSize: bufferSize,
                    automaticallySchedule: false, sink: { _ in }
                )
            }
        )
        let token = try await stream.subscribe(wantsVPIO: false, blocksVPIOPromotion: false) { _, _ in }
        XCTAssertEqual(creations.withLock { $0 }, 0)
        await stream.unsubscribe(token)
    }

    func testQueueObserverKeepsMonotonicTimingAndEmitsOnlyOneCheckpointAndTerminal() async throws {
        let time = OSAllocatedUnfairLock(initialState: UInt64(0))
        let output = QueueDiagnosticOutput()
        let observer = AudioEngineLifecycleDiagnostics(
            operation: .start, scope: .sharedSubscriptionQueue,
            vpioEnabled: false, bufferSize: 1024,
            now: { time.withLock { $0 } }, automaticallySchedule: false,
            sink: { output.append($0) }
        )
        time.withLock { $0 = 6_000_000_000 }
        observer.reportIfSlow()
        observer.reportIfSlow()
        time.withLock { $0 = 4_000_000_000 }
        observer.finish()
        observer.finish()
        observer.reportIfSlow()
        await observer.flushPendingEmissions()

        XCTAssertEqual(output.snapshots.map(\.outcome), [.slow, .success])
        XCTAssertEqual(output.snapshots.map(\.elapsedMilliseconds), [6000, 6000])
        XCTAssertTrue(output.snapshots.allSatisfy { $0.phaseDurationsMilliseconds == [.queueWait: 6000] })
        XCTAssertTrue(output.snapshots.allSatisfy { $0.props["scope"] == "shared_subscription_queue" })
        XCTAssertTrue(output.snapshots.allSatisfy { $0.localLogLine.contains("scope=shared_subscription_queue") })
        XCTAssertTrue(output.snapshots.allSatisfy { $0.routeSource == "unknown" && $0.transport == "unknown" })
        XCTAssertTrue(output.snapshots.allSatisfy { $0.workflowID == nil && $0.consumer == nil })
    }

    func testSlowQueueDrainBeforeTimerDeliveryEmitsOnlyTerminal() async throws {
        let time = OSAllocatedUnfairLock(initialState: UInt64(0))
        let output = QueueDiagnosticOutput()
        let observer = AudioEngineLifecycleDiagnostics(
            operation: .start, scope: .sharedSubscriptionQueue,
            vpioEnabled: false, bufferSize: 1024,
            now: { time.withLock { $0 } }, automaticallySchedule: false,
            sink: { output.append($0) }
        )
        time.withLock { $0 = 7_000_000_000 }
        observer.finish()
        observer.reportIfSlow()
        await observer.flushPendingEmissions()

        XCTAssertEqual(output.snapshots.count, 1)
        let snapshot = try XCTUnwrap(output.snapshots.first)
        XCTAssertEqual(snapshot.outcome, .success)
        XCTAssertTrue(snapshot.wasSlow)
        XCTAssertEqual(snapshot.elapsedMilliseconds, 7000)
        XCTAssertEqual(snapshot.scope, .sharedSubscriptionQueue)
    }

    func testNativeLifecycleRetainsUnscopedFastStartSnapshot() async throws {
        let output = QueueDiagnosticOutput()
        let observer = AudioEngineLifecycleDiagnostics(
            operation: .start, vpioEnabled: false, bufferSize: 1024,
            now: { 0 }, automaticallySchedule: false,
            sink: { output.append($0) }
        )
        observer.finish()
        await observer.flushPendingEmissions()

        XCTAssertEqual(output.snapshots.count, 1)
        let snapshot = try XCTUnwrap(output.snapshots.first)
        XCTAssertNil(snapshot.scope)
        XCTAssertNil(snapshot.props["scope"])
        XCTAssertFalse(snapshot.wasSlow)
    }
}

private final class QueueDiagnosticOutput: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [AudioEngineLifecycleSnapshot]())

    var snapshots: [AudioEngineLifecycleSnapshot] { values.withLock { $0 } }
    func append(_ snapshot: AudioEngineLifecycleSnapshot) { values.withLock { $0.append(snapshot) } }
}

private final class QueueDiagnosticPlatform: MicrophoneEnginePlatform, Sendable {
    private struct State {
        var running = false
        var startCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onPrepare: @Sendable () -> Void
    private let onStart: @Sendable () -> Void

    init(prepare: @escaping @Sendable () -> Void = {}, start: @escaping @Sendable () -> Void = {}) {
        onPrepare = prepare
        onStart = start
    }

    var isEngineRunning: Bool { state.withLock { $0.running } }
    var startCount: Int { state.withLock { $0.startCount } }
    var inputFormat: AVAudioFormat? { nil }

    func prepare(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        onPrepare()
    }

    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        state.withLock { $0.startCount += 1 }
        onStart()
        state.withLock { $0.running = true }
    }

    func stopEngine() {
        state.withLock { $0.running = false }
    }
}
