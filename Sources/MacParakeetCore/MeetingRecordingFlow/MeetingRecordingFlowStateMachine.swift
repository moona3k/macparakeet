import Foundation

public enum MeetingRecordingPermissionFailure: Equatable, Sendable {
    case microphone
    case screenRecording
}

public enum MeetingRecordingFlowState: Equatable, Sendable {
    case idle
    case checkingPermissions
    case starting
    case recording
    case stopping
    case transcribing
    case finishing(outcome: MeetingRecordingFlowFinishOutcome)
}

public enum MeetingRecordingFlowFinishOutcome: Equatable, Sendable {
    case completed(UUID)
    case error(String)
}

public enum MeetingRecordingFlowEvent: Equatable, Sendable {
    case startRequested
    case permissionsGranted(generation: Int)
    case permissionsDenied(generation: Int, reason: MeetingRecordingPermissionFailure)
    case recordingStarted(generation: Int)
    case startFailed(generation: Int, message: String)
    case stopRequested
    case cancelRequested
    /// Emitted by the pill polling task when it detects that audio capture
    /// has stopped unexpectedly while the state machine still believes a
    /// recording is in progress (e.g., a USB mic was unplugged mid-meeting,
    /// `MeetingRecordingService.failCapture` ran). Routes through the same
    /// stop+transcribe path as `.stopRequested` so whatever audio was
    /// captured before the failure still becomes a saved Transcription.
    case captureFailed(generation: Int)
    /// User-confirmed abort of the in-flight final transcription (issue #487).
    /// `keepAudio: true` leaves the session folder + recovery lock intact so
    /// the recording stays retryable from Library / launch recovery;
    /// `keepAudio: false` deletes the recording entirely.
    case abortTranscriptionRequested(keepAudio: Bool)
    case recordingQueued(generation: Int, transcriptionID: UUID)
    case transcriptionCompleted(generation: Int, transcriptionID: UUID)
    case transcriptionFailed(generation: Int, message: String)
    case dismissRequested
    case autoDismissExpired(generation: Int)
}

public enum MeetingRecordingFlowEffect: Equatable, Sendable {
    case checkPermissions
    case showRecordingPill
    case startRecording
    case showTranscribingState
    case stopRecordingAndTranscribe
    case showCompleted
    case showError(String)
    case cancelRecording
    /// Cancel the in-flight stop+transcribe task. The handler must wait for
    /// the cancelled task to drain, then — when `keepAudio` is false — delete
    /// the session's transcription rows and recording folder.
    case abortTranscription(keepAudio: Bool)
    case hidePill
    case updateMenuBar(DictationFlowMenuBarState)
    case navigateToTranscription(UUID)
    case presentPermissionAlert(MeetingRecordingPermissionFailure)
    case startAutoDismissTimer(seconds: Double)
    case cancelAutoDismissTimer
}

public struct MeetingRecordingFlowStateMachine: Equatable, Sendable {
    public private(set) var state: MeetingRecordingFlowState = .idle
    public private(set) var generation: Int = 0

    public init() {}

    public mutating func handle(_ event: MeetingRecordingFlowEvent) -> [MeetingRecordingFlowEffect] {
        switch (state, event) {
        case (.idle, .startRequested):
            generation += 1
            state = .checkingPermissions
            return [.checkPermissions]

        case (.checkingPermissions, .permissionsGranted(let gen)):
            guard gen == generation else { return [] }
            state = .starting
            return [.showRecordingPill, .startRecording, .updateMenuBar(.recording)]

        case (.checkingPermissions, .permissionsDenied(let gen, let reason)):
            guard gen == generation else { return [] }
            state = .idle
            return [.updateMenuBar(.idle), .presentPermissionAlert(reason)]

        case (.checkingPermissions, .cancelRequested):
            state = .idle
            return [.cancelRecording, .hidePill, .updateMenuBar(.idle)]

        case (.starting, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .recording
            return []

        case (.starting, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.starting, .stopRequested):
            state = .stopping
            return []

        case (.stopping, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .stopping
            return [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]

        case (.stopping, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.stopping, .recordingQueued(let gen, _)):
            guard gen == generation else { return [] }
            state = .idle
            return [.hidePill, .updateMenuBar(.idle)]

        case (.stopping, .transcriptionFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.recording, .cancelRequested):
            state = .idle
            return [.cancelRecording, .hidePill, .updateMenuBar(.idle)]

        case (.starting, .cancelRequested):
            state = .idle
            return [.cancelRecording, .hidePill, .updateMenuBar(.idle)]

        case (.recording, .stopRequested):
            state = .stopping
            return [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]

        case (.recording, .captureFailed(let gen)):
            guard gen == generation else { return [] }
            state = .stopping
            return [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]

        case (.transcribing, .abortTranscriptionRequested(let keepAudio)):
            state = .idle
            return [.abortTranscription(keepAudio: keepAudio), .hidePill, .updateMenuBar(.idle)]

        case (.transcribing, .transcriptionCompleted(let gen, let transcriptionID)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .completed(transcriptionID))
            return [
                .showCompleted,
                .updateMenuBar(.idle),
                .navigateToTranscription(transcriptionID),
                .startAutoDismissTimer(seconds: 1),
            ]

        case (.transcribing, .transcriptionFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.finishing, .dismissRequested):
            state = .idle
            return [.cancelAutoDismissTimer, .hidePill]

        case (.finishing, .autoDismissExpired(let gen)):
            guard gen == generation else { return [] }
            state = .idle
            return [.hidePill]

        case (.recording, .dismissRequested),
             (.starting, .dismissRequested),
             (.stopping, .dismissRequested),
             (.transcribing, .dismissRequested),
             (.checkingPermissions, .dismissRequested):
            return []

        default:
            return []
        }
    }
}
