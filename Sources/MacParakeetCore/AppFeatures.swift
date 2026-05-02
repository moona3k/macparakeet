import Foundation

/// Compile-time feature gates. Flip a single literal to expose or hide a feature
/// without touching every call site. Release builds should set these to the
/// shipping configuration before tagging a version.
public enum AppFeatures {
    /// Meeting Recording (ADR-014). When `false`, all meeting recording entry
    /// points are hidden: sidebar item, menu-bar "Record Meeting", global meeting
    /// hotkey, settings card, library filter, onboarding step, and the screen
    /// recording permission row. Data model, services, and tests remain intact.
    public static let meetingRecordingEnabled: Bool = true

    /// Calendar auto-start (ADR-017). When `false`, all calendar entry points
    /// are hidden: onboarding calendar step, Settings calendar subsection,
    /// search-index calendar entry, and the auto-start coordinator never starts
    /// polling. CalendarService, MeetingAutoStartCoordinator, models, and tests
    /// remain intact — only the surfaces that would invoke them are gated.
    /// Hidden in v0.6 pending hands-on E2E validation; flip to `true` in a
    /// point release once the auto-start flow has been exercised against real
    /// calendars.
    public static let calendarEnabled: Bool = false
}
