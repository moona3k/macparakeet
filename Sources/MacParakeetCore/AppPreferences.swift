import Foundation

public enum AppPreferences {
    public static let menuBarOnlyModeKey = "menuBarOnlyMode"
    public static let telemetryEnabledKey = "telemetryEnabled"
    public static func isMenuBarOnlyModeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: menuBarOnlyModeKey) as? Bool ?? false
    }

    public static func isTelemetryEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: telemetryEnabledKey) as? Bool ?? true
    }
}

/// Calendar-driven meeting auto-start preferences (ADR-017). Namespaced under
/// `CalendarAutoStart.*` so we can grep them as a group and wipe them in tests
/// without disturbing other preferences.
public enum CalendarAutoStartPreferences {
    public static let modeKey = "CalendarAutoStart.mode"
    public static let reminderMinutesKey = "CalendarAutoStart.reminderMinutes"
    public static let triggerFilterKey = "CalendarAutoStart.triggerFilter"
    public static let autoStopEnabledKey = "CalendarAutoStart.autoStopEnabled"
    /// Set of `EKCalendar.calendarIdentifier` strings the user has *deselected*.
    /// Stored as the inverse so a fresh install / new calendar account is
    /// included by default — users opt out, not in.
    public static let excludedCalendarIdsKey = "CalendarAutoStart.excludedCalendarIds"

    public static let defaultReminderMinutes = 5
}
