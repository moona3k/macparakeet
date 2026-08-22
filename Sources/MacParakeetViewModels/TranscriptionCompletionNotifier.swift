import Foundation

/// Pure decision + copy for the "transcription finished" signal (a chime, plus
/// a banner when the app is backgrounded). Kept free of AppKit and
/// UserNotifications so it is fully unit-testable; the app layer turns a
/// non-`nil` `Content` into a `SoundManager` chime and an optional banner.
///
/// Each factory takes its governing Settings toggle as `settingEnabled` and
/// returns `nil` when it is off, leaving the app layer nothing to do. Two
/// independent toggles feed these: `notifyOnTranscriptionComplete` (the
/// Transcriptions tab, governing file/URL work) drives `singleContent` and
/// `batchContent`, while `notifyOnMeetingEnd` (the Meetings tab) drives
/// `meetingReadyContent` and the meeting-end path below. Do not wire a caller
/// to the other tab's preference.
public enum TranscriptionCompletionNotifier {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Signal content for a single completed transcription, or `nil` when the
    /// user has turned completion notifications off.
    public static func singleContent(
        settingEnabled: Bool,
        transcriptName: String,
        wordCount: Int
    ) -> Content? {
        guard settingEnabled else { return nil }
        return Content(
            title: transcriptName,
            body: "Transcription complete \u{00B7} \(wordsLabel(wordCount))"
        )
    }

    /// Signal content for a finished batch, or `nil` when notifications are off.
    /// A batch always signals once, on drain — never per intermediate file.
    public static func batchContent(
        settingEnabled: Bool,
        completed: Int,
        failed: Int
    ) -> Content? {
        guard settingEnabled else { return nil }
        if failed == 0 {
            return Content(
                title: "Transcriptions complete",
                body: "\(filesLabel(completed)) transcribed"
            )
        }
        return Content(
            title: "Transcriptions finished with errors",
            body: "\(completed) transcribed \u{00B7} \(failed) failed"
        )
    }

    /// Signal content for a meeting that finished transcribing while the
    /// "Open app when meeting ends" setting is off — the quiet path's only
    /// signal that the transcript is ready, or `nil` when the user has also
    /// turned the meeting-end notification off.
    ///
    /// `settingEnabled` is the meetings-scoped `notifyOnMeetingEnd` toggle,
    /// deliberately independent of `notifyOnTranscriptionComplete`: that
    /// toggle lives in the Transcriptions settings tab and governs file/URL
    /// work, while both meeting-end toggles live together in Meetings.
    public static func meetingReadyContent(
        settingEnabled: Bool,
        meetingTitle: String,
        wordCount: Int
    ) -> Content? {
        guard settingEnabled else { return nil }
        return Content(
            title: meetingTitle,
            body: "Meeting transcript ready \u{00B7} \(wordsLabel(wordCount))"
        )
    }

    /// How the app should respond when a meeting's transcript finishes.
    public enum MeetingEndPresentation: Equatable, Sendable {
        case openApp
        case quietSignal(Content)
        case silent

        /// Whether the app may select the finished transcript as the current
        /// one. Only the auto-open path may: selection is what drives a
        /// mounted main window to Library, so selecting on a quiet path would
        /// pull a foregrounded user off whatever tab they were working in —
        /// the exact interruption "Open app when meeting ends = off" exists to
        /// prevent. Selection cannot be undone after the fact, so callers must
        /// consult this *before* presenting the completed transcription.
        public var selectsTranscription: Bool {
            if case .openApp = self { return true }
            return false
        }
    }

    /// Decide the meeting-end behavior from the two meetings-tab settings.
    /// Auto-open wins: while it is on, the app opens on the transcript and no
    /// banner is needed, so `notifyEnabled` only matters on the quiet path.
    public static func meetingEndPresentation(
        openAppEnabled: Bool,
        notifyEnabled: Bool,
        meetingTitle: String,
        wordCount: Int
    ) -> MeetingEndPresentation {
        if openAppEnabled { return .openApp }
        guard
            let content = meetingReadyContent(
                settingEnabled: notifyEnabled,
                meetingTitle: meetingTitle,
                wordCount: wordCount
            )
        else { return .silent }
        return .quietSignal(content)
    }

    /// Critical meeting finalization failure content. This is independent of
    /// the completion-notification preference because it tells the user saved
    /// audio needs action, not that background work succeeded.
    public static func meetingNeedsRetryContent() -> Content {
        Content(
            title: "Meeting needs a retry",
            body: "Your audio is saved."
        )
    }

    static func wordsLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "word" : "words")"
    }

    static func filesLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files")"
    }
}
