import CoreAudio
import XCTest
@testable import MacParakeetCore

final class MicrophoneEnginePrewarmRoutingTests: XCTestCase {
    func testPrewarmPrefixStopsBeforeBluetoothFallback() {
        let attempts = [
            MeetingInputDeviceAttempt(source: .selected(uid: "desk"), deviceID: 1),
            MeetingInputDeviceAttempt.implicitSystemDefault(resolvedDeviceID: 2),
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 3),
        ]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { deviceID in
                deviceID == 2
            }
        )

        XCTAssertEqual(result, [MeetingInputDeviceAttempt(source: .selected(uid: "desk"), deviceID: 1)])
    }

    func testPrewarmPrefixFailsClosedForUnresolvedFirstRoute() {
        let attempts = [
            MeetingInputDeviceAttempt.implicitSystemDefault(),
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 3),
        ]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in false }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testPrewarmPrefixPreservesResolvedImplicitSystemDefault() {
        let attempts = [MeetingInputDeviceAttempt.implicitSystemDefault(resolvedDeviceID: 4)]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in false }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.explicitDeviceID)
        XCTAssertTrue(result.first?.usesImplicitSystemDefault ?? false)
    }

    func testPrewarmPrefixNeverUsesLowerPrioritySafeFallback() {
        let attempts = [
            MeetingInputDeviceAttempt(source: .selected(uid: "preferred"), deviceID: 5),
            MeetingInputDeviceAttempt(source: .builtIn, deviceID: 6),
        ]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in false }
        )

        XCTAssertEqual(result, [MeetingInputDeviceAttempt(source: .selected(uid: "preferred"), deviceID: 5)])
    }

    func testPrewarmPrefixFailsClosedForUnknownTransport() {
        let attempts = [MeetingInputDeviceAttempt(source: .selected(uid: "preferred"), deviceID: 7)]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in
                AudioDeviceManager.bluetoothRouteState(
                    transport: kAudioDeviceTransportTypeUnknown,
                    activeSubDeviceTransports: []
                )
            }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testPrewarmPrefixFailsClosedForAggregateWithNoActiveSubDevices() {
        let attempts = [MeetingInputDeviceAttempt.implicitSystemDefault(resolvedDeviceID: 8)]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in
                AudioDeviceManager.bluetoothRouteState(
                    transport: kAudioDeviceTransportTypeAggregate,
                    activeSubDeviceTransports: []
                )
            }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testPrewarmPrefixRejectsAggregateBackedByBluetooth() {
        let attempts = [MeetingInputDeviceAttempt.implicitSystemDefault(resolvedDeviceID: 9)]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in true }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testPreparedAttemptSafetyRechecksCurrentTransport() {
        let attempt = MeetingInputDeviceAttempt.implicitSystemDefault(resolvedDeviceID: 10)

        XCTAssertTrue(AVAudioEngineMicrophonePlatform.preparedAttemptIsSafe(
            attempt,
            bluetoothInputState: { _ in false }
        ))
        XCTAssertFalse(AVAudioEngineMicrophonePlatform.preparedAttemptIsSafe(
            attempt,
            bluetoothInputState: { _ in true }
        ))
        XCTAssertFalse(AVAudioEngineMicrophonePlatform.preparedAttemptIsSafe(
            attempt,
            bluetoothInputState: { _ in nil }
        ))
    }
}
