import Foundation

/// Timing of one endpointed hands-free utterance, for tuning the endpointer.
/// It carries no text or audio: durations, a merge count, and the word overlap
/// with the previous delivered command (a repeat signal).
public struct VoiceControlSpeechTurnMetrics: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case delivered, empty, failed }

    public var at: Date
    public var outcome: Outcome
    /// First to last voiced audio, merged segments and their gaps included.
    public var speechMilliseconds: Int
    /// Silences of at least 200 ms between voiced audio, in order. A gap that
    /// ended a segment which was then merged appears here at its full length.
    public var pauseMilliseconds: [Int]
    public var mergedSegments: Int
    /// Trailing silence the endpointer waited for before ending the segment.
    public var endpointSilenceMilliseconds: Int
    /// From the endpoint to the transcript (or empty/failed result).
    public var transcribeMilliseconds: Int
    /// From the previous delivered transcript to this utterance's detected onset.
    public var sincePreviousMilliseconds: Int?
    /// Word-set overlap (Jaccard, 0...1) with the previous delivered transcript.
    public var overlapWithPrevious: Double?

    enum CodingKeys: String, CodingKey {
        case at = "ts", outcome
        case speechMilliseconds = "speech_ms", pauseMilliseconds = "pauses_ms", mergedSegments = "merged_segments"
        case endpointSilenceMilliseconds = "endpoint_silence_ms", transcribeMilliseconds = "transcribe_ms"
        case sincePreviousMilliseconds = "since_previous_ms", overlapWithPrevious = "overlap_previous"
    }

    static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 0 }
        return (Double(lhs.intersection(rhs).count) / Double(union.count) * 100).rounded() / 100
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

/// Measures voiced spans and pauses on the 16 kHz sample clock. The session
/// feeds every hands-free chunk, then reports endpointer begin/end signals.
struct VoiceControlSpeechTimer: Sendable {
    struct Span: Sendable, Equatable {
        var speechSamples: Int
        var pauseSamples: [Int]
        var segments: Int
    }

    static let minimumPauseSamples = 3_200

    private var clock = 0
    private var runStart: Int?
    private var lastVoicedEnd: Int?
    private var turnStart: Int?
    private var segmentEnd: Int?
    private var pauses: [Int] = []
    private var segments = 0

    mutating func reset() { self = Self() }

    /// `inTurn` is whether speech has begun and not yet ended before this chunk.
    mutating func consume(count: Int, voiced: Bool, inTurn: Bool) {
        let start = clock
        clock += count
        guard voiced else { return }
        if let last = lastVoicedEnd, start - last < Self.minimumPauseSamples {
            // The same voiced run continues.
        } else {
            if inTurn, let last = lastVoicedEnd { pauses.append(start - last) }
            runStart = start
        }
        lastVoicedEnd = clock
    }

    /// `continuing` is true when the new speech was merged into an ended segment.
    mutating func began(continuing: Bool) {
        let onset = runStart ?? clock
        if continuing, let end = segmentEnd, turnStart != nil {
            pauses.append(onset - end)
            segments += 1
        } else {
            turnStart = onset
            pauses = []
            segments = 1
        }
        segmentEnd = nil
    }

    mutating func ended() -> Span {
        segmentEnd = lastVoicedEnd
        let end = lastVoicedEnd ?? clock
        return Span(speechSamples: max(0, end - (turnStart ?? end)), pauseSamples: pauses, segments: segments)
    }
}
