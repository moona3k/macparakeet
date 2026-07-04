import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
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

    func testDefaultOffHealthUIFlagHidesPresentationWhileKeepingViewModelHealthState() {
        let captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .live, level: 0.5),
            system: MeetingSourceHealth(source: .system, status: .interrupted)
        )

        let panelViewModel = MeetingRecordingPanelViewModel()
        panelViewModel.state = .recording
        panelViewModel.captureHealth = captureHealth
        XCTAssertFalse(panelViewModel.sourceHealthChips.isEmpty)

        let pillViewModel = MeetingRecordingPillViewModel()
        pillViewModel.state = .recording
        pillViewModel.captureHealth = captureHealth
        XCTAssertNotNil(pillViewModel.mirroredSourceHealthWarning)

        XCTAssertFalse(AppFeatures.meetingSourceHealthUIEnabled)
        XCTAssertTrue(MeetingRecordingPanelView(viewModel: panelViewModel).visibleSourceHealthChips.isEmpty)
        XCTAssertNil(MeetingRecordingPillView(viewModel: pillViewModel).visibleSourceHealthWarning)
        XCTAssertNil(MeetingRecordingTile(viewModel: pillViewModel, onTap: {}).visibleSourceHealthWarning)
    }
}
