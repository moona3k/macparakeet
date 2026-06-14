import Foundation

public struct LabeledSegment: Codable, Equatable, Sendable {
    public let speakerId: String
    public let startMs: Int
    public let endMs: Int

    public init(speakerId: String, startMs: Int, endMs: Int) {
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
    }

    public init(_ segment: SpeakerSegment) {
        self.init(
            speakerId: segment.speakerId,
            startMs: segment.startMs,
            endMs: segment.endMs
        )
    }
}

public struct DERBreakdown: Codable, Equatable, Sendable {
    public let missedMs: Int
    public let falseAlarmMs: Int
    public let confusionMs: Int
    public let totalReferenceMs: Int
    public let der: Double

    public init(
        missedMs: Int,
        falseAlarmMs: Int,
        confusionMs: Int,
        totalReferenceMs: Int,
        der: Double
    ) {
        self.missedMs = missedMs
        self.falseAlarmMs = falseAlarmMs
        self.confusionMs = confusionMs
        self.totalReferenceMs = totalReferenceMs
        self.der = der
    }
}

public enum DiarizationMetrics {
    private struct Interval {
        let startMs: Int
        let endMs: Int
    }

    private struct SpeakerPair: Hashable {
        let reference: String
        let hypothesis: String
    }

    /// Approximate NIST md-eval-style DER with no collar. Overlap regions are
    /// simplified to binary speech coverage instead of scoring every active
    /// reference/hypothesis speaker independently.
    public static func der(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> DERBreakdown {
        let reference = normalized(reference)
        let hypothesis = normalized(hypothesis)
        let mapping = greedySpeakerMapping(reference: reference, hypothesis: hypothesis)
        let totalReferenceMs = speechDuration(reference)

        var missedMs = 0
        var falseAlarmMs = 0
        var confusionMs = 0

        let boundaries = sortedBoundaries(reference + hypothesis)
        guard boundaries.count >= 2 else {
            let falseAlarmMs = speechDuration(hypothesis)
            return DERBreakdown(
                missedMs: totalReferenceMs,
                falseAlarmMs: falseAlarmMs,
                confusionMs: 0,
                totalReferenceMs: totalReferenceMs,
                der: derValue(
                    missedMs: totalReferenceMs,
                    falseAlarmMs: falseAlarmMs,
                    confusionMs: 0,
                    totalReferenceMs: totalReferenceMs
                )
            )
        }

        for index in 0..<(boundaries.count - 1) {
            let startMs = boundaries[index]
            let endMs = boundaries[index + 1]
            guard endMs > startMs else { continue }

            let activeReference = activeSpeakers(in: reference, startMs: startMs, endMs: endMs)
            let activeHypothesis = activeSpeakers(in: hypothesis, startMs: startMs, endMs: endMs)
            let durationMs = endMs - startMs

            if activeReference.isEmpty {
                if !activeHypothesis.isEmpty {
                    falseAlarmMs += durationMs
                }
                continue
            }

            if activeHypothesis.isEmpty {
                missedMs += durationMs
                continue
            }

            let hasMappedMatch = activeHypothesis.contains { hypothesisSpeaker in
                guard let referenceSpeaker = mapping[hypothesisSpeaker] else { return false }
                return activeReference.contains(referenceSpeaker)
            }

            if !hasMappedMatch {
                confusionMs += durationMs
            }
        }

        return DERBreakdown(
            missedMs: missedMs,
            falseAlarmMs: falseAlarmMs,
            confusionMs: confusionMs,
            totalReferenceMs: totalReferenceMs,
            der: derValue(
                missedMs: missedMs,
                falseAlarmMs: falseAlarmMs,
                confusionMs: confusionMs,
                totalReferenceMs: totalReferenceMs
            )
        )
    }

    public static func coverage(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> Double {
        let referenceIntervals = mergedIntervals(normalized(reference))
        let totalReferenceMs = referenceIntervals.reduce(0) { $0 + ($1.endMs - $1.startMs) }
        guard totalReferenceMs > 0 else { return 0 }

        let hypothesisIntervals = mergedIntervals(normalized(hypothesis))
        let coveredMs = overlapDuration(referenceIntervals, hypothesisIntervals)
        return Double(coveredMs) / Double(totalReferenceMs)
    }

    public static func speakerCountDelta(expected: Int, detected: Int) -> Int {
        detected - expected
    }

    public static func speakerCountDelta(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> Int {
        speakerCountDelta(
            expected: speakerCount(reference),
            detected: speakerCount(hypothesis)
        )
    }

    public static func speakerCount(_ segments: [LabeledSegment]) -> Int {
        Set(normalized(segments).map(\.speakerId)).count
    }

    public static func speechDuration(_ segments: [LabeledSegment]) -> Int {
        mergedIntervals(normalized(segments)).reduce(0) { total, interval in
            total + interval.endMs - interval.startMs
        }
    }

    public static func speechDuration(_ segments: [SpeakerSegment]) -> Int {
        speechDuration(segments.map(LabeledSegment.init))
    }

    // JER is intentionally omitted for this baseline because a correct
    // implementation needs per-speaker union/intersection scoring under the
    // same overlap policy as DER, and DER+coverage are enough for slice 1.

    private static func derValue(
        missedMs: Int,
        falseAlarmMs: Int,
        confusionMs: Int,
        totalReferenceMs: Int
    ) -> Double {
        guard totalReferenceMs > 0 else { return 0 }
        return Double(missedMs + falseAlarmMs + confusionMs) / Double(totalReferenceMs)
    }

    private static func greedySpeakerMapping(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> [String: String] {
        var overlaps: [SpeakerPair: Int] = [:]

        for ref in reference {
            for hyp in hypothesis {
                let overlap = overlapDuration(ref, hyp)
                if overlap > 0 {
                    overlaps[SpeakerPair(reference: ref.speakerId, hypothesis: hyp.speakerId), default: 0] += overlap
                }
            }
        }

        let pairs = overlaps.map { pair, overlap in
            (pair: pair, overlap: overlap)
        }.sorted { lhs, rhs in
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            if lhs.pair.reference != rhs.pair.reference {
                return lhs.pair.reference < rhs.pair.reference
            }
            return lhs.pair.hypothesis < rhs.pair.hypothesis
        }

        var usedReferences = Set<String>()
        var usedHypotheses = Set<String>()
        var mapping: [String: String] = [:]

        for entry in pairs {
            guard !usedReferences.contains(entry.pair.reference),
                  !usedHypotheses.contains(entry.pair.hypothesis)
            else {
                continue
            }
            usedReferences.insert(entry.pair.reference)
            usedHypotheses.insert(entry.pair.hypothesis)
            mapping[entry.pair.hypothesis] = entry.pair.reference
        }

        return mapping
    }

    private static func normalized(_ segments: [LabeledSegment]) -> [LabeledSegment] {
        segments
            .filter { !$0.speakerId.isEmpty && $0.endMs > $0.startMs }
            .sorted {
                if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
                if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
                return $0.speakerId < $1.speakerId
            }
    }

    private static func sortedBoundaries(_ segments: [LabeledSegment]) -> [Int] {
        Set(segments.flatMap { [$0.startMs, $0.endMs] }).sorted()
    }

    private static func activeSpeakers(
        in segments: [LabeledSegment],
        startMs: Int,
        endMs: Int
    ) -> Set<String> {
        Set(segments.compactMap { segment in
            segment.startMs < endMs && segment.endMs > startMs ? segment.speakerId : nil
        })
    }

    private static func overlapDuration(_ lhs: LabeledSegment, _ rhs: LabeledSegment) -> Int {
        max(0, min(lhs.endMs, rhs.endMs) - max(lhs.startMs, rhs.startMs))
    }

    private static func mergedIntervals(_ segments: [LabeledSegment]) -> [Interval] {
        let intervals = segments.map { Interval(startMs: $0.startMs, endMs: $0.endMs) }
            .sorted {
                if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
                return $0.endMs < $1.endMs
            }

        var merged: [Interval] = []
        for interval in intervals where interval.endMs > interval.startMs {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }

            if interval.startMs <= last.endMs {
                merged[merged.count - 1] = Interval(
                    startMs: last.startMs,
                    endMs: max(last.endMs, interval.endMs)
                )
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func overlapDuration(_ lhs: [Interval], _ rhs: [Interval]) -> Int {
        var lhsIndex = 0
        var rhsIndex = 0
        var total = 0

        while lhsIndex < lhs.count && rhsIndex < rhs.count {
            let lhsInterval = lhs[lhsIndex]
            let rhsInterval = rhs[rhsIndex]
            total += max(0, min(lhsInterval.endMs, rhsInterval.endMs) - max(lhsInterval.startMs, rhsInterval.startMs))

            if lhsInterval.endMs < rhsInterval.endMs {
                lhsIndex += 1
            } else {
                rhsIndex += 1
            }
        }

        return total
    }
}
