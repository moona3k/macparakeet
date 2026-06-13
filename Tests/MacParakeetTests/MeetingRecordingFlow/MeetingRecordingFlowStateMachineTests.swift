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
        XCTAssertEqual(machine.generation, 0,
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

    func testPendingStopTransitionsToTranscribingOnceRecordingStarts() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.recordingStarted(generation: 1))

        XCTAssertEqual(machine.state, .transcribing)
        XCTAssertEqual(
            effects,
            [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]
        )
    }

    func testRecordingStopBeginsTranscription() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.stopRequested)

        XCTAssertEqual(machine.state, .transcribing)
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

        XCTAssertEqual(machine.state, .transcribing)
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

    func testCompletedTranscriptionNavigatesAndSchedulesDismiss() {
        var machine = MeetingRecordingFlowStateMachine()
        let transcriptionID = UUID()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.transcriptionCompleted(generation: 1, transcriptionID: transcriptionID))

        XCTAssertEqual(machine.state, .finishing(outcome: .completed(transcriptionID)))
        XCTAssertEqual(
            effects,
            [
                .showCompleted,
                .updateMenuBar(.idle),
                .navigateToTranscription(transcriptionID),
                .startAutoDismissTimer(seconds: 1),
            ]
        )
    }

    func testTranscriptionFailureShowsErrorAndSchedulesDismiss() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.transcriptionFailed(generation: 1, message: "Boom"))

        XCTAssertEqual(machine.state, .finishing(outcome: .error("Boom")))
        XCTAssertEqual(
            effects,
            [.showError("Boom"), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]
        )
    }

    func testAutoDismissReturnsToIdle() {
        var machine = MeetingRecordingFlowStateMachine()
        let transcriptionID = UUID()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)
        _ = machine.handle(.transcriptionCompleted(generation: 1, transcriptionID: transcriptionID))

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

    func testCancelFromTranscribingIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .transcribing)
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

    // MARK: - Abort transcription (issue #487)

    private func makeTranscribingMachine() -> MeetingRecordingFlowStateMachine {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)
        return machine
    }

    func testAbortTranscriptionKeepingAudioReturnsToIdle() {
        var machine = makeTranscribingMachine()

        let effects = machine.handle(.abortTranscriptionRequested(keepAudio: true))

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(
            effects,
            [.abortTranscription(keepAudio: true), .hidePill, .updateMenuBar(.idle)]
        )
    }

    func testAbortTranscriptionDeletingRecordingReturnsToIdle() {
        var machine = makeTranscribingMachine()

        let effects = machine.handle(.abortTranscriptionRequested(keepAudio: false))

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(
            effects,
            [.abortTranscription(keepAudio: false), .hidePill, .updateMenuBar(.idle)]
        )
    }

    func testAbortTranscriptionOutsideTranscribingIsNoOp() {
        // The confirmation dialog can race the transcription finishing — the
        // abort event must be inert in every non-transcribing state.
        var idleMachine = MeetingRecordingFlowStateMachine()
        XCTAssertTrue(idleMachine.handle(.abortTranscriptionRequested(keepAudio: false)).isEmpty)
        XCTAssertEqual(idleMachine.state, .idle)

        var recordingMachine = MeetingRecordingFlowStateMachine()
        _ = recordingMachine.handle(.startRequested)
        _ = recordingMachine.handle(.permissionsGranted(generation: 1))
        _ = recordingMachine.handle(.recordingStarted(generation: 1))
        XCTAssertTrue(recordingMachine.handle(.abortTranscriptionRequested(keepAudio: false)).isEmpty)
        XCTAssertEqual(recordingMachine.state, .recording)

        var finishedMachine = makeTranscribingMachine()
        let transcriptionID = UUID()
        _ = finishedMachine.handle(.transcriptionCompleted(generation: 1, transcriptionID: transcriptionID))
        XCTAssertTrue(finishedMachine.handle(.abortTranscriptionRequested(keepAudio: false)).isEmpty)
        XCTAssertEqual(finishedMachine.state, .finishing(outcome: .completed(transcriptionID)))
    }

    func testLateTranscriptionOutcomeAfterAbortIsIgnored() {
        // After an abort the cancelled task may still emit its terminal
        // events; neither may revive the flow or surface an error.
        var machine = makeTranscribingMachine()
        _ = machine.handle(.abortTranscriptionRequested(keepAudio: true))

        let failureEffects = machine.handle(.transcriptionFailed(generation: 1, message: "cancelled"))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(failureEffects.isEmpty)

        let completionEffects = machine.handle(.transcriptionCompleted(generation: 1, transcriptionID: UUID()))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(completionEffects.isEmpty)
    }
}
