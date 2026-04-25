import Foundation

/// Small `@Observable` shared between the toast controller and its SwiftUI
/// view. The controller drives `progress` from a 60Hz timer; the view binds
/// to `progress`, `title`, `body`, and the action labels and renders.
///
/// Lives in `MacParakeetViewModels` (not in App) so unit tests can construct
/// it without launching AppKit panels.
@MainActor
@Observable
public final class MeetingCountdownToastViewModel {
    public enum Style: Sendable, Equatable {
        /// Pre-meeting countdown — default action is "start recording now",
        /// cancel = "don't auto-start this one."
        case autoStart
        /// End-of-meeting countdown — default action is "stop recording",
        /// cancel = "keep recording."
        case autoStop
    }

    public var style: Style
    public var title: String
    public var body: String
    /// 0...1 — completion fraction over `duration` seconds.
    public var progress: Double = 0
    public var duration: TimeInterval

    public init(style: Style, title: String, body: String, duration: TimeInterval) {
        self.style = style
        self.title = title
        self.body = body
        self.duration = duration
    }

    public var primaryActionLabel: String {
        switch style {
        case .autoStart: return "Cancel"
        case .autoStop: return "Keep Recording"
        }
    }

    public var secondaryActionLabel: String? {
        switch style {
        case .autoStart: return "Start Now"
        case .autoStop: return nil
        }
    }
}
