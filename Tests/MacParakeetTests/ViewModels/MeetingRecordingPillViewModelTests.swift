import XCTest
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
}
