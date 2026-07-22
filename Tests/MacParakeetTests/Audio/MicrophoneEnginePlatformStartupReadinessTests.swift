import AVFoundation
import os
import XCTest
@testable import MacParakeetCore

final class MicrophoneEnginePlatformStartupReadinessTests: XCTestCase {
    func testStartFallsBackWhenPreferredRouteProducesNoBuffer() throws {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let engines = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let buffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [
                    MeetingInputDeviceAttempt(
                        source: .selected(uid: "preferred"),
                        deviceID: 10
                    ),
                    .implicitSystemDefault(resolvedDeviceID: 20),
                ]
            },
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { engine, _, _, tapHandler in
                let invocation = invocationCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                engines.withLock { $0.append(engine) }
                if invocation == 2 {
                    tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        XCTAssertEqual(invocationCount.withLock { $0 }, 2)
        XCTAssertEqual(
            platform.lastSucceededAttempt,
            .implicitSystemDefault(resolvedDeviceID: 20)
        )
        let startedEngines = engines.withLock { $0 }
        XCTAssertEqual(startedEngines.count, 2)
        XCTAssertFalse(startedEngines[0] === startedEngines[1])
    }

    func testStartFailsWhenNoRouteProducesABuffer() {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [
                    MeetingInputDeviceAttempt(
                        source: .selected(uid: "preferred"),
                        deviceID: 10
                    ),
                    .implicitSystemDefault(resolvedDeviceID: 20),
                ]
            },
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { _, _, _, _ in
                invocationCount.withLock { $0 += 1 }
            }
        )

        XCTAssertThrowsError(
            try platform.configureAndStart(
                vpioEnabled: false,
                bufferSize: 256,
                tapHandler: { _, _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? AVAudioEngineMicrophonePlatformError,
                .initialReadinessTimedOut
            )
        }
        XCTAssertFalse(platform.isEngineRunning)
        XCTAssertEqual(invocationCount.withLock { $0 }, 2)
    }

