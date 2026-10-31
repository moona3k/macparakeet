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
/// Query and visibility tests exercise the catalog's public results. New or
/// renamed rows still require review against their rendered destinations.
///
/// **Feature flags:** entries pointing at gated surfaces are filtered out
/// when their `AppFeatures` flag is `false`, so search never lands on a
/// card or row that won't render.
public enum SettingsSearchIndex {
    /// Shared anchor for the advanced recordings/files engine control.
    public static let advancedTranscriptionAnchor = "engine.transcriptionSelector"

    /// The anchor of the Meeting Recording card, which the view gates on
    /// `AppFeatures.meetingRecordingEnabled` along with every row inside it.
    private static let meetingCardAnchor = "meeting"

    /// Ids whose destination card or row is gated on
    /// `AppFeatures.meetingRecordingEnabled`. When the flag is off these
    /// entries are filtered out so search never lands on a destination
    /// that won't render.
    ///
    /// Derived from the card anchor rather than hand-listed: the whole card
    /// disappears with the flag, so every entry pointing at it must too, and
    /// deriving means adding a meeting setting cannot forget to gate its
    /// search row. Only entries that sit under a different anchor yet exist
    /// solely to serve meeting recording — screen-recording permission — are
    /// named explicitly.
    private static let meetingGatedIds: Set<String> = {
        var ids = Set(
            allEntries
                .filter { $0.cardAnchor == meetingCardAnchor }
                .map(\.id)
        )
        ids.insert("system.permissions.screen")
        return ids
    }()

    /// Ids gated on `AppFeatures.calendarEnabled` independently of meeting
    /// recording. Filtered out when the flag is off so search doesn't land
    /// on a hidden calendar subsection.
    private static let calendarGatedIds: Set<String> = [
        "meeting.calendar"
    ]

    /// Ids gated on ADR-023's staged auto-stop flag. The preference exists in
    /// the model either way, but Settings search should not expose a hidden row.
    private static let meetingAutoStopGatedIds: Set<String> = [
        "meeting.autoStop"
    ]

    public static let entries = visibleEntries(
        hasEnrolledVoices: false, speakerDetectionEnabled: true,
        voiceProfilesAvailable: AppFeatures.isVoiceProfilesAvailable())

    /// Match the view's current voice-profile destinations. Stored voices (or
    /// a failed store read) keep management available even with enrollment off.
    static func visibleEntries(
        hasEnrolledVoices: Bool,
        speakerDetectionEnabled: Bool,
        voiceProfilesAvailable: Bool
    ) -> [SettingsSearchEntry] {
        var result = allEntries
        if !AppFeatures.meetingRecordingEnabled {
            result = result.filter { !meetingGatedIds.contains($0.id) }
        }
        if !AppFeatures.calendarEnabled {
            result = result.filter { !calendarGatedIds.contains($0.id) }
        }
        if !AppFeatures.meetingAutoStopEnabled {
            result = result.filter { !meetingAutoStopGatedIds.contains($0.id) }
        }
        if !AppFeatures.meetingActivityDetectionEnabled {
            result = result.filter { $0.id != "meeting.activityDetection" }
        }
        if !voiceProfilesAvailable || !speakerDetectionEnabled {
            result.removeAll { $0.id == "meeting.rememberSpeakers" }
        }
        if !voiceProfilesAvailable && !hasEnrolledVoices {
            result.removeAll { $0.id == "meeting.voiceProfiles" }
        }
        return result
    }

