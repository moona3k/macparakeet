import Foundation

// MARK: - Types

/// A contiguous group of words forming a segment with a timestamp.
public struct TranscriptSegment: Sendable {
    public let startMs: Int
    public let text: String
    public let speakerId: String?

    public init(startMs: Int, text: String, speakerId: String?) {
        self.startMs = startMs
        self.text = text
        self.speakerId = speakerId
    }
}

/// A speaker turn is a consecutive sequence of segments from the same speaker.
public struct SpeakerTurn: Sendable {
    public let speakerId: String
    public let speakerLabel: String
    public let segments: [TranscriptSegment]

    public init(speakerId: String, speakerLabel: String, segments: [TranscriptSegment]) {
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.segments = segments
    }
}

/// Per-speaker statistics computed from diarization segments and word timestamps.
public struct SpeakerStatistics: Sendable {
    public var speakingTimeMs: Int = 0
    public var wordCount: Int = 0

    public init(speakingTimeMs: Int = 0, wordCount: Int = 0) {
        self.speakingTimeMs = speakingTimeMs
        self.wordCount = wordCount
    }
}

// MARK: - TranscriptSegmenter

public enum TranscriptSegmenter {
    /// Group word timestamps into segments based on punctuation, gaps, and speaker changes.
    public static func groupIntoSegments(words: [WordTimestamp]) -> [TranscriptSegment] {
        segmentBoundaries(words: words).map {
            TranscriptSegment(startMs: $0.startMs, text: $0.text, speakerId: $0.speakerId)
        }
    }

    /// Materialize durable segments with IDs and word-index ranges into `words`.
    public static func materializeSegments(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        idGenerator: () -> UUID = { UUID() }
    ) -> [TranscriptSegmentRecord] {
        var speakersByID: [String: String] = [:]
        for speaker in speakers ?? [] where speakersByID[speaker.id] == nil {
            speakersByID[speaker.id] = speaker.label
        }
        return segmentBoundaries(words: words).map { boundary in
            TranscriptSegmentRecord(
                id: idGenerator(),
                startMs: boundary.startMs,
                endMs: boundary.endMs,
                speakerId: boundary.speakerId,
                speakerLabel: speakerLabel(for: boundary.speakerId, speakersByID: speakersByID),
                text: boundary.text,
                wordRange: boundary.wordRange
            )
        }
    }

    /// Group segments into consecutive speaker turns.
    public static func groupIntoSpeakerTurns(
        segments: [TranscriptSegment],
        speakerLabelProvider: (String?) -> String
    ) -> [SpeakerTurn] {
        guard !segments.isEmpty else { return [] }

        var turns: [SpeakerTurn] = []
        var currentSpeaker = segments[0].speakerId ?? ""
        var currentSegments: [TranscriptSegment] = []

        for segment in segments {
            let segSpeaker = segment.speakerId ?? currentSpeaker
            if segSpeaker != currentSpeaker && !currentSegments.isEmpty {
                turns.append(SpeakerTurn(
                    speakerId: currentSpeaker,
                    speakerLabel: speakerLabelProvider(currentSpeaker),
                    segments: currentSegments
                ))
                currentSegments = []
                currentSpeaker = segSpeaker
            }
            currentSpeaker = segSpeaker
            currentSegments.append(segment)
        }

        if !currentSegments.isEmpty {
            turns.append(SpeakerTurn(
                speakerId: currentSpeaker,
                speakerLabel: speakerLabelProvider(currentSpeaker),
                segments: currentSegments
            ))
        }

        return turns
    }

    /// Compute per-speaker statistics from diarization segments and word timestamps.
    public static func computeSpeakerStats(
        diarizationSegments: [DiarizationSegmentRecord]?,
        wordTimestamps: [WordTimestamp]?
    ) -> [String: SpeakerStatistics] {
        var stats: [String: SpeakerStatistics] = [:]

        // Speaking time from diarization segments
        if let segments = diarizationSegments {
            for segment in segments {
                stats[segment.speakerId, default: SpeakerStatistics()].speakingTimeMs += (segment.endMs - segment.startMs)
            }
        }

        // Word count from word timestamps
        if let words = wordTimestamps {
            for word in words {
                if let speakerId = word.speakerId {
                    stats[speakerId, default: SpeakerStatistics()].wordCount += 1
                }
            }
        }

        return stats
    }

    /// Sanitize a filename for use as an export stem (remove disallowed chars).
    public static func sanitizedExportStem(from fileName: String) -> String {
        let rawStem = (fileName as NSString).deletingPathExtension
        let disallowed = CharacterSet(charactersIn: "/:\\\0")
        let parts = rawStem.components(separatedBy: disallowed)
        let normalized = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "transcript" : normalized
    }

    private static func segmentBoundaries(words: [WordTimestamp]) -> [SegmentBoundary] {
        guard !words.isEmpty else { return [] }

        var boundaries: [SegmentBoundary] = []
        var currentWords: [String] = []
        var segmentStartIndex = 0
        var segmentStart = words[0].startMs
        var segmentSpeaker = words[0].speakerId

        func appendBoundary(endIndexExclusive: Int, speakerId: String?) {
            guard !currentWords.isEmpty else { return }
            let lastWord = words[endIndexExclusive - 1]
            boundaries.append(SegmentBoundary(
                startMs: segmentStart,
                endMs: lastWord.endMs,
                text: currentWords.joined(separator: " "),
                speakerId: speakerId,
                wordRange: TranscriptSegmentWordRange(
                    startIndex: segmentStartIndex,
                    endIndexExclusive: endIndexExclusive
                )
            ))
        }

        for (i, word) in words.enumerated() {
            let isLast = i == words.count - 1
            let speakerChanged = word.speakerId != nil && word.speakerId != segmentSpeaker

            // Flush current segment on speaker change before adding this word.
            if speakerChanged && !currentWords.isEmpty {
                appendBoundary(endIndexExclusive: i, speakerId: segmentSpeaker)
                currentWords = []
                segmentStartIndex = i
                segmentStart = word.startMs
                segmentSpeaker = word.speakerId
            }

            currentWords.append(word.word)
            // Track speaker (nil words inherit current speaker).
            if word.speakerId != nil {
                segmentSpeaker = word.speakerId
            }

            let endsWithPunctuation = word.word.last.map { ".!?".contains($0) } ?? false
            let hasLongGap = i + 1 < words.count && (words[i + 1].startMs - word.endMs) > 1500
            let tooLong = currentWords.count >= 40

            if isLast || (endsWithPunctuation && currentWords.count >= 3) || hasLongGap || tooLong {
                appendBoundary(endIndexExclusive: i + 1, speakerId: segmentSpeaker)
                currentWords = []
                if !isLast {
                    segmentStartIndex = i + 1
                    segmentStart = words[i + 1].startMs
                    segmentSpeaker = words[i + 1].speakerId ?? segmentSpeaker
                }
            }
        }

        return boundaries
    }

    private static func speakerLabel(
        for speakerId: String?,
        speakersByID: [String: String]
    ) -> String {
        guard let speakerId else { return "Unknown Speaker" }
        if let label = speakersByID[speakerId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        if let source = AudioSource(rawValue: speakerId) {
            return source.displayLabel
        }
        return speakerId
    }
}

private struct SegmentBoundary {
    let startMs: Int
    let endMs: Int
    let text: String
    let speakerId: String?
    let wordRange: TranscriptSegmentWordRange
}
