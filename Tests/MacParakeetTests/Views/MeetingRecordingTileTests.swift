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

    func testDefaultOffHealthUIFlagStillShowsConfirmedActionableWarning() {
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
        XCTAssertEqual(
            MeetingRecordingPanelView(viewModel: panelViewModel).visibleSourceHealthChips.map(\.label),
            ["System audio interrupted"]
        )
        XCTAssertEqual(
            MeetingRecordingAppKitPillView(viewModel: pillViewModel, onTap: {}).displayedSourceHealthWarning?.label,
            "System audio interrupted"
        )
        XCTAssertEqual(
            MeetingRecordingTile(viewModel: pillViewModel, onTap: {}).visibleSourceHealthWarning?.label,
            "System audio interrupted"
        )
    }

    func testDefaultOffHealthUIFlagStillHidesQuietButNormalSilence() {
        let captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .silent),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )
        let panelViewModel = MeetingRecordingPanelViewModel()
        panelViewModel.state = .recording
        panelViewModel.captureHealth = captureHealth
        let pillViewModel = MeetingRecordingPillViewModel()
        pillViewModel.state = .recording
        pillViewModel.captureHealth = captureHealth

        XCTAssertTrue(MeetingRecordingPanelView(viewModel: panelViewModel).visibleSourceHealthChips.isEmpty)
        XCTAssertNil(MeetingRecordingAppKitPillView(viewModel: pillViewModel, onTap: {}).displayedSourceHealthWarning)
        XCTAssertNil(MeetingRecordingTile(viewModel: pillViewModel, onTap: {}).visibleSourceHealthWarning)
    }

    func testProductionPillShowsUnavailableMicrophoneAndUpdatesWithoutStateChange() {
        // Issue #1223: the floating pill is the only surface of a calendar
        // auto-started meeting, so a failed microphone must show there.
        let pillViewModel = MeetingRecordingPillViewModel()
        pillViewModel.state = .recording
        pillViewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .live, level: 0.5),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )
        let pill = MeetingRecordingAppKitPillView(viewModel: pillViewModel, onTap: {})
        XCTAssertNil(pill.displayedSourceHealthWarning)
        XCTAssertNil(pill.toolTip)

        pillViewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .unavailable),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )
        pill.refresh()

        let warning = pill.displayedSourceHealthWarning
        XCTAssertEqual(warning?.source, .microphone)
        XCTAssertEqual(warning?.status, .unavailable)
        XCTAssertEqual(pill.toolTip, warning?.label)
        XCTAssertEqual(pill.accessibilityLabel(), "Recording meeting, \(warning?.label ?? "")")
    }

    func testPillBackingScaleChangeClearsARecoveredWarning() {
        let pillViewModel = MeetingRecordingPillViewModel()
        pillViewModel.state = .recording
        pillViewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .unavailable),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )
        let pill = MeetingRecordingAppKitPillView(viewModel: pillViewModel, onTap: {})
        XCTAssertNotNil(pill.displayedSourceHealthWarning)

        pillViewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .live, level: 0.5),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )
        pill.viewDidChangeBackingProperties()

        XCTAssertNil(pill.displayedSourceHealthWarning)
        XCTAssertNil(pill.toolTip)
    }

    func testMicrophoneMuteButtonAccessibilityLabelReflectsAction() {
        XCTAssertEqual(
            MeetingMicrophoneMuteButton(isMuted: false, onToggle: {}).accessibilityLabelText,
            "Mute microphone"
        )
        XCTAssertEqual(
            MeetingMicrophoneMuteButton(isMuted: true, onToggle: {}).accessibilityLabelText,
            "Unmute microphone"
        )
        XCTAssertEqual(
            MeetingMicrophoneMuteButton(isMuted: true, isEnabled: false, onToggle: {}).accessibilityLabelText,
            "Microphone muted"
        )
    }

    func testAudioSavedConfirmationAutoClears() async {
        let viewModel = MeetingRecordingPillViewModel()

        viewModel.showAudioSavedConfirmation(duration: .milliseconds(10))

        XCTAssertTrue(viewModel.showsAudioSavedConfirmation)
        let deadline = ContinuousClock.now + .seconds(5)
        while viewModel.showsAudioSavedConfirmation, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(viewModel.showsAudioSavedConfirmation)
    }
}
