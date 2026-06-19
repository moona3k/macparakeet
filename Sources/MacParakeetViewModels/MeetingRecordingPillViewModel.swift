import SwiftUI

@MainActor @Observable
public final class MeetingRecordingPillViewModel {
    public enum PillState: Equatable {
        case idle
        case recording
        /// Capture intentionally paused. The pill rosette dims and freezes;
        /// stop / discard remain available.
        case paused
        case completing
        case transcribing
        case completed
        case error(String)
    }

    public var state: PillState = .idle
    public var elapsedSeconds: Int = 0
    public var micLevel: Float = 0
    public var systemLevel: Float = 0
    public var backgroundTranscriptionCount: Int = 0
    /// True once the stop+transcribe flow has a finalized recording on disk,
    /// i.e. the in-flight final transcription can be safely aborted (issue
    /// #487). Gates the tile's Stop button and the pill menu item so neither
    /// fires while the recording is still being finalized.
    public var canAbortTranscription: Bool = false
    public var onStop: (() -> Void)?
    public var onPauseToggle: (() -> Void)?
    /// Opens the stop-transcription confirmation (Keep Audio / Delete
    /// Recording). Bound by the flow coordinator while a meeting flow is
    /// active; shared by the Transcribe-tab tile and the floating pill menu.
    public var onAbortTranscription: (() -> Void)?
    public var onCompletionAnimationFinished: (() -> Void)?

    public init() {}

    public var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public var canTogglePause: Bool {
        switch state {
        case .recording, .paused:
            return true
        case .idle, .completing, .transcribing, .completed, .error:
            return false
        }
    }

    public var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }
}
