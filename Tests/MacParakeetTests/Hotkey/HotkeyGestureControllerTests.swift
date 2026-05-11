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

    func testInterruptionDuringConfirmedHoldCancelsRecordingImmediately() {
        let controller = HotkeyGestureController()
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.holdWindowElapsed()

        let outputs = controller.interrupted()

        XCTAssertEqual(
            outputs,
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
        XCTAssertEqual(
            controller.triggerReleased(timestampMs: 1_500),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
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

    func testDoubleTapOnlyDoesNotStartHoldToTalk() {
        let controller = HotkeyGestureController(mode: .doubleTapOnly)

        XCTAssertEqual(controller.triggerPressed(timestampMs: 1_000), [])
        XCTAssertEqual(controller.startupDebounceElapsed(), [])
        XCTAssertEqual(controller.holdWindowElapsed(), [])
        XCTAssertEqual(
            controller.triggerReleased(timestampMs: 1_050),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .showReadyForSecondTap,
            ]
        )
        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_200),
            [.startRecording(mode: .persistent)]
        )
    }

    func testHoldOnlyStartsAfterStartupAndStopsOnRelease() {
        let controller = HotkeyGestureController(mode: .holdOnly)

        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_000),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
        XCTAssertEqual(
            controller.startupDebounceElapsed(),
            [.startRecording(mode: .holdToTalk)]
        )
        XCTAssertEqual(
            controller.triggerReleased(timestampMs: 1_300),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .stopRecording,
            ]
        )
    }

    func testHoldOnlyQuickReleaseDoesNotShowSecondTapReadyState() {
        let controller = HotkeyGestureController(mode: .holdOnly)

        _ = controller.triggerPressed(timestampMs: 1_000)

        XCTAssertEqual(
            controller.triggerReleased(timestampMs: 1_050),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
    }

    func testNotifyCancelledByUIBlocksDoubleTapOnlyUntilReset() {
        let controller = HotkeyGestureController(mode: .doubleTapOnly)

        controller.notifyCancelledByUI()

        XCTAssertEqual(controller.triggerPressed(timestampMs: 1_000), [])
        XCTAssertEqual(
            controller.triggerReleased(timestampMs: 1_050),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )

        controller.reset()

        _ = controller.triggerPressed(timestampMs: 1_100)
        XCTAssertEqual(
            controller.triggerReleased(timestampMs: 1_150),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .showReadyForSecondTap,
            ]
        )
    }

    func testNotifyCancelledByUIBlocksHoldOnlyUntilReset() {
        let controller = HotkeyGestureController(mode: .holdOnly)

        controller.notifyCancelledByUI()

        XCTAssertEqual(controller.triggerPressed(timestampMs: 1_000), [])
        XCTAssertEqual(
            controller.triggerReleased(timestampMs: 1_050),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )

        controller.reset()

        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_100),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testHoldOnlyEscapeDuringCancelWindowConfirmsAndUnblocks() {
        let controller = HotkeyGestureController(mode: .holdOnly)
        _ = controller.triggerPressed(timestampMs: 1_000)
        _ = controller.startupDebounceElapsed()

        XCTAssertEqual(
            controller.escapePressed(),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
        XCTAssertEqual(
            controller.escapePressed(),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_200),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testSuppressedControllerIgnoresGesturesUntilReset() {
        let controller = HotkeyGestureController(mode: .holdOnly)

        controller.suppressUntilReset()

        XCTAssertEqual(controller.triggerPressed(timestampMs: 1_000), [])
        XCTAssertEqual(controller.startupDebounceElapsed(), [])
        XCTAssertEqual(controller.escapePressed(), [])
        XCTAssertEqual(controller.triggerReleased(timestampMs: 1_200), [])

        controller.reset()

        XCTAssertEqual(
            controller.triggerPressed(timestampMs: 1_300),
            [.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs)]
        )
    }

    func testCancelWindowNotificationOverridesSuppression() {
        let controller = HotkeyGestureController(mode: .holdOnly)

        controller.suppressUntilReset()
        controller.notifyCancelledByUI()

        XCTAssertEqual(
            controller.escapePressed(),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .cancelRecording,
            ]
        )
    }
}
