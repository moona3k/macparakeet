import Foundation

/// Pure decision + copy for the "transcription finished" signal (a chime, plus
/// a banner when the app is backgrounded). Kept free of AppKit and
/// UserNotifications so it is fully unit-testable; the app layer turns a
/// non-`nil` `Content` into a `SoundManager` chime and an optional banner.
///
/// One Settings toggle (`notifyOnTranscriptionComplete`, default on) governs
/// both surfaces — when it is off these factory methods return `nil` and the
/// app layer does nothing.
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

    static func wordsLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "word" : "words")"
    }

    static func filesLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files")"
    }
}
