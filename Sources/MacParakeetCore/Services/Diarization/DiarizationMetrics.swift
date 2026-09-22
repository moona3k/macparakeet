import Foundation

public struct LabeledSegment: Codable, Equatable, Sendable {
    public let recordingId: String?
    public let speakerId: String
    public let startMs: Int
    public let endMs: Int

    public init(recordingId: String? = nil, speakerId: String, startMs: Int, endMs: Int) {
        self.recordingId = recordingId
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

public struct DiarizationScoringOptions: Codable, Equatable, Sendable {
    public var collarMs: Int
    public var skipOverlap: Bool

    public static let `default` = Self()

    public init(collarMs: Int = 0, skipOverlap: Bool = false) {
        self.collarMs = max(0, collarMs)
        self.skipOverlap = skipOverlap
    }
}

public struct DERBreakdown: Codable, Equatable, Sendable {
    public let missedMs: Int
    public let falseAlarmMs: Int
    public let confusionMs: Int
    public let totalReferenceMs: Int
    public let der: Double
    public let collarMs: Int
    public let skipOverlap: Bool

    public init(
        missedMs: Int,
        falseAlarmMs: Int,
        confusionMs: Int,
        totalReferenceMs: Int,
        der: Double,
        collarMs: Int = 0,
        skipOverlap: Bool = false
    ) {
        self.missedMs = missedMs
        self.falseAlarmMs = falseAlarmMs
        self.confusionMs = confusionMs
        self.totalReferenceMs = totalReferenceMs
        self.der = der
        self.collarMs = collarMs
        self.skipOverlap = skipOverlap
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

    /// Lightweight DER scorer with exact millisecond regions and optimal speaker mapping.
    /// Overlap regions use speaker-time accounting unless `skipOverlap` is set.
    public static func der(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> DERBreakdown {
        der(reference: reference, hypothesis: hypothesis, options: .default)
    }

    public static func der(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        options: DiarizationScoringOptions
    ) -> DERBreakdown {
        let reference = normalized(reference)
        let hypothesis = normalized(hypothesis)
        let regions = scoredRegions(reference: reference, hypothesis: hypothesis, options: options)
        let mapping = optimalSpeakerMapping(reference: reference, hypothesis: hypothesis, regions: regions)

        var missedMs = 0
        var falseAlarmMs = 0
        var confusionMs = 0
        var totalReferenceMs = 0

        for region in regions {
            let activeReference = activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs)
            let activeHypothesis = activeSpeakers(in: hypothesis, startMs: region.startMs, endMs: region.endMs)
            let referenceCount = activeReference.count
            let hypothesisCount = activeHypothesis.count
            let durationMs = region.endMs - region.startMs

            let correctCount = activeHypothesis.reduce(into: Set<String>()) { matches, hypothesisSpeaker in
                guard let referenceSpeaker = mapping[hypothesisSpeaker],
                      activeReference.contains(referenceSpeaker)
                else {
                    return
                }
                matches.insert(referenceSpeaker)
            }
            .count

            missedMs += max(0, referenceCount - hypothesisCount) * durationMs
            falseAlarmMs += max(0, hypothesisCount - referenceCount) * durationMs
            confusionMs += max(0, min(referenceCount, hypothesisCount) - correctCount) * durationMs
            totalReferenceMs += referenceCount * durationMs
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
            ),
            collarMs: options.collarMs,
            skipOverlap: options.skipOverlap
        )
    }

    public static func coverage(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> Double {
        coverage(reference: reference, hypothesis: hypothesis, options: .default)
    }

    public static func coverage(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        options: DiarizationScoringOptions
    ) -> Double {
        let reference = normalized(reference)
        let hypothesis = normalized(hypothesis)
        let regions = scoredRegions(reference: reference, hypothesis: hypothesis, options: options)

        var totalReferenceMs = 0
        var coveredMs = 0
        for region in regions {
            let hasReference = !activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs).isEmpty
            guard hasReference else { continue }
            let durationMs = region.endMs - region.startMs
            totalReferenceMs += durationMs
            if !activeSpeakers(in: hypothesis, startMs: region.startMs, endMs: region.endMs).isEmpty {
                coveredMs += durationMs
            }
        }

        guard totalReferenceMs > 0 else { return 0 }
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

    private static func optimalSpeakerMapping(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        regions: [Interval]
    ) -> [String: String] {
        let referenceSpeakers = Set(reference.map(\.speakerId)).sorted()
        let hypothesisSpeakers = Set(hypothesis.map(\.speakerId)).sorted()
        guard !referenceSpeakers.isEmpty, !hypothesisSpeakers.isEmpty else { return [:] }

        let overlaps = speakerOverlaps(reference: reference, hypothesis: hypothesis, regions: regions)
        guard let maxOverlap = overlaps.values.max(), maxOverlap > 0 else { return [:] }

        let matrixSize = max(referenceSpeakers.count, hypothesisSpeakers.count)
        var costs = Array(
            repeating: Array(repeating: maxOverlap, count: matrixSize),
            count: matrixSize
        )

        for hypothesisIndex in hypothesisSpeakers.indices {
            for referenceIndex in referenceSpeakers.indices {
                let pair = SpeakerPair(
                    reference: referenceSpeakers[referenceIndex],
                    hypothesis: hypothesisSpeakers[hypothesisIndex]
                )
                costs[hypothesisIndex][referenceIndex] = maxOverlap - (overlaps[pair] ?? 0)
            }
        }

        let assignment = minimumCostAssignment(costs)
        var mapping: [String: String] = [:]
        for hypothesisIndex in hypothesisSpeakers.indices {
            let referenceIndex = assignment[hypothesisIndex]
            guard referenceIndex >= 0, referenceIndex < referenceSpeakers.count else { continue }

            let pair = SpeakerPair(
                reference: referenceSpeakers[referenceIndex],
                hypothesis: hypothesisSpeakers[hypothesisIndex]
            )
            guard (overlaps[pair] ?? 0) > 0 else { continue }
            mapping[hypothesisSpeakers[hypothesisIndex]] = referenceSpeakers[referenceIndex]
        }

        return mapping
    }

    private static func speakerOverlaps(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        regions: [Interval]
    ) -> [SpeakerPair: Int] {
        var overlaps: [SpeakerPair: Int] = [:]

        for region in regions {
            let durationMs = region.endMs - region.startMs
            let activeReference = activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs)
            let activeHypothesis = activeSpeakers(in: hypothesis, startMs: region.startMs, endMs: region.endMs)
            for referenceSpeaker in activeReference {
                for hypothesisSpeaker in activeHypothesis {
                    overlaps[SpeakerPair(reference: referenceSpeaker, hypothesis: hypothesisSpeaker), default: 0] += durationMs
                }
            }
        }

        return overlaps
    }

    private static func minimumCostAssignment(_ costs: [[Int]]) -> [Int] {
        let rowCount = costs.count
        guard rowCount > 0 else { return [] }
        let columnCount = costs[0].count
        precondition(columnCount > 0)
        precondition(costs.allSatisfy { $0.count == columnCount })

        // Hungarian assignment in O(n^3). The scorer builds a square matrix
        // with zero-overlap dummy rows/columns so every real speaker can still
        // be left unmatched when that is the optimal DER alignment.
        var rowPotential = Array(repeating: 0, count: rowCount + 1)
        var columnPotential = Array(repeating: 0, count: columnCount + 1)
        var matchedRowForColumn = Array(repeating: 0, count: columnCount + 1)
        var previousColumn = Array(repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            matchedRowForColumn[0] = row
            var currentColumn = 0
            var minCost = Array(repeating: Int.max, count: columnCount + 1)
            var usedColumns = Array(repeating: false, count: columnCount + 1)

            repeat {
                usedColumns[currentColumn] = true
                let currentRow = matchedRowForColumn[currentColumn]
                var delta = Int.max
                var nextColumn = 0

                for column in 1...columnCount where !usedColumns[column] {
                    let reducedCost = costs[currentRow - 1][column - 1]
                        - rowPotential[currentRow]
                        - columnPotential[column]
                    if reducedCost < minCost[column] {
                        minCost[column] = reducedCost
                        previousColumn[column] = currentColumn
                    }
                    if minCost[column] < delta {
                        delta = minCost[column]
                        nextColumn = column
                    }
                }

                for column in 0...columnCount {
                    if usedColumns[column] {
                        rowPotential[matchedRowForColumn[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minCost[column] -= delta
                    }
                }

                currentColumn = nextColumn
            } while matchedRowForColumn[currentColumn] != 0

            repeat {
                let priorColumn = previousColumn[currentColumn]
                matchedRowForColumn[currentColumn] = matchedRowForColumn[priorColumn]
                currentColumn = priorColumn
            } while currentColumn != 0
        }

        var assignment = Array(repeating: -1, count: rowCount)
        for column in 1...columnCount {
            let row = matchedRowForColumn[column]
            if row > 0 {
                assignment[row - 1] = column - 1
            }
        }

        return assignment
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

    private static func scoredRegions(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        options: DiarizationScoringOptions
    ) -> [Interval] {
        var boundaries = Set((reference + hypothesis).flatMap { [$0.startMs, $0.endMs] })
        let collarIntervals = collarIntervals(reference: reference, collarMs: options.collarMs)
        for interval in collarIntervals {
            boundaries.insert(interval.startMs)
            boundaries.insert(interval.endMs)
        }

        let sorted = boundaries.sorted()
        guard sorted.count >= 2 else { return [] }

        var regions: [Interval] = []
        var collarIndex = 0
        for index in 0..<(sorted.count - 1) {
            let region = Interval(startMs: sorted[index], endMs: sorted[index + 1])
            guard region.endMs > region.startMs else { continue }
            while collarIndex < collarIntervals.count,
                  collarIntervals[collarIndex].endMs <= region.startMs {
                collarIndex += 1
            }
            if collarIndex < collarIntervals.count,
               overlapDuration(region, collarIntervals[collarIndex]) > 0 {
                continue
            }
            if options.skipOverlap,
               activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs).count > 1 {
                continue
            }
            regions.append(region)
        }
        return regions
    }

    private static func mergedIntervals(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            return $0.endMs < $1.endMs
        }

        var merged: [Interval] = []
        for interval in sorted where interval.endMs > interval.startMs {
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

    private static func collarIntervals(reference: [LabeledSegment], collarMs: Int) -> [Interval] {
        guard collarMs > 0 else { return [] }
        let beforeMs = collarMs / 2
        let afterMs = collarMs - beforeMs

        let intervals = reference.flatMap { segment in
            [
                Interval(startMs: max(0, segment.startMs - beforeMs), endMs: segment.startMs + afterMs),
                Interval(startMs: max(0, segment.endMs - beforeMs), endMs: segment.endMs + afterMs),
            ]
        }
        .filter { $0.endMs > $0.startMs }

        return mergedIntervals(intervals)
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

    private static func overlapDuration(_ lhs: Interval, _ rhs: Interval) -> Int {
        max(0, min(lhs.endMs, rhs.endMs) - max(lhs.startMs, rhs.startMs))
    }

    private static func mergedIntervals(_ segments: [LabeledSegment]) -> [Interval] {
        mergedIntervals(segments.map { Interval(startMs: $0.startMs, endMs: $0.endMs) })
    }
}
