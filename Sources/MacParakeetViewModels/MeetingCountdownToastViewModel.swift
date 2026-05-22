import Foundation

/// Small `@Observable` shared between the toast controller and its SwiftUI
/// view for the calendar-driven **auto-start** countdown. The controller
/// drives `progress` from a 60Hz timer; the view binds to `progress`, `title`,
/// and `calendarContext` and renders the countdown halo.
///
/// Auto-*stop* was removed (ADR-017 amendment, 2026-05): scheduled end times
/// are unreliable, so stopping is left to the user / a future activity-based
/// detector rather than a clock-driven countdown. This view model therefore
/// only ever represents an auto-start countdown.
///
/// Lives in `MacParakeetViewModels` (not in App) so unit tests can construct
/// it without launching AppKit panels.
@MainActor
@Observable
public final class MeetingCountdownToastViewModel {
    /// Optional metadata that upgrades the toast to its richer pre-meeting
    /// variant (ADR-020 §10). When present, the view renders the meeting
    /// service in the status line. Manual-start toasts pass `nil`.
    public struct CalendarContext: Sendable, Equatable {
        public let attendeeCount: Int
        public let serviceName: String?      // "Zoom", "Google Meet", "Teams"…
        public let steeringHint: String      // retained for accessibility / future use

        public init(attendeeCount: Int, serviceName: String?, steeringHint: String) {
            self.attendeeCount = attendeeCount
            self.serviceName = serviceName
            self.steeringHint = steeringHint
        }
    }

    public var title: String
    public var body: String
    /// 0...1 — completion fraction over `duration` seconds.
    public var progress: Double = 0
    public var duration: TimeInterval
    public var calendarContext: CalendarContext?

    public init(
        title: String,
        body: String,
        duration: TimeInterval,
        calendarContext: CalendarContext? = nil
    ) {
        self.title = title
        self.body = body
        self.duration = duration
        self.calendarContext = calendarContext
    }

    /// Compact attendees + service summary for the rich context line.
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
