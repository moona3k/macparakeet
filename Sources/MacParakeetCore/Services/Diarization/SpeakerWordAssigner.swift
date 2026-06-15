import Foundation

public enum WordSpeakerAssignmentMethod: String, Codable, Sendable, Equatable {
    case directOverlap
    case fallbackNearest
    case sourceOnly
    case unassigned
}

public struct WordSpeakerAssignmentSummary: Codable, Sendable, Equatable {
    public let totalWords: Int
    public let directOverlapWords: Int
    public let fallbackNearestWords: Int
    public let sourceOnlyWords: Int
    public let unassignedWords: Int
    public let fallbackToleranceMs: Int
    public let ambiguityMarginMs: Int
    public let minFallbackQualityScore: Double

    public init(
        totalWords: Int,
        directOverlapWords: Int,
        fallbackNearestWords: Int,
        sourceOnlyWords: Int,
        unassignedWords: Int,
        fallbackToleranceMs: Int,
        ambiguityMarginMs: Int,
        minFallbackQualityScore: Double
    ) {
        self.totalWords = totalWords
        self.directOverlapWords = directOverlapWords
        self.fallbackNearestWords = fallbackNearestWords
        self.sourceOnlyWords = sourceOnlyWords
        self.unassignedWords = unassignedWords
        self.fallbackToleranceMs = fallbackToleranceMs
        self.ambiguityMarginMs = ambiguityMarginMs
        self.minFallbackQualityScore = minFallbackQualityScore
    }
}

public struct SpeakerWordAssignmentResult: Sendable, Equatable {
    public let words: [WordTimestamp]
    public let summary: WordSpeakerAssignmentSummary

    public init(words: [WordTimestamp], summary: WordSpeakerAssignmentSummary) {
        self.words = words
        self.summary = summary
    }
}

public struct SpeakerWordAssigner: Sendable {
    public let fallbackToleranceMs: Int
    public let ambiguityMarginMs: Int
    public let minFallbackQualityScore: Double

    public init(
        fallbackToleranceMs: Int = 250,
        ambiguityMarginMs: Int = 150,
        minFallbackQualityScore: Double = 0.60
    ) {
        self.fallbackToleranceMs = fallbackToleranceMs
        self.ambiguityMarginMs = ambiguityMarginMs
        self.minFallbackQualityScore = minFallbackQualityScore
    }

    public func assign(
        words: [WordTimestamp],
        segments: [SpeakerSegment],
        sourceOnlySpeakerId: String? = nil
    ) -> SpeakerWordAssignmentResult {
        var counts: [WordSpeakerAssignmentMethod: Int] = [
            .directOverlap: 0,
            .fallbackNearest: 0,
            .sourceOnly: 0,
            .unassigned: 0,
        ]
        let eligibleSegments = segments
            .filter {
                isEligible(segment: $0, sourceOnlySpeakerId: sourceOnlySpeakerId)
            }
            .sorted {
                if $0.startMs == $1.startMs {
                    if $0.endMs == $1.endMs {
                        return $0.speakerId < $1.speakerId
                    }
                    return $0.endMs < $1.endMs
                }
                return $0.startMs < $1.startMs
            }
        let sortedWords = words.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startMs == rhs.element.startMs {
                    if lhs.element.endMs == rhs.element.endMs {
                        return lhs.offset < rhs.offset
                    }
                    return lhs.element.endMs < rhs.element.endMs
                }
                return lhs.element.startMs < rhs.element.startMs
            }

        var assignedWords: [WordTimestamp] = []
        assignedWords.reserveCapacity(words.count)
        var firstCandidateIndex = 0

        for (_, word) in sortedWords {
            let assignment = assignment(
                for: word,
                candidateSegments: candidateSegments(
                    for: word,
                    segments: eligibleSegments,
                    firstCandidateIndex: &firstCandidateIndex
                ),
                sourceOnlySpeakerId: sourceOnlySpeakerId
            )
            counts[assignment.method, default: 0] += 1
            var assignedWord = word
            assignedWord.speakerId = assignment.speakerId
            assignedWords.append(assignedWord)
        }

