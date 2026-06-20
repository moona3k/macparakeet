import XCTest
import MacParakeetCore
@testable import MacParakeet

final class MeetingRecordingTileTests: XCTestCase {
    func testPermissionStateReadyWhenRequiredPermissionsGranted() {
        let state = MeetingRecordingTile.PermissionState(
            microphoneGranted: true,
            screenRecordingGranted: true,
            sourceMode: .microphoneAndSystem
        )

        XCTAssertEqual(state, .ready(sourceMode: .microphoneAndSystem))
    }

    func testPermissionStateRequiresMicrophoneOnlyWhenMeetingCapturesMicrophone() {
        let microphoneAndSystem = MeetingRecordingTile.PermissionState(
            microphoneGranted: false,
            screenRecordingGranted: true,
            sourceMode: .microphoneAndSystem
        )
        let systemOnly = MeetingRecordingTile.PermissionState(
            microphoneGranted: false,
            screenRecordingGranted: true,
            sourceMode: .systemOnly
        )
        let microphoneOnly = MeetingRecordingTile.PermissionState(
            microphoneGranted: false,
            screenRecordingGranted: true,
            sourceMode: .microphoneOnly
        )

        XCTAssertEqual(microphoneAndSystem, .missing(microphone: true, screenRecording: false))
        XCTAssertEqual(systemOnly, .ready(sourceMode: .systemOnly))
        XCTAssertEqual(microphoneOnly, .missing(microphone: true, screenRecording: false))
    }

    func testPermissionStateRequiresScreenRecordingOnlyWhenMeetingCapturesSystemAudio() {
        let microphoneAndSystem = MeetingRecordingTile.PermissionState(
            microphoneGranted: true,
            screenRecordingGranted: false,
            sourceMode: .microphoneAndSystem
        )
        let microphoneOnly = MeetingRecordingTile.PermissionState(
            microphoneGranted: true,
            screenRecordingGranted: false,
            sourceMode: .microphoneOnly
        )
        let systemOnly = MeetingRecordingTile.PermissionState(
            microphoneGranted: true,
            screenRecordingGranted: false,
            sourceMode: .systemOnly
        )

        XCTAssertEqual(microphoneAndSystem, .missing(microphone: false, screenRecording: true))
        XCTAssertEqual(microphoneOnly, .ready(sourceMode: .microphoneOnly))
        XCTAssertEqual(systemOnly, .missing(microphone: false, screenRecording: true))
    }
}
