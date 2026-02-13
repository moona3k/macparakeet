import Foundation

public enum AppPreferences {
    public static let menuBarOnlyModeKey = "menuBarOnlyMode"

    public static func isMenuBarOnlyModeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: menuBarOnlyModeKey) as? Bool ?? false
    }
}
