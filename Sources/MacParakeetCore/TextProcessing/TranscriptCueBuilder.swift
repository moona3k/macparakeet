import Foundation

public struct TranscriptCue: Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let speakerId: String?

    public init(startMs: Int, endMs: Int, text: String, speakerId: String?) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
    }
}

public enum TranscriptCueBuilder {
    /// Groups word timestamps into compact cues suitable for subtitles,
    /// playback overlays, and AI context.
    public static func build(from words: [WordTimestamp]) -> [TranscriptCue] {
        guard !words.isEmpty else { return [] }

        var cues: [TranscriptCue] = []
        var currentWords: [String] = []
        var cueStartMs = words[0].startMs
        var cueEndMs = words[0].endMs
        var cueSpeakerId = words[0].speakerId

        for (index, word) in words.enumerated() {
            let speakerChanged = !currentWords.isEmpty && word.speakerId != cueSpeakerId
            if speakerChanged {
                cues.append(TranscriptCue(
                    startMs: cueStartMs,
                    endMs: cueEndMs,
                    text: currentWords.joined(separator: " "),
                    speakerId: cueSpeakerId
                ))
                currentWords = []
                cueStartMs = word.startMs
                cueSpeakerId = word.speakerId
            }

            currentWords.append(word.word)
            cueEndMs = word.endMs

            let isLast = index == words.count - 1
            let endsWithPunctuation = word.word.last.map { ".!?".contains($0) } ?? false
            let hasLongGap = !isLast && (words[index + 1].startMs - word.endMs) > 800
            let tooManyWords = currentWords.count >= 12
            let tooLong = (cueEndMs - cueStartMs) > 7000

            if isLast || (endsWithPunctuation && currentWords.count >= 2) || hasLongGap || tooManyWords || tooLong {
                cues.append(TranscriptCue(
                    startMs: cueStartMs,
                    endMs: cueEndMs,
                    text: currentWords.joined(separator: " "),
                    speakerId: cueSpeakerId
                ))
                currentWords = []
                if !isLast {
                    cueStartMs = words[index + 1].startMs
                    cueSpeakerId = words[index + 1].speakerId
                }
            }
        }

        return cues
    }
}
