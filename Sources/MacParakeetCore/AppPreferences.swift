import Foundation

public enum AppPreferences {
    public static let appearanceModeKey = "appearanceMode"
    public static let menuBarOnlyModeKey = "menuBarOnlyMode"
    public static let telemetryEnabledKey = "telemetryEnabled"

    public static func appearanceMode(defaults: UserDefaults = .standard) -> AppAppearanceMode {
        AppAppearanceMode.current(defaults: defaults)
    }

    public static func isMenuBarOnlyModeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: menuBarOnlyModeKey) as? Bool ?? false
    }

    public static func isTelemetryEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: telemetryEnabledKey) as? Bool ?? true
    }
}

public enum AppAppearanceMode: String, CaseIterable, Hashable, Sendable {
    case system
    case light
    case dark

    public var displayTitle: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    public var detail: String {
        switch self {
        case .system:
            return "Follow your macOS appearance."
        case .light:
            return "Keep MacParakeet in light mode."
        case .dark:
            return "Keep MacParakeet in dark mode."
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> AppAppearanceMode {
        guard let raw = defaults.string(forKey: AppPreferences.appearanceModeKey),
              let mode = AppAppearanceMode(rawValue: raw) else {
            return .system
        }
        return mode
    }
}

/// Calendar-driven meeting auto-start preferences (ADR-017). Namespaced under
/// `CalendarAutoStart.*` so we can grep them as a group and wipe them in tests
/// without disturbing other preferences.
public enum CalendarAutoStartPreferences {
    public static let modeKey = "CalendarAutoStart.mode"
    public static let reminderMinutesKey = "CalendarAutoStart.reminderMinutes"
    public static let triggerFilterKey = "CalendarAutoStart.triggerFilter"
    /// Set of `EKCalendar.calendarIdentifier` strings the user has *deselected*.
    /// Stored as the inverse so a fresh install / new calendar account is
    /// included by default — users opt out, not in.
    public static let excludedCalendarIdsKey = "CalendarAutoStart.excludedCalendarIds"

    public static let defaultReminderMinutes = 5
}
