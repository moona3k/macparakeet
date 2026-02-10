import Foundation

public struct STTResult: Sendable {
    public let text: String
    public let words: [TimestampedWord]

    public init(text: String, words: [TimestampedWord] = []) {
        self.text = text
        self.words = words
    }
}

public struct TimestampedWord: Sendable {
    public let word: String
    public let startMs: Int
    public let endMs: Int
    public let confidence: Double

    public init(word: String, startMs: Int, endMs: Int, confidence: Double) {
        self.word = word
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
    }
}
