import Foundation
import MacParakeetCore

/// One searchable destination in the Settings panel — either a whole card
/// or a specific row within a card. All entries point to a stable
/// `cardAnchor` string; tapping a result navigates to that anchor inside
/// its tab via `ScrollViewReader`.
///
/// Row-level entries are deliberate: when a user types "screen recording"
/// they want to land on the row, not just the parent card. The `subtitle`
/// carries the breadcrumb ("in Permissions") so the result is legible.
public struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    /// Stable, unique id for this entry — used as the result-list row
    /// id. Navigation targets the destination card via `cardAnchor`, so
    /// multiple entries (for example, row-level matches inside the same
    /// card) can share an anchor while keeping distinct ids.
    public let id: String
    public let tab: SettingsTab
    public let title: String
    public let subtitle: String
    /// Hidden but searchable terms — synonyms, abbreviations, related
    /// jargon. A user typing "mic" should find "Microphone".
    public let keywords: [String]
    /// The card anchor a result navigates to. Multiple entries can point
    /// to the same anchor (e.g. row entries inside a card).
    public let cardAnchor: String

    public init(
        id: String,
        tab: SettingsTab,
        title: String,
        subtitle: String,
        keywords: [String] = [],
        cardAnchor: String
    ) {
        self.id = id
        self.tab = tab
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.cardAnchor = cardAnchor
    }

    /// Case-insensitive substring match against title, subtitle, and
    /// keywords. The query is trimmed before matching so leading or
    /// trailing whitespace doesn't break the search.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        if title.lowercased().contains(needle) { return true }
        if subtitle.lowercased().contains(needle) { return true }
        for keyword in keywords where keyword.lowercased().contains(needle) {
            return true
        }
        return false
    }
}

/// Static catalog of every searchable destination in the Settings panel.
///
/// Lives in `MacParakeetViewModels` (not in the view target) for two
/// reasons: it has no SwiftUI dependency, and tests can verify the
/// shape (unique ids, valid tabs, no empty titles) without spinning up
/// a view hierarchy.
///
/// Entry ordering inside a tab is card-then-rows. The index ordering is
/// also the result ordering — there's no relevance score yet (substring
/// matching with 20 entries doesn't need one).
///
/// **Maintenance:** when a Settings card is added, renamed, or moved
/// between tabs, update both the entries here and the `cardAnchor` on
/// the corresponding view's `.id(...)` modifier in `SettingsView.swift`.
/// Anchor drift is currently caught by manual review — the index and
/// the view are coupled by string convention, not by a compiler check.
///
/// **Feature flags:** entries pointing at gated surfaces are filtered out
/// when their `AppFeatures` flag is `false`, so search never lands on a
/// card or row that won't render.
public enum SettingsSearchIndex {
    /// Ids whose destination card or row is gated on
    /// `AppFeatures.meetingRecordingEnabled`. When the flag is off these
    /// entries are filtered out so search never lands on a destination
    /// that won't render.
    private static let meetingGatedIds: Set<String> = [
        "meeting",
        "meeting.calendar",
        "system.permissions.screen"
    ]

    /// Ids gated on `AppFeatures.calendarEnabled` independently of meeting
    /// recording. Filtered out when the flag is off so search doesn't land
    /// on a hidden calendar subsection.
    private static let calendarGatedIds: Set<String> = [
        "meeting.calendar"
    ]

    /// Ids gated on `AppFeatures.aiFormatterProfilesEnabled`. The global AI
    /// Formatter prompt remains visible via `ai.provider`; only app/category
    /// profile management is hidden by this gate.
    private static let aiFormatterProfileGatedIds: Set<String> = [
        "ai.formatter"
    ]

    public static let entries: [SettingsSearchEntry] = {
        var result = allEntries
        if !AppFeatures.meetingRecordingEnabled {
            result = result.filter { !meetingGatedIds.contains($0.id) }
        }
        if !AppFeatures.calendarEnabled {
            result = result.filter { !calendarGatedIds.contains($0.id) }
        }
        if !AppFeatures.aiFormatterProfilesEnabled {
            result = result.filter { !aiFormatterProfileGatedIds.contains($0.id) }
        }
        return result
    }()

