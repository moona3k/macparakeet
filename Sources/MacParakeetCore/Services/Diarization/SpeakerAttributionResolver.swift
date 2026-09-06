import CryptoKit
import Foundation

public struct SpeakerEditableSegmentID: Codable, Hashable, Sendable {
    public let transcriptionId: UUID
    public let transcriptFingerprint: TranscriptFingerprint
    public let wordRange: TranscriptSegmentWordRange

    public init(
        transcriptionId: UUID,
        transcriptFingerprint: TranscriptFingerprint,
        wordRange: TranscriptSegmentWordRange
    ) {
        self.transcriptionId = transcriptionId
        self.transcriptFingerprint = transcriptFingerprint
        self.wordRange = wordRange
    }
}

public struct SpeakerEditableSegment: Identifiable, Sendable, Equatable {
    public let id: SpeakerEditableSegmentID
    public let anchorTranscriptSegmentIDs: [UUID]
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let assignment: SpeakerAssignment
    public let automaticSpeakerIDs: [String]
    public let sourceProvenance: [AudioSource]
    public let isManuallySplit: Bool

    public init(
        id: SpeakerEditableSegmentID,
        anchorTranscriptSegmentIDs: [UUID],
        startMs: Int,
        endMs: Int,
        text: String,
        assignment: SpeakerAssignment,
        automaticSpeakerIDs: [String],
        sourceProvenance: [AudioSource],
        isManuallySplit: Bool
    ) {
        self.id = id
        self.anchorTranscriptSegmentIDs = anchorTranscriptSegmentIDs
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.assignment = assignment
        self.automaticSpeakerIDs = automaticSpeakerIDs
        self.sourceProvenance = sourceProvenance
        self.isManuallySplit = isManuallySplit
    }

    public var wordRange: TranscriptSegmentWordRange { id.wordRange }
}

public struct EffectiveSpeakerRun: Sendable, Equatable {
    public let wordRange: TranscriptSegmentWordRange
    public let assignment: SpeakerAssignment
}

public struct EffectiveDurableSegment: Identifiable, Sendable, Equatable {
    public let base: TranscriptSegmentRecord
    public let speakerRuns: [EffectiveSpeakerRun]

    public var id: UUID { base.id }
}

public struct EffectiveSpeakerTurn: Identifiable, Sendable, Equatable {
    public let id: SpeakerEditableSegmentID
    public let assignment: SpeakerAssignment
    public let speakerLabel: String
    public let segments: [SpeakerEditableSegment]
}

public struct SpeakerWordProvenance: Sendable, Equatable {
    public let wordIndex: Int
    public let automaticSpeakerID: String?
    public let audioSource: AudioSource?
}

public enum UnresolvedSpeakerCorrectionReason: String, Sendable, Equatable {
    case wrongFingerprint
    case missingAnchor
    case rangeMismatch
    case invalidBoundary
    case missingSpeaker
    case invalidSpeaker
    case protectedSpeaker
    case reassignmentRequired
    case overlappingTargets
    case malformedHistory
}

public struct UnresolvedSpeakerCorrection: Sendable, Equatable {
    public let correctionID: UUID
    public let reason: UnresolvedSpeakerCorrectionReason
}

public struct EffectiveSpeakerAttribution: Sendable, Equatable {
    public let fingerprint: TranscriptFingerprint
    public let correctionRevision: Int
    public let speakers: [SpeakerInfo]
    public let words: [WordTimestamp]
    public let diarizationSegments: [DiarizationSegmentRecord]
    public let durableSegments: [EffectiveDurableSegment]
    public let editableSegments: [SpeakerEditableSegment]
    public let turns: [EffectiveSpeakerTurn]
    public let statistics: [String: SpeakerStatistics]
    public let provenanceByWord: [SpeakerWordProvenance]
    public let unresolvedCorrections: [UnresolvedSpeakerCorrection]
}