    func testMissingRouteIdentityDoesNotAcceptZeroFilledBuffer() {
        let zeroBuffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer())
        let platform = AVAudioEngineMicrophonePlatform(
            startupReadinessTimeout: 0,
            engineStarter: { _, _, _, tapHandler in
                tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 1))
            }
        )

        XCTAssertThrowsError(
            try platform.configureAndStart(
                vpioEnabled: false,
                bufferSize: 256,
                tapHandler: { _, _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? AVAudioEngineMicrophonePlatformError,
                .initialReadinessTimedOut
            )
        }
        XCTAssertFalse(platform.isEngineRunning)
    }

    func testBluetoothVPIOReferenceOnlyPreferredRouteFallsBack() throws {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let deliveredBufferCount = OSAllocatedUnfairLock(initialState: 0)
        let referenceOnlyBuffer = UncheckedSendableAudioPCMBuffer(
            makeStartupReadinessBuffer(channels: 2)
        )
        referenceOnlyBuffer.buffer.floatChannelData?[1][0] = 0.001
        let microphoneBuffer = UncheckedSendableAudioPCMBuffer(
            makeStartupReadinessBuffer(nonZero: true)
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
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { $0 == 10 },
            engineStarter: { _, _, _, tapHandler in
                let invocation = invocationCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                let buffer = invocation == 1 ? referenceOnlyBuffer : microphoneBuffer
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: true,
            bufferSize: 256,
            tapHandler: { _, _ in
                deliveredBufferCount.withLock { $0 += 1 }
            }
        )

        XCTAssertEqual(invocationCount.withLock { $0 }, 2)
        XCTAssertEqual(
            platform.lastSucceededAttempt,
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)
        )
        XCTAssertEqual(
            deliveredBufferCount.withLock { $0 },
            1,
            "VPIO reference audio must not hide a silent Bluetooth microphone channel"
        )
    }

    func testUnresolvedSystemDefaultZeroFilledRouteFallsBack() throws {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let deliveredBufferCount = OSAllocatedUnfairLock(initialState: 0)
        let zeroBuffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer())
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [
                    .implicitSystemDefault(resolvedDeviceID: nil),
                    MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20),
                ]
            },
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { _, _, _, tapHandler in
                invocationCount.withLock { $0 += 1 }
                tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 1))
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

        XCTAssertEqual(invocationCount.withLock { $0 }, 2)
        XCTAssertEqual(
            platform.lastSucceededAttempt,
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)
        )
        XCTAssertEqual(
            deliveredBufferCount.withLock { $0 },
            1,
            "Unresolved topology must fail closed until Core Audio identifies the route"
        )
    }

    func testNonBluetoothZeroFilledBufferCountsAsReady() throws {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let zeroBuffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer())
        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)]
            },
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { _, _, _, tapHandler in
                invocationCount.withLock { $0 += 1 }
                tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 1))
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        XCTAssertTrue(platform.isEngineRunning)
        XCTAssertEqual(invocationCount.withLock { $0 }, 1)
    }

    func testPreparedStartFallsBackWhenConfigurationChangesDuringReadiness() throws {
        let preparedEngine = OSAllocatedUnfairLock<AVAudioEngine?>(initialState: nil)
        let postedConfigurationChange = OSAllocatedUnfairLock(initialState: false)
        let startedEngines = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let buffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)]
            },
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { engine, _, _, tapHandler in
                startedEngines.withLock { $0.append(engine) }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                let shouldPost = postedConfigurationChange.withLock { posted -> Bool in
                    guard !posted else { return false }
                    posted = true
                    return true
                }
                if shouldPost, let engine = preparedEngine.withLock({ $0 }) {
                    NotificationCenter.default.post(
                        name: .AVAudioEngineConfigurationChange,
                        object: engine
                    )
                }
            }
        )
        defer { platform.stopEngine() }

        platform.prepare(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )
        let preparedState = platform.preparedEngineStateForTesting
        XCTAssertTrue(preparedState.prepared)
        preparedEngine.withLock { $0 = preparedState.engine }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        let engines = startedEngines.withLock { $0 }
        XCTAssertEqual(engines.count, 2, "stale prepared start + cold fallback")
        XCTAssertTrue(engines[0] === preparedState.engine)
        XCTAssertFalse(engines[0] === engines[1])
        XCTAssertTrue(platform.isEngineRunning)
    }

    func testColdStartFallsBackWhenConfigurationChangesDuringReadiness() throws {
        let currentEngine = OSAllocatedUnfairLock<AVAudioEngine?>(initialState: nil)
        let currentDefaultDeviceID = OSAllocatedUnfairLock<AudioDeviceID>(initialState: 10)
        let postedConfigurationChange = OSAllocatedUnfairLock(initialState: false)
        let startedEngines = OSAllocatedUnfairLock(initialState: [AVAudioEngine]())
        let buffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer())

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [
                    .implicitSystemDefault(
                        resolvedDeviceID: currentDefaultDeviceID.withLock { $0 }
                    ),
                    MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20),
                ]
            },
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { engine, _, _, tapHandler in
                currentEngine.withLock { $0 = engine }
                startedEngines.withLock { $0.append(engine) }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                let shouldPost = postedConfigurationChange.withLock { posted -> Bool in
                    guard !posted else { return false }
                    posted = true
                    return true
                }
                if shouldPost, let engine = currentEngine.withLock({ $0 }) {
                    currentDefaultDeviceID.withLock { $0 = 11 }
                    NotificationCenter.default.post(
                        name: .AVAudioEngineConfigurationChange,
                        object: engine
                    )
                }
            }
        )
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        let engines = startedEngines.withLock { $0 }
        XCTAssertEqual(engines.count, 2, "stale cold start + next route")
        XCTAssertFalse(engines[0] === engines[1])
        XCTAssertEqual(
            platform.lastSucceededAttempt,
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)
        )
        XCTAssertTrue(platform.isEngineRunning)
    }

    func testImplicitDefaultFallsBackWhenDefaultChangesDuringReadiness() throws {
        let platformBox = OSAllocatedUnfairLock<AVAudioEngineMicrophonePlatform?>(initialState: nil)
        let changedDefault = OSAllocatedUnfairLock(initialState: false)
        let startedDeviceIDs = OSAllocatedUnfairLock(initialState: [AudioDeviceID?]())
        let currentDeviceID = OSAllocatedUnfairLock<AudioDeviceID?>(initialState: nil)
        let buffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer(nonZero: true))

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [
                    .implicitSystemDefault(resolvedDeviceID: 10),
                    MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20),
                ]
            },
            inputDeviceSetter: { deviceID, _ in
                currentDeviceID.withLock { $0 = deviceID }
                return true
            },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { _, _, _, tapHandler in
                startedDeviceIDs.withLock { $0.append(currentDeviceID.withLock { $0 }) }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                let shouldChange = changedDefault.withLock { changed -> Bool in
                    guard !changed else { return false }
                    changed = true
                    return true
                }
                if shouldChange {
                    platformBox.withLock { $0 }?.noteDefaultInputChangeForTesting()
                }
            }
        )
        platformBox.withLock { $0 = platform }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        XCTAssertEqual(startedDeviceIDs.withLock { $0 }, [nil, 20])
        XCTAssertEqual(
            platform.lastSucceededAttempt,
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 20)
        )
    }

    func testExplicitSelectedStartIgnoresUnrelatedDefaultChangeDuringReadiness() throws {
        let platformBox = OSAllocatedUnfairLock<AVAudioEngineMicrophonePlatform?>(initialState: nil)
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let buffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer(nonZero: true))

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [MeetingInputDeviceAttempt(source: .selected(uid: "usb"), deviceID: 10)]
            },
            inputDeviceSetter: { _, _ in true },
            startupReadinessTimeout: 0,
            bluetoothInputState: { _ in false },
            engineStarter: { _, _, _, tapHandler in
                invocationCount.withLock { $0 += 1 }
                tapHandler(buffer.buffer, AVAudioTime(hostTime: 1))
                platformBox.withLock { $0 }?.noteDefaultInputChangeForTesting()
            }
        )
        platformBox.withLock { $0 = platform }
        defer { platform.stopEngine() }

        try platform.configureAndStart(
            vpioEnabled: false,
            bufferSize: 256,
            tapHandler: { _, _ in }
        )

        XCTAssertEqual(invocationCount.withLock { $0 }, 1)
        XCTAssertEqual(
            platform.lastSucceededAttempt,
            MeetingInputDeviceAttempt(source: .selected(uid: "usb"), deviceID: 10)
        )
    }

    func testImplicitDefaultRefreshesBluetoothSignalPolicyWhileRunning() throws {
        let currentDeviceID = OSAllocatedUnfairLock<AudioDeviceID>(initialState: 20)
        let currentBluetoothState = OSAllocatedUnfairLock<Bool?>(initialState: false)
        let installedTapHandler = OSAllocatedUnfairLock<
            (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        >(initialState: nil)
        let deliveredBufferCount = OSAllocatedUnfairLock(initialState: 0)
        let zeroBuffer = UncheckedSendableAudioPCMBuffer(makeStartupReadinessBuffer())
        let signalBuffer = UncheckedSendableAudioPCMBuffer(
            makeStartupReadinessBuffer(nonZero: true)
        )

        let platform = AVAudioEngineMicrophonePlatform(
            deviceAttemptsBuilder: {
                [.implicitSystemDefault(resolvedDeviceID: currentDeviceID.withLock { $0 })]
            },
            startupReadinessTimeout: 0,
            bluetoothInputState: { deviceID in
                deviceID == 10 ? currentBluetoothState.withLock { $0 } : false
            },
            engineStarter: { _, _, _, tapHandler in
                installedTapHandler.withLock { $0 = tapHandler }
                tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 1))
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
        XCTAssertEqual(deliveredBufferCount.withLock { $0 }, 1)

        currentDeviceID.withLock { $0 = 10 }
        currentBluetoothState.withLock { $0 = nil }
        platform.refreshActiveTapSignalPolicyForTesting()
        let tapHandler = try XCTUnwrap(installedTapHandler.withLock { $0 })
        tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 2))

        currentBluetoothState.withLock { $0 = true }
        platform.refreshActiveTapSignalPolicyForTesting()
        tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 3))

        currentBluetoothState.withLock { $0 = nil }
        platform.refreshActiveTapSignalPolicyForTesting()
        tapHandler(zeroBuffer.buffer, AVAudioTime(hostTime: 4))

        currentBluetoothState.withLock { $0 = true }
        platform.refreshActiveTapSignalPolicyForTesting()
        tapHandler(signalBuffer.buffer, AVAudioTime(hostTime: 5))

        XCTAssertEqual(
            deliveredBufferCount.withLock { $0 },
            2,
            "Unresolved/Bluetooth transitions must filter zero PCM but forward real samples"
        )
    }
}

private func makeStartupReadinessBuffer(
    nonZero: Bool = false,
    channels: AVAudioChannelCount = 1
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
    buffer.frameLength = 32
    if nonZero {
        buffer.floatChannelData?[0][0] = 0.001
    }
    return buffer
}