        let summary = WordSpeakerAssignmentSummary(
            totalWords: words.count,
            directOverlapWords: counts[.directOverlap, default: 0],
            fallbackNearestWords: counts[.fallbackNearest, default: 0],
            sourceOnlyWords: counts[.sourceOnly, default: 0],
            unassignedWords: counts[.unassigned, default: 0],
            fallbackToleranceMs: fallbackToleranceMs,
            ambiguityMarginMs: ambiguityMarginMs,
            minFallbackQualityScore: minFallbackQualityScore
        )
        return SpeakerWordAssignmentResult(words: assignedWords, summary: summary)
    }

    private func assignment(
        for word: WordTimestamp,
        candidateSegments: ArraySlice<SpeakerSegment>,
        sourceOnlySpeakerId: String?
    ) -> (speakerId: String?, method: WordSpeakerAssignmentMethod) {
        guard isEligible(word: word, sourceOnlySpeakerId: sourceOnlySpeakerId) else {
            return (word.speakerId, sourceOnlySpeakerId == nil ? .unassigned : .sourceOnly)
        }

        let directOverlap = directOverlapSpeaker(for: word, segments: candidateSegments)
        if directOverlap.isAmbiguous {
            return sourceOnlyAssignment(sourceOnlySpeakerId)
        }
        if let speakerId = directOverlap.speakerId {
            return (speakerId, .directOverlap)
        }

        if let speakerId = nearestFallbackSpeaker(for: word, segments: candidateSegments) {
            return (speakerId, .fallbackNearest)
        }

        return sourceOnlyAssignment(sourceOnlySpeakerId)
    }

    private func candidateSegments(
        for word: WordTimestamp,
        segments: [SpeakerSegment],
        firstCandidateIndex: inout Int
    ) -> ArraySlice<SpeakerSegment> {
        let windowMs = max(0, fallbackToleranceMs + ambiguityMarginMs)
        let earliestEndMs = word.startMs - windowMs
        while firstCandidateIndex < segments.count,
              segments[firstCandidateIndex].endMs < earliestEndMs {
            firstCandidateIndex += 1
        }

        let latestStartMs = word.endMs + windowMs
        var endIndex = firstCandidateIndex
        while endIndex < segments.count,
              segments[endIndex].startMs <= latestStartMs {
            endIndex += 1
        }

        return segments[firstCandidateIndex..<endIndex]
    }

    private func sourceOnlyAssignment(_ sourceOnlySpeakerId: String?) -> (speakerId: String?, method: WordSpeakerAssignmentMethod) {
        if let sourceOnlySpeakerId {
            return (sourceOnlySpeakerId, .sourceOnly)
        }
        return (nil, .unassigned)
    }

    private func directOverlapSpeaker(
        for word: WordTimestamp,
        segments: ArraySlice<SpeakerSegment>
    ) -> (speakerId: String?, isAmbiguous: Bool) {
        let overlapsBySpeaker = segments.reduce(into: [String: Int]()) { overlaps, segment in
            let overlap = overlapMs(word: word, segment: segment)
            guard overlap > 0 else { return }
            overlaps[segment.speakerId, default: 0] += overlap
        }
        let ranked = overlapsBySpeaker
            .map { (speakerId: $0.key, overlapMs: $0.value) }
            .sorted { lhs, rhs in
                if lhs.overlapMs == rhs.overlapMs {
                    return lhs.speakerId < rhs.speakerId
                }
                return lhs.overlapMs > rhs.overlapMs
            }
        guard let best = ranked.first else {
            return (nil, false)
        }
        if let runnerUp = ranked.dropFirst().first,
           best.overlapMs - runnerUp.overlapMs <= ambiguityMarginMs {
            return (nil, true)
        }
        return (best.speakerId, false)
    }

    private func nearestFallbackSpeaker(for word: WordTimestamp, segments: ArraySlice<SpeakerSegment>) -> String? {
        let candidates = segments.map { segment in
            (segment: segment, gapMs: gapMs(word: word, segment: segment))
        }
        guard let best = candidates.min(by: { lhs, rhs in
            if lhs.gapMs == rhs.gapMs {
                if lhs.segment.startMs == rhs.segment.startMs {
                    return lhs.segment.speakerId < rhs.segment.speakerId
                }
                return lhs.segment.startMs < rhs.segment.startMs
            }
            return lhs.gapMs < rhs.gapMs
        }) else {
            return nil
        }
        guard best.gapMs <= fallbackToleranceMs else { return nil }
        guard best.segment.qualityScore >= minFallbackQualityScore else { return nil }

        let ambiguousRunnerUp = candidates.contains { candidate in
            candidate.segment.speakerId != best.segment.speakerId
                && candidate.gapMs - best.gapMs <= ambiguityMarginMs
        }
        guard !ambiguousRunnerUp else { return nil }
        return best.segment.speakerId
    }

    private func overlapMs(word: WordTimestamp, segment: SpeakerSegment) -> Int {
        max(0, min(word.endMs, segment.endMs) - max(word.startMs, segment.startMs))
    }

    private func gapMs(word: WordTimestamp, segment: SpeakerSegment) -> Int {
        if word.endMs <= segment.startMs {
            return segment.startMs - word.endMs
        }
        if segment.endMs <= word.startMs {
            return word.startMs - segment.endMs
        }
        return 0
    }

    private func isEligible(word: WordTimestamp, sourceOnlySpeakerId: String?) -> Bool {
        guard let sourceOnlySpeakerId else { return true }
        guard let assignmentSource = SpeakerID.source(for: sourceOnlySpeakerId) else { return true }
        guard let wordSource = SpeakerID.source(for: word.speakerId) else { return true }
        return wordSource == assignmentSource
    }

    private func isEligible(segment: SpeakerSegment, sourceOnlySpeakerId: String?) -> Bool {
        guard let sourceOnlySpeakerId else { return true }
        guard let assignmentSource = SpeakerID.source(for: sourceOnlySpeakerId) else { return true }
        guard let segmentSource = SpeakerID.source(for: segment.speakerId) else { return true }
        return segmentSource == assignmentSource
    }
}
