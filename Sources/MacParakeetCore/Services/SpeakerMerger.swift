import Foundation

/// Merges word-level timestamps with speaker diarization segments.
/// Both inputs must be sorted by start time.
public enum SpeakerMerger {

    /// Assign a speakerId to each word based on which diarization segment has the most time overlap.
    /// Tie-breaking: earlier segment wins. No overlap → speakerId = nil.
    public static func mergeWordTimestampsWithSpeakers(
        words: [WordTimestamp],
        segments: [SpeakerSegment]
    ) -> [WordTimestamp] {
        guard !words.isEmpty, !segments.isEmpty else { return words }

        // Defensive sort — FluidAudio returns chronological output, but
        // the algorithm requires sorted input for correctness.
        let sortedWords = words.sorted { $0.startMs < $1.startMs }
        let sortedSegments = segments.sorted { $0.startMs < $1.startMs }

        var result = sortedWords
        var segIdx = 0

        for (wordIdx, word) in sortedWords.enumerated() {
            // Advance segIdx past segments that end before this word starts.
            // Since words are sorted by startMs, segments before segIdx can never
            // overlap any future word either, making this amortized O(W+S).
            while segIdx < sortedSegments.count && sortedSegments[segIdx].endMs <= word.startMs {
                segIdx += 1
            }

            var bestSpeaker: String? = nil
            var bestOverlap = 0

            // Scan forward from segIdx to find the segment with most overlap
            var s = segIdx
            while s < sortedSegments.count {
                let seg = sortedSegments[s]
                if seg.startMs >= word.endMs {
                    break // No more segments can overlap this word
                }

                let overlapStart = max(word.startMs, seg.startMs)
                let overlapEnd = min(word.endMs, seg.endMs)
                let overlap = overlapEnd - overlapStart

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = seg.speakerId
                }
                // Tie-breaking: earlier segment wins (first match with same overlap kept)

                s += 1
            }

            if bestOverlap > 0 {
                result[wordIdx].speakerId = bestSpeaker
            }
        }

        return result
    }
}
