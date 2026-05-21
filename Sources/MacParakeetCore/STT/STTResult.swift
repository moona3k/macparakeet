import Foundation

public struct STTResult: Sendable {
    public let text: String
    public let words: [TimestampedWord]
    /// Engine-emitted sentence/phrase segments with their own start/end
    /// timestamps. Whisper emits these natively; Parakeet does not (the
    /// FluidAudio API returns only token timings), so this stays `nil` on
    /// the Parakeet path. When present, the subtitle exporter uses these
    /// directly as cue boundaries instead of running NLTokenizer.
    public let segments: [STTSegment]?
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
        segments: [STTSegment]? = nil,
        language: String? = nil,
        engine: SpeechEnginePreference = .parakeet,
        engineVariant: String? = nil
    ) {
        self.text = text
        self.words = words
        self.segments = segments
        self.language = language
        self.engine = engine
        self.engineVariant = engineVariant
    }
}

/// One engine-emitted segment — a sentence or phrase the STT model decided
/// belongs together. Whisper produces these natively. Used by the subtitle
/// exporter as authoritative cue boundaries when present.
///
/// Distinct from the `TranscriptSegment` in `TranscriptSegmenter`: that type
/// is a heuristic post-STT grouping used for transcript display. This type
/// is the raw engine output.
public struct STTSegment: Sendable, Codable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
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
