import Foundation

/// Compile-time feature gates. Flip a single literal to expose or hide a feature
/// without touching every call site. Release builds should set these to the
/// shipping configuration before tagging a version.
public enum AppFeatures {
    /// Meeting Recording (ADR-014). When `false`, all meeting recording entry
    /// points are hidden: Transcribe tile, menu-bar "Start Recording", global
    /// meeting hotkey, settings card, library filter, and the screen recording
    /// permission row. Meeting recording sets itself up on first use via a
    /// self-prompt (no onboarding step). Data model, services, and tests remain intact.
    public static let meetingRecordingEnabled: Bool = true

    /// Calendar auto-start (ADR-017). When `false`, all calendar entry points
    /// are hidden: Settings calendar subsection, search-index calendar entry,
    /// and the auto-start coordinator never starts polling. Calendar sets itself
    /// up on first use from Settings (no onboarding step). CalendarService,
    /// MeetingAutoStartCoordinator, models, and tests remain intact — only the
    /// surfaces that would invoke them are gated.
    /// Enabled after the post-#318 reliability hardening (ADR-017 Phases 1+2):
    /// mid-flight teardown, RSVP/zero-duration guards, and reschedule re-fire.
    /// Calendar-driven auto-stop was removed by the 2026-05 amendment. Auto-
    /// start defaults to mode `.off`, so upgraders opt in explicitly via
    /// Settings; nothing changes for existing users until they do.
    public static let calendarEnabled: Bool = true

    /// Activity-based meeting auto-stop (ADR-023). When `true`, Settings shows
    /// the opt-in meeting auto-stop toggle and the app constructs the
    /// coordinator that observes meeting-end signals only while a recording is
    /// active. Default off until field validation proves the trust posture.
    public static let meetingAutoStopEnabled: Bool = false

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

    /// VAD-guided meeting live chunking
    /// (`plans/completed/2026-05-meeting-vad-guided-live-chunking.md`). When
    /// `false`, meeting live-preview chunks use the fixed 5s / 1s-overlap
    /// `AudioChunker` path. When `true`, launch-time prep tries to cache the
    /// Silero VAD model, and cached-model Parakeet sessions cut live-preview
    /// chunks at speech boundaries. Each source independently falls back to
    /// fixed chunking when VAD is unavailable or errors repeatedly. The final
    /// saved transcript (post-stop full-file STT) is unaffected either way.
    ///
    /// Enabled for the VAD release candidate after Phase 0/corpus replay showed
    /// clean inline performance and Phase 4.5 made model prep universal. Keep
    /// `vad_model_prep` allowlisted and deployed before shipping flag-on builds.
    public static let meetingVadLiveChunkingEnabled: Bool = true

    /// Display-only live dictation preview. Nemotron multilingual uses its
    /// native live partial path; Parakeet uses the single-flight tail-window
    /// sample preview path. Whisper remains default-off until its per-pass
    /// latency is measured on a real model.
    public static let liveDictationStreamingEnabled: Bool = true

    /// App-aware AI Formatter profiles (REQ-LLM-004, issues #117/#412). When
    /// `true`, dictation formatter prompts resolve through custom app
    /// profiles, custom category profiles, built-in smart defaults (readable
    /// and toggleable in Settings — master switch + per-category switches),
    /// and then the fallback prompt; Settings shows profile management and
    /// History shows routing provenance. When `false`, all of that is hidden
    /// (profile keywords drop out of search; the formatter card itself stays
    /// indexed) and dictation uses only the global formatter prompt. The
    /// profile table and repository migrate either way, so flipping this flag
    /// is a no-data operation.
    ///
    /// Enabled 2026-06-10 after the ship-polish pass (smart-defaults
    /// visibility/toggles, edit-path category fix, manual-entry parity)
    /// resolved the UX gaps that pulled the flag in `6cd4a7034`.
    public static let aiFormatterProfilesEnabled: Bool = true
}