    /// Full unfiltered catalog. Order matters: result lists are produced
    /// by filtering visible entries, and tests assert stable index order.
    /// Internal so catalog and visibility tests can exercise both flag states.
    static let allEntries: [SettingsSearchEntry] = [
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
            id: "dictation.push.to.talk",
            tab: .capture,
            title: "Push to talk",
            subtitle: "in Dictation",
            keywords: [
                "hold", "hold to talk", "hold to dictate", "hotkey", "shortcut", "fn key",
                "release",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.hands.free",
            tab: .capture,
            title: "Hands-free mode",
            subtitle: "in Dictation",
            keywords: [
                "hands free", "handsfree", "toggle", "double tap", "tap to start", "hotkey",
                "shortcut",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.additional.shortcuts",
            tab: .capture,
            title: "Additional shortcuts",
            subtitle: "in Dictation",
            keywords: [
                "second shortcut", "second hotkey", "alternate shortcut", "extra shortcut",
                "another keyboard", "external keyboard",
            ],
            cardAnchor: "dictation"
        ),
        // The Additional shortcuts group repeats the two dictation rows for a
        // second keyboard. They carry the same titles as the rows above, so the
        // subtitle names the group to keep the two results apart.
        SettingsSearchEntry(
            id: "dictation.additional.push.to.talk",
            tab: .capture,
            title: "Push to talk",
            subtitle: "in Dictation, under Additional shortcuts",
            keywords: [
                "second push to talk", "alternate push to talk", "hold to dictate", "hotkey",
                "shortcut",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.additional.hands.free",
            tab: .capture,
            title: "Hands-free mode",
            subtitle: "in Dictation, under Additional shortcuts",
            keywords: [
                "second hands-free", "alternate hands-free", "hands free", "handsfree",
                "tap to start", "hotkey", "shortcut",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.ai.polish",
            tab: .capture,
            title: "AI-polished dictation",
            subtitle: "in Dictation",
            keywords: [
                "ai", "polish", "polished", "formatter", "llm", "rewrite", "clean up", "hotkey",
                "shortcut",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.idle.pill",
            tab: .capture,
            title: "Show dictation pill at all times",
            subtitle: "in Dictation",
            keywords: [
                "Show idle pill at all times", "idle pill", "pill", "indicator", "always visible",
                "menu bar", "floating",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.overlay.position",
            tab: .capture,
            title: "Pill position",
            subtitle: "in Dictation",
            keywords: [
                "overlay", "overlay position", "placement", "location", "move pill",
                "top of screen", "bottom of screen",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.url.control",
            tab: .capture,
            title: "Allow dictation control from links",
            subtitle: "in Dictation",
            keywords: [
                "url", "automation", "stream deck", "streamdeck", "raycast", "keyboard maestro", "shortcuts", "toggle",
            ],
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
            id: "dictation.capture.sounds",
            tab: .capture,
            title: "Play sounds when dictation starts and stops",
            subtitle: "in Dictation",
            keywords: [
                "sound", "tone", "chime", "beep", "start sound", "stop sound",
                "capture cue", "tink", "pop", "audio feedback", "handy", "marimba",
                "custom sound", "import sound", "volume", "preview", "wav", "mute",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.streaming.cursor",
            tab: .capture,
            title: "Streaming cursor",
            subtitle: "in Dictation",
            keywords: ["streaming", "cursor", "typewriter", "caret", "character", "superwhisper", "insert"],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.live.preview",
            tab: .capture,
            title: "Live transcript preview",
            subtitle: "in Dictation",
            keywords: ["preview", "live preview", "transcript preview", "dictation pill", "overlay", "in progress"],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.preview.text.size",
            tab: .capture,
            title: "Preview text size",
            subtitle: "in Dictation",
            keywords: [
                "font size", "text size", "bigger text", "larger text", "preview", "live preview",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.undo.window",
            tab: .capture,
            title: "Undo window",
            subtitle: "in Dictation",
            keywords: ["undo", "cancel", "countdown", "timer", "wait", "discard", "off", "disable"],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.escape.cancel",
            tab: .capture,
            title: "Escape cancels dictation",
            subtitle: "in Dictation",
            keywords: [
                "escape", "esc", "cancel", "ignore escape", "safari", "fullscreen",
                "live transcription", "don't cancel",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.preserve.discarded",
            tab: .capture,
            title: "Preserve discarded dictations",
            subtitle: "in Dictation",
            keywords: [
                "preserve", "discarded", "cancelled", "canceled", "recover",
                "accidental cancel", "keep cancelled", "history",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.silence.auto.stop",
            tab: .capture,
            title: "Auto-stop after silence",
            subtitle: "in Dictation",
            keywords: [
                "silence", "auto stop", "stop automatically", "stop recording",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.silence.delay",
            tab: .capture,
            title: "Silence delay",
            subtitle: "in Dictation",
            keywords: ["silence", "delay", "timeout", "seconds", "how long", "auto stop"],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.instant",
            tab: .capture,
            title: "Instant dictation",
            subtitle: "in Dictation",
            keywords: [
                "instant", "mic ready", "warm", "low latency", "faster start", "first words",
                "mic indicator", "airpods", "bluetooth",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "dictation.pause.media",
            tab: .capture,
            title: "Pause media while dictating",
            subtitle: "in Dictation",
            keywords: [
                "pause", "media", "music", "playback", "resume", "spotify", "podcast",
            ],
            cardAnchor: "dictation"
        ),
        SettingsSearchEntry(
            id: "transcription",
            tab: .capture,
            title: "Transcription",
            subtitle: "How file and video URL transcription behaves.",
            keywords: [
                "file", "youtube", "x", "twitter", "url", "drag drop", "audio file", "video file", "transcribe",
            ],
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
            title: "Video URL transcription hotkey",
            subtitle: "in Transcription",
            keywords: ["hotkey", "shortcut", "youtube", "x", "twitter", "url", "video"],
            cardAnchor: "transcription"
        ),
        SettingsSearchEntry(
            id: "transcription.youtube.audio.quality",
            tab: .capture,
            title: "Video download audio quality",
            subtitle: "in Transcription",
            keywords: [
                "youtube", "x", "twitter", "video", "audio", "quality", "m4a", "best available", "opus", "webm",
            ],
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
            keywords: [
                "notification", "notify", "sound", "chime", "alert", "banner", "done", "finished", "complete", "batch",
            ],
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
            id: "transcription.autosave.format",
            tab: .capture,
            title: "Format",
            subtitle: "in Transcription",
            keywords: [
                "file format", "export format", "plain text", "txt", "markdown", "srt", "vtt",
                "json", "auto save",
            ],
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
            id: "meeting.hotkey",
            tab: .capture,
            title: "Meeting hotkey",
            subtitle: "in Meeting Recording",
            keywords: [
                "hotkey", "shortcut", "keyboard shortcut", "meeting shortcut",
                "change hotkey", "change shortcut", "remove hotkey", "remove shortcut",
                "disable hotkey", "unmap", "remap",
                "cmd shift m", "cmd+shift+m", "command shift m", "command+shift+m", "⌘⇧m",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.calendar",
            tab: .capture,
            title: "Calendar",
            subtitle: "in Meeting Recording",
            keywords: [
                "calendar", "auto start", "auto-start", "reminders", "events", "ics",
                "outlook", "microsoft 365", "exchange", "internet accounts",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.floatingControls",
            tab: .capture,
            title: "Show floating meeting controls",
            subtitle: "in Meeting Recording",
            keywords: [
                "floating controls", "meeting pill", "recording pill",
                "hide meeting", "hide recording", "recording ui", "menu bar",
                "overlay",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.openAppAfterEnd",
            tab: .capture,
            title: "Open app when meeting ends",
            subtitle: "in Meeting Recording",
            keywords: [
                "open app", "auto open", "auto-open", "bring forward", "focus",
                "steal focus", "meeting ends", "after meeting", "stop recording",
                "background", "stay in background",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.notifyOnEnd",
            tab: .capture,
            title: "Notify when transcript is ready",
            subtitle: "in Meeting Recording",
            keywords: [
                "notification", "notify", "banner", "chime", "sound",
                "meeting ready", "transcript ready", "meeting complete",
                "meeting notification",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.audioSources",
            tab: .capture,
            title: "Audio sources",
            subtitle: "in Meeting Recording",
            keywords: [
                "audio source", "microphone only", "system audio only", "mic and system audio",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.urlControl",
            tab: .capture,
            title: "Allow recording control from links",
            subtitle: "in Meeting Recording",
            keywords: [
                "links", "url", "url scheme", "deep link", "automation", "shortcuts",
                "start recording", "stop recording", "pause recording", "resume recording",
                "remote control", "macparakeet://",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.startMuted",
            tab: .capture,
            title: "Start meetings muted",
            subtitle: "in Meeting Recording",
            keywords: [
                "start muted", "mute microphone", "mic off", "unmute later",
                "join muted", "begin muted", "silence microphone",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.liveTranscription",
            tab: .capture,
            title: "Live transcription during recording",
            subtitle: "in Meeting Recording",
            keywords: [
                "live transcription", "live preview", "live captions", "cpu", "gpu",
                "performance", "battery", "disable live transcription", "just record",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.speakerDetection",
            tab: .capture,
            title: "Speaker detection",
            subtitle: "in Meeting Recording",
            keywords: ["speaker", "speaker labels", "diarization", "participants", "others", "system audio"],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.rememberSpeakers",
            tab: .capture,
            title: "Remember speakers",
            subtitle: "in Meeting Recording",
            keywords: [
                "remember", "voice", "voiceprint", "voice profile", "recognize", "suggest names",
                "speaker names", "consent",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.voiceProfiles",
            tab: .capture,
            title: "Voice profiles",
            subtitle: "in Meeting Recording",
            keywords: [
                "voices", "voice profile", "voiceprint", "delete voices", "manage voices",
                "saved voices",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.autoSave",
            tab: .capture,
            title: "Also save meetings to a folder",
            subtitle: "in Meeting Recording",
            keywords: [
                "save", "export", "folder", "copy", "auto save", "autosave", "markdown", "txt",
                "format",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.autoSave.format",
            tab: .capture,
            title: "Format",
            subtitle: "in Meeting Recording",
            keywords: [
                "file format", "export format", "plain text", "txt", "markdown", "srt", "vtt",
                "json", "auto save",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.autoSave.timestamps",
            tab: .capture,
            title: "Include timestamps",
            subtitle: "in Meeting Recording",
            keywords: ["timestamps", "time", "export", "auto save", "folder", "paragraph"],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.autoSave.speakerLabels",
            tab: .capture,
            title: "Include speaker labels",
            subtitle: "in Meeting Recording",
            keywords: ["speaker labels", "speaker names", "export", "auto save", "folder"],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.autoSave.metadata",
            tab: .capture,
            title: "Include meeting details",
            subtitle: "in Meeting Recording",
            keywords: [
                "meeting details", "metadata", "title", "duration", "export", "auto save", "folder",
            ],
            cardAnchor: "meeting"
        ),
        SettingsSearchEntry(
            id: "meeting.autoStop",
            tab: .capture,
            title: "Stop recording automatically",
            subtitle: "in Meeting Recording",
            keywords: [
                "auto stop", "auto-stop", "auto-stop meetings", "stop recording",
                "meeting ended", "silence", "zoom closed",
            ],
            cardAnchor: "meeting"
        ),

        SettingsSearchEntry(
            id: "meeting.activityDetection",
            tab: .capture,
            title: "Remind me to record meetings",
            subtitle: "in Meeting Recording",
            keywords: ["meeting detection", "detect calls", "record this meeting", "zoom", "google meet", "reminder"],
            cardAnchor: "meeting"
        ),

        // MARK: Engine
        SettingsSearchEntry(
            id: "engine.selector",
            tab: .engine,
            title: "Speech Engine",
            subtitle: "Your selected engine handles dictation, meetings, recordings, and files.",
            keywords: [
                "engine", "speech", "stt", "parakeet", "nemotron", "whisper", "cohere",
                "model", "preview", "timestamps", "ane", "neural engine",
            ],
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: advancedTranscriptionAnchor,
            tab: .engine,
            title: "Recordings & Files Engine",
            subtitle: "Optionally use a different engine for completed meeting recordings, files, media, and URLs.",
            keywords: [
                "meeting engine", "transcription engine", "final transcript", "file engine", "files engine",
                "recordings", "accuracy", "slower", "separate engine", "same as live", "advanced",
                "media", "retranscription", "dictation", "parakeet", "nemotron", "whisper", "cohere",
            ],
            cardAnchor: advancedTranscriptionAnchor
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
                "faster parakeet", "speed", "low latency", "language", "model", "variant",
            ],
            // Anchored to the engine selector for the same reason as the
            // Whisper Language entry: the Parakeet Model card only renders
            // when Parakeet is active, so landing on the always-present
            // selector keeps the search result from jumping to a hidden anchor.
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: "engine.nemotronModel",
            tab: .engine,
            title: "Nemotron Model",
            subtitle: "Available when Nemotron is the active engine.",
            keywords: [
                "nemotron", "english", "english-only", "multilingual",
                "streaming", "beta", "model", "variant",
            ],
            // Same hidden-anchor rationale as the Parakeet Model entry: the
            // Nemotron Model card only renders when Nemotron is active.
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: "engine.cohereModel",
            tab: .engine,
            title: "Cohere Performance",
            subtitle: "Available when Cohere is the active engine.",
            keywords: [
                "cohere", "gpu", "ane", "neural engine", "compute", "performance",
                "speed", "latency", "fastest", "balanced", "model",
            ],
            // Same hidden-anchor rationale as the Parakeet/Nemotron Model
            // entries: the Cohere Performance card only renders when Cohere is
            // the active engine, so land on the always-present selector.
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: "engine.cohereModel.compute",
            tab: .engine,
            title: "Compute",
            subtitle: "in Cohere Performance",
            keywords: ["gpu", "ane", "neural engine", "faster", "balanced", "cohere"],
            // Lands on the selector with its card, for the same reason.
            cardAnchor: "engine.selector"
        ),
        SettingsSearchEntry(
            id: "engine.models",
            tab: .engine,
            title: "Local Models",
            subtitle: "Parakeet, Nemotron, Whisper, and Cohere model status.",
            keywords: [
                "model", "download", "repair", "disk", "parakeet", "nemotron",
                "whisper", "cohere", "coreml", "local",
            ],
            cardAnchor: "engine.models"
        ),
        SettingsSearchEntry(
            id: "engine.models.parakeet",
            tab: .engine,
            title: "Parakeet",
            subtitle: "in Local Models",
            cardAnchor: "engine.models"
        ),
        SettingsSearchEntry(
            id: "engine.models.nemotron",
            tab: .engine,
            title: "Nemotron",
            subtitle: "in Local Models",
            cardAnchor: "engine.models"
        ),
        SettingsSearchEntry(
            id: "engine.models.whisper",
            tab: .engine,
            title: "Whisper",
            subtitle: "in Local Models",
            keywords: ["whisperkit"],
            cardAnchor: "engine.models"
        ),
        SettingsSearchEntry(
            id: "engine.models.cohere",
            tab: .engine,
            title: "Cohere",
            subtitle: "in Local Models",
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
                "provider", "local ai", "local app", "command line", "cli",
                "kimi", "moonshot", "deepseek", "qwen", "dashscope", "z.ai", "zai", "z ai", "glm", "minimax",
                "openrouter", "local-network http", "allow http", "http", "self-hosted",
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
                "summary context", "chat context", "ask context",
            ],
            cardAnchor: "ai.transcriptContext"
        ),
        SettingsSearchEntry(
            id: "ai.meetingLanguage",
            tab: .ai,
            title: "Language of AI Results",
            subtitle: "Language for summaries, chapters, action items, and other prompt results.",
            keywords: [
                "ai result language", "meeting ai language", "summary language", "output language",
                "follow transcript", "english", "polish", "german", "spanish",
                "french", "portuguese", "japanese", "chinese", "korean", "translation", "translate",
                "summaries in", "chapters language", "action items language",
            ],
            cardAnchor: "ai.meetingLanguage"
        ),
        SettingsSearchEntry(
            id: "ai.meetingTitles",
            tab: .ai,
            title: "Meeting Titles",
            subtitle: "Auto-generate short meeting names from completed transcripts.",
            keywords: [
                "meeting title", "meeting titles", "auto title", "auto-title", "auto-title meetings",
                "automatic title", "library title", "recording title", "timestamp title",
            ],
            cardAnchor: "ai.meetingTitles"
        ),
        // The AI Formatter card (header + fallback prompt) is always visible;
        // only the smart defaults + profile management inside it are gated on
        // `AppFeatures.aiFormatterProfilesEnabled`. The entry stays indexed in
        // both states with flag-appropriate copy and keywords.
        SettingsSearchEntry(
            id: "ai.formatter",
            tab: .ai,
            title: "AI Formatter",
            subtitle: AppFeatures.aiFormatterProfilesEnabled
                ? "Smart defaults, fallback prompt, and app-specific formatter profiles."
                : "Formatting prompt for transcripts and dictation.",
            keywords: AppFeatures.aiFormatterProfilesEnabled
                ? [
                    "formatter", "formatting", "cleanup", "dictation prompt", "app profiles",
                    "smart defaults", "fallback prompt", "bundle id", "category", "rewrite", "polish",
                    "use for transcripts", "use for dictation", "meeting transcripts",
                ]
                : [
                    "formatter", "formatting", "cleanup", "dictation prompt",
                    "fallback prompt", "rewrite", "polish",
                    "use for transcripts", "use for dictation", "meeting transcripts",
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
            id: "system.appearance.theme",
            tab: .system,
            title: "Theme",
            subtitle: "in Appearance",
            keywords: ["dark mode", "light mode", "match system", "color scheme", "appearance"],
            cardAnchor: "system.appearance"
        ),
        SettingsSearchEntry(
            id: "system.appearance.discover",
            tab: .system,
            title: "Show Discover in the sidebar",
            subtitle: "in Appearance",
            keywords: ["discover", "sidebar", "hide discover", "feed"],
            cardAnchor: "system.appearance"
        ),
        SettingsSearchEntry(
            id: "system.startup",
            tab: .system,
            title: "Startup",
            subtitle: "How MacParakeet starts and where it appears on your Mac.",
            keywords: [
                "launch at login", "login items", "menu bar", "menu bar icon", "hide menu bar icon",
                "status icon", "menu bar only", "startup", "boot", "auto launch",
            ],
            cardAnchor: "system.startup"
        ),
        SettingsSearchEntry(
            id: "system.startup.launchAtLogin",
            tab: .system,
            title: "Launch at login",
            subtitle: "in Startup",
            keywords: [
                "login items", "start at login", "open at login", "auto launch", "sign in", "boot",
            ],
            cardAnchor: "system.startup"
        ),
        SettingsSearchEntry(
            id: "system.startup.hideMenuBarIcon",
            tab: .system,
            title: "Hide menu bar icon",
            subtitle: "in Startup",
            keywords: ["menu bar", "status icon", "hide icon", "remove from menu bar"],
            cardAnchor: "system.startup"
        ),
        SettingsSearchEntry(
            id: "system.startup.menuBarOnly",
            tab: .system,
            title: "Menu bar only mode",
            subtitle: "in Startup",
            keywords: [
                "dock", "dock icon", "hide dock icon", "no dock", "menu bar only", "menu bar app",
                "background",
            ],
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
            title: "Screen & System Audio",
            subtitle: "in Permissions",
            keywords: [
                "screen recording", "screen & system audio recording", "system audio",
                "meeting capture", "core audio taps",
            ],
            cardAnchor: "system.permissions"
        ),
        SettingsSearchEntry(
            id: "system.storage",
            tab: .system,
            title: "Storage",
            subtitle: "Retention preferences and disk usage.",
            keywords: [
                "storage", "retention", "disk", "history",
                "save dictation", "save audio", "keep youtube audio", "youtube",
                "keep meeting audio", "meeting audio", "meeting recordings",
                "remove audio", "clear audio", "transcript only", "audio lifecycle",
            ],
            cardAnchor: "system.storage"
        ),
        SettingsSearchEntry(
            id: "system.storage.saveHistory",
            tab: .system,
            title: "Save dictation history",
            subtitle: "in Storage",
            keywords: [
                "history", "dictation history", "save dictations", "don't save", "private",
                "voice stats",
            ],
            cardAnchor: "system.storage"
        ),
        SettingsSearchEntry(
            id: "system.storage.saveAudio",
            tab: .system,
            title: "Save audio recordings",
            subtitle: "in Storage",
            keywords: [
                "audio", "recordings", "dictation audio", "keep audio", "delete audio",
                "transcript only",
            ],
            cardAnchor: "system.storage"
        ),
        SettingsSearchEntry(
            id: "system.storage.keepDownloadAudio",
            tab: .system,
            title: "Keep downloaded video audio",
            subtitle: "in Storage",
            keywords: [
                "video", "youtube", "downloaded audio", "auto delete", "keep", "cache", "downloads",
            ],
            cardAnchor: "system.storage"
        ),
        SettingsSearchEntry(
            id: "system.storage.meetingRetention",
            tab: .system,
            title: "Meeting audio retention",
            subtitle: "in Storage",
            keywords: [
                "retention", "meeting audio", "delete after", "days", "keep audio", "cleanup",
                "auto delete",
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
            id: "system.updates.autoCheck",
            tab: .system,
            title: "Automatically check for updates",
            subtitle: "in Updates",
            keywords: [
                "auto update", "automatic updates", "check automatically", "background check",
                "sparkle",
            ],
            cardAnchor: "system.updates"
        ),
        SettingsSearchEntry(
            id: "system.updates.autoDownload",
            tab: .system,
            title: "Automatically download updates",
            subtitle: "in Updates",
            keywords: [
                "auto update", "automatic updates", "auto download", "install updates", "sparkle",
            ],
            cardAnchor: "system.updates"
        ),
        SettingsSearchEntry(
            id: "system.updates.manualCheck",
            tab: .system,
            title: "Manual check",
            subtitle: "in Updates",
            keywords: [
                "check for updates", "check now", "update now", "latest version", "new version",
            ],
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
            id: "system.privacy.telemetry",
            tab: .system,
            title: "Help improve MacParakeet",
            subtitle: "in Privacy",
            keywords: [
                "telemetry", "usage statistics", "analytics", "opt out", "anonymous", "tracking",
            ],
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
            id: "system.onboarding.rerun",
            tab: .system,
            title: "Run setup again",
            subtitle: "in Setup",
            keywords: [
                "rerun", "re-run", "guided setup", "onboarding", "permissions", "model download",
                "troubleshoot", "fix",
            ],
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
                "lifetime stats", "clear all dictations", "clear transform history", "clear youtube",
            ],
            cardAnchor: "system.reset"
        ),
        SettingsSearchEntry(
            id: "system.reset.dictationHistory",
            tab: .system,
            title: "Dictation history",
            subtitle: "in Reset & Cleanup",
            keywords: [
                "clear dictations", "delete dictations", "delete history", "erase", "wipe",
                "audio files",
            ],
            cardAnchor: "system.reset"
        ),
        SettingsSearchEntry(
            id: "system.reset.transformHistory",
            tab: .system,
            title: "Transform history",
            subtitle: "in Reset & Cleanup",
            keywords: ["clear transforms", "delete transform runs", "transforms", "wipe"],
            cardAnchor: "system.reset"
        ),
        SettingsSearchEntry(
            id: "system.reset.videoAudio",
            tab: .system,
            title: "Downloaded video audio",
            subtitle: "in Reset & Cleanup",
            keywords: [
                "clear downloads", "delete downloads", "youtube", "video", "downloaded audio",
                "wipe",
            ],
            cardAnchor: "system.reset"
        ),
        SettingsSearchEntry(
            id: "system.reset.voiceProfiles",
            tab: .system,
            title: "Voice profiles",
            subtitle: "in Reset & Cleanup",
            keywords: [
                "delete voices", "clear voices", "voiceprint", "speakers", "wipe", "biometric",
            ],
            cardAnchor: "system.reset"
        ),
        SettingsSearchEntry(
            id: "system.reset.meetingAudio",
            tab: .system,
            title: "Meeting audio",
            subtitle: "in Reset & Cleanup",
            keywords: ["clear meeting audio", "delete meeting audio", "recordings", "wipe"],
            cardAnchor: "system.reset"
        ),
        SettingsSearchEntry(
            id: "system.reset.lifetimeStats",
            tab: .system,
            title: "Lifetime voice stats",
            subtitle: "in Reset & Cleanup",
            keywords: [
                "stats", "counters", "reset counters", "total words", "longest dictation",
                "lifetime",
            ],
            cardAnchor: "system.reset"
        ),
    ]

    /// Returns entries whose title, subtitle, or keywords contain the
    /// (trimmed, lowercased) query as a substring. Empty / whitespace
    /// queries return an empty array — callers should fall back to the
    /// tabbed view in that case rather than rendering an empty results
    /// list.
    public static func matches(
        _ query: String, hasEnrolledVoices: Bool = false, speakerDetectionEnabled: Bool = true
    ) -> [SettingsSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return visibleEntries(
            hasEnrolledVoices: hasEnrolledVoices,
            speakerDetectionEnabled: speakerDetectionEnabled,
            voiceProfilesAvailable: AppFeatures.isVoiceProfilesAvailable()
        ).filter { $0.matches(trimmed) }
    }
}