public enum SpeakerAttributionResolver {
    public static func fingerprint(for transcription: Transcription) -> TranscriptFingerprint {
        let payload = FingerprintPayload(transcription: transcription)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            preconditionFailure("Speaker attribution fingerprint encoding failed")
        }
        let digest = SHA256.hash(data: data)
        return TranscriptFingerprint(
            rawValue: digest.map { String(format: "%02x", $0) }.joined()
        )
    }

    public static func resolve(
        transcription: Transcription,
        corrections: [SpeakerCorrection] = [],
        state: SpeakerCorrectionState? = nil
    ) -> EffectiveSpeakerAttribution {
        let fingerprint = fingerprint(for: transcription)
        let provenance = wordProvenance(transcription.wordTimestamps ?? [])
        let baseline = ReplayState(transcription: transcription)
        var replay = baseline
        var unresolved: [UnresolvedSpeakerCorrection] = []

        let chain = activeCorrectionChain(
            corrections: corrections,
            state: state,
            fingerprint: fingerprint,
            unresolved: &unresolved
        )
        for correction in chain {
            apply(
                correction,
                transcription: transcription,
                fingerprint: fingerprint,
                baseline: baseline,
                replay: &replay,
                unresolved: &unresolved
            )
        }

        let effectiveWords = effectiveWords(
            from: transcription.wordTimestamps ?? [],
            assignments: replay.assignments
        )
        let editableSegments = makeEditableSegments(
            transcription: transcription,
            fingerprint: fingerprint,
            assignments: replay.assignments,
            splitBoundaries: replay.splitBoundaries,
            provenance: provenance
        )
        let diarizationSegments =
            replay.assignmentChanged
            ? deriveDiarizationSegments(from: effectiveWords)
            : (transcription.diarizationSegments ?? [])

        return EffectiveSpeakerAttribution(
            fingerprint: fingerprint,
            correctionRevision: state?.revision ?? 0,
            speakers: replay.speakers,
            words: effectiveWords,
            diarizationSegments: diarizationSegments,
            durableSegments: makeEffectiveDurableSegments(
                transcription.transcriptSegments ?? [],
                assignments: replay.assignments
            ),
            editableSegments: editableSegments,
            turns: makeTurns(editableSegments, speakers: replay.speakers),
            statistics: TranscriptSegmenter.computeSpeakerStats(
                diarizationSegments: diarizationSegments,
                wordTimestamps: effectiveWords
            ),
            provenanceByWord: provenance,
            unresolvedCorrections: unresolved
        )
    }

    private static func activeCorrectionChain(
        corrections: [SpeakerCorrection],
        state: SpeakerCorrectionState?,
        fingerprint: TranscriptFingerprint,
        unresolved: inout [UnresolvedSpeakerCorrection]
    ) -> [SpeakerCorrection] {
        guard !corrections.isEmpty else { return [] }
        if let state, state.transcriptFingerprint != fingerprint.rawValue {
            unresolved.append(
                contentsOf: corrections.map {
                    UnresolvedSpeakerCorrection(correctionID: $0.id, reason: .wrongFingerprint)
                })
            return []
        }

        if let state, corrections.contains(where: { $0.transcriptionId != state.transcriptionId }) {
            unresolved.append(
                contentsOf: corrections.map {
                    UnresolvedSpeakerCorrection(correctionID: $0.id, reason: .malformedHistory)
                })
            return []
        }
        var byID: [UUID: SpeakerCorrection] = [:]
        for correction in corrections {
            guard byID.updateValue(correction, forKey: correction.id) == nil else {
                unresolved.append(.init(correctionID: correction.id, reason: .malformedHistory))
                return []
            }
        }
        let inferredHead =
            corrections
            .filter { $0.branchState == .current }
            .max { $0.sequence < $1.sequence }?.id
        var cursor = state?.headId ?? inferredHead
        var visited = Set<UUID>()
        var reversed: [SpeakerCorrection] = []

        while let id = cursor {
            guard visited.insert(id).inserted, let correction = byID[id] else {
                unresolved.append(
                    UnresolvedSpeakerCorrection(
                        correctionID: id,
                        reason: .malformedHistory
                    ))
                return []
            }
            reversed.append(correction)
            cursor = correction.parentId
        }
        return reversed.reversed()
    }

    private static func apply(
        _ correction: SpeakerCorrection,
        transcription: Transcription,
        fingerprint: TranscriptFingerprint,
        baseline: ReplayState,
        replay: inout ReplayState,
        unresolved: inout [UnresolvedSpeakerCorrection]
    ) {
        guard correction.transcriptionId == transcription.id,
            correction.transcriptFingerprint == fingerprint
        else {
            unresolved.append(.init(correctionID: correction.id, reason: .wrongFingerprint))
            return
        }
        guard correction.operation == correction.payload.operation else {
            unresolved.append(.init(correctionID: correction.id, reason: .malformedHistory))
            return
        }

        func reject(_ reason: UnresolvedSpeakerCorrectionReason) {
            unresolved.append(.init(correctionID: correction.id, reason: reason))
        }

        switch correction.payload {
        case .rename(let speakerID, let label):
            guard let index = replay.speakers.firstIndex(where: { $0.id == speakerID }) else {
                reject(.missingSpeaker)
                return
            }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                reject(.invalidSpeaker)
                return
            }
            replay.speakers[index].label = trimmed

        case .add(let speaker, let targets):
            guard validManualSpeaker(speaker), !replay.speakers.contains(where: { $0.id == speaker.id }) else {
                reject(.invalidSpeaker)
                return
            }
            if let reason = validateTargets(
                targets,
                transcription: transcription,
                splitBoundaries: replay.splitBoundaries,
                requireCurrentRanges: true
            ) {
                reject(reason)
                return
            }
            replay.speakers.append(
                SpeakerInfo(
                    id: speaker.id,
                    label: speaker.label.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            set(targets, to: .speaker(id: speaker.id), replay: &replay)

        case .assign(let targets, let assignment):
            if case .speaker(let id) = assignment,
                !replay.speakers.contains(where: { $0.id == id })
            {
                reject(.missingSpeaker)
                return
            }
            if let reason = validateTargets(
                targets,
                transcription: transcription,
                splitBoundaries: replay.splitBoundaries,
                requireCurrentRanges: true
            ) {
                reject(reason)
                return
            }
            set(targets, to: assignment, replay: &replay)

        case .split(let target, let wordIndex):
            if let reason = validateTargets(
                [target],
                transcription: transcription,
                splitBoundaries: replay.splitBoundaries,
                requireCurrentRanges: true
            ) {
                reject(reason)
                return
            }
            guard wordIndex > target.wordRange.startIndex,
                wordIndex < target.wordRange.endIndexExclusive
            else {
                reject(.invalidBoundary)
                return
            }
            replay.splitBoundaries.insert(wordIndex)

        case .removeSplit(let boundary, let joinedAssignment):
            guard replay.splitBoundaries.contains(boundary.wordIndex),
                targetAnchorsAreValid(boundary.target, transcription: transcription),
                boundary.wordIndex > boundary.target.wordRange.startIndex,
                boundary.wordIndex < boundary.target.wordRange.endIndexExclusive
            else {
                reject(.invalidBoundary)
                return
            }
            let ranges = editableRanges(
                words: transcription.wordTimestamps ?? [],
                splitBoundaries: replay.splitBoundaries
            )
            guard
                let rightIndex = ranges.firstIndex(where: {
                    $0.startIndex == boundary.wordIndex
                }), rightIndex > 0
            else {
                reject(.invalidBoundary)
                return
            }
            let left = ranges[rightIndex - 1]
            let right = ranges[rightIndex]
            let joinedRange = TranscriptSegmentWordRange(
                startIndex: left.startIndex,
                endIndexExclusive: right.endIndexExclusive
            )
            guard joinedRange == boundary.target.wordRange else {
                reject(.invalidBoundary)
                return
            }
            let leftAssignment = replay.assignments[left.startIndex]
            let rightAssignment = replay.assignments[right.startIndex]
            if leftAssignment != rightAssignment, joinedAssignment == nil {
                reject(.reassignmentRequired)
                return
            }
            if let joinedAssignment {
                if case .speaker(let id) = joinedAssignment,
                    !replay.speakers.contains(where: { $0.id == id })
                {
                    reject(.missingSpeaker)
                    return
                }
                setRange(joinedRange, to: joinedAssignment, replay: &replay)
            }
            replay.splitBoundaries.remove(boundary.wordIndex)

        case .merge(let sourceSpeakerID, let targetSpeakerID):
            guard sourceSpeakerID != targetSpeakerID,
                replay.speakers.contains(where: { $0.id == sourceSpeakerID }),
                replay.speakers.contains(where: { $0.id == targetSpeakerID })
            else {
                reject(.missingSpeaker)
                return
            }
            guard !isProtectedSourceSpeaker(sourceSpeakerID) else {
                reject(.protectedSpeaker)
                return
            }
            replaceSpeaker(sourceSpeakerID, with: .speaker(id: targetSpeakerID), replay: &replay)
            replay.speakers.removeAll { $0.id == sourceSpeakerID }

        case .remove(let speakerID, let reassignment):
            guard replay.speakers.contains(where: { $0.id == speakerID }) else {
                reject(.missingSpeaker)
                return
            }
            guard !isProtectedSourceSpeaker(speakerID) else {
                reject(.protectedSpeaker)
                return
            }
            let isUsed = replay.assignments.contains(.speaker(id: speakerID))
            guard !isUsed || reassignment != nil else {
                reject(.reassignmentRequired)
                return
            }
            if let reassignment {
                if case .speaker(let id) = reassignment,
                    (id == speakerID || !replay.speakers.contains(where: { $0.id == id }))
                {
                    reject(.missingSpeaker)
                    return
                }
                replaceSpeaker(speakerID, with: reassignment, replay: &replay)
            }
            replay.speakers.removeAll { $0.id == speakerID }

        case .reset:
            replay = baseline
        }
    }

    private static func validateTargets(
        _ targets: [SpeakerCorrectionTarget],
        transcription: Transcription,
        splitBoundaries: Set<Int>,
        requireCurrentRanges: Bool
    ) -> UnresolvedSpeakerCorrectionReason? {
        let sorted = targets.sorted { $0.wordRange.startIndex < $1.wordRange.startIndex }
        for (index, target) in sorted.enumerated() {
            guard targetAnchorsAreValid(target, transcription: transcription) else {
                return .missingAnchor
            }
            if index > 0,
                sorted[index - 1].wordRange.endIndexExclusive > target.wordRange.startIndex
            {
                return .overlappingTargets
            }
        }
        if requireCurrentRanges {
            let current = Set(
                editableRanges(
                    words: transcription.wordTimestamps ?? [],
                    splitBoundaries: splitBoundaries
                ))
            guard targets.allSatisfy({ current.contains($0.wordRange) }) else {
                return .rangeMismatch
            }
        }
        return nil
    }

    private static func targetAnchorsAreValid(
        _ target: SpeakerCorrectionTarget,
        transcription: Transcription
    ) -> Bool {
        let words = transcription.wordTimestamps ?? []
        guard target.wordRange.startIndex >= 0,
            target.wordRange.startIndex < target.wordRange.endIndexExclusive,
            target.wordRange.endIndexExclusive <= words.count
        else { return false }
        let expected = (transcription.transcriptSegments ?? []).compactMap { segment -> UUID? in
            rangesOverlap(segment.wordRange, target.wordRange) ? segment.id : nil
        }
        return !expected.isEmpty && expected == target.anchorTranscriptSegmentIDs
    }

    private static func rangesOverlap(
        _ lhs: TranscriptSegmentWordRange,
        _ rhs: TranscriptSegmentWordRange
    ) -> Bool {
        lhs.startIndex < rhs.endIndexExclusive && rhs.startIndex < lhs.endIndexExclusive
    }

    private static func editableRanges(
        words: [WordTimestamp],
        splitBoundaries: Set<Int>
    ) -> [TranscriptSegmentWordRange] {
        TranscriptSegmenter.editableWordRanges(words: words).flatMap { base in
            let boundaries =
                splitBoundaries
                .filter { $0 > base.startIndex && $0 < base.endIndexExclusive }
                .sorted()
            var start = base.startIndex
            var result: [TranscriptSegmentWordRange] = []
            for boundary in boundaries {
                result.append(.init(startIndex: start, endIndexExclusive: boundary))
                start = boundary
            }
            result.append(.init(startIndex: start, endIndexExclusive: base.endIndexExclusive))
            return result
        }
    }

    private static func set(
        _ targets: [SpeakerCorrectionTarget],
        to assignment: SpeakerAssignment,
        replay: inout ReplayState
    ) {
        for target in targets {
            setRange(target.wordRange, to: assignment, replay: &replay)
        }
    }

    private static func setRange(
        _ range: TranscriptSegmentWordRange,
        to assignment: SpeakerAssignment,
        replay: inout ReplayState
    ) {
        for index in range.startIndex..<range.endIndexExclusive {
            replay.assignments[index] = assignment
        }
        replay.assignmentChanged = true
    }

    private static func replaceSpeaker(
        _ sourceID: String,
        with assignment: SpeakerAssignment,
        replay: inout ReplayState
    ) {
        for index in replay.assignments.indices
        where replay.assignments[index] == .speaker(id: sourceID) {
            replay.assignments[index] = assignment
            replay.assignmentChanged = true
        }
    }

    private static func validManualSpeaker(_ speaker: ManualSpeaker) -> Bool {
        guard speaker.id.hasPrefix("user:"),
            UUID(uuidString: String(speaker.id.dropFirst("user:".count))) != nil
        else { return false }
        return !speaker.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isProtectedSourceSpeaker(_ id: String) -> Bool {
        AudioSource(rawValue: id) != nil
    }

    private static func effectiveWords(
        from words: [WordTimestamp],
        assignments: [SpeakerAssignment]
    ) -> [WordTimestamp] {
        zip(words, assignments).map { word, assignment in
            var result = word
            switch assignment {
            case .speaker(let id): result.speakerId = id
            case .unassigned: result.speakerId = nil
            }
            return result
        }
    }

    private static func makeEditableSegments(
        transcription: Transcription,
        fingerprint: TranscriptFingerprint,
        assignments: [SpeakerAssignment],
        splitBoundaries: Set<Int>,
        provenance: [SpeakerWordProvenance]
    ) -> [SpeakerEditableSegment] {
        let words = transcription.wordTimestamps ?? []
        let baseRanges = Set(TranscriptSegmenter.editableWordRanges(words: words))
        return editableRanges(words: words, splitBoundaries: splitBoundaries).map { range in
            let wordSlice = words[range.startIndex..<range.endIndexExclusive]
            let automaticIDs = uniqueInOrder(wordSlice.compactMap(\.speakerId))
            let sources = uniqueInOrder(
                provenance[range.startIndex..<range.endIndexExclusive].compactMap(\.audioSource)
            )
            return SpeakerEditableSegment(
                id: .init(
                    transcriptionId: transcription.id,
                    transcriptFingerprint: fingerprint,
                    wordRange: range
                ),
                anchorTranscriptSegmentIDs: anchors(for: range, in: transcription.transcriptSegments ?? []),
                startMs: wordSlice.first?.startMs ?? 0,
                endMs: wordSlice.last?.endMs ?? 0,
                text: wordSlice.map(\.word).joined(separator: " "),
                assignment: assignments[range.startIndex],
                automaticSpeakerIDs: automaticIDs,
                sourceProvenance: sources,
                isManuallySplit: !baseRanges.contains(range)
            )
        }
    }

    private static func makeEffectiveDurableSegments(
        _ segments: [TranscriptSegmentRecord],
        assignments: [SpeakerAssignment]
    ) -> [EffectiveDurableSegment] {
        segments.map { segment in
            EffectiveDurableSegment(
                base: segment,
                speakerRuns: assignmentRuns(in: segment.wordRange, assignments: assignments)
            )
        }
    }

    private static func assignmentRuns(
        in range: TranscriptSegmentWordRange,
        assignments: [SpeakerAssignment]
    ) -> [EffectiveSpeakerRun] {
        guard range.startIndex >= 0,
            range.startIndex < range.endIndexExclusive,
            range.endIndexExclusive <= assignments.count
        else { return [] }
        var start = range.startIndex
        var current = assignments[start]
        var runs: [EffectiveSpeakerRun] = []
        for index in (start + 1)..<range.endIndexExclusive where assignments[index] != current {
            runs.append(
                .init(
                    wordRange: .init(startIndex: start, endIndexExclusive: index),
                    assignment: current
                ))
            start = index
            current = assignments[index]
        }
        runs.append(
            .init(
                wordRange: .init(startIndex: start, endIndexExclusive: range.endIndexExclusive),
                assignment: current
            ))
        return runs
    }

    private static func makeTurns(
        _ segments: [SpeakerEditableSegment],
        speakers: [SpeakerInfo]
    ) -> [EffectiveSpeakerTurn] {
        let labels = Dictionary(speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        var turns: [EffectiveSpeakerTurn] = []
        for segment in segments {
            if let last = turns.last, last.assignment == segment.assignment {
                turns[turns.count - 1] = EffectiveSpeakerTurn(
                    id: last.id,
                    assignment: last.assignment,
                    speakerLabel: last.speakerLabel,
                    segments: last.segments + [segment]
                )
            } else {
                let label: String
                switch segment.assignment {
                case .speaker(let id): label = labels[id] ?? id
                case .unassigned: label = "Unassigned"
                }
                turns.append(
                    .init(
                        id: segment.id,
                        assignment: segment.assignment,
                        speakerLabel: label,
                        segments: [segment]
                    ))
            }
        }
        return turns
    }

    private static func deriveDiarizationSegments(
        from words: [WordTimestamp]
    ) -> [DiarizationSegmentRecord] {
        var result: [DiarizationSegmentRecord] = []
        for (index, word) in words.enumerated() {
            guard let speakerID = word.speakerId else { continue }
            let continuesPreviousWord =
                index > 0
                && words[index - 1].speakerId == speakerID
                && !TranscriptSegmenter.hasSignificantGap(
                    from: words[index - 1],
                    to: word
                )
            if let last = result.last,
                last.speakerId == speakerID,
                continuesPreviousWord
            {
                result[result.count - 1].endMs = max(last.endMs, word.endMs)
            } else {
                result.append(
                    .init(
                        speakerId: speakerID,
                        startMs: word.startMs,
                        endMs: word.endMs
                    ))
            }
        }
        return result
    }

    private static func wordProvenance(_ words: [WordTimestamp]) -> [SpeakerWordProvenance] {
        words.enumerated().map { index, word in
            SpeakerWordProvenance(
                wordIndex: index,
                automaticSpeakerID: word.speakerId,
                audioSource: source(for: word.speakerId)
            )
        }
    }

    private static func source(for speakerID: String?) -> AudioSource? {
        switch speakerID {
        case AudioSource.microphone.rawValue: .microphone
        case AudioSource.system.rawValue: .system
        case let id? where id.hasPrefix("\(AudioSource.system.rawValue):"): .system
        default: nil
        }
    }

    private static func anchors(
        for range: TranscriptSegmentWordRange,
        in segments: [TranscriptSegmentRecord]
    ) -> [UUID] {
        segments.compactMap { rangesOverlap($0.wordRange, range) ? $0.id : nil }
    }

    private static func uniqueInOrder<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen = Set<Element>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct ReplayState {
    var speakers: [SpeakerInfo]
    var assignments: [SpeakerAssignment]
    var splitBoundaries: Set<Int> = []
    var assignmentChanged = false

    init(transcription: Transcription) {
        speakers = transcription.speakers ?? []
        // Automatic nil timings inherit the preceding speaker, matching the
        // baseline segmenter. An explicit correction can still assign nil.
        var currentSpeakerID: String?
        assignments = (transcription.wordTimestamps ?? []).map { word in
            if let speakerID = word.speakerId { currentSpeakerID = speakerID }
            return currentSpeakerID.map { .speaker(id: $0) } ?? .unassigned
        }
    }
}

private struct FingerprintPayload: Encodable {
    let words: [FingerprintWord]
    let segments: [FingerprintSegment]

    init(transcription: Transcription) {
        words = (transcription.wordTimestamps ?? []).map(FingerprintWord.init)
        segments = (transcription.transcriptSegments ?? []).map(FingerprintSegment.init)
    }
}

private struct FingerprintWord: Encodable {
    let word: String
    let startMs: Int
    let endMs: Int
    let speakerId: String?

    init(_ word: WordTimestamp) {
        self.word = word.word
        startMs = word.startMs
        endMs = word.endMs
        speakerId = word.speakerId
    }
}

private struct FingerprintSegment: Encodable {
    let id: String
    let startMs: Int
    let endMs: Int
    let text: String
    let wordRange: TranscriptSegmentWordRange

    init(_ segment: TranscriptSegmentRecord) {
        id = segment.id.uuidString.lowercased()
        startMs = segment.startMs
        endMs = segment.endMs
        text = segment.text
        wordRange = segment.wordRange
    }
}
