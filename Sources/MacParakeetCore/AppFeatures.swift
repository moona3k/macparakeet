import Foundation

/// Compile-time feature gates. Flip a single literal to expose or hide a feature
/// without touching every call site. Release builds should set these to the
/// shipping configuration before tagging a version.
public enum AppFeatures {
    /// Meeting Recording (ADR-014). When `false`, all meeting recording entry
    /// points are hidden: Transcribe tile, menu-bar "Start Recording", global
    /// meeting hotkey, settings card, library filter, onboarding step, and the
    /// screen recording permission row. Data model, services, and tests remain
    /// intact.
    public static let meetingRecordingEnabled: Bool = true

    /// Calendar auto-start (ADR-017). When `false`, all calendar entry points
    /// are hidden: onboarding calendar step, Settings calendar subsection,
    /// search-index calendar entry, and the auto-start coordinator never starts
    /// polling. CalendarService, MeetingAutoStartCoordinator, models, and tests
    /// remain intact — only the surfaces that would invoke them are gated.
    /// Enabled after the post-#318 reliability hardening (ADR-017 Phases 1+2):
    /// generation-bound auto-stop, mid-flight teardown, RSVP/zero-duration
    /// guards, reschedule re-fire, and forgiveness-window polling. Auto-start
    /// defaults to mode `.off`, so upgraders opt in explicitly via onboarding
    /// or Settings; nothing changes for existing users until they do.
    public static let calendarEnabled: Bool = true

    /// Transforms spike (docs/research/transforms-design-2026-05.md, Phase 1
    /// AX-coverage spike). When `true`, installs the spike's hardcoded
    /// Opt+Ctrl+1 path alongside the productized registry — kept only as
    /// a development-only escape hatch. The spike's Polish prompt is now
    /// also a built-in `.transform` row, so any release build should
    /// leave this `false` and rely on `transformsEnabled` instead.
    public static let transformsSpikeEnabled: Bool = false

    /// Transforms — productized Phase 2 (ADR-022). When `true`:
    /// - the Transforms tab appears in the main sidebar
    /// - `TransformsHotkeyRegistry` installs its event tap on launch
    /// - the user's bound `.transform` prompts dispatch on hotkey press
    ///
    /// When `false`, the tab is hidden and no event tap is installed.
    /// Data model + repository are migrated either way — built-in
    /// Transforms exist in the DB so flipping this flag is a no-data
    /// operation.
    ///
    /// Enabled once the website telemetry allowlist accepts
    /// `transform_executed` / `transform_failed` (ADR-022 §9).
    public static let transformsEnabled: Bool = true
}
