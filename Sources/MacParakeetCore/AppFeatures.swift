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
}
