import Foundation

/// A reading-oriented paragraph assembled from timestamped transcript words.
public struct TranscriptParagraph: Sendable, Equatable {
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

/// Builds stable, human-readable paragraphs without changing stored transcript segments.
public enum TranscriptParagraphBuilder {
    private static let maximumSentenceCount = 3
    private static let maximumWordCount = 80
    private static let paragraphPauseMs = 2_500

    public static func build(from words: [WordTimestamp]) -> [TranscriptParagraph] {
        guard let firstWord = words.first else { return [] }

        var paragraphs: [TranscriptParagraph] = []
        var paragraphWords: [String] = []
        var paragraphStartMs = firstWord.startMs
        var paragraphEndMs = firstWord.endMs
        var paragraphSpeakerId = firstWord.speakerId
        var sentenceCount = 0

        func appendParagraph() {
            guard !paragraphWords.isEmpty else { return }
            paragraphs.append(
                TranscriptParagraph(
                    startMs: paragraphStartMs,
                    endMs: paragraphEndMs,
                    text: paragraphWords.joined(separator: " "),
                    speakerId: paragraphSpeakerId
                )
            )
        }

        for (index, word) in words.enumerated() {
            let speakerChanged = word.speakerId.map { $0 != paragraphSpeakerId } ?? false
            let pauseReached = word.startMs - paragraphEndMs >= paragraphPauseMs
            if !paragraphWords.isEmpty, speakerChanged || pauseReached {
                appendParagraph()
                paragraphWords.removeAll(keepingCapacity: true)
                paragraphStartMs = word.startMs
                paragraphSpeakerId = word.speakerId ?? paragraphSpeakerId
                sentenceCount = 0
            }

            paragraphWords.append(word.word)
            paragraphEndMs = word.endMs

            if endsSentence(word.word) {
                sentenceCount += 1
            }

            guard sentenceCount >= maximumSentenceCount || paragraphWords.count >= maximumWordCount else {
                continue
            }

            appendParagraph()
            paragraphWords.removeAll(keepingCapacity: true)
            sentenceCount = 0

            if words.indices.contains(index + 1) {
                let nextWord = words[index + 1]
                paragraphStartMs = nextWord.startMs
                paragraphEndMs = nextWord.endMs
                paragraphSpeakerId = nextWord.speakerId ?? paragraphSpeakerId
            }
        }

        appendParagraph()
        return paragraphs
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let lastCharacter = word.last else { return false }
        return lastCharacter == "." || lastCharacter == "!" || lastCharacter == "?"
    }
}
