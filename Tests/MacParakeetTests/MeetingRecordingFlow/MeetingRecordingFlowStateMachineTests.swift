import XCTest
@testable import MacParakeetCore

final class MeetingRecordingFlowStateMachineTests: XCTestCase {
    func testStartRequestsPermissions() {
        var machine = MeetingRecordingFlowStateMachine()

        let effects = machine.handle(.startRequested)

        XCTAssertEqual(machine.state, .checkingPermissions)
        XCTAssertEqual(machine.generation, 1)
        XCTAssertEqual(effects, [.checkPermissions])
    }

    func testStopRequestedWhileIdleIsNoOp() {
        // Invariant: `.stopRequested` from `.idle` must be a no-op — a stop
        // must NEVER start a recording. (Privacy fix: a blind toggle would
        // silently begin mic + system-audio capture nobody asked for.)
        var machine = MeetingRecordingFlowStateMachine()

        let effects = machine.handle(.stopRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(
            machine.generation, 0,
            "No generation bump means no recording was started")
    }

    func testPermissionDeniedReturnsToIdleAndPresentsAlert() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.permissionsDenied(generation: 1, reason: .screenRecording))

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.updateMenuBar(.idle), .presentPermissionAlert(.screenRecording)])
    }

    func testPermissionsGrantedStartsRecordingFlow() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.permissionsGranted(generation: 1))

        XCTAssertEqual(machine.state, .starting)
        XCTAssertEqual(
            effects,
            [.showRecordingPill, .startRecording, .updateMenuBar(.recording)]
        )
    }

    func testStopWhileStartingQueuesPendingStop() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))

        let effects = machine.handle(.stopRequested)

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertTrue(effects.isEmpty)
    }

    func testPendingStopBeginsDurableStopOnceRecordingStarts() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.recordingStarted(generation: 1))

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertEqual(
            effects,
            [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]
        )
    }

    func testRecordingStopBeginsDurableStopAndQueuePreparation() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.stopRequested)

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertEqual(
            effects,
            [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]
        )
    }

    func testCaptureFailureWhileRecordingBeginsTranscription() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.captureFailed(generation: 1))

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertEqual(
            effects,
            [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]
        )
    }

    func testCaptureFailureWhileStartingIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))

        let effects = machine.handle(.captureFailed(generation: 1))

        XCTAssertEqual(machine.state, .starting)
        XCTAssertTrue(effects.isEmpty)
    }

    func testStaleCaptureFailureIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.captureFailed(generation: 0))

        XCTAssertEqual(machine.state, .recording)
        XCTAssertTrue(effects.isEmpty)
    }

    func testRecordingQueuedReturnsToIdleWithoutNavigation() {
        var machine = MeetingRecordingFlowStateMachine()
        let transcriptionID = UUID()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.recordingQueued(generation: 1, transcriptionID: transcriptionID))

        // The flow returns to `.idle` immediately (back-to-back can start now),
        // while the pill plays a self-contained saved-completion celebration via
        // `.showSavedCompletion` instead of vanishing the instant queueing ends.
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(
            effects,
            [.showSavedCompletion, .updateMenuBar(.idle)]
        )
    }

    func testDurableStopFailureShowsErrorAndSchedulesDismiss() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.transcriptionFailed(generation: 1, message: "Boom"))

        XCTAssertEqual(machine.state, .finishing(error: "Boom"))
        XCTAssertEqual(
            effects,
            [.showError("Boom"), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]
        )
    }

    func testAutoDismissReturnsToIdle() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)
        _ = machine.handle(.transcriptionFailed(generation: 1, message: "Boom"))

        let effects = machine.handle(.autoDismissExpired(generation: 1))

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.hidePill])
    }

    func testCancelFromRecordingDiscards() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.cancelRecording, .hidePill, .updateMenuBar(.idle)])
    }

    func testCancelFromStartingDiscards() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.cancelRecording, .hidePill, .updateMenuBar(.idle)])
    }

    func testCancelFromCheckingPermissionsDiscardsPendingStart() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.cancelRecording, .hidePill, .updateMenuBar(.idle)])
    }

    func testCancelFromStoppingIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertTrue(effects.isEmpty)
    }

    func testStaleGenerationIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsDenied(generation: 1, reason: .microphone))
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.permissionsGranted(generation: 1))

        XCTAssertEqual(machine.state, .checkingPermissions)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Durable stop boundary

    private func makeStoppingMachine() -> MeetingRecordingFlowStateMachine {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)
        return machine
    }

    func testLateTranscriptionFailureAfterRecordingQueuedIsIgnored() {
        var machine = makeStoppingMachine()
        _ = machine.handle(.recordingQueued(generation: 1, transcriptionID: UUID()))

        let failureEffects = machine.handle(.transcriptionFailed(generation: 1, message: "cancelled"))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(failureEffects.isEmpty)
    }
}
