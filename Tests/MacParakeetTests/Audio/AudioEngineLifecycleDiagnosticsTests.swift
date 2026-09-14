import Foundation
import os
import XCTest
@testable import MacParakeetCore

final class AudioEngineLifecycleDiagnosticsTests: XCTestCase {
    override func tearDown() {
        Observability.resetCaptureCorrelation()
        super.tearDown()
    }

    func testPhaseTimingAccumulatesRepeatedPhasesAndRetainsFinalAttempt() async throws {
        let (recorder, clock, output) = makeRecorder()
        recorder.beginAttempt(source: "selected", transport: "usb", prepared: false)
        clock.set(milliseconds: 100)
        recorder.enter(.setDevice)
        clock.set(milliseconds: 250)
        recorder.enter(.startEngine)
        clock.set(milliseconds: 500)
        recorder.enter(.firstBuffer)
        clock.set(milliseconds: 700)
        recorder.beginAttempt(source: "built_in", transport: "built-in", prepared: true)
        recorder.enter(.setDevice)
        clock.set(milliseconds: 800)
        recorder.enter(.ready)
        clock.set(milliseconds: 900)
        recorder.finish()
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.operation, .start)
        XCTAssertEqual(snapshot.outcome, .success)
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertEqual(snapshot.elapsedMilliseconds, 900)
        XCTAssertEqual(snapshot.phaseMilliseconds, 100)
        XCTAssertEqual(snapshot.attemptCount, 2)
        XCTAssertEqual(snapshot.routeSource, "built_in")
        XCTAssertEqual(snapshot.transport, "built-in")
        XCTAssertTrue(snapshot.prepared)
        XCTAssertFalse(snapshot.vpioEnabled)
        XCTAssertEqual(snapshot.bufferSize, 512)
        XCTAssertFalse(snapshot.wasSlow)
        XCTAssertEqual(
            snapshot.phaseDurationsMilliseconds,
            [.queueWait: 100, .setDevice: 250, .startEngine: 250, .firstBuffer: 200, .ready: 100]
        )
        XCTAssertNotNil(UUID(uuidString: snapshot.attemptID))
    }

    func testPendingOperationReportsOneSlowCheckpointThenOneCorrelatedTerminal() async throws {
        let (recorder, clock, output) = makeRecorder()
        clock.set(milliseconds: 200)
        recorder.enter(.voiceProcessing)
        clock.set(milliseconds: 4_999)
        recorder.reportIfSlow()
        await recorder.flushPendingEmissions()
        XCTAssertTrue(output.snapshots.isEmpty)

        clock.set(milliseconds: 5_000)
        recorder.reportIfSlow()
        recorder.reportIfSlow()
        await recorder.flushPendingEmissions()
        let checkpoint = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(checkpoint.outcome, .slow)
        XCTAssertEqual(checkpoint.phase, .voiceProcessing)
        XCTAssertEqual(checkpoint.phaseMilliseconds, 4_800)
        XCTAssertTrue(checkpoint.wasSlow)

        clock.set(milliseconds: 6_000)
        recorder.reportIfSlow()
        recorder.finish()
        recorder.reportIfSlow()
        recorder.finish()
        await recorder.flushPendingEmissions()
        XCTAssertEqual(output.snapshots.map(\.outcome), [.slow, .success])
        let terminal = try XCTUnwrap(output.snapshots.last)
        XCTAssertEqual(terminal.attemptID, checkpoint.attemptID)
        XCTAssertEqual(terminal.elapsedMilliseconds, 6_000)
        XCTAssertTrue(terminal.wasSlow)
    }

    func testConcurrentFinishAndWatchdogPreserveOrderAndTerminalUniqueness() async throws {
        for _ in 0..<32 {
            let (recorder, clock, output) = makeRecorder()
            clock.set(milliseconds: 6_000)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { recorder.reportIfSlow() }
                group.addTask { recorder.finish() }
                group.addTask { recorder.reportIfSlow() }
                group.addTask { recorder.finish() }
            }
            await recorder.flushPendingEmissions()
            let snapshots = output.snapshots
            XCTAssertTrue(snapshots.map(\.outcome) == [.success] || snapshots.map(\.outcome) == [.slow, .success])
            XCTAssertEqual(snapshots.filter { $0.outcome == .success }.count, 1)
            XCTAssertTrue(snapshots.allSatisfy(\.wasSlow))
            XCTAssertEqual(Set(snapshots.map(\.attemptID)).count, 1)
        }
    }

    func testFinishStopsAllLaterMutationsAndReports() async throws {
        let (recorder, clock, output) = makeRecorder()
        recorder.beginAttempt(source: "system_default", transport: "bluetooth", prepared: false)
        recorder.finish()
        recorder.enter(.teardown)
        recorder.beginAttempt(source: "built_in", transport: "built-in", prepared: true)
        recorder.noteError(CancellationError())
        clock.set(milliseconds: 10_000)
        recorder.reportIfSlow()
        recorder.finish(error: CancellationError())
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.outcome, .success)
        XCTAssertEqual(snapshot.phase, .queueWait)
        XCTAssertEqual(snapshot.attemptCount, 1)
        XCTAssertEqual(snapshot.transport, "bluetooth")
        XCTAssertNil(snapshot.lastErrorType)
        XCTAssertFalse(snapshot.wasSlow)
    }

    func testBothCancellationTypesProduceCancelledOutcome() async throws {
        let errors: [Error] = [CancellationError(), AVAudioEngineMicrophonePlatformError.startupCancelled]
        for error in errors {
            let (recorder, _, output) = makeRecorder()
            recorder.enter(.firstBuffer)
            recorder.finish(error: error)
            await recorder.flushPendingEmissions()

            let snapshot = try XCTUnwrap(output.snapshots.single)
            XCTAssertEqual(snapshot.outcome, .cancelled)
            XCTAssertEqual(snapshot.lastErrorType, TelemetryErrorClassifier.classify(error))
            XCTAssertEqual(snapshot.lastErrorPhase, .firstBuffer)
        }
    }

    func testErrorClassificationOmitsFreeformErrorAndRouteContent() async throws {
        let (recorder, _, output) = makeRecorder()
        let privateText = "private speech /Users/someone/meeting.wav api_key=secret"
        recorder.beginAttempt(source: privateText, transport: "usb\n\(privateText)", prepared: false)
        recorder.enter(.inputFormat)
        recorder.finish(
            error: NSError(domain: privateText, code: -17, userInfo: [NSLocalizedDescriptionKey: privateText]))
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.outcome, .failure)
        XCTAssertEqual(snapshot.routeSource, "unknown")
        XCTAssertEqual(snapshot.transport, "unknown")
        XCTAssertEqual(snapshot.lastErrorType, "NSError.-17")
        XCTAssertEqual(snapshot.lastErrorPhase, .inputFormat)
        XCTAssertFalse(snapshot.localLogLine.contains(privateText))
        XCTAssertFalse(snapshot.localLogLine.contains("\n"))
        XCTAssertFalse(snapshot.props.keys.contains("error_detail"))
    }

    func testSuccessfulFallbackRetainsEarlierClassifiedErrorAndItsPhase() async throws {
        let (recorder, _, output) = makeRecorder()
        recorder.enter(.startEngine)
        recorder.noteError(NSError(domain: NSOSStatusErrorDomain, code: -10875))
        recorder.beginAttempt(source: "built_in", transport: "built-in", prepared: false)
        recorder.enter(.ready)
        recorder.finish()
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.outcome, .success)
        XCTAssertEqual(snapshot.lastErrorType, "NSOSStatusErrorDomain.-10875")
        XCTAssertEqual(snapshot.lastErrorPhase, .startEngine)
    }

    func testNewlyRecordedErrorUpdatesTheClassificationAndPhase() async throws {
        let (recorder, _, output) = makeRecorder()
        recorder.enter(.setDevice)
        recorder.noteError(NSError(domain: NSOSStatusErrorDomain, code: -50))
        recorder.enter(.startEngine)
        let error = NSError(domain: NSOSStatusErrorDomain, code: -10875)
        recorder.noteError(error)
        recorder.finish(error: error)
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.lastErrorType, "NSOSStatusErrorDomain.-10875")
        XCTAssertEqual(snapshot.lastErrorPhase, .startEngine)
    }

    func testTeardownDoesNotReplaceThePhaseOfTheReportedError() async throws {
        let (recorder, _, output) = makeRecorder()
        let error = NSError(domain: NSOSStatusErrorDomain, code: -10875)
        recorder.enter(.startEngine)
        recorder.noteError(error)
        recorder.enter(.teardown)
        recorder.finish(error: error)
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.phase, .teardown)
        XCTAssertEqual(snapshot.lastErrorType, "NSOSStatusErrorDomain.-10875")
        XCTAssertEqual(snapshot.lastErrorPhase, .startEngine)
    }

    func testFastPrepareAndStopSuppressSuccessFailureAndCancellation() async {
        let errors: [Error?] = [nil, NSError(domain: NSOSStatusErrorDomain, code: -50), CancellationError()]
        for operation in [AudioEngineLifecycleSnapshot.Operation.prepare, .stop] {
            for error in errors {
                let (recorder, clock, output) = makeRecorder(operation: operation)
                clock.set(milliseconds: 4_999)
                recorder.finish(error: error)
                await recorder.flushPendingEmissions()
                XCTAssertTrue(output.snapshots.isEmpty)
            }
        }
    }

    func testSlowPrepareAndStopPublishTerminalWhenTimerWasDelayed() async throws {
        for operation in [AudioEngineLifecycleSnapshot.Operation.prepare, .stop] {
            let (recorder, clock, output) = makeRecorder(operation: operation)
            clock.set(milliseconds: 5_000)
            recorder.finish()
            recorder.reportIfSlow()
            await recorder.flushPendingEmissions()
            let snapshot = try XCTUnwrap(output.snapshots.single)
            XCTAssertEqual(snapshot.operation, operation)
            XCTAssertEqual(snapshot.outcome, .success)
            XCTAssertTrue(snapshot.wasSlow)
        }
    }

    func testSlowPrepareAndStopKeepTerminalAfterCheckpoint() async throws {
        for operation in [AudioEngineLifecycleSnapshot.Operation.prepare, .stop] {
            let (recorder, clock, output) = makeRecorder(operation: operation)
            clock.set(milliseconds: 5_000)
            recorder.reportIfSlow()
            clock.set(milliseconds: 4_000)
            recorder.finish(error: CancellationError())
            await recorder.flushPendingEmissions()
            XCTAssertEqual(output.snapshots.map(\.outcome), [.slow, .cancelled])
            XCTAssertTrue(output.snapshots.allSatisfy(\.wasSlow))
        }
    }

    func testRecoveryAlwaysPublishesFastTerminal() async throws {
        let (recorder, _, output) = makeRecorder(operation: .recovery)
        recorder.finish()
        await recorder.flushPendingEmissions()
        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.operation, .recovery)
        XCTAssertEqual(snapshot.outcome, .success)
        XCTAssertFalse(snapshot.wasSlow)
    }

    func testSafeTransportCategoriesArePreservedAndOtherLabelsAreUnknown() async throws {
        let categories = [
            "none", "built-in", "bluetooth", "bluetooth-le", "usb", "aggregate", "virtual", "unknown",
            "aggregate-built-in", "aggregate-bluetooth", "aggregate-bluetooth-le", "aggregate-usb",
            "aggregate-aggregate", "aggregate-virtual", "aggregate-unknown",
        ]
        for label in categories + ["aggregate-private-device", "aggregate-none", "USB", "thunderbolt"] {
            let (recorder, _, output) = makeRecorder()
            recorder.beginAttempt(source: "selected", transport: label, prepared: false)
            recorder.finish()
            await recorder.flushPendingEmissions()
            let snapshot = try XCTUnwrap(output.snapshots.single)
            XCTAssertEqual(snapshot.transport, categories.contains(label) ? label : "unknown")
        }
    }

    func testClockRollbackCannotUnderflowOrDoubleCountPhases() async throws {
        let (recorder, clock, output) = makeRecorder()
        clock.set(milliseconds: 100)
        recorder.enter(.inputNode)
        clock.set(milliseconds: 20)
        recorder.enter(.voiceProcessing)
        clock.set(milliseconds: 200)
        recorder.finish()
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(snapshot.elapsedMilliseconds, 200)
        XCTAssertEqual(snapshot.phaseDurationsMilliseconds, [.queueWait: 100, .inputNode: 0, .voiceProcessing: 100])
        XCTAssertEqual(snapshot.phaseDurationsMilliseconds.values.reduce(0, +), snapshot.elapsedMilliseconds)
    }

    func testMaximumClockAndInvalidThresholdsDoNotOverflow() async throws {
        for threshold in [TimeInterval.nan, -.infinity, -1, .infinity, .greatestFiniteMagnitude] {
            let (recorder, clock, output) = makeRecorder(slowThreshold: threshold)
            clock.set(nanoseconds: .max)
            recorder.reportIfSlow()
            recorder.finish()
            await recorder.flushPendingEmissions()

            let terminal = try XCTUnwrap(output.snapshots.last)
            XCTAssertEqual(terminal.elapsedMilliseconds, Int(UInt64.max / 1_000_000))
            XCTAssertEqual(terminal.phaseMilliseconds, terminal.elapsedMilliseconds)
            XCTAssertEqual(terminal.phaseDurationsMilliseconds[.queueWait], terminal.elapsedMilliseconds)
            XCTAssertEqual(terminal.outcome, .success)
        }
    }

    func testPropsAreBoundedAndLocalRecordUsesTheSameSortedFields() async throws {
        let (recorder, _, output) = makeRecorder()
        for phase in AudioEngineLifecycleSnapshot.Phase.allCases { recorder.enter(phase) }
        recorder.finish(error: NSError(domain: NSOSStatusErrorDomain, code: -50))
        await recorder.flushPendingEmissions()

        let snapshot = try XCTUnwrap(output.snapshots.single)
        XCTAssertLessThanOrEqual(snapshot.props.count, 40)
        XCTAssertEqual(snapshot.props["last_error_phase"], "ready")
        XCTAssertEqual(snapshot.props["phase_queue_wait_ms"], "0")
        XCTAssertEqual(snapshot.props["was_slow"], "false")
        let expectedFields = snapshot.props.map { "\($0.key)=\($0.value)" }.sorted()
        XCTAssertEqual(snapshot.localLogLine, "audio_engine_lifecycle " + expectedFields.joined(separator: " "))
    }

    func testCaptureCorrelationIsStampedAtRecorderCreationAndOmittedWhenIdle() async throws {
        let workflowID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        Observability.beginCaptureCorrelation(
            ObservabilityCaptureCorrelation(workflowID: workflowID, consumer: .meeting)
        )
        let (recorder, _, output) = makeRecorder()
        Observability.resetCaptureCorrelation()
        recorder.finish()
        await recorder.flushPendingEmissions()
        let correlated = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(correlated.workflowID, workflowID)
        XCTAssertEqual(correlated.consumer, "meeting")
        XCTAssertEqual(correlated.props["workflow_id"], workflowID)
        XCTAssertEqual(correlated.props["consumer"], "meeting")

        let (idleRecorder, _, idleOutput) = makeRecorder()
        idleRecorder.finish()
        await idleRecorder.flushPendingEmissions()
        let idle = try XCTUnwrap(idleOutput.snapshots.single)
        XCTAssertNil(idle.workflowID)
        XCTAssertNil(idle.consumer)
        XCTAssertFalse(idle.props.keys.contains("workflow_id"))
        XCTAssertFalse(idle.props.keys.contains("consumer"))
    }

    func testEndCaptureCorrelationClearsOnlyMatchingWorkflow() async throws {
        let first = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let second = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
        Observability.beginCaptureCorrelation(
            ObservabilityCaptureCorrelation(workflowID: first, consumer: .dictation)
        )
        Observability.endCaptureCorrelation(workflowID: second)
        XCTAssertEqual(Observability.currentCaptureCorrelation?.workflowID, first)

        Observability.endCaptureCorrelation(workflowID: first)
        XCTAssertNil(Observability.currentCaptureCorrelation)
    }

    func testTimerDoesNotRetainAnAbandonedRecorder() {
        weak var weakRecorder: AudioEngineLifecycleDiagnostics?
        do {
            let recorder = AudioEngineLifecycleDiagnostics(
                operation: .start, vpioEnabled: false, bufferSize: 512, sink: { _ in }
            )
            weakRecorder = recorder
            XCTAssertNotNil(weakRecorder)
        }
        XCTAssertNil(weakRecorder)
    }

    func testAutomaticTimerReportsWhileLifecycleThreadIsBlocked() async throws {
        let checkpoint = expectation(description: "Automatic slow checkpoint")
        let completed = expectation(description: "Lifecycle completed after release")
        let release = DispatchSemaphore(value: 0)
        let output = LifecycleTestOutput()
        defer { release.signal() }
        DispatchQueue.global(qos: .userInitiated).async {
            let recorder = AudioEngineLifecycleDiagnostics(
                operation: .start, vpioEnabled: false, bufferSize: 512,
                slowThreshold: 0.03,
                sink: { snapshot in
                    output.append(snapshot)
                    if snapshot.outcome == .slow { checkpoint.fulfill() }
                    if snapshot.outcome == .success { completed.fulfill() }
                }
            )
            recorder.enter(.startEngine)
            _ = release.wait(timeout: .now() + 5)
            recorder.finish()
        }
        await fulfillment(of: [checkpoint], timeout: 3)
        let slow = try XCTUnwrap(output.snapshots.single)
        XCTAssertEqual(slow.phase, .startEngine)
        XCTAssertEqual(slow.outcome, .slow)
        release.signal()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(output.snapshots.map(\.outcome), [.slow, .success])
        XCTAssertEqual(Set(output.snapshots.map(\.attemptID)).count, 1)
    }

    private func makeRecorder(
        operation: AudioEngineLifecycleSnapshot.Operation = .start,
        slowThreshold: TimeInterval = 5
    ) -> (AudioEngineLifecycleDiagnostics, LifecycleTestClock, LifecycleTestOutput) {
        let clock = LifecycleTestClock()
        let output = LifecycleTestOutput()
        let recorder = AudioEngineLifecycleDiagnostics(
            operation: operation,
            vpioEnabled: false,
            bufferSize: 512,
            slowThreshold: slowThreshold,
            now: { clock.now() },
            automaticallySchedule: false,
            sink: { output.append($0) }
        )
        return (recorder, clock, output)
    }
}

private final class LifecycleTestClock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: UInt64(0))

    func now() -> UInt64 { time.withLock { $0 } }
    func set(milliseconds: UInt64) { set(nanoseconds: milliseconds * 1_000_000) }
    func set(nanoseconds: UInt64) { time.withLock { $0 = nanoseconds } }
}

private final class LifecycleTestOutput: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [AudioEngineLifecycleSnapshot]())

    var snapshots: [AudioEngineLifecycleSnapshot] { values.withLock { $0 } }
    func append(_ snapshot: AudioEngineLifecycleSnapshot) { values.withLock { $0.append(snapshot) } }
}

private extension Array where Element == AudioEngineLifecycleSnapshot {
    var single: Element? { count == 1 ? first : nil }
}
