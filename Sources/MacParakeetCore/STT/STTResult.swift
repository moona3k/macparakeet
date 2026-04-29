import Foundation

public struct STTResult: Sendable {
    public let text: String
    public let words: [TimestampedWord]
    public let language: String?
    /// The engine that produced this result. Authoritative — set by the
    /// engine implementation rather than read from settings, so a mid-job
    /// preference toggle cannot mislabel an in-flight transcription.
    public let engine: SpeechEnginePreference
    /// Engine-specific model variant (e.g. the Whisper model id). `nil`
    /// for engines without a meaningful variant choice (Parakeet).
    public let engineVariant: String?

    public init(
        text: String,
        words: [TimestampedWord] = [],
        language: String? = nil,
        engine: SpeechEnginePreference = .parakeet,
        engineVariant: String? = nil
    ) {
        self.text = text
        self.words = words
        self.language = language
        self.engine = engine
        self.engineVariant = engineVariant
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
