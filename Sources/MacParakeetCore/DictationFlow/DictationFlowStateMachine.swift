import Foundation

// MARK: - State

/// The states of the dictation UI flow.
///
/// This state machine models the full lifecycle of a single dictation session,
/// from idle through recording to result display. It is a pure value type with
/// no side effects — the coordinator executes effects returned by `handle(_:)`.
public enum DictationFlowState: Equatable, Sendable {
    /// No dictation activity. Idle pill may be showing.
    case idle
    /// Ready pill visible, waiting for second tap. Auto-dismisses after timeout.
    case ready
    /// Entitlements check in flight. No overlay visible yet.
    case checkingEntitlements(mode: FnKeyStateMachine.RecordingMode)
    /// DictationService.startRecording() in flight. Overlay is visible, showing recording UI.
    case startingService(mode: FnKeyStateMachine.RecordingMode)
    /// Actively recording. Audio level loop running.
    case recording(mode: FnKeyStateMachine.RecordingMode)
    /// Stop requested while startRecording still in flight. Will auto-stop once recording begins.
    case pendingStop(mode: FnKeyStateMachine.RecordingMode)
    /// Stop called, transcription in progress.
    case processing
    /// Cancel countdown running (5 seconds). User can undo or confirm.
    case cancelCountdown
    /// Terminal display state before returning to idle.
    case finishing(outcome: DictationFlowFinishOutcome)
}

// MARK: - Finish Outcome

public enum DictationFlowFinishOutcome: Equatable, Sendable {
    /// Transcription succeeded, paste dispatched, awaiting paste result.
    case success
    /// Paste failed after successful transcription — text copied to clipboard.
    case pasteFailedCopied(String)
    /// No speech detected.
    case noSpeech
    /// An error occurred (start failed, transcription failed, stop rejected).
    case error(String)
}

// MARK: - Events

/// Cancel reason for telemetry and hotkey state machine sync.
public enum DictationFlowCancelReason: Equatable, Sendable {
    case escape
    case ui
}

/// Events that drive state transitions.
public enum DictationFlowEvent: Equatable, Sendable {
    // User triggers
    case readyPillRequested
    case readyPillTimedOut(generation: Int)
    case startRequested(mode: FnKeyStateMachine.RecordingMode)
    case stopRequested
    case cancelRequested(reason: DictationFlowCancelReason)
    case undoRequested
    case dismissRequested

    // Async completions (carry generation for stale rejection)
    case entitlementsGranted(generation: Int)
    case entitlementsDenied(generation: Int)
    case recordingStarted(generation: Int)
    case startFailed(generation: Int, message: String)
    case transcriptionCompleted(generation: Int)
    case transcriptionFailedNoSpeech(generation: Int)
    case transcriptionFailed(generation: Int, message: String)
    case pasteSucceeded(generation: Int)
    case pasteFailed(generation: Int, message: String)

    // Timers (carry generation for stale rejection)
    case cancelCountdownExpired(generation: Int)
    case cancelConfirmedImmediate
    case displayDismissExpired(generation: Int)
}

// MARK: - Effects

/// Menu bar icon state.
public enum DictationFlowMenuBarState: Equatable, Sendable {
    case idle
    case recording
    case processing
}

/// Side effects returned by the state machine for the coordinator to execute.
public enum DictationFlowEffect: Equatable, Sendable {
    // Overlay lifecycle
    case showReadyPill
    case rescheduleReadyDismissTimer
    case showRecordingOverlay(mode: FnKeyStateMachine.RecordingMode)
    case showProcessingState
    case showCancelCountdown
    case showSuccess
    case showNoSpeech
    case showError(String)
    case hideOverlay
    case dismissReadyPill

    // Idle pill
    case showIdlePill
    case hideIdlePill

    // Audio/service
    case checkEntitlements
    case startRecording(mode: FnKeyStateMachine.RecordingMode)
    case stopRecordingAndTranscribe
    case cancelRecording(reason: DictationFlowCancelReason)
    case confirmCancel
    case undoCancelAndTranscribe

    // Paste
    case resignKeyWindow
    case pasteTranscript

    // History
    case reloadHistory

    // App integration
    case updateMenuBar(DictationFlowMenuBarState)
    case resetHotkeyStateMachine
    case notifyHotkeyCancelledByUI
    case presentEntitlementsAlert

    // Timer management
    case startReadyDismissTimer
    case cancelReadyDismissTimer
    case startCancelCountdown
    case cancelCancelCountdown
    case startDisplayDismissTimer(seconds: Double)
    case cancelAllTimers

    // Task management
    case cancelRecordingTask
    case cancelActionTask
}

// MARK: - State Machine

/// Pure, deterministic state machine for the dictation UI flow.
///
/// All transition logic lives here. The coordinator calls `handle(_:)` and
/// executes the returned effects. No async, no AppKit, no side effects.
public struct DictationFlowStateMachine: Sendable, Equatable {
    public private(set) var state: DictationFlowState = .idle
    public private(set) var generation: Int = 0

    public init() {}

