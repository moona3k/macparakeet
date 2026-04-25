import XCTest
import CoreAudio
@testable import MacParakeetCore

final class MicrophoneCaptureTests: XCTestCase {
    func testInitCreatesCaptureInstance() {
        let capture = MicrophoneCapture()
        XCTAssertNotNil(capture)
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
                MeetingInputDeviceAttempt(source: .systemDefault, deviceID: 20),
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
                MeetingInputDeviceAttempt(source: .systemDefault, deviceID: 20),
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
                MeetingInputDeviceAttempt(source: .systemDefault, deviceID: 30),
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
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }
}