    /// Full unfiltered catalog. Order matters: result lists are produced
    /// by `entries.filter(...)`, and tests assert that the filter is
    /// stable in index order.
    private static let allEntries: [SettingsSearchEntry] = [
        // MARK: Capture
        SettingsSearchEntry(
            id: "audio.input",
            tab: .capture,
            title: "Audio Input",
            subtitle: "Choose the microphone used for dictation and meetings.",
            keywords: ["microphone", "mic", "input device", "audio device"],
            cardAnchor: "audio.input"
        ),
        SettingsSearchEntry(
            id: "dictation",
            tab: .capture,
            title: "Dictation",
            subtitle: "Hotkey, silence detection, and overlay behavior.",
            keywords: ["hotkey", "fn key", "shortcut", "voice", "dictate", "talk", "press to talk"],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.idle.pill",
            tab: .capture,
            title: "Show idle pill at all times",
            subtitle: "in Dictation",
            keywords: ["pill", "indicator", "always visible", "menu bar", "floating"],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.keep.clipboard",
            tab: .capture,
            title: "Keep dictation on clipboard",
            subtitle: "in Dictation",
            keywords: ["clipboard", "copy", "paste", "cmd v", "command v", "transcript", "retain", "remote"],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "transcription",
            tab: .capture,
            title: "Transcription",
            subtitle: "How file and YouTube transcription behaves.",
            keywords: ["file", "youtube", "drag drop", "audio file", "video file", "transcribe"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "transcription.hotkey.file",
            tab: .capture,
            title: "File transcription hotkey",
            subtitle: "in Transcription",
            keywords: ["hotkey", "shortcut", "file", "drag drop", "audio file", "video file"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "transcription.hotkey.youtube",
            tab: .capture,
            title: "YouTube transcription hotkey",
            subtitle: "in Transcription",
            keywords: ["hotkey", "shortcut", "youtube", "url", "video"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "transcription.youtube.audio.quality",
            tab: .capture,
            title: "YouTube audio quality",
            subtitle: "in Transcription",
            keywords: ["youtube", "audio", "quality", "m4a", "best available", "opus", "webm"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "transcription.diarization",
            tab: .capture,
            title: "Speaker detection",
            subtitle: "in Transcription",
            keywords: ["speaker", "diarization", "pyannote", "who said what", "speakers"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "transcription.completion.notification",
            tab: .capture,
            title: "Notify when transcription finishes",
            subtitle: "in Transcription",
            keywords: ["notification", "notify", "sound", "chime", "alert", "banner", "done", "finished", "complete", "batch"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "transcription.autosave",
            tab: .capture,
            title: "Auto-save transcripts to disk",
            subtitle: "in Transcription",
            keywords: ["auto save", "autosave", "export", "save", "disk", "folder", "file"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "meeting",
            tab: .capture,
            title: "Meeting Recording",
            subtitle: "Dedicated controls for meeting audio capture.",
            keywords: ["meeting", "system audio", "screen recording", "meeting capture", "core audio taps"],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.calendar",
            tab: .capture,
            title: "Calendar",
            subtitle: "in Meeting Recording",
            keywords: ["calendar", "auto start", "auto-start", "reminders", "events", "ics"],
            cardAnchor: "meeting"
        ),

        // MARK: Engine
        SettingsSearchEntry(
            id: "engine.selector",
            tab: .engine,
            title: "Speech Recognition",
            subtitle: "Parakeet, Nemotron, and Whisper engine selector.",
            keywords: ["engine", "speech", "stt", "parakeet", "whisper", "model", "ane", "neural engine"],
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: "engine.language",
            tab: .engine,
            title: "Whisper Language",
            subtitle: "Available when Whisper is the active engine.",
            keywords: ["language", "locale", "korean", "japanese", "multilingual", "auto detect", "whisper"],
            // Anchored to the engine selector rather than the language card
            // because the language card only renders when Whisper is active.
            // Searching "language" while on Parakeet would otherwise jump
            // to a hidden anchor; landing on the selector lets the user
            // switch to Whisper, which then reveals the language picker.
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: "engine.parakeetModel",
            tab: .engine,
            title: "Parakeet Model",
            subtitle: "Available when Parakeet is the active engine.",
            keywords: [
                "parakeet", "v2", "v3", "english only", "english-only", "multilingual",
                "faster parakeet", "speed", "low latency", "language", "model", "variant"
            ],
            // Anchored to the engine selector for the same reason as the
            // Whisper Language entry: the Parakeet Model card only renders
            // when Parakeet is active, so landing on the always-present
            // selector keeps the search result from jumping to a hidden anchor.
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: "engine.models",
            tab: .engine,
            title: "Local Models",
            subtitle: "Parakeet, Nemotron, and Whisper model status.",
            keywords: ["model", "download", "repair", "disk", "parakeet", "whisper", "coreml", "local"],
            cardAnchor: "engine.models"
        ),

        // MARK: AI
        SettingsSearchEntry(
            id: "ai.provider",
            tab: .ai,
            title: "AI Setup",
            subtitle: "Optional. Powers summaries, chat, meeting Ask, and Transforms.",
            keywords: [
                "ai", "llm", "openai", "anthropic", "claude", "gpt", "lm studio", "ollama",
                "openai compatible", "summary", "summaries", "chat", "ask", "api key",
                "provider", "local ai", "local app", "command line", "cli"
            ],
            cardAnchor: "ai.provider"
        ),
        SettingsSearchEntry(
            id: "ai.transcriptContext",
            tab: .ai,
            title: "Transcript Context for AI",
            subtitle: "Rich or plain transcript context for summaries, chat, and Meeting Ask.",
            keywords: [
                "meeting ai", "meeting context", "transcript context", "rich transcript",
                "plain transcript", "speaker labels", "speaker diarization", "timestamps",
                "summary context", "chat context", "ask context"
            ],
            cardAnchor: "ai.transcriptContext"
        ),
        SettingsSearchEntry(
            id: "ai.formatter",
            tab: .ai,
            title: "AI Formatter",
            subtitle: "Smart defaults, fallback prompt, and app-specific formatter profiles.",
            keywords: [
                "formatter", "formatting", "cleanup", "dictation prompt", "app profiles",
                "smart defaults", "fallback prompt", "bundle id", "category", "rewrite", "polish"
            ],
            cardAnchor: "ai.formatter"
        ),

        // MARK: System
        SettingsSearchEntry(
            id: "system.appearance",
            tab: .system,
            title: "Appearance",
            subtitle: "Light, dark, or follow macOS.",
            keywords: ["theme", "dark mode", "light mode", "color scheme", "system appearance"],
            cardAnchor: "system.appearance"
        ),
        SettingsSearchEntry(
            id: "system.startup",
            tab: .system,
            title: "Startup",
            subtitle: "How MacParakeet shows up at sign-in.",
            keywords: ["launch at login", "login items", "menu bar only", "startup", "boot", "auto launch"],
            cardAnchor: "system.startup"
        ),
        SettingsSearchEntry(
            id: "system.permissions",
            tab: .system,
            title: "Permissions",
            subtitle: "Microphone, Accessibility, Screen Recording.",
            keywords: ["permission", "tcc", "privacy", "microphone", "mic", "accessibility", "screen recording"],
            cardAnchor: "system.permissions"
        ),
        SettingsSearchEntry(
            id: "system.permissions.mic",
            tab: .system,
            title: "Microphone",
            subtitle: "in Permissions",
            keywords: ["mic", "audio input", "voice"],
            cardAnchor: "system.permissions"
        ),
        SettingsSearchEntry(
            id: "system.permissions.accessibility",
            tab: .system,
            title: "Accessibility",
            subtitle: "in Permissions",
            keywords: ["paste", "hotkey", "global shortcut", "ax"],
            cardAnchor: "system.permissions"
        ),
        SettingsSearchEntry(
            id: "system.permissions.screen",
            tab: .system,
            title: "Screen & System Audio Recording",
            subtitle: "in Permissions",
            keywords: ["screen recording", "system audio", "meeting capture", "core audio taps"],
            cardAnchor: "system.permissions"
        ),
        SettingsSearchEntry(
            id: "system.storage",
            tab: .system,
            title: "Storage",
            subtitle: "Retention preferences and disk usage.",
            keywords: [
                "storage", "retention", "disk", "history",
                "save dictation", "save audio", "keep youtube audio", "youtube"
            ],
            cardAnchor: "system.storage"
        ),
        SettingsSearchEntry(
            id: "system.updates",
            tab: .system,
            title: "Updates",
            subtitle: "Automatic update checks and manual update.",
            keywords: ["update", "sparkle", "version", "release", "auto update"],
            cardAnchor: "system.updates"
        ),
        SettingsSearchEntry(
            id: "system.privacy",
            tab: .system,
            title: "Privacy",
            subtitle: "Telemetry opt-out and data handling.",
            keywords: ["telemetry", "analytics", "tracking", "data collection", "privacy"],
            cardAnchor: "system.privacy"
        ),
        SettingsSearchEntry(
            id: "system.onboarding",
            tab: .system,
            title: "Setup",
            subtitle: "Re-run guided setup.",
            keywords: ["onboarding", "setup", "first run", "tutorial", "getting started"],
            cardAnchor: "system.onboarding"
        ),
        SettingsSearchEntry(
            id: "system.about",
            tab: .system,
            title: "About",
            subtitle: "Version and build identity.",
            keywords: ["about", "version", "build", "credits", "open source", "license"],
            cardAnchor: "system.about"
        ),
        SettingsSearchEntry(
            id: "system.reset",
            tab: .system,
            title: "Reset & Cleanup",
            subtitle: "Destructive — clear history, reset stats.",
            keywords: [
                "reset", "clear", "delete", "destructive", "wipe",
                "lifetime stats", "clear all dictations", "clear transform history", "clear youtube"
            ],
            cardAnchor: "system.reset"
        )
    ]

    /// Returns entries whose title, subtitle, or keywords contain the
    /// (trimmed, lowercased) query as a substring. Empty / whitespace
    /// queries return an empty array — callers should fall back to the
    /// tabbed view in that case rather than rendering an empty results
    /// list.
    public static func matches(_ query: String) -> [SettingsSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return entries.filter { $0.matches(trimmed) }
    }
}
