import SwiftUI

@MainActor @Observable
public final class MeetingRecordingPillViewModel {
    public enum PillState: Equatable {
        case idle
        case recording
        /// User has paused capture (issue #235). Distinct from `.recording`
        /// so the pill rosette stops animating, the menu/tile show "Resume",
        /// and audio levels render as silent. Stop / discard remain available.
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
    public var onStop: (() -> Void)?
    /// Toggles between pause and resume based on the current `state`. Wired
    /// by `MeetingRecordingFlowCoordinator`; the pill, panel, and Transcribe
    /// tile all share this VM so they all drive the same toggle.
    public var onPauseToggle: (() -> Void)?
    public var onCompletionAnimationFinished: (() -> Void)?

    public init() {}

    public var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// True while the pill is in a state where the user can toggle pause /
    /// resume. Used by the floating pill, the meeting panel header, and the
    /// Transcribe-tab tile to gate the Pause/Resume button.
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
