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

    func testPrewarmPrefixPinsResolvedSystemDefaultExplicitly() {
        let attempts = [MeetingInputDeviceAttempt.implicitSystemDefault(resolvedDeviceID: 4)]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in false }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.explicitDeviceID, 4)
        XCTAssertFalse(result.first?.usesImplicitSystemDefault ?? true)
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

    func testPrewarmPrefixFailsClosedForUnknownTransportState() {
        let attempts = [MeetingInputDeviceAttempt(source: .selected(uid: "preferred"), deviceID: 7)]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in nil }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testPrewarmPrefixRejectsAggregateBackedByBluetooth() {
        let attempts = [MeetingInputDeviceAttempt.implicitSystemDefault(resolvedDeviceID: 8)]

        let result = AVAudioEngineMicrophonePlatform.prewarmAttemptPrefix(
            from: attempts,
            bluetoothInputState: { _ in true }
        )

        XCTAssertTrue(result.isEmpty)
    }
}
