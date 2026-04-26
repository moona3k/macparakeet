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

    /// Optional metadata that upgrades the auto-start toast to its richer
    /// pre-meeting variant (ADR-020 §10). When present, the view renders an
    /// extra row with attendee count + meeting service icon, and a steering
    /// hint pointing the user at the Notes tab. Manual-start toasts pass
    /// `nil` here and get the existing minimal layout.
    public struct CalendarContext: Sendable, Equatable {
        public let attendeeCount: Int
        public let serviceName: String?      // "Zoom", "Google Meet", "Teams"…
        public let steeringHint: String      // "Take notes to shape the summary. ⌘1 = Notes"

        public init(attendeeCount: Int, serviceName: String?, steeringHint: String) {
            self.attendeeCount = attendeeCount
            self.serviceName = serviceName
            self.steeringHint = steeringHint
        }
    }

    public var style: Style
    public var title: String
    public var body: String
    /// 0...1 — completion fraction over `duration` seconds.
    public var progress: Double = 0
    public var duration: TimeInterval
    public var calendarContext: CalendarContext?

    public init(
        style: Style,
        title: String,
        body: String,
        duration: TimeInterval,
        calendarContext: CalendarContext? = nil
    ) {
        self.style = style
        self.title = title
        self.body = body
        self.duration = duration
        self.calendarContext = calendarContext
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

    /// Compact attendees + service summary for the rich context row.
    /// `nil` when there's no calendar context to show. ADR-020 §10.
    public var contextSummary: String? {
        guard let ctx = calendarContext else { return nil }
        var parts: [String] = []
        if ctx.attendeeCount > 0 {
            parts.append("\(ctx.attendeeCount) \(ctx.attendeeCount == 1 ? "attendee" : "attendees")")
        }
        if let service = ctx.serviceName {
            parts.append(service)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
