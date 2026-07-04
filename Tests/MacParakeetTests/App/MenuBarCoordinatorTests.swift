import AppKit
import XCTest
@testable import MacParakeet

@MainActor
final class MenuBarCoordinatorTests: XCTestCase {
    func testMeetingRecordingMenuPresentationWhileIdle() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: true,
            isMeetingRecordingActive: false,
            canOpenLiveMeetingPanel: false,
            showFloatingMeetingControls: true
        )

        XCTAssertEqual(presentation.recordingTitle, "Start Recording")
        XCTAssertTrue(presentation.recordingEnabled)
        XCTAssertTrue(presentation.openLiveMeetingPanelHidden)
        XCTAssertFalse(presentation.openLiveMeetingPanelEnabled)
        XCTAssertTrue(presentation.showFloatingMeetingControlsEnabled)
        XCTAssertEqual(presentation.showFloatingMeetingControlsState, .on)
    }

    func testMeetingRecordingMenuPresentationWhileRecordingWithPillHidden() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: true,
            isMeetingRecordingActive: true,
            canOpenLiveMeetingPanel: true,
            showFloatingMeetingControls: false
        )

        XCTAssertEqual(presentation.recordingTitle, "Stop Recording")
        XCTAssertTrue(presentation.recordingEnabled)
        XCTAssertFalse(presentation.openLiveMeetingPanelHidden)
        XCTAssertTrue(presentation.openLiveMeetingPanelEnabled)
        XCTAssertTrue(presentation.showFloatingMeetingControlsEnabled)
        XCTAssertEqual(presentation.showFloatingMeetingControlsState, .off)
    }

    func testMeetingRecordingMenuPresentationDisablesActionsBeforeEnvironmentIsReady() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: false,
            isMeetingRecordingActive: true,
            canOpenLiveMeetingPanel: true,
            showFloatingMeetingControls: false
        )

        XCTAssertFalse(presentation.recordingEnabled)
        XCTAssertFalse(presentation.openLiveMeetingPanelEnabled)
        XCTAssertFalse(presentation.showFloatingMeetingControlsEnabled)
    }

    func testMeetingRecordingMenuPresentationKeepsPanelActionDisabledUntilPanelExists() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: true,
            isMeetingRecordingActive: true,
            canOpenLiveMeetingPanel: false,
            showFloatingMeetingControls: false
        )

        XCTAssertFalse(presentation.openLiveMeetingPanelHidden)
        XCTAssertFalse(presentation.openLiveMeetingPanelEnabled)
    }
}
