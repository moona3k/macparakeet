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

/// User-selectable subtitle authoring presets. Maps 1:1 to `SubtitleExportConfig`
/// constants. Selecting `.standard` keeps the default cue-shaping behavior; the
/// other cases switch to the corresponding industry style guide.
public enum SubtitlePreset: String, CaseIterable, Sendable {
    case standard
    case netflix
    case bbc
    case youtube

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .netflix: "Netflix"
        case .bbc: "BBC"
        case .youtube: "YouTube"
        }
    }

    public var subtitleDescription: String {
        switch self {
        case .standard: "Balanced defaults — 42 chars, 25 CPS"
        case .netflix: "Netflix style guide — 17 CPS, 833ms minimum"
        case .bbc: "BBC guidelines — 37 chars, 17 CPS, 1s minimum"
        case .youtube: "Looser pacing, no minimum duration"
        }
    }

    public var config: SubtitleExportConfig {
        switch self {
        case .standard: return .default
        case .netflix: return .netflix
        case .bbc: return .bbc
        case .youtube: return .youtube
        }
    }
}

public enum SubtitleExportPreferences {
    public static let presetKey = "SubtitleExport.preset"

    public static func selectedPreset(defaults: UserDefaults = .standard) -> SubtitlePreset {
        guard let raw = defaults.string(forKey: presetKey),
              let preset = SubtitlePreset(rawValue: raw)
        else { return .standard }
        return preset
    }

    public static func setSelectedPreset(_ preset: SubtitlePreset, defaults: UserDefaults = .standard) {
        defaults.set(preset.rawValue, forKey: presetKey)
    }
}
