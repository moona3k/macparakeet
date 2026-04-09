import XCTest
@testable import MacParakeetCore

final class DictationFlowStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func makeMachine() -> DictationFlowStateMachine {
        DictationFlowStateMachine()
    }

    /// Advance a machine through a sequence of events, returning the final effects.
    @discardableResult
    private func advance(
        _ machine: inout DictationFlowStateMachine,
        through events: [DictationFlowEvent]
    ) -> [DictationFlowEffect] {
        var lastEffects: [DictationFlowEffect] = []
        for event in events {
            lastEffects = machine.handle(event)
        }
        return lastEffects
    }

    /// Start a machine and advance to recording state.
    private func machineInRecording(
        mode: FnKeyStateMachine.RecordingMode = .persistent
    ) -> DictationFlowStateMachine {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: mode))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        _ = m.handle(.recordingStarted(generation: gen))
        return m
    }

    /// Start a machine and advance to processing state.
    private func machineInProcessing() -> DictationFlowStateMachine {
        var m = machineInRecording()
        _ = m.handle(.stopRequested)
        return m
    }

    /// Start a machine and advance to cancel countdown state.
    private func machineInCancelCountdown() -> DictationFlowStateMachine {
        var m = machineInRecording()
        _ = m.handle(.cancelRequested(reason: .escape))
        return m
    }

    // MARK: - Idle State

    func testInitialStateIsIdle() {
        let m = makeMachine()
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.generation, 0)
    }

    func testIdleReadyPillRequested() {
        var m = makeMachine()
        let effects = m.handle(.readyPillRequested)

        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.generation, 1)
        XCTAssertTrue(effects.contains(.hideIdlePill))
        XCTAssertTrue(effects.contains(.showReadyPill))
        XCTAssertTrue(effects.contains(.startReadyDismissTimer))
    }

    func testIdleStartRequested() {
        var m = makeMachine()
        let effects = m.handle(.startRequested(mode: .persistent))

        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))
        XCTAssertEqual(m.generation, 1)
        XCTAssertTrue(effects.contains(.hideIdlePill))
        XCTAssertTrue(effects.contains(.checkEntitlements))
    }

    func testIdleIgnoresInvalidEvents() {
        var m = makeMachine()
        let events: [DictationFlowEvent] = [
            .stopRequested,
            .cancelRequested(reason: .escape),
            .discardRequested(showReadyPill: true),
            .undoRequested,
            .transcriptionCompleted(generation: 0),
            .recordingStarted(generation: 0),
            .cancelCountdownExpired(generation: 0),
            .cancelConfirmedImmediate,
        ]
        for event in events {
            let effects = m.handle(event)
            XCTAssertTrue(effects.isEmpty, "Idle should ignore \(event)")
            XCTAssertEqual(m.state, .idle)
        }
    }

    // MARK: - Ready State

    func testReadySelfTransition() {
        var m = makeMachine()
        _ = m.handle(.readyPillRequested)
        let gen = m.generation

        let effects = m.handle(.readyPillRequested)
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.generation, gen) // generation unchanged
        XCTAssertEqual(effects, [.rescheduleReadyDismissTimer])
    }

    func testReadyTimedOut() {
        var m = makeMachine()
        _ = m.handle(.readyPillRequested)
        let gen = m.generation

        let effects = m.handle(.readyPillTimedOut(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.dismissReadyPill))
        XCTAssertTrue(effects.contains(.showIdlePill))
    }

    func testReadyTimedOutStaleGeneration() {
        var m = makeMachine()
        _ = m.handle(.readyPillRequested)

        let effects = m.handle(.readyPillTimedOut(generation: 0)) // stale
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.state, .ready) // unchanged
    }

    func testReadyStartRequested() {
        var m = makeMachine()
        _ = m.handle(.readyPillRequested)
        let gen = m.generation

        let effects = m.handle(.startRequested(mode: .holdToTalk))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .holdToTalk))
        XCTAssertEqual(m.generation, gen) // same generation (seamless)
        XCTAssertTrue(effects.contains(.cancelReadyDismissTimer))
        XCTAssertTrue(effects.contains(.checkEntitlements))
    }

    func testReadyCancelRequested() {
        var m = makeMachine()
        _ = m.handle(.readyPillRequested)

        let effects = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelReadyDismissTimer))
        XCTAssertTrue(effects.contains(.dismissReadyPill))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.showIdlePill))
    }

    func testReadyDismissRequested() {
        var m = makeMachine()
        _ = m.handle(.readyPillRequested)

        let effects = m.handle(.dismissRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelReadyDismissTimer))
        XCTAssertTrue(effects.contains(.dismissReadyPill))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
    }

    // MARK: - Checking Entitlements

    func testCheckingEntitlementsGranted() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation

        let effects = m.handle(.entitlementsGranted(generation: gen))
        XCTAssertEqual(m.state, .startingService(mode: .persistent))
        XCTAssertTrue(effects.contains(.showRecordingOverlay(mode: .persistent)))
        XCTAssertTrue(effects.contains(.startRecording(mode: .persistent)))
        XCTAssertTrue(effects.contains(.updateMenuBar(.recording)))
    }

    func testCheckingEntitlementsDenied() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation

        let effects = m.handle(.entitlementsDenied(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
        XCTAssertTrue(effects.contains(.presentEntitlementsAlert))
        XCTAssertTrue(effects.contains(.showIdlePill))
    }

    func testCheckingEntitlementsStaleGeneration() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))

        let effects = m.handle(.entitlementsGranted(generation: 0)) // stale
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))
    }

    func testCheckingEntitlementsCancelRequested() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))

        let effects = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
        XCTAssertTrue(effects.contains(.showIdlePill))
    }

    func testCheckingEntitlementsStopRequested() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))

        let effects = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
    }

    func testCheckingEntitlementsDiscardRequestedShowsReadyPill() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .holdToTalk))

        let effects = m.handle(.discardRequested(showReadyPill: true))
        XCTAssertEqual(m.state, .ready)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.showReadyPill))
        XCTAssertTrue(effects.contains(.startReadyDismissTimer))
    }

    func testCheckingEntitlementsDiscardRequestedSilentlyReturnsIdle() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .holdToTalk))

        let effects = m.handle(.discardRequested(showReadyPill: false))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.showIdlePill))
        XCTAssertFalse(effects.contains(.showReadyPill))
    }

    func testCheckingEntitlementsDismissRequested() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))

        let effects = m.handle(.dismissRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
    }

    // MARK: - Starting Service

    func testStartingServiceRecordingStarted() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .holdToTalk))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        let effects = m.handle(.recordingStarted(generation: gen))
        XCTAssertEqual(m.state, .recording(mode: .holdToTalk))
        XCTAssertTrue(effects.isEmpty) // audio level loop starts externally
    }

    func testStartingServiceStartFailed() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        let effects = m.handle(.startFailed(generation: gen, message: "Mic error"))
        XCTAssertEqual(m.state, .finishing(outcome: .error("Mic error")))
        XCTAssertTrue(effects.contains(.showError("Mic error")))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
        XCTAssertTrue(effects.contains(.startDisplayDismissTimer(seconds: 5)))
    }

    func testStartingServiceStopRequested() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        let effects = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .pendingStop(mode: .persistent))
        XCTAssertTrue(effects.isEmpty) // deferred
    }

    func testStartingServiceCancelRequested() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        let effects = m.handle(.cancelRequested(reason: .ui))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.cancelRecording(reason: .ui)))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
    }

    func testStartingServiceDiscardRequestedShowsReadyPill() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .holdToTalk))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        let effects = m.handle(.discardRequested(showReadyPill: true))
        XCTAssertEqual(m.state, .ready)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.discardRecording))
        XCTAssertTrue(effects.contains(.showReadyPill))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
    }

    func testStartingServiceDiscardRequestedSilentlyReturnsIdle() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .holdToTalk))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        let effects = m.handle(.discardRequested(showReadyPill: false))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.discardRecording))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.showIdlePill))
        XCTAssertFalse(effects.contains(.showReadyPill))
    }

    func testStartingServiceStaleRecordingStarted() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        let effects = m.handle(.recordingStarted(generation: gen - 1))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.state, .startingService(mode: .persistent))
    }

    // MARK: - Recording

    func testRecordingStopRequested() {
        var m = machineInRecording()

        let effects = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .processing)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.stopRecordingAndTranscribe))
        XCTAssertTrue(effects.contains(.showProcessingState))
        XCTAssertTrue(effects.contains(.updateMenuBar(.processing)))
    }

    func testRecordingCancelRequestedEscape() {
        var m = machineInRecording()

        let effects = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .cancelCountdown)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.cancelRecording(reason: .escape)))
        XCTAssertTrue(effects.contains(.showCancelCountdown))
        XCTAssertTrue(effects.contains(.startCancelCountdown))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
        // Always emitted (old code always calls notifyCancelledByUI)
        XCTAssertTrue(effects.contains(.notifyHotkeyCancelledByUI))
    }

    func testRecordingCancelRequestedUI() {
        var m = machineInRecording()

        let effects = m.handle(.cancelRequested(reason: .ui))
        XCTAssertEqual(m.state, .cancelCountdown)
        XCTAssertTrue(effects.contains(.notifyHotkeyCancelledByUI))
    }

    func testRecordingDiscardRequestedShowsReadyPill() {
        var m = machineInRecording(mode: .holdToTalk)

        let effects = m.handle(.discardRequested(showReadyPill: true))
        XCTAssertEqual(m.state, .ready)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.discardRecording))
        XCTAssertTrue(effects.contains(.showReadyPill))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
    }

    func testRecordingDiscardRequestedSilentlyReturnsIdle() {
        var m = machineInRecording(mode: .holdToTalk)

        let effects = m.handle(.discardRequested(showReadyPill: false))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.discardRecording))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.showIdlePill))
        XCTAssertFalse(effects.contains(.showReadyPill))
    }

    func testRecordingRapidRestart() {
        var m = machineInRecording()
        let oldGen = m.generation

        let effects = m.handle(.startRequested(mode: .holdToTalk))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .holdToTalk))
        XCTAssertEqual(m.generation, oldGen + 1) // new generation
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.cancelRecording(reason: .ui)))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.checkEntitlements))
    }

    func testRecordingDismissRequested() {
        var m = machineInRecording()

        let effects = m.handle(.dismissRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.cancelRecording(reason: .ui)))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
    }

    // MARK: - Pending Stop

    func testPendingStopRecordingStarted() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        _ = m.handle(.stopRequested) // → pendingStop
        XCTAssertEqual(m.state, .pendingStop(mode: .persistent))

        let effects = m.handle(.recordingStarted(generation: gen))
        XCTAssertEqual(m.state, .processing)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.stopRecordingAndTranscribe))
        XCTAssertTrue(effects.contains(.showProcessingState))
        XCTAssertTrue(effects.contains(.updateMenuBar(.processing)))
    }

    func testPendingStopStartFailed() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        _ = m.handle(.stopRequested)

        let effects = m.handle(.startFailed(generation: gen, message: "Failed"))
        XCTAssertEqual(m.state, .finishing(outcome: .error("Failed")))
        XCTAssertTrue(effects.contains(.showError("Failed")))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
    }

    func testPendingStopCancelRequested() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        _ = m.handle(.stopRequested)

        let effects = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testPendingStopStaleRecordingStarted() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        _ = m.handle(.stopRequested)

        let effects = m.handle(.recordingStarted(generation: gen - 1))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.state, .pendingStop(mode: .persistent))
    }

    // MARK: - Processing

    func testProcessingTranscriptionCompleted() {
        var m = machineInProcessing()
        let gen = m.generation

        let effects = m.handle(.transcriptionCompleted(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))
        XCTAssertTrue(effects.contains(.showSuccess))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
        XCTAssertTrue(effects.contains(.resignKeyWindow))
        XCTAssertTrue(effects.contains(.pasteTranscript))
    }

    func testProcessingTranscriptionFailedNoSpeech() {
        var m = machineInProcessing()
        let gen = m.generation

        let effects = m.handle(.transcriptionFailedNoSpeech(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .noSpeech))
        XCTAssertTrue(effects.contains(.showNoSpeech))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
        XCTAssertTrue(effects.contains(.startDisplayDismissTimer(seconds: 2.5)))
    }

    func testProcessingTranscriptionFailed() {
        var m = machineInProcessing()
        let gen = m.generation

        let effects = m.handle(.transcriptionFailed(generation: gen, message: "STT error"))
        XCTAssertEqual(m.state, .finishing(outcome: .error("STT error")))
        XCTAssertTrue(effects.contains(.showError("STT error")))
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)))
        XCTAssertTrue(effects.contains(.startDisplayDismissTimer(seconds: 5)))
    }

    func testProcessingCancelRequested() {
        var m = machineInProcessing()

        let effects = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.cancelActionTask))
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testProcessingDismissRequested() {
        var m = machineInProcessing()

        let effects = m.handle(.dismissRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testProcessingStaleTranscriptionCompleted() {
        var m = machineInProcessing()

        let effects = m.handle(.transcriptionCompleted(generation: 0))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.state, .processing)
    }

    // MARK: - Cancel Countdown

    func testCancelCountdownUndoRequested() {
        var m = machineInCancelCountdown()

        let effects = m.handle(.undoRequested)
        XCTAssertEqual(m.state, .processing)
        XCTAssertTrue(effects.contains(.cancelCancelCountdown))
        XCTAssertTrue(effects.contains(.cancelActionTask))
        XCTAssertTrue(effects.contains(.undoCancelAndTranscribe))
        XCTAssertTrue(effects.contains(.showProcessingState))
        XCTAssertTrue(effects.contains(.updateMenuBar(.processing)))
    }

    func testCancelCountdownConfirmedImmediate() {
        var m = machineInCancelCountdown()

        let effects = m.handle(.cancelConfirmedImmediate)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelCancelCountdown))
        XCTAssertTrue(effects.contains(.confirmCancel))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
    }

    func testCancelCountdownExpired() {
        var m = machineInCancelCountdown()
        let gen = m.generation

        let effects = m.handle(.cancelCountdownExpired(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.confirmCancel))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.showIdlePill))
    }

    func testCancelCountdownStaleExpired() {
        var m = machineInCancelCountdown()

        let effects = m.handle(.cancelCountdownExpired(generation: 0))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.state, .cancelCountdown)
    }

    func testCancelCountdownRapidRestart() {
        var m = machineInCancelCountdown()
        let oldGen = m.generation

        let effects = m.handle(.startRequested(mode: .persistent))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))
        XCTAssertEqual(m.generation, oldGen + 1)
        XCTAssertTrue(effects.contains(.cancelCancelCountdown))
        XCTAssertTrue(effects.contains(.confirmCancel))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.checkEntitlements))
    }

    func testCancelCountdownDismissRequested() {
        var m = machineInCancelCountdown()

        let effects = m.handle(.dismissRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.confirmCancel))
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testCancelCountdownRePressingEscape() {
        var m = machineInCancelCountdown()

        // Second cancel while in countdown = confirm immediately
        let effects = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.confirmCancel))
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    // MARK: - Finishing

    func testFinishingPasteSucceeded() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))

        let effects = m.handle(.pasteSucceeded(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))
        XCTAssertTrue(effects.contains(.startDisplayDismissTimer(seconds: 0.8)))
    }

    func testFinishingPasteFailed() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))

        let effects = m.handle(.pasteFailed(generation: gen, message: "Copied to clipboard. Press Cmd+V."))
        XCTAssertEqual(m.state, .finishing(outcome: .pasteFailedCopied("Copied to clipboard. Press Cmd+V.")))
        XCTAssertTrue(effects.contains(.showError("Copied to clipboard. Press Cmd+V.")))
        XCTAssertTrue(effects.contains(.startDisplayDismissTimer(seconds: 5)))
    }

    func testFinishingDisplayDismissExpired() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))
        _ = m.handle(.pasteSucceeded(generation: gen))

        let effects = m.handle(.displayDismissExpired(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.reloadHistory))
        XCTAssertTrue(effects.contains(.resetHotkeyStateMachine))
        XCTAssertTrue(effects.contains(.showIdlePill))
    }

    func testFinishingDismissRequested() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))

        let effects = m.handle(.dismissRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.cancelActionTask))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.reloadHistory))
    }

    func testFinishingCancelRequested() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))

        // Escape key during finishing = dismiss
        let effects = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.cancelActionTask))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.reloadHistory))
    }

    func testFinishingNoSpeechDismiss() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionFailedNoSpeech(generation: gen))

        XCTAssertEqual(m.state, .finishing(outcome: .noSpeech))

        let effects = m.handle(.displayDismissExpired(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testFinishingErrorDismiss() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionFailed(generation: gen, message: "Oops"))

        let effects = m.handle(.displayDismissExpired(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testFinishingStaleDisplayDismiss() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))
        _ = m.handle(.pasteSucceeded(generation: gen))

        let effects = m.handle(.displayDismissExpired(generation: gen - 1))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.state, .finishing(outcome: .success))
    }

    func testFinishingReadyPillRequested() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionFailedNoSpeech(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .noSpeech))
        let oldGen = m.generation

        // Hotkey first tap during "no speech" → dismiss and show ready pill
        let effects = m.handle(.readyPillRequested)
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.generation, oldGen + 1)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.reloadHistory))
        XCTAssertTrue(effects.contains(.showReadyPill))
        XCTAssertTrue(effects.contains(.startReadyDismissTimer))
        // Cancel action task to prevent stale paste from prior flow
        XCTAssertTrue(effects.contains(.cancelActionTask))
    }

    func testFinishingStartRequested() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionFailedNoSpeech(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .noSpeech))
        let oldGen = m.generation

        // Hotkey rapid restart during "no speech" → dismiss and start new session
        let effects = m.handle(.startRequested(mode: .persistent))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))
        XCTAssertEqual(m.generation, oldGen + 1)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.reloadHistory))
        XCTAssertTrue(effects.contains(.checkEntitlements))
        XCTAssertTrue(effects.contains(.cancelActionTask))
    }

    func testFinishingSuccessStartRequested() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))
        let oldGen = m.generation

        // Hotkey during success display → cancel stale paste, start new session
        let effects = m.handle(.startRequested(mode: .holdToTalk))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .holdToTalk))
        XCTAssertEqual(m.generation, oldGen + 1)
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.checkEntitlements))
        XCTAssertTrue(effects.contains(.reloadHistory))
        XCTAssertTrue(effects.contains(.cancelActionTask))
    }

    func testFinishingSuccessReadyPillRequested() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))

        let effects = m.handle(.readyPillRequested)
        XCTAssertEqual(m.state, .ready)
        XCTAssertTrue(effects.contains(.showReadyPill))
        XCTAssertTrue(effects.contains(.cancelActionTask))
    }

    func testFinishingErrorStartRequested() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionFailed(generation: gen, message: "Oops"))
        XCTAssertEqual(m.state, .finishing(outcome: .error("Oops")))

        let effects = m.handle(.startRequested(mode: .persistent))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))
        XCTAssertTrue(effects.contains(.checkEntitlements))
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testFinishingSuccessStartRequestedIgnoresStaleCallback() {
        var m = machineInProcessing()
        let gen = m.generation
        _ = m.handle(.transcriptionCompleted(generation: gen))

        // Rapid restart from success — paste is in flight
        _ = m.handle(.startRequested(mode: .persistent))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))

        // Stale paste callback arrives — must be ignored (state mismatch + generation)
        let effects = m.handle(.pasteSucceeded(generation: gen))
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Full Happy Path

    func testHappyPathPersistent() {
        var m = makeMachine()

        // Idle → ready
        _ = m.handle(.readyPillRequested)
        XCTAssertEqual(m.state, .ready)

        // Ready → checkingEntitlements
        _ = m.handle(.startRequested(mode: .persistent))
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))
        let gen = m.generation

        // → startingService
        _ = m.handle(.entitlementsGranted(generation: gen))
        XCTAssertEqual(m.state, .startingService(mode: .persistent))

        // → recording
        _ = m.handle(.recordingStarted(generation: gen))
        XCTAssertEqual(m.state, .recording(mode: .persistent))

        // → processing
        _ = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .processing)

        // → finishing
        _ = m.handle(.transcriptionCompleted(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))

        // → paste succeeded
        _ = m.handle(.pasteSucceeded(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))

        // → idle
        let effects = m.handle(.displayDismissExpired(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.reloadHistory))
    }

    func testHappyPathHoldToTalk() {
        var m = makeMachine()

        _ = m.handle(.startRequested(mode: .holdToTalk))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        _ = m.handle(.recordingStarted(generation: gen))
        XCTAssertEqual(m.state, .recording(mode: .holdToTalk))

        _ = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .processing)
    }

    // MARK: - Cancel Flow

    func testCancelFlowExpired() {
        var m = machineInRecording()
        let gen = m.generation

        _ = m.handle(.cancelRequested(reason: .escape))
        XCTAssertEqual(m.state, .cancelCountdown)

        let effects = m.handle(.cancelCountdownExpired(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.confirmCancel))
    }

    func testCancelFlowUndo() {
        var m = machineInRecording()
        let gen = m.generation

        _ = m.handle(.cancelRequested(reason: .escape))
        _ = m.handle(.undoRequested)
        XCTAssertEqual(m.state, .processing)

        _ = m.handle(.transcriptionCompleted(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))
    }

    func testCancelFlowImmediateConfirm() {
        var m = machineInRecording()

        _ = m.handle(.cancelRequested(reason: .escape))
        _ = m.handle(.cancelConfirmedImmediate)
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - Rapid Restart Flows

    func testRapidRestartFromRecording() {
        var m = machineInRecording()
        let oldGen = m.generation

        _ = m.handle(.startRequested(mode: .persistent))
        XCTAssertNotEqual(m.generation, oldGen)
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .persistent))

        // Old generation events should be rejected
        let effects = m.handle(.recordingStarted(generation: oldGen))
        XCTAssertTrue(effects.isEmpty)
    }

    func testRapidRestartFromRecordingThenEntitlementsDeniedResetsMenuBar() {
        var m = machineInRecording()
        // Menu bar was set to .recording when entering recording state
        _ = m.generation

        // Rapid restart → checkingEntitlements
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation

        // Entitlements denied → must reset menu bar to idle
        let effects = m.handle(.entitlementsDenied(generation: gen))
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.updateMenuBar(.idle)),
                       "Menu bar must reset to idle after rapid restart + entitlement failure")
        XCTAssertTrue(effects.contains(.hideOverlay))
        XCTAssertTrue(effects.contains(.showIdlePill))
    }

    func testRapidRestartFromCancelCountdown() {
        var m = machineInCancelCountdown()
        let oldGen = m.generation

        _ = m.handle(.startRequested(mode: .holdToTalk))
        XCTAssertNotEqual(m.generation, oldGen)
        XCTAssertEqual(m.state, .checkingEntitlements(mode: .holdToTalk))

        // Old cancel countdown should be rejected
        let effects = m.handle(.cancelCountdownExpired(generation: oldGen))
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Generation Stale Rejection

    func testAllAsyncEventsRejectedWithStaleGeneration() {
        var m = machineInRecording()
        let gen = m.generation
        let staleGen = gen - 1

        // Stop → processing first
        _ = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .processing)

        let staleEvents: [DictationFlowEvent] = [
            .transcriptionCompleted(generation: staleGen),
            .transcriptionFailedNoSpeech(generation: staleGen),
            .transcriptionFailed(generation: staleGen, message: "err"),
        ]

        for event in staleEvents {
            let effects = m.handle(event)
            XCTAssertTrue(effects.isEmpty, "Should reject stale \(event)")
            XCTAssertEqual(m.state, .processing)
        }
    }

    // MARK: - Pending Stop Flow

    func testPendingStopFullFlow() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))

        // Stop while starting
        _ = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .pendingStop(mode: .persistent))

        // Recording starts → auto-transitions to processing
        let effects = m.handle(.recordingStarted(generation: gen))
        XCTAssertEqual(m.state, .processing)
        XCTAssertTrue(effects.contains(.stopRecordingAndTranscribe))

        // Complete transcription
        _ = m.handle(.transcriptionCompleted(generation: gen))
        XCTAssertEqual(m.state, .finishing(outcome: .success))
    }

    // MARK: - Edge Cases

    func testDismissFromAnyNonIdleState() {
        let modes: [FnKeyStateMachine.RecordingMode] = [.persistent, .holdToTalk]
        for mode in modes {
            // From checkingEntitlements
            var m1 = makeMachine()
            _ = m1.handle(.startRequested(mode: mode))
            let e1 = m1.handle(.dismissRequested)
            XCTAssertEqual(m1.state, .idle)
            XCTAssertFalse(e1.isEmpty)

            // From startingService
            var m2 = makeMachine()
            _ = m2.handle(.startRequested(mode: mode))
            _ = m2.handle(.entitlementsGranted(generation: m2.generation))
            let e2 = m2.handle(.dismissRequested)
            XCTAssertEqual(m2.state, .idle)
            XCTAssertFalse(e2.isEmpty)

            // From recording
            var m3 = machineInRecording(mode: mode)
            let e3 = m3.handle(.dismissRequested)
            XCTAssertEqual(m3.state, .idle)
            XCTAssertFalse(e3.isEmpty)
        }
    }

    func testStartingServiceDismissRequested() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .persistent))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        XCTAssertEqual(m.state, .startingService(mode: .persistent))

        let effects = m.handle(.dismissRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.cancelAllTimers))
        XCTAssertTrue(effects.contains(.cancelRecordingTask))
        XCTAssertTrue(effects.contains(.cancelRecording(reason: .ui)))
        XCTAssertTrue(effects.contains(.hideOverlay))
    }

    func testModePreservedThroughPendingStop() {
        var m = makeMachine()
        _ = m.handle(.startRequested(mode: .holdToTalk))
        let gen = m.generation
        _ = m.handle(.entitlementsGranted(generation: gen))
        _ = m.handle(.stopRequested)
        XCTAssertEqual(m.state, .pendingStop(mode: .holdToTalk))
    }

    func testReadyToStartPreservesGeneration() {
        var m = makeMachine()
        _ = m.handle(.readyPillRequested)
        let readyGen = m.generation

        _ = m.handle(.startRequested(mode: .persistent))
        XCTAssertEqual(m.generation, readyGen) // seamless — same generation
    }

    func testIdleToStartBumpsGeneration() {
        var m = makeMachine()
        let initialGen = m.generation

        _ = m.handle(.startRequested(mode: .persistent))
        XCTAssertEqual(m.generation, initialGen + 1)
    }
}
