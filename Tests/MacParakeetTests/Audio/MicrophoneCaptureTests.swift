import AVFoundation
import CoreAudio
import XCTest
@testable import MacParakeetCore

final class MicrophoneCaptureTests: XCTestCase {
    func testSubscribesWithVPIOForVPIOPreferred() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        let report = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in },
            onStall: nil
        )
        defer { capture.stop() }

        XCTAssertEqual(report.requestedMode, .vpioPreferred)
        XCTAssertEqual(report.effectiveMode, .vpio)
        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(platform.configureAndStartCalls.first?.vpioEnabled, true)
        XCTAssertTrue(stream.diagnostics.engineRunning)
    }

    func testSharedModeSubscribesRawForRawProcessing() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        let report = try await capture.start(
            processingMode: .raw,
            handler: { _, _ in },
            onStall: nil
        )
        defer { capture.stop() }

        XCTAssertEqual(report.effectiveMode, .raw)
        XCTAssertEqual(platform.configureAndStartCalls.first?.vpioEnabled, false)
    }

    func testSharedModeForwardsBuffersToHandler() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let counter = MicrophoneCaptureTestCounter()

        _ = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in counter.increment() },
            onStall: nil
        )
        defer { capture.stop() }

        let buffer = makeSharedTestBuffer()
        let time = AVAudioTime(hostTime: 0)
        platform.deliverBuffer(buffer, time: time)
        platform.deliverBuffer(buffer, time: time)

        XCTAssertEqual(counter.value, 2)
    }

    func testEarlyFirstBufferBeforeWatchdogArmedDoesNotReportStall() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let stallBox = MicrophoneCaptureTestStallBox()
        let earlyBuffer = UncheckedSendableAudioPCMBuffer(makeSharedTestBuffer())
        platform.afterConfigureAndStartHook = {
            platform.deliverBuffer(earlyBuffer.buffer, time: AVAudioTime(hostTime: 0))
        }

        _ = try await capture.start(
            processingMode: .raw,
            handler: { _, _ in },
            onStall: { error in stallBox.record(error) }
        )
        defer { capture.stop() }

        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertNil(
            stallBox.recordedError,
            "A first buffer delivered before start() arms the watchdog must still disarm the watchdog."
        )
    }

    func testNoBufferWatchdogAppendsDiagnosticsLine() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let stallBox = MicrophoneCaptureTestStallBox()
        let beforeDiagnostics = currentDiagnosticsLogContents()

        _ = try await capture.start(
            processingMode: .raw,
            handler: { _, _ in },
            onStall: { error in stallBox.record(error) }
        )
        defer { capture.stop() }

        let line = try await waitForDiagnosticsLine(
            containing: "meeting_mic_capture_no_buffers_within_timeout",
            after: beforeDiagnostics
        )
        let stallObserved = await waitUntil(timeoutSeconds: 1) { stallBox.recordedError != nil }
        XCTAssertTrue(
            stallObserved,
            "The watchdog must still notify the stall observer."
        )
        XCTAssertTrue(line.contains("elapsed_s=2.000"))
        XCTAssertTrue(line.contains("isRunning=true"))
        XCTAssertTrue(line.contains("default_input="))
        XCTAssertTrue(line.contains("default_input_transport="))
    }

    func testSharedModeVPIOForwardsChannelZeroOnly() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let snapshotBox = MicrophoneCaptureTestBufferSnapshotBox()

        _ = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { buffer, _ in snapshotBox.record(buffer) },
            onStall: nil
        )
        defer { capture.stop() }

        let buffer = try makeSharedMultiChannelFloatBuffer(channels: 4, frames: 16) { channel, frame in
            channel == 0 ? Float(frame) + 0.25 : Float((channel + 1) * 100 + frame)
        }
        platform.deliverBuffer(buffer, time: AVAudioTime(hostTime: 0))

        let snapshot = try XCTUnwrap(snapshotBox.snapshot)
        XCTAssertEqual(snapshot.channelCount, 1)
        XCTAssertEqual(snapshot.samplesByChannel.count, 1)
        for frame in 0..<16 {
            XCTAssertEqual(snapshot.samplesByChannel[0][frame], Float(frame) + 0.25, accuracy: 0.0001)
        }
    }

    func testSharedModeRawDownmixesMultiChannelBuffers() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let snapshotBox = MicrophoneCaptureTestBufferSnapshotBox()

        _ = try await capture.start(
            processingMode: .raw,
            handler: { buffer, _ in snapshotBox.record(buffer) },
            onStall: nil
        )
        defer { capture.stop() }

        let buffer = try makeSharedMultiChannelFloatBuffer(channels: 4, frames: 8) { channel, frame in
            channel == 1 ? Float(frame) + 0.5 : 0
        }
        platform.deliverBuffer(buffer, time: AVAudioTime(hostTime: 0))

        let snapshot = try XCTUnwrap(snapshotBox.snapshot)
        XCTAssertEqual(snapshot.channelCount, 1)
        XCTAssertEqual(snapshot.samplesByChannel.count, 1)
        for frame in 0..<8 {
            XCTAssertEqual(snapshot.samplesByChannel[0][frame], (Float(frame) + 0.5) / 4, accuracy: 0.0001)
        }
    }

    func testSharedModeVPIOPreferredFallsBackToRawWhenSubscribeThrows() async throws {
        let platform = SharedMicTestPlatform()
        platform.configureAndStartError = MicrophoneCaptureMockError.simulatedFailure
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        // Failure on the first attempt (VPIO). Clear the error so the raw
        // retry succeeds.
        platform.configureAndStartError = nil
        platform.failNextStartCount = 1

        let report = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in },
            onStall: nil
        )
        defer { capture.stop() }

        XCTAssertEqual(report.effectiveMode, .raw, "vpioPreferred falls back to raw when VPIO subscribe fails")
        XCTAssertGreaterThanOrEqual(platform.configureAndStartCalls.count, 2, "Both vpio and raw subscribe attempts occur")
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, false, "Final attempt must be the raw retry")
    }

    func testSharedModeVPIORequiredThrowsOnSubscribeFailure() async {
        let platform = SharedMicTestPlatform()
        platform.configureAndStartError = MicrophoneCaptureMockError.simulatedFailure
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        do {
            _ = try await capture.start(
                processingMode: .vpioRequired,
                handler: { _, _ in },
                onStall: nil
            )
            XCTFail("vpioRequired must throw when VPIO can't engage")
        } catch MeetingAudioError.microphoneProcessingUnavailable(let mode, _) {
            XCTAssertEqual(mode, .vpioRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0)
    }

    func testSharedModeVPIORequiredThrowsWhenEngagementIsDeferred() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let blocker = try await stream.subscribe(wantsVPIO: false) { _, _ in }

        do {
            _ = try await capture.start(
                processingMode: .vpioRequired,
                handler: { _, _ in },
                onStall: nil
            )
            XCTFail("vpioRequired must throw when VPIO engagement is deferred by an active raw subscriber")
        } catch MeetingAudioError.microphoneProcessingUnavailable(let mode, let reason) {
            XCTAssertEqual(mode, .vpioRequired)
            XCTAssertTrue(reason.contains("deferred"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let diag = stream.diagnostics
        XCTAssertEqual(diag.subscriberCount, 1, "Only the raw blocker should remain subscribed")
        XCTAssertFalse(diag.vpioEngaged)
        XCTAssertFalse(diag.vpioDeferred)

        await stream.unsubscribe(blocker)
    }

    func testSharedModeThrowsPermissionDeniedWhenProviderFalse() async {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { false }
        )

        do {
            _ = try await capture.start(
                processingMode: .raw,
                handler: { _, _ in },
                onStall: nil
            )
            XCTFail("Expected microphonePermissionDenied")
        } catch MeetingAudioError.microphonePermissionDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(platform.configureAndStartCalls.count, 0, "Permission gate must short-circuit before any platform call")
    }

    func testSharedModeStopDuringSubscribeUnsubscribesOrphanToken() async throws {
        // Race scenario: `stop()` is called while `start()` is awaiting
        // `subscribe`. The post-subscribe state re-check must detect that
        // the lifecycle was taken to .idle and unsubscribe the just-issued
        // token so the shared stream isn't left with a live subscriber that
        // nobody owns. Without the guard, the engine would stay running with
        // an orphan handler attached.
        let platform = SharedMicTestPlatform()
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        let startTask = Task {
            try await capture.start(
                processingMode: .raw,
                handler: { _, _ in },
                onStall: nil
            )
        }

        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success, "Mock platform should have been entered")
        // stop() runs while subscribe is paused inside the platform.
        capture.stop()
        // Let subscribe complete. start's post-subscribe re-check must now
        // detect the missing .starting state and clean up.
        release.signal()

        do {
            _ = try await startTask.value
            XCTFail("start() should throw when stop ran during subscribe")
        } catch MeetingAudioError.audioEngineStartFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Wait for the fire-and-forget orphan-unsubscribe Task to settle.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0, "Orphan token must be unsubscribed")
        XCTAssertFalse(stream.diagnostics.engineRunning, "Engine must be stopped after orphan cleanup")
    }

    func testSharedModeEngineDeathSurfacesAsStall() async throws {
        // When a deferred-VPIO promotion fails, MicrophoneCapture must
        // forward the engine-death notification to its `onStall` observer.
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let stallBox = MicrophoneCaptureTestStallBox()

        // Pre-seed a non-VPIO blocker so the capture's VPIO subscribe gets deferred.
        let blockerToken = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        defer { Task { await stream.unsubscribe(blockerToken) } }

        _ = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in },
            onStall: { error in stallBox.record(error) }
        )
        defer { capture.stop() }
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        // Make the deferred promotion fail when the blocker leaves.
        platform.configureAndStartError = MicrophoneCaptureMockError.simulatedFailure
        await stream.unsubscribe(blockerToken)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(stallBox.recordedError, "Engine death must reach onStall")
    }

    func testInputDeviceAttemptsPreferSelectedThenDefaultThenBuiltIn() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "usb-mic",
            selectedInputDeviceID: { uid in uid == "usb-mic" ? AudioDeviceID(10) : nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
                .implicitSystemDefault(resolvedDeviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    func testInputDeviceAttemptsSkipMissingSelectedDevice() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "missing-mic",
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                .implicitSystemDefault(resolvedDeviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    func testInputDeviceAttemptsDeduplicateDefaultAndBuiltIn() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(30) },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                .implicitSystemDefault(resolvedDeviceID: 30),
            ]
        )
    }

    func testInputDeviceAttemptsCanUseBuiltInWhenDefaultMissing() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { nil },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                .implicitSystemDefault(resolvedDeviceID: nil),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    func testSystemDefaultAttemptUsesImplicitEngineRouting() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "usb-mic",
            selectedInputDeviceID: { uid in uid == "usb-mic" ? AudioDeviceID(10) : nil },
            defaultInputDevice: { AudioDeviceID(10) },
            builtInMicrophone: { nil }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
                .implicitSystemDefault(resolvedDeviceID: 10),
            ]
        )
        XCTAssertFalse(attempts[0].usesImplicitSystemDefault)
        XCTAssertTrue(attempts[1].usesImplicitSystemDefault)
        XCTAssertEqual(attempts[0].explicitDeviceID, 10)
        XCTAssertNil(attempts[1].explicitDeviceID)
    }

    func testExplicitSystemDefaultAttemptCanStillPinDevice() {
        let attempt = MeetingInputDeviceAttempt(source: .systemDefault, deviceID: 20)

        XCTAssertFalse(attempt.usesImplicitSystemDefault)
        XCTAssertEqual(attempt.explicitDeviceID, 20)
    }

    // MARK: - Bluetooth-output avoidance (issues #481/#541/#409)

    func testBluetoothOutputPrefersBuiltInWhenOnSystemDefault() throws {
        // System default input is the Bluetooth headset (id 20); built-in is
        // id 30. With output on Bluetooth and no explicit selection, built-in
        // is promoted to the front so capture doesn't force HFP/SCO.
        let beforeDiagnostics = currentDiagnosticsLogContents()
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            outputIsBluetooth: { true }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
                .implicitSystemDefault(resolvedDeviceID: 20),
            ],
            "Built-in must lead, with the Bluetooth system default kept as fallback"
        )
        let line = try diagnosticsLine(
            containing: "mic_attempts_bluetooth_output_policy",
            after: beforeDiagnostics
        )
        XCTAssertTrue(line.contains("preference=on"))
        XCTAssertTrue(line.contains("explicit_selection_resolved=false"))
        XCTAssertTrue(line.contains("default_output_transport=bluetooth"))
        XCTAssertTrue(line.contains("outcome=fired"))
        XCTAssertTrue(line.contains("reason=built_in_promoted"))
    }

    func testBluetoothOutputPrefersBuiltInWhenOutputLookupIsUnavailable() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            outputIsBluetooth: { nil }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
                .implicitSystemDefault(resolvedDeviceID: 20),
            ],
            "An unresolved output route during churn must fail closed once the default input is risky"
        )
    }

    func testBluetoothOutputDoesNotReorderWhenOutputIsNotBluetooth() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            outputIsBluetooth: { false }
        )

        XCTAssertEqual(
            attempts,
            [
                .implicitSystemDefault(resolvedDeviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    func testBluetoothOutputDoesNotOverrideNonBluetoothSystemDefaultInput() {
        var queriedDefaultInput = false
        var queriedOutput = false
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            defaultInputIsBluetooth: { deviceID in
                queriedDefaultInput = true
                XCTAssertEqual(deviceID, 20)
                return false
            },
            outputIsBluetooth: {
                queriedOutput = true
                return true
            }
        )

        XCTAssertEqual(
            attempts,
            [
                .implicitSystemDefault(resolvedDeviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ],
            "A non-Bluetooth system-default input such as a USB desk mic must not be displaced"
        )
        XCTAssertTrue(queriedDefaultInput)
        XCTAssertFalse(
            queriedOutput,
            "The output transport must not be queried when the default input is not Bluetooth"
        )
    }

    func testBluetoothOutputKeepsExplicitSelectionFirstAndPinsBuiltInBeforeDefaultFallback() throws {
        // An explicit selection remains first, but if it fails during Bluetooth
        // route churn we still avoid floating to the unpinned headset default
        // before trying the pinned built-in mic.
        let beforeDiagnostics = currentDiagnosticsLogContents()
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "usb-mic",
            selectedInputDeviceID: { uid in uid == "usb-mic" ? AudioDeviceID(10) : nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            outputIsBluetooth: { true }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
                .implicitSystemDefault(resolvedDeviceID: 20),
            ],
            "Explicit selection must stay first, with built-in pinned before the Bluetooth default fallback"
        )
        let line = try diagnosticsLine(
            containing: "mic_attempts_bluetooth_output_policy",
            after: beforeDiagnostics
        )
        XCTAssertTrue(line.contains("preference=on"))
        XCTAssertTrue(line.contains("explicit_selection_resolved=true"))
        XCTAssertTrue(line.contains("default_output_transport=bluetooth"))
        XCTAssertTrue(line.contains("outcome=skipped"))
        XCTAssertTrue(line.contains("reason=explicit_selection_resolved"))
    }

    func testBluetoothOutputLeavesExplicitSelectionFallbackUntouchedForNonBluetoothDefaultInput() {
        var queriedDefaultInput = false
        var queriedOutput = false
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "usb-mic",
            selectedInputDeviceID: { uid in uid == "usb-mic" ? AudioDeviceID(10) : nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            defaultInputIsBluetooth: { deviceID in
                queriedDefaultInput = true
                XCTAssertEqual(deviceID, 20)
                return false
            },
            outputIsBluetooth: {
                queriedOutput = true
                return true
            }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
                .implicitSystemDefault(resolvedDeviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ],
            "A non-Bluetooth default input remains the first fallback behind an explicit selection"
        )
        XCTAssertTrue(queriedDefaultInput)
        XCTAssertFalse(
            queriedOutput,
            "The output transport must not be queried when the default input is not Bluetooth"
        )
    }

    func testBluetoothOutputDropsBluetoothDefaultFallbackWhenExplicitSelectionIsBuiltIn() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "built-in-mic",
            selectedInputDeviceID: { uid in uid == "built-in-mic" ? AudioDeviceID(30) : nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            outputIsBluetooth: { true }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .selected(uid: "built-in-mic"), deviceID: 30),
            ],
            "Explicit built-in selection must not fall through to an unpinned Bluetooth default"
        )
    }

    func testBluetoothOutputPinsBuiltInFallbackWhenBuiltInDefaultFollowsExplicitSelection() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "usb-mic",
            selectedInputDeviceID: { uid in uid == "usb-mic" ? AudioDeviceID(10) : nil },
            defaultInputDevice: { AudioDeviceID(30) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            defaultInputIsBluetooth: { _ in
                XCTFail("Built-in default should not need a Bluetooth input query")
                return true
            },
            outputIsBluetooth: { true }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ],
            "Built-in should be pinned behind the explicit selection without keeping a duplicate implicit default"
        )
    }

    func testBluetoothOutputPinsBuiltInWhenBuiltInIsAlreadyDefault() {
        // System default resolves to the built-in mic. Pin it explicitly under
        // Bluetooth output so a route-change flap cannot float the implicit
        // default onto the headset.
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(30) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            outputIsBluetooth: { true }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    func testBluetoothOutputRuleDisabledLeavesChainUntouched() throws {
        var queriedOutput = false
        let beforeDiagnostics = currentDiagnosticsLogContents()
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: false,
            outputIsBluetooth: {
                queriedOutput = true
                return true
            }
        )

        XCTAssertEqual(
            attempts,
            [
                .implicitSystemDefault(resolvedDeviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
        XCTAssertFalse(queriedOutput, "Disabled rule must not query the output transport")
        let line = try diagnosticsLine(
            containing: "mic_attempts_bluetooth_output_policy",
            after: beforeDiagnostics
        )
        XCTAssertTrue(line.contains("preference=off"))
        XCTAssertTrue(line.contains("explicit_selection_resolved=false"))
        XCTAssertTrue(line.contains("default_output_transport=not_queried"))
        XCTAssertTrue(line.contains("outcome=skipped"))
        XCTAssertTrue(line.contains("reason=preference_off"))
    }

    func testBluetoothOutputPromotesBuiltInWhenSavedSelectionUnresolvable() {
        // A mic was selected once (saved UID) but is currently unplugged, so it
        // doesn't resolve to a device. We fall back to the system default —
        // which here is the Bluetooth headset — so the avoidance rule must
        // still promote the built-in mic rather than landing on the race.
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "unplugged-usb-mic",
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) },
            preferBuiltInWhenOutputIsBluetooth: true,
            outputIsBluetooth: { true }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
                .implicitSystemDefault(resolvedDeviceID: 20),
            ],
            "A saved-but-unresolvable selection must not block Bluetooth-output avoidance"
        )
    }

    func testBluetoothOutputNoBuiltInMicLeavesChainAndSkipsQuery() {
        // No built-in mic (e.g. Mac mini / Mac Studio): nothing to promote, so
        // the chain is unchanged and the output-transport HAL query is skipped.
        var queriedDefaultInput = false
        var queriedOutput = false
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { nil },
            preferBuiltInWhenOutputIsBluetooth: true,
            defaultInputIsBluetooth: { _ in
                queriedDefaultInput = true
                return true
            },
            outputIsBluetooth: {
                queriedOutput = true
                return true
            }
        )

        XCTAssertEqual(attempts, [.implicitSystemDefault(resolvedDeviceID: 20)])
        XCTAssertFalse(
            queriedDefaultInput,
            "With no built-in mic to promote, the default input transport must not be queried"
        )
        XCTAssertFalse(
            queriedOutput,
            "With no built-in mic to promote, the output transport query must be skipped"
        )
    }

    func testPlatformSkipsInputDeviceSetterForImplicitSystemDefaultAttempt() throws {
        let recorder = MicrophoneCaptureInputDeviceSetterRecorder()
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [
                    MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
                    .implicitSystemDefault(resolvedDeviceID: 20),
                    MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
                ]
            },
            inputDeviceSetter: { deviceID, _ in
                recorder.record(deviceID)
                return false
            },
            engineStarter: { _, _, _, _ in }
        )

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 1024,
            tapHandler: { _, _ in }
        )
        defer { platform.stopEngine() }

        XCTAssertEqual(recorder.deviceIDs, [10])
        XCTAssertEqual(platform.lastSucceededAttempt, .implicitSystemDefault(resolvedDeviceID: 20))
    }

    private func makeSharedTestBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        return buffer
    }

    private func currentDiagnosticsLogContents() -> String {
        (try? String(contentsOf: AudioCaptureDiagnostics.diagnosticLogURL(), encoding: .utf8)) ?? ""
    }

    private func diagnosticsLine(
        containing marker: String,
        after previousContents: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        return try XCTUnwrap(
            diagnosticsLineIfPresent(containing: marker, after: previousContents),
            "Expected diagnostics line containing \(marker)",
            file: file,
            line: line
        )
    }

    private func diagnosticsLineIfPresent(
        containing marker: String,
        after previousContents: String
    ) -> String? {
        guard let contents = try? String(contentsOf: AudioCaptureDiagnostics.diagnosticLogURL(), encoding: .utf8) else {
            return nil
        }
        let newContents =
            contents.hasPrefix(previousContents)
            ? String(contents.dropFirst(previousContents.count))
            : contents
        return newContents.split(separator: "\n").map(String.init).last { $0.contains(marker) }
    }

    private func waitForDiagnosticsLine(
        containing marker: String,
        after previousContents: String,
        timeoutSeconds: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let line = diagnosticsLineIfPresent(containing: marker, after: previousContents) {
                return line
            }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        return try diagnosticsLine(containing: marker, after: previousContents, file: file, line: line)
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval,
        pollInterval: Duration = .milliseconds(25),
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: pollInterval)
        } while Date() < deadline
        return condition()
    }

    private func makeSharedMultiChannelFloatBuffer(
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        fill: (_ channel: Int, _ frame: Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder) | channels
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = fill(channel, frame)
            }
        }
        return buffer
    }
}

