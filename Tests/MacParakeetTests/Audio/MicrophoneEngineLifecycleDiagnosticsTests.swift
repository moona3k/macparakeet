import AVFoundation
import os
import XCTest
@testable import MacParakeetCore

final class MicrophoneEngineLifecycleDiagnosticsTests: XCTestCase {
    func testColdNativeStartIsObservableWhilePlatformQueueIsBlocked() async throws {
        try await verifyBlockedStart(prepared: false)
    }

    func testPreparedNativeStartIsObservableWhilePlatformQueueIsBlocked() async throws {
        try await verifyBlockedStart(prepared: true)
    }

    private func verifyBlockedStart(prepared: Bool) async throws {
        let now = OSAllocatedUnfairLock(initialState: UInt64(0))
        let recorder = OSAllocatedUnfairLock<AudioEngineLifecycleDiagnostics?>(initialState: nil)
        let snapshots = OSAllocatedUnfairLock(initialState: [AudioEngineLifecycleSnapshot]())
        let startReturned = OSAllocatedUnfairLock(initialState: false)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        let nativeEntered = expectation(description: "Native start entered")
        let startCompleted = expectation(description: "Start completed after release")
        let release = DispatchSemaphore(value: 0)
        // A failed assertion must still release the simulated native call.
        defer { release.signal() }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        pcm.frameLength = 16
        pcm.floatChannelData?[0].initialize(repeating: 0.25, count: 16)
        let buffer = UncheckedSendableAudioPCMBuffer(pcm)
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: { [.implicitSystemDefault(resolvedDeviceID: 10)] },
            inputDeviceSetter: { _, _ in true },
            bluetoothInputState: { _ in false },
            lifecycleDiagnosticsFactory: { operation, vpio, size in
                let diagnostics = AudioEngineLifecycleDiagnostics(
                    operation: operation, vpioEnabled: vpio, bufferSize: size,
                    now: { now.withLock { $0 } }, automaticallySchedule: false,
                    sink: { snapshot in snapshots.withLock { $0.append(snapshot) } }
                )
                if operation == .start { recorder.withLock { $0 = diagnostics } }
                return diagnostics
            },
            engineStarter: { _, _, _, tap in
                nativeEntered.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw ProbeError.releaseTimedOut
                }
                tap(buffer.buffer, AVAudioTime(hostTime: 1))
            }
        )
        if prepared {
            platform.prepare(vpioEnabled: false, bufferSize: 256, tapHandler: { _, _ in })
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                startReturned.withLock { $0 = true }
                startCompleted.fulfill()
            }
            do {
                try platform.configureAndStart(vpioEnabled: false, bufferSize: 256, tapHandler: { _, _ in })
            } catch {
                errors.withLock { $0.append(String(describing: error)) }
            }
        }
        await fulfillment(of: [nativeEntered], timeout: 3)
        let diagnostics = try XCTUnwrap(recorder.withLock { $0 })
        now.withLock { $0 = 5_000_000_000 }
        diagnostics.reportIfSlow()
        await diagnostics.flushPendingEmissions()
        let checkpoint = try XCTUnwrap(snapshots.withLock { $0.first(where: { $0.outcome == .slow }) })
        XCTAssertEqual(checkpoint.phase, .startEngine)
        XCTAssertEqual(checkpoint.prepared, prepared)
        XCTAssertEqual(checkpoint.elapsedMilliseconds, 5_000)
        XCTAssertFalse(startReturned.withLock { $0 })

        release.signal()
        await fulfillment(of: [startCompleted], timeout: 3)
        await diagnostics.flushPendingEmissions()
        XCTAssertEqual(errors.withLock { $0 }, [])
        let events = snapshots.withLock { $0.filter { $0.operation == .start } }
        XCTAssertEqual(events.map(\.outcome), [.slow, .success])
        XCTAssertEqual(Set(events.map(\.attemptID)).count, 1)
        XCTAssertTrue(events.allSatisfy(\.wasSlow))
        platform.stopEngine()
    }

    func testThrownNativeFailureKeepsOriginalPhaseAcrossTeardown() async throws {
        let snapshots = OSAllocatedUnfairLock(initialState: [AudioEngineLifecycleSnapshot]())
        let recorder = OSAllocatedUnfairLock<AudioEngineLifecycleDiagnostics?>(initialState: nil)
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: { [] },
            lifecycleDiagnosticsFactory: { operation, vpio, size in
                let diagnostics = AudioEngineLifecycleDiagnostics(
                    operation: operation, vpioEnabled: vpio, bufferSize: size,
                    automaticallySchedule: false,
                    sink: { snapshot in snapshots.withLock { $0.append(snapshot) } }
                )
                recorder.withLock { $0 = diagnostics }
                return diagnostics
            },
            engineStarter: { _, _, _, _ in throw ProbeError.nativeFailure }
        )
        XCTAssertThrowsError(
            try platform.configureAndStart(vpioEnabled: false, bufferSize: 256, tapHandler: { _, _ in })
        )
        let diagnostics = try XCTUnwrap(recorder.withLock { $0 })
        await diagnostics.flushPendingEmissions()
        let failure = try XCTUnwrap(snapshots.withLock { $0.first })
        XCTAssertEqual(failure.outcome, .failure)
        XCTAssertEqual(failure.lastErrorPhase, .startEngine)
        XCTAssertEqual(failure.phase, .teardown)
        XCTAssertEqual(snapshots.withLock { $0.count }, 1)
        platform.stopEngine()
    }

    func testSlowPrepareFailureKeepsSetDeviceOrigin() async throws {
        let now = OSAllocatedUnfairLock(initialState: UInt64(0))
        let snapshots = OSAllocatedUnfairLock(initialState: [AudioEngineLifecycleSnapshot]())
        let recorder = OSAllocatedUnfairLock<AudioEngineLifecycleDiagnostics?>(initialState: nil)
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: { [MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)] },
            inputDeviceSetter: { _, _ in
                now.withLock { $0 = 5_000_000_000 }
                return false
            },
            bluetoothInputState: { _ in false },
            lifecycleDiagnosticsFactory: { operation, vpio, size in
                let diagnostics = AudioEngineLifecycleDiagnostics(
                    operation: operation, vpioEnabled: vpio, bufferSize: size,
                    now: { now.withLock { $0 } }, automaticallySchedule: false,
                    sink: { snapshot in snapshots.withLock { $0.append(snapshot) } }
                )
                recorder.withLock { $0 = diagnostics }
                return diagnostics
            },
            engineStarter: { _, _, _, _ in XCTFail("Preparation must not start native capture") }
        )
        platform.prepare(vpioEnabled: false, bufferSize: 256, tapHandler: { _, _ in })
        let diagnostics = try XCTUnwrap(recorder.withLock { $0 })
        await diagnostics.flushPendingEmissions()
        let failure = try XCTUnwrap(snapshots.withLock { $0.first })
        XCTAssertEqual(failure.outcome, .failure)
        XCTAssertEqual(failure.lastErrorPhase, .setDevice)
        XCTAssertEqual(failure.phase, .teardown)
        XCTAssertTrue(failure.wasSlow)
        platform.stopEngine()
    }

    func testMixedFallbackErrorsKeepLastAttemptOriginNotEarlierThrownError() async throws {
        let snapshots = OSAllocatedUnfairLock(initialState: [AudioEngineLifecycleSnapshot]())
        let recorder = OSAllocatedUnfairLock<AudioEngineLifecycleDiagnostics?>(initialState: nil)
        let lastAttempt = MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [MeetingInputDeviceAttempt(source: .selected(uid: "test-only"), deviceID: 10), lastAttempt]
            },
            inputDeviceSetter: { device, _ in device == 10 },
            bluetoothInputState: { _ in false },
            lifecycleDiagnosticsFactory: { operation, vpio, size in
                let diagnostics = AudioEngineLifecycleDiagnostics(
                    operation: operation, vpioEnabled: vpio, bufferSize: size,
                    automaticallySchedule: false,
                    sink: { snapshot in snapshots.withLock { $0.append(snapshot) } }
                )
                recorder.withLock { $0 = diagnostics }
                return diagnostics
            },
            engineStarter: { _, _, _, _ in throw ProbeError.nativeFailure }
        )
        XCTAssertThrowsError(
            try platform.configureAndStart(vpioEnabled: false, bufferSize: 256, tapHandler: { _, _ in })
        ) { XCTAssertTrue($0 is ProbeError) }
        let diagnostics = try XCTUnwrap(recorder.withLock { $0 })
        await diagnostics.flushPendingEmissions()
        let failure = try XCTUnwrap(snapshots.withLock { $0.first })
        XCTAssertEqual(failure.outcome, .failure)
        XCTAssertEqual(failure.attemptCount, 2)
        XCTAssertEqual(failure.lastErrorPhase, .setDevice)
        XCTAssertEqual(
            failure.lastErrorType,
            TelemetryErrorClassifier.classify(AVAudioEngineMicrophonePlatformError.deviceSetFailed(lastAttempt))
        )
        platform.stopEngine()
    }
}

private enum ProbeError: Error { case releaseTimedOut, nativeFailure }
