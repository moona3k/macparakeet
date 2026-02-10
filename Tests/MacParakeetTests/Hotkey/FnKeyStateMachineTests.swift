import XCTest
@testable import MacParakeetCore

final class FnKeyStateMachineTests: XCTestCase {

    var sm: FnKeyStateMachine!

    override func setUp() {
        sm = FnKeyStateMachine()
    }

    // MARK: - Double-tap Detection

    func testDoubleTapStartsPersistentRecording() {
        // First tap down
        let a1 = sm.fnDown(timestampMs: 1000)
        XCTAssertEqual(a1, .none)
        XCTAssertEqual(sm.state, .waitingForSecondTap)

        // First tap up (quick release)
        let a2 = sm.fnUp(timestampMs: 1050)
        XCTAssertEqual(a2, .none)

        // Second tap down within 400ms
        let a3 = sm.fnDown(timestampMs: 1200)
        XCTAssertEqual(a3, .startRecording(mode: .persistent))
        XCTAssertEqual(sm.state, .persistent)
    }

    func testPersistentStopsOnThirdFnPress() {
        // Double-tap to start
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        XCTAssertEqual(sm.state, .persistent)

        // Press Fn again to stop
        _ = sm.fnUp(timestampMs: 1250) // release from double-tap
        let action = sm.fnDown(timestampMs: 2000)
        XCTAssertEqual(action, .stopRecording)
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - Hold Detection

    func testHoldTimerStartsHoldToTalk() {
        _ = sm.fnDown(timestampMs: 1000)
        XCTAssertEqual(sm.state, .waitingForSecondTap)

        // Timer fires (Fn still held)
        let action = sm.holdTimerFired()
        XCTAssertEqual(action, .startRecording(mode: .holdToTalk))
        XCTAssertEqual(sm.state, .holdToTalk)
    }

    func testHoldReleaseStopsRecording() {
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.holdTimerFired()
        XCTAssertEqual(sm.state, .holdToTalk)

        let action = sm.fnUp(timestampMs: 1500)
        XCTAssertEqual(action, .stopRecording)
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - Slow Taps (not double-tap)

    func testSlowTapsDoNotDoubleTap() {
        // First tap
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)

        // Second tap too slow (> 400ms after first tap up)
        let action = sm.fnDown(timestampMs: 1500)
        XCTAssertEqual(action, .none) // Treated as new first tap, not double-tap
        XCTAssertEqual(sm.state, .waitingForSecondTap)
    }

    // MARK: - Cancel (Escape)

    func testEscapeDuringPersistentCancels() {
        // Start persistent recording
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        XCTAssertEqual(sm.state, .persistent)

        let action = sm.escapePressed()
        XCTAssertEqual(action, .cancelRecording)
        XCTAssertEqual(sm.state, .cancelWindow)
    }

    func testEscapeDuringHoldCancels() {
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.holdTimerFired()
        XCTAssertEqual(sm.state, .holdToTalk)

        let action = sm.escapePressed()
        XCTAssertEqual(action, .cancelRecording)
        XCTAssertEqual(sm.state, .cancelWindow)
    }

    func testEscapeInIdleDoesNothing() {
        let action = sm.escapePressed()
        XCTAssertEqual(action, .none)
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - Cancel Window

    func testFnBlockedDuringCancelWindow() {
        // Enter cancel window
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        _ = sm.escapePressed()
        XCTAssertEqual(sm.state, .cancelWindow)

        // Fn press during cancel window
        let action = sm.fnDown(timestampMs: 2000)
        XCTAssertEqual(action, .none)
        XCTAssertEqual(sm.state, .blocked)
    }

    func testCancelWindowExpires() {
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        _ = sm.escapePressed()

        _ = sm.cancelWindowExpired()
        XCTAssertEqual(sm.state, .idle)
    }

    func testUndoDuringCancelWindow() {
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        _ = sm.escapePressed()
        XCTAssertEqual(sm.state, .cancelWindow)

        _ = sm.undoPressed()
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - Reset

    func testReset() {
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        XCTAssertEqual(sm.state, .persistent)

        sm.reset()
        XCTAssertEqual(sm.state, .idle)
    }

    // MARK: - Edge Cases

    func testHoldTimerInNonWaitingState() {
        // Timer fires when not in waiting state
        let action = sm.holdTimerFired()
        XCTAssertEqual(action, .none)
    }

    func testFnUpInIdleState() {
        let action = sm.fnUp(timestampMs: 1000)
        XCTAssertEqual(action, .none)
    }

    func testCancelledByUIBlocksFn() {
        // Start persistent recording
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        XCTAssertEqual(sm.state, .persistent)

        // Cancel via UI button (not Esc)
        sm.cancelledByUI()
        XCTAssertEqual(sm.state, .cancelWindow)

        // Fn should be blocked
        let action = sm.fnDown(timestampMs: 2000)
        XCTAssertEqual(action, .none)
        XCTAssertEqual(sm.state, .blocked)
    }

    func testResumeRecordingAfterUndo() {
        // Start persistent, cancel via Esc, then undo
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        _ = sm.escapePressed()
        XCTAssertEqual(sm.state, .cancelWindow)

        // Undo → resume recording
        sm.resumeRecording(mode: .persistent)
        XCTAssertEqual(sm.state, .persistent)

        // Fn should stop the recording
        _ = sm.fnUp(timestampMs: 3000) // release any held key
        let action = sm.fnDown(timestampMs: 3500)
        XCTAssertEqual(action, .stopRecording)
        XCTAssertEqual(sm.state, .idle)
    }

    func testBlockedReleaseToCancelWindow() {
        _ = sm.fnDown(timestampMs: 1000)
        _ = sm.fnUp(timestampMs: 1050)
        _ = sm.fnDown(timestampMs: 1200)
        _ = sm.escapePressed()
        _ = sm.fnDown(timestampMs: 2000)
        XCTAssertEqual(sm.state, .blocked)

        let action = sm.fnUp(timestampMs: 2100)
        XCTAssertEqual(action, .none)
        XCTAssertEqual(sm.state, .cancelWindow)
    }
}