// MARK: - Test doubles for shared-stream path

private enum MicrophoneCaptureMockError: Error, Equatable {
    case simulatedFailure
}

private final class MicrophoneCaptureInputDeviceSetterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deviceIDsLocked: [AudioDeviceID] = []

    var deviceIDs: [AudioDeviceID] {
        lock.withLock { deviceIDsLocked }
    }

    func record(_ deviceID: AudioDeviceID) {
        lock.withLock {
            deviceIDsLocked.append(deviceID)
        }
    }
}

private final class MicrophoneCaptureTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private struct MicrophoneCaptureTestBufferSnapshot {
    let channelCount: AVAudioChannelCount
    let samplesByChannel: [[Float]]
}

private final class MicrophoneCaptureTestBufferSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: MicrophoneCaptureTestBufferSnapshot?

    func record(_ buffer: AVAudioPCMBuffer) {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let samplesByChannel: [[Float]]
        if let data = buffer.floatChannelData {
            samplesByChannel = (0..<channelCount).map { channel in
                Array(UnsafeBufferPointer(start: data[channel], count: frameCount))
            }
        } else {
            samplesByChannel = []
        }
        lock.withLock {
            _snapshot = MicrophoneCaptureTestBufferSnapshot(
                channelCount: buffer.format.channelCount,
                samplesByChannel: samplesByChannel
            )
        }
    }

    var snapshot: MicrophoneCaptureTestBufferSnapshot? {
        lock.withLock { _snapshot }
    }
}

private final class MicrophoneCaptureTestStallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: MeetingAudioError?
    func record(_ error: MeetingAudioError) {
        lock.withLock { _error = error }
    }
    var recordedError: MeetingAudioError? {
        lock.withLock { _error }
    }
}

/// Lightweight platform double for `MicrophoneCapture` shared-mode tests.
/// Mirrors `SharedMicrophoneStreamTests`'s `MockMicrophonePlatform` shape but
/// duplicated here to keep the two test files independent.
private final class SharedMicTestPlatform: MicrophoneEnginePlatform, @unchecked Sendable {
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
    /// Counts down on each successful start. While >0, treat the call as a
    /// failure even if `configureAndStartError` is nil. Lets a test simulate
    /// "first attempt fails, second succeeds."
    var failNextStartCount: Int = 0
    /// Optional hook invoked at the top of `configureAndStart` (before the
    /// error injection check). Lets a test pause the platform mid-subscribe
    /// so it can interleave a `stop()` and exercise the start-during-stop
    /// race-guard. Read without holding `lock` so the hook can call back
    /// into the platform without deadlocking.
    private let hookLock = NSLock()
    private var _configureAndStartHook: (@Sendable () -> Void)?
    private var _afterConfigureAndStartHook: (@Sendable () -> Void)?
    var configureAndStartHook: (@Sendable () -> Void)? {
        get { hookLock.withLock { _configureAndStartHook } }
        set { hookLock.withLock { _configureAndStartHook = newValue } }
    }
    var afterConfigureAndStartHook: (@Sendable () -> Void)? {
        get { hookLock.withLock { _afterConfigureAndStartHook } }
        set { hookLock.withLock { _afterConfigureAndStartHook = newValue } }
    }

    var isEngineRunning: Bool {
        lock.withLock { _isRunning }
    }

    var inputFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
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
        configureAndStartHook?()
        let shouldThrow: Error? = lock.withLock {
            _configureCalls.append(ConfigureCall(vpioEnabled: vpioEnabled, bufferSize: bufferSize))
            if let err = configureAndStartError { return err }
            if failNextStartCount > 0 {
                failNextStartCount -= 1
                return MicrophoneCaptureMockError.simulatedFailure
            }
            return nil
        }
        if let shouldThrow {
            throw shouldThrow
        }
        lock.withLock {
            _isRunning = true
            _tapHandler = tapHandler
        }
        afterConfigureAndStartHook?()
    }

    func stopEngine() {
        lock.withLock {
            _isRunning = false
            _tapHandler = nil
            _stopCount += 1
        }
    }

    func deliverBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let handler = lock.withLock { _tapHandler }
        handler?(buffer, time)
    }
}
