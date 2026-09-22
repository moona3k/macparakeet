import Foundation

/// Pure decision + copy for the "transcription finished" signal (a chime, plus
/// a banner when the app is backgrounded). Kept free of AppKit and
/// UserNotifications so it is fully unit-testable; the app layer turns a
/// non-`nil` `Content` into a `SoundManager` chime and an optional banner.
///
/// Success factories take their governing Settings toggle as `settingEnabled`
/// and return `nil` when it is off. `notifyOnTranscriptionComplete` governs
/// file/URL work through `singleContent` and `batchContent`, while the independent
/// `notifyOnMeetingEnd` toggle governs `meetingReadyContent`. Failure content
/// remains independent of these success-notification preferences.
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
    /// toggle lives in the Transcription settings card and governs file/URL
    /// work, while both meeting-end toggles live in the Meeting Recording card.
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
