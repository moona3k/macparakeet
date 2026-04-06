import SwiftUI

@MainActor @Observable
public final class MeetingRecordingPillViewModel {
    public enum PillState: Equatable {
        case idle
        case recording
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
    public var onCompletionAnimationFinished: (() -> Void)?

    public init() {}

    public var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
