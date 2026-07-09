import AppKit
import XCTest
@testable import MacParakeet

@MainActor
final class MenuBarCoordinatorTests: XCTestCase {
    func testMeetingRecordingMenuPresentationWhileIdle() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: true,
            isMeetingRecordingActive: false,
            canOpenLiveMeetingPanel: false
        )

        XCTAssertEqual(presentation.recordingTitle, "Start Recording")
        XCTAssertTrue(presentation.recordingEnabled)
        XCTAssertTrue(presentation.openLiveMeetingPanelHidden)
        XCTAssertFalse(presentation.openLiveMeetingPanelEnabled)
    }

    func testMeetingRecordingMenuPresentationWhileRecording() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: true,
            isMeetingRecordingActive: true,
            canOpenLiveMeetingPanel: true
        )

        XCTAssertEqual(presentation.recordingTitle, "Stop Recording")
        XCTAssertTrue(presentation.recordingEnabled)
        XCTAssertFalse(presentation.openLiveMeetingPanelHidden)
        XCTAssertTrue(presentation.openLiveMeetingPanelEnabled)
    }

    func testMeetingRecordingMenuPresentationDisablesActionsBeforeEnvironmentIsReady() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: false,
            isMeetingRecordingActive: true,
            canOpenLiveMeetingPanel: true
        )

        XCTAssertFalse(presentation.recordingEnabled)
        XCTAssertFalse(presentation.openLiveMeetingPanelEnabled)
    }

    func testMeetingRecordingMenuPresentationKeepsPanelActionDisabledUntilPanelExists() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: true,
            isMeetingRecordingActive: true,
            canOpenLiveMeetingPanel: false
        )

        XCTAssertFalse(presentation.openLiveMeetingPanelHidden)
        XCTAssertFalse(presentation.openLiveMeetingPanelEnabled)
    }
}
