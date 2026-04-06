import Foundation
import SwiftUI

@MainActor @Observable
public final class MeetingRecordingPanelViewModel {
    public enum PanelState: Equatable {
        case hidden
        case recording
        case transcribing
        case error(String)
    }

    public var state: PanelState = .hidden
    public var elapsedSeconds: Int = 0
    public var micLevel: Float = 0
    public var systemLevel: Float = 0
    public var previewLines: [MeetingRecordingPreviewLine] = []
    public var isTranscriptionLagging: Bool = false
    public var onStop: (() -> Void)?
    public var onClose: (() -> Void)?

    public init() {}

    public func updatePreviewLines(
        _ lines: [MeetingRecordingPreviewLine],
        isTranscriptionLagging: Bool = false
    ) {
        previewLines = lines
        self.isTranscriptionLagging = isTranscriptionLagging
    }

    public func reset() {
        state = .hidden
        elapsedSeconds = 0
        micLevel = 0
        systemLevel = 0
        previewLines = []
        isTranscriptionLagging = false
    }

    public var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public var canStop: Bool {
        if case .recording = state {
            return true
        }
        return false
    }

    public var statusTitle: String {
        switch state {
        case .hidden, .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .error:
            return "Recording Error"
        }
    }

    public var statusMessage: String {
        switch state {
        case .hidden, .recording:
            if isTranscriptionLagging {
                return "Live transcript preview is catching up. The final transcript will still include the full meeting."
            }
            return "Live transcript preview updates while the flower pill stays pinned."
        case .transcribing:
            return "Meeting audio is being transcribed and saved to your library."
        case .error(let message):
            return message
        }
    }

    public var showsLaggingIndicator: Bool {
        if case .recording = state {
            return isTranscriptionLagging
        }
        return false
    }

    public var showsElapsedTime: Bool {
        if case .error = state {
            return false
        }
        return true
    }

    public var showsAudioLevels: Bool {
        if case .recording = state {
            return true
        }
        return false
    }
}
