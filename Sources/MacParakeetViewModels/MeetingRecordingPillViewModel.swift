import MacParakeetCore
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
    public var captureHealth: MeetingCaptureHealthSummary = .notRecording
    public var backgroundTranscriptionCount: Int = 0
    public var onStop: (() -> Void)?
    public var onPauseToggle: (() -> Void)?
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

    public var mirroredSourceHealthWarning: MeetingSourceHealthChip? {
        switch state {
        case .recording, .paused:
            return MeetingSourceHealthChip.primaryDegraded(for: captureHealth)
        case .idle, .completing, .transcribing, .completed, .error:
            return nil
        }
    }
}
