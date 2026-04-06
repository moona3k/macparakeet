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
}
