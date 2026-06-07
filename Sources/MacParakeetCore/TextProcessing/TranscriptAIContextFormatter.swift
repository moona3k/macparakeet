import Foundation

public enum TranscriptAIContextFormatter {
    public static func format(
        transcription: Transcription,
        mode: TranscriptAIContextMode = .richTranscript
    ) -> String {
        switch mode {
        case .plainTranscript:
            return preferredText(transcription)
        case .richTranscript:
            return richText(transcription) ?? preferredText(transcription)
        }
    }

    private static func preferredText(_ transcription: Transcription) -> String {
        (transcription.cleanTranscript ?? transcription.rawTranscript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func editedTranscriptText(_ transcription: Transcription) -> String? {
        guard transcription.isTranscriptEdited,
              let text = transcription.cleanTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private static func richText(_ transcription: Transcription) -> String? {
        if let edited = editedTranscriptText(transcription) {
            return edited
        }

        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            return nil
        }

        let cues = TranscriptCueBuilder.build(from: words)
        guard !cues.isEmpty else { return nil }

        return cues.map { cue in
            let timestamp = "[\(readableTimestamp(ms: cue.startMs))]"
            if let label = speakerLabel(for: cue.speakerId, in: transcription.speakers) {
                return "\(timestamp) \(label): \(cue.text)"
            }
            return "\(timestamp) \(cue.text)"
        }
        .joined(separator: "\n")
    }

    private static func speakerLabel(for speakerId: String?, in speakers: [SpeakerInfo]?) -> String? {
        guard let speakerId else { return nil }
        guard let speakers, !speakers.isEmpty else { return speakerId }
        return speakers.first(where: { $0.id == speakerId })?.label ?? speakerId
    }

    private static func readableTimestamp(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
