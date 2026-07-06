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
    /// active. Enabled on `main` (2026-06-14) so the opt-in toggle is
    /// dogfoodable; the per-user setting still defaults off, so nothing
    /// auto-stops until a user turns it on. Not yet in a tagged release.
    public static let meetingAutoStopEnabled: Bool = true

    /// Meeting capture reliability watchdog (ADR-025 Phase A). When `true`,
    /// meeting capture observes metadata-only microphone/system buffer liveness
    /// and emits `mic_stall_detected` telemetry for confirmed mic-health
    /// stalls. This does not stop, truncate, repair, or discard recordings.
    /// Keep this default-on reliability path behind a kill switch while repair
    /// phases are still being validated.
    public static let meetingCaptureReliabilityEnabled: Bool = true

    /// Meeting source health presentation. When `false`, the Core health model,
    /// service plumbing, view-model state, and tests remain intact, but the
    /// panel chips, floating pill degraded glyph, and transcription-tile health
    /// mirror are hidden. Default-off after 2026-07-04 product review because
    /// quiet-but-normal recordings made the amber warning chips feel alarmist.
    public static let meetingSourceHealthUIEnabled: Bool = false

    /// Activity-based meeting detection (ADR-024). When `false`, Settings hides
    /// the meeting-activity detection mode, the app does not construct the
    /// coordinator, and no CoreAudio/CoreMediaIO collectors are started. Pure
    /// detector types and tests remain compiled so flipping the flag is a
    /// no-data operation after validation.
    public static let meetingActivityDetectionEnabled: Bool = false

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

    /// Cohere Transcribe dictation engine. When `true`, Settings offers Cohere
    /// as a selectable speech engine (on-device Core ML via FluidAudio's
    /// `CoherePipeline`). When `false`, the engine type, runtime routing, and
    /// model plumbing remain compiled and intact — only the Settings surface
    /// that lets a user select it is hidden, so flipping the flag is a no-data
    /// operation. Gated separately because the model is a ~2.1 GB download and
    /// the engine is batch-only (no live partials/word timestamps).
    public static let cohereEngineEnabled: Bool = true

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

    /// Display-only live dictation preview. Nemotron and Parakeet Unified use
    /// their native live partial paths; Parakeet TDT builds use the single-flight
    /// tail-window sample preview path. Whisper remains default-off until its
    /// per-pass latency is measured on a real model.
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
    ///
    /// Re-gated to `false` on 2026-06-14 to hold app-aware profiles out of the
    /// v0.6.23 release; the rest of the v0.6.23 delta ships without it. Flip
    /// back to `true` to ship profiles in a later tag (no-data operation — the
    /// profile table/repository migrate regardless of this flag).
    public static let aiFormatterProfilesEnabled: Bool = false

    /// In-process local LLM provider (MLX foundation). When `false`, the
    /// provider descriptor, config, routing seam, and fake-runtime tests remain
    /// compiled, but Settings and user-reachable provider lists hide the option.
    /// The real MLX implementation is a separate opt-in build target gated by
    /// `MACPARAKEET_ENABLE_MLX_LOCAL_LLM=1`, so normal SwiftPM builds and CI do
    /// not resolve mlx-swift-lm.
    public static let inProcessLocalLLMEnabled: Bool = false

    /// Developer-only escape hatch for exercising the local LLM setup flow
    /// while the public feature flag above stays off.
    public static let inProcessLocalLLMDeveloperDefaultsKey = "MacParakeetEnableInProcessLocalLLM"
    public static let inProcessLocalLLMDeveloperLaunchArgument = "--enable-local-ai"

    public static func inProcessLocalLLMDeveloperOverrideEnabled(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        defaults.bool(forKey: inProcessLocalLLMDeveloperDefaultsKey)
            || arguments.contains(inProcessLocalLLMDeveloperLaunchArgument)
    }

    public static func isInProcessLocalLLMProductVisible(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        inProcessLocalLLMEnabled
            || inProcessLocalLLMDeveloperOverrideEnabled(
                defaults: defaults,
                arguments: arguments
            )
    }

    public static func isInProcessLocalLLMVisible(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        runtimeAvailable: Bool = false
    ) -> Bool {
        runtimeAvailable
            && isInProcessLocalLLMProductVisible(
                defaults: defaults,
                arguments: arguments
            )
    }

    public static func shouldShowInProcessLocalLLMUnavailableExplanation(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        runtimeAvailable: Bool
    ) -> Bool {
        !runtimeAvailable
            && inProcessLocalLLMDeveloperOverrideEnabled(
                defaults: defaults,
                arguments: arguments
            )
    }
}
