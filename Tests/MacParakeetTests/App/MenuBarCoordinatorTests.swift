import AppKit
import XCTest
@testable import MacParakeet

@MainActor
final class MenuBarCoordinatorTests: XCTestCase {
    func testStatusItemVisibilityTransitionsAreIdempotent() {
        var state = MenuBarStatusItemState()

        XCTAssertEqual(state.setVisible(true), .install(.idle))
        XCTAssertEqual(state.setVisible(true), .none)
        XCTAssertEqual(state.setVisible(false), .remove)
        XCTAssertEqual(state.setVisible(false), .none)
    }

    func testStatusItemRestoresLatestIconStateAfterBeingHidden() {
        var state = MenuBarStatusItemState()

        XCTAssertEqual(state.updateIcon(.recording), .none)
        XCTAssertEqual(state.setVisible(true), .install(.recording))
        XCTAssertEqual(state.updateIcon(.processing), .update(.processing))
        XCTAssertEqual(state.setVisible(false), .remove)
        XCTAssertEqual(state.updateIcon(.idle), .none)
        XCTAssertEqual(state.setVisible(true), .install(.idle))
    }

    func testStatusItemRetriesAfterInstallationFailure() {
        var state = MenuBarStatusItemState()

        XCTAssertEqual(state.setVisible(true), .install(.idle))
        state.markInstallationFailed()

        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.setVisible(true), .install(.idle))
    }

    func testMeetingRecordingMenuPresentationWhileIdle() {
        let presentation = MenuBarCoordinator.meetingRecordingMenuPresentation(
            environmentReady: true,
            isMeetingRecordingActive: false,
            canOpenLiveMeetingPanel: false
        )

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
