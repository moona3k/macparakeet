import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingRecordingPillViewModelTests: XCTestCase {
    func testCanTogglePauseOnlyWhileRecordingOrPaused() {
        let viewModel = MeetingRecordingPillViewModel()

        viewModel.state = .idle
        XCTAssertFalse(viewModel.canTogglePause)

        viewModel.state = .recording
        XCTAssertTrue(viewModel.canTogglePause)

        viewModel.state = .paused
        XCTAssertTrue(viewModel.canTogglePause)

        viewModel.state = .completing
        XCTAssertFalse(viewModel.canTogglePause)

        viewModel.state = .transcribing
        XCTAssertFalse(viewModel.canTogglePause)

        viewModel.state = .completed
        XCTAssertFalse(viewModel.canTogglePause)

        viewModel.state = .error("boom")
        XCTAssertFalse(viewModel.canTogglePause)
    }

    func testIsPausedConvenienceMatchesPillState() {
        let viewModel = MeetingRecordingPillViewModel()

        viewModel.state = .recording
        XCTAssertFalse(viewModel.isPaused)

        viewModel.state = .paused
        XCTAssertTrue(viewModel.isPaused)

        viewModel.state = .completed
        XCTAssertFalse(viewModel.isPaused)
    }

    func testFormattedElapsedUsesMinutesAndSeconds() {
        let viewModel = MeetingRecordingPillViewModel()
        viewModel.elapsedSeconds = 65
        XCTAssertEqual(viewModel.formattedElapsed, "1:05")

        viewModel.elapsedSeconds = 0
        XCTAssertEqual(viewModel.formattedElapsed, "0:00")

        viewModel.elapsedSeconds = 600
        XCTAssertEqual(viewModel.formattedElapsed, "10:00")
    }

    func testMirroredSourceHealthWarningUsesPrimaryDegradedStateWhileRecording() {
        let viewModel = MeetingRecordingPillViewModel()
        viewModel.state = .recording
        viewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .muted),
            system: MeetingSourceHealth(source: .system, status: .interrupted)
        )

        let warning = viewModel.mirroredSourceHealthWarning

        XCTAssertEqual(warning?.label, "System audio interrupted")
        XCTAssertEqual(warning?.severity, .critical)
        XCTAssertEqual(warning?.symbolName, "exclamationmark.triangle.fill")
    }

    func testMirroredSourceHealthWarningAlsoShowsWhilePaused() {
        let viewModel = MeetingRecordingPillViewModel()
        viewModel.state = .paused
        viewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .stalled),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )

        XCTAssertEqual(viewModel.mirroredSourceHealthWarning?.label, "Mic may be stalled")
    }

    func testMirroredSourceHealthWarningHidesForHealthyOrNonRecordingStates() {
        let viewModel = MeetingRecordingPillViewModel()
        viewModel.state = .recording
        viewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .live, level: 0.5),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )

        XCTAssertNil(viewModel.mirroredSourceHealthWarning)

        viewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .silent),
            system: MeetingSourceHealth(source: .system, status: .live, level: 0.5)
        )
        viewModel.state = .transcribing

        XCTAssertNil(viewModel.mirroredSourceHealthWarning)
    }

    func testActionableWarningExcludesSilentAndShowsRecovering() {
        let viewModel = MeetingRecordingPillViewModel()
        viewModel.state = .recording
        viewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .silent),
            system: MeetingSourceHealth(source: .system, status: .recovering)
        )

        XCTAssertEqual(
            viewModel.mirroredActionableSourceHealthWarning?.label,
            "System audio reconnecting"
        )

        viewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .silent),
            system: MeetingSourceHealth(source: .system, status: .live)
        )
        XCTAssertNil(viewModel.mirroredActionableSourceHealthWarning)
    }

    func testVisibleWarningAppliesCurrentProductPolicy() {
        let viewModel = MeetingRecordingPillViewModel()
        viewModel.state = .recording
        viewModel.captureHealth = MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: .silent),
            system: MeetingSourceHealth(source: .system, status: .recovering)
        )

        XCTAssertFalse(AppFeatures.meetingSourceHealthUIEnabled)
        XCTAssertEqual(
            viewModel.mirroredVisibleSourceHealthWarning?.label,
            "System audio reconnecting"
        )
    }
}