    /// Process an event and return the effects to execute.
    /// The state is mutated in-place. Returns an empty array if the event
    /// is invalid for the current state or has a stale generation.
    public mutating func handle(_ event: DictationFlowEvent) -> [DictationFlowEffect] {
        switch (state, event) {

        // MARK: Idle

        case (.idle, .readyPillRequested):
            generation += 1
            state = .ready
            return [.hideIdlePill, .showReadyPill, .startReadyDismissTimer]

        case (.idle, .startRequested(let mode)):
            generation += 1
            state = .checkingEntitlements(mode: mode)
            return [.hideIdlePill, .checkEntitlements]

        // MARK: Ready pill

        case (.ready, .readyPillRequested):
            // Self-transition: reuse overlay, reschedule dismiss timer
            return [.rescheduleReadyDismissTimer]

        case (.ready, .readyPillTimedOut(let gen)):
            guard gen == generation else { return [] }
            state = .idle
            return [.dismissReadyPill, .showIdlePill]

        case (.ready, .startRequested(let mode)):
            // Transition from ready to starting — keep same generation (seamless)
            state = .checkingEntitlements(mode: mode)
            return [.cancelReadyDismissTimer, .checkEntitlements]

        case (.ready, .cancelRequested):
            state = .idle
            return [.cancelReadyDismissTimer, .dismissReadyPill, .resetHotkeyStateMachine, .showIdlePill]

        case (.ready, .dismissRequested):
            state = .idle
            return [.cancelReadyDismissTimer, .dismissReadyPill, .resetHotkeyStateMachine, .showIdlePill]

        // MARK: Checking entitlements

        case (.checkingEntitlements(let mode), .entitlementsGranted(let gen)):
            guard gen == generation else { return [] }
            state = .startingService(mode: mode)
            return [.showRecordingOverlay(mode: mode), .startRecording(mode: mode), .updateMenuBar(.recording)]

        case (.checkingEntitlements, .entitlementsDenied(let gen)):
            guard gen == generation else { return [] }
            state = .idle
            return [.hideOverlay, .resetHotkeyStateMachine, .updateMenuBar(.idle), .presentEntitlementsAlert, .showIdlePill]

        case (.checkingEntitlements, .cancelRequested):
            state = .idle
            return [.cancelRecordingTask, .hideOverlay, .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill]

        case (.checkingEntitlements, .stopRequested):
            state = .idle
            return [.cancelRecordingTask, .hideOverlay, .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill]

        case (.checkingEntitlements, .dismissRequested):
            state = .idle
            return [.cancelAllTimers, .cancelRecordingTask, .hideOverlay, .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill]

        // MARK: Starting service

        case (.startingService(let mode), .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .recording(mode: mode)
            return []

        case (.startingService, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .resetHotkeyStateMachine, .updateMenuBar(.idle), .startDisplayDismissTimer(seconds: 5)]

        case (.startingService(let mode), .stopRequested):
            state = .pendingStop(mode: mode)
            return []

        case (.startingService, .cancelRequested(let reason)):
            state = .idle
            return [
                .cancelRecordingTask, .cancelRecording(reason: reason),
                .hideOverlay, .resetHotkeyStateMachine,
                .updateMenuBar(.idle), .showIdlePill,
            ]

        case (.startingService, .dismissRequested):
            state = .idle
            return [
                .cancelAllTimers, .cancelRecordingTask, .cancelRecording(reason: .ui),
                .hideOverlay, .resetHotkeyStateMachine,
                .updateMenuBar(.idle), .showIdlePill,
            ]

        // MARK: Recording

        case (.recording, .stopRequested):
            state = .processing
            return [
                .cancelRecordingTask, .stopRecordingAndTranscribe,
                .showProcessingState, .updateMenuBar(.processing),
            ]

        case (.recording, .cancelRequested(let reason)):
            state = .cancelCountdown
            return [
                .cancelRecordingTask, .cancelRecording(reason: reason),
                .showCancelCountdown, .updateMenuBar(.idle), .startCancelCountdown,
                .notifyHotkeyCancelledByUI,
            ]

        case (.recording, .startRequested(let mode)):
            // Rapid restart: tear down current recording, start new flow
            generation += 1
            state = .checkingEntitlements(mode: mode)
            return [
                .cancelAllTimers, .cancelRecordingTask, .cancelRecording(reason: .ui),
                .hideOverlay, .hideIdlePill, .checkEntitlements,
            ]

        case (.recording, .dismissRequested):
            state = .idle
            return [
                .cancelAllTimers, .cancelRecordingTask, .cancelRecording(reason: .ui),
                .hideOverlay, .resetHotkeyStateMachine,
                .updateMenuBar(.idle), .showIdlePill,
            ]

        // MARK: Pending stop

        case (.pendingStop, .startRequested(let mode)):
            generation += 1
            state = .checkingEntitlements(mode: mode)
            return [
                .cancelAllTimers, .cancelRecordingTask, .cancelRecording(reason: .ui),
                .hideOverlay, .hideIdlePill, .checkEntitlements,
            ]

        case (.pendingStop, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .processing
            return [.cancelRecordingTask, .stopRecordingAndTranscribe, .showProcessingState, .updateMenuBar(.processing)]

        case (.pendingStop, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .resetHotkeyStateMachine, .updateMenuBar(.idle), .startDisplayDismissTimer(seconds: 5)]

        case (.pendingStop, .cancelRequested(let reason)):
            state = .idle
            return [
                .cancelRecordingTask, .cancelRecording(reason: reason),
                .hideOverlay, .resetHotkeyStateMachine,
                .updateMenuBar(.idle), .showIdlePill,
            ]

        case (.pendingStop, .dismissRequested):
            state = .idle
            return [
                .cancelAllTimers, .cancelRecordingTask, .cancelRecording(reason: .ui),
                .hideOverlay, .resetHotkeyStateMachine,
                .updateMenuBar(.idle), .showIdlePill,
            ]

        // MARK: Processing

        case (.processing, .startRequested(let mode)):
            generation += 1
            state = .checkingEntitlements(mode: mode)
            return [
                .cancelAllTimers, .cancelActionTask,
                .hideOverlay, .hideIdlePill, .checkEntitlements,
            ]

        case (.processing, .transcriptionCompleted(let gen)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .success)
            return [.showSuccess, .updateMenuBar(.idle), .resignKeyWindow, .pasteTranscript]

        case (.processing, .transcriptionFailedNoSpeech(let gen)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .noSpeech)
            return [.showNoSpeech, .updateMenuBar(.idle), .startDisplayDismissTimer(seconds: 3)]

        case (.processing, .transcriptionFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startDisplayDismissTimer(seconds: 5)]

        case (.processing, .cancelRequested), (.processing, .dismissRequested):
            state = .idle
            return [
                .cancelAllTimers, .cancelActionTask,
                .hideOverlay, .resetHotkeyStateMachine,
                .updateMenuBar(.idle), .showIdlePill,
            ]

        // MARK: Cancel countdown

        case (.cancelCountdown, .undoRequested):
            state = .processing
            return [
                .cancelCancelCountdown, .cancelActionTask,
                .undoCancelAndTranscribe, .showProcessingState,
                .updateMenuBar(.processing), .resetHotkeyStateMachine,
            ]

        case (.cancelCountdown, .cancelConfirmedImmediate):
            state = .idle
            return [
                .cancelCancelCountdown, .cancelActionTask,
                .confirmCancel, .hideOverlay,
                .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill,
            ]

        case (.cancelCountdown, .cancelCountdownExpired(let gen)):
            guard gen == generation else { return [] }
            state = .idle
            return [
                .confirmCancel, .hideOverlay,
                .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill,
            ]

        case (.cancelCountdown, .startRequested(let mode)):
            // Rapid restart from cancel countdown
            generation += 1
            state = .checkingEntitlements(mode: mode)
            return [
                .cancelCancelCountdown, .cancelActionTask,
                .confirmCancel, .hideOverlay,
                .hideIdlePill, .checkEntitlements, .resetHotkeyStateMachine,
            ]

        case (.cancelCountdown, .dismissRequested):
            state = .idle
            return [
                .cancelAllTimers, .cancelActionTask,
                .confirmCancel, .hideOverlay,
                .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill,
            ]

        // Re-pressing Esc while in cancel countdown = confirm immediately
        case (.cancelCountdown, .cancelRequested):
            state = .idle
            return [
                .cancelCancelCountdown, .cancelActionTask,
                .confirmCancel, .hideOverlay,
                .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill,
            ]

        // MARK: Finishing

        case (.finishing(.success), .pasteSucceeded(let gen)):
            guard gen == generation else { return [] }
            // Stay in finishing(.success), start dismiss timer
            return [.startDisplayDismissTimer(seconds: 0.8)]

        case (.finishing(.success), .pasteFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .pasteFailedCopied(message))
            return [.showError(message), .startDisplayDismissTimer(seconds: 5)]

        case (.finishing, .displayDismissExpired(let gen)):
            guard gen == generation else { return [] }
            state = .idle
            return [
                .cancelActionTask, .hideOverlay, .reloadHistory,
                .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill,
            ]

        case (.finishing, .readyPillRequested):
            generation += 1
            state = .ready
            return [
                .cancelAllTimers, .cancelActionTask,
                .hideOverlay, .reloadHistory,
                .hideIdlePill, .showReadyPill, .startReadyDismissTimer,
            ]

        case (.finishing, .startRequested(let mode)):
            generation += 1
            state = .checkingEntitlements(mode: mode)
            return [
                .cancelAllTimers, .cancelActionTask,
                .hideOverlay, .reloadHistory,
                .hideIdlePill, .checkEntitlements,
            ]

        case (.finishing, .cancelRequested), (.finishing, .dismissRequested):
            state = .idle
            return [
                .cancelAllTimers, .cancelActionTask, .hideOverlay, .reloadHistory,
                .resetHotkeyStateMachine, .updateMenuBar(.idle), .showIdlePill,
            ]

        // MARK: Default — ignore invalid events

        default:
            return []
        }
    }
}
