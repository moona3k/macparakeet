import XCTest
@testable import MacParakeetCore

final class HotkeyGestureControllerTests: XCTestCase {
    func testFirstPressSchedulesStartupAndHoldTimers() {
        let controller = HotkeyGestureController()

        let outputs = controller.triggerPressed(timestampMs: 1_000)

        XCTAssertEqual(
            outputs,
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testQuickReleaseBeforeStartupShowsReadyForSecondTap() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)

        let outputs = controller.triggerReleased(timestampMs: 1_050)

        XCTAssertEqual(
            outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .showReadyForSecondTap,
            ]
        )
    }

    func testQuickReleaseAfterStartupDiscardsWithoutDuplicateReadyOutput() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)
        XCTAssertEqual(
            controller.startupDebounceElapsed(),
            [.startRecording(mode: .holdToTalk)]
        )

        let outputs = controller.triggerReleased(timestampMs: 1_050)

        XCTAssertEqual(
            outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .discardRecording(showReadyPill: true),
            ]
        )
    }

    func testSecondTapStartsPersistentWithoutReschedulingTimers() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.triggerReleased(timestampMs: 1_050)

        let outputs = controller.triggerPressed(timestampMs: 1_200)

        XCTAssertEqual(outputs, [.startRecording(mode: .persistent)])
    }

    func testInterruptionBeforeStartupCancelsTimersOnly() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)

        let outputs = controller.interrupted()

        XCTAssertEqual(outputs, [.cancelStartupDebounce, .cancelHoldWindow])
    }

    func testInterruptionAfterStartupSilentlyDiscards() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.startupDebounceElapsed()

        let outputs = controller.interrupted()

        XCTAssertEqual(
            outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .discardRecording(showReadyPill: false),
            ]
        )
    }

    func testEscapeWhileIdleDelegatesToIdleHandler() {
        let controller = HotkeyGestureController()

        XCTAssertEqual(controller.escapePressed(), [.escapeWhileIdle])
    }

    func testEscapeDuringReadyWindowResetsWithoutShowingIdleEscape() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.triggerReleased(timestampMs: 1_050)

        let outputs = controller.escapePressed()

        XCTAssertEqual(outputs, [.cancelStartupDebounce, .cancelHoldWindow])
    }

    func testEscapeDuringProvisionalRecordingCancelsRecording() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.startupDebounceElapsed()

        let outputs = controller.escapePressed()

        XCTAssertEqual(
            outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
    }

    func testNonBareReleaseDuringHoldCancelsRecording() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.holdWindowElapsed()

        let outputs = controller.nonBareTriggerReleased()

        XCTAssertEqual(
            outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
    }

    func testLowTapThresholdClampsStartupDebounce() {
        let controller = HotkeyGestureController(tapThresholdMs: 50)

        let outputs = controller.triggerPressed(timestampMs: 1_000)

        XCTAssertEqual(
            outputs,
            [
                .scheduleStartupDebounce(milliseconds: 50),
                .scheduleHoldWindow(milliseconds: 50),
            ]
        )
    }
}
