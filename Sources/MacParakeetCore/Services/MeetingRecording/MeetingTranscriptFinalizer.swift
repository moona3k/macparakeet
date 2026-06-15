import Foundation

struct MeetingTranscriptFinalizer {
    struct SourceTranscript: Sendable {
        let source: AudioSource
        let result: STTResult
        let startOffsetMs: Int
    }

    struct SystemDiarization: Sendable {
        let speakers: [SpeakerInfo]
        let segments: [SpeakerSegment]
    }

    struct FinalizedTranscript: Sendable {
        let rawTranscript: String
        let words: [WordTimestamp]
        let speakers: [SpeakerInfo]
        let diarizationSegments: [DiarizationSegmentRecord]
        let durationMs: Int?
        let wordSpeakerAssignmentSummary: WordSpeakerAssignmentSummary?
    }

    static func finalize(
        sourceTranscripts: [SourceTranscript],
        systemDiarization: SystemDiarization? = nil
    ) -> FinalizedTranscript {
        let normalized = sourceTranscripts.sorted { lhs, rhs in
            if lhs.startOffsetMs == rhs.startOffsetMs {
                return sourceOrder(lhs.source) < sourceOrder(rhs.source)
            }
            return lhs.startOffsetMs < rhs.startOffsetMs
        }

        let shiftedWordsBySource = Dictionary(uniqueKeysWithValues: normalized.map { sourceTranscript in
            (
                sourceTranscript.source,
                shiftedWords(
                    for: sourceTranscript.result,
                    source: sourceTranscript.source,
                    offsetMs: sourceTranscript.startOffsetMs
                )
            )
        })

        let systemWords = shiftedWordsBySource[.system] ?? []
        let sourceReconciliation = MeetingTranscriptSourceReconciler.reconcile(
            microphoneWords: shiftedWordsBySource[.microphone] ?? [],
            systemWords: systemWords
        )
        let microphoneWords = sourceReconciliation.microphoneWords
        let finalizedSystemWords: [WordTimestamp]
        let wordSpeakerAssignmentSummary: WordSpeakerAssignmentSummary?
        if let systemDiarization {
            let assignmentResult = SpeakerWordAssigner().assign(
                words: systemWords,
                segments: systemDiarization.segments,
                sourceOnlySpeakerId: AudioSource.system.rawValue
            )
            finalizedSystemWords = assignmentResult.words
            wordSpeakerAssignmentSummary = assignmentResult.summary
        } else {
            finalizedSystemWords = systemWords
            wordSpeakerAssignmentSummary = nil
        }

        var mergedWords = microphoneWords + finalizedSystemWords

        mergedWords.sort {
            if $0.startMs == $1.startMs {
                return sourceOrder(id: $0.speakerId) < sourceOrder(id: $1.speakerId)
            }
            return $0.startMs < $1.startMs
        }

        let speakers = activeSpeakers(from: mergedWords, systemDiarization: systemDiarization)
        let diarizationSegments = buildDiarizationSegments(from: mergedWords)
        let rawTranscript = finalTranscriptText(
            from: normalized,
            mergedWords: mergedWords,
            forceMergedWordText: sourceReconciliation.removedMicrophoneWordCount > 0
        )

        return FinalizedTranscript(
            rawTranscript: rawTranscript,
            words: mergedWords,
            speakers: speakers,
            diarizationSegments: diarizationSegments,
            durationMs: mergedWords.map(\.endMs).max(),
            wordSpeakerAssignmentSummary: wordSpeakerAssignmentSummary
        )
    }

    private static func shiftedWords(
        for result: STTResult,
        source: AudioSource,
        offsetMs: Int
    ) -> [WordTimestamp] {
        result.words.map {
            WordTimestamp(
                word: $0.word,
                startMs: $0.startMs + offsetMs,
                endMs: $0.endMs + offsetMs,
                confidence: $0.confidence,
                speakerId: source.rawValue
            )
        }
    }

    private static func activeSpeakers(
        from words: [WordTimestamp],
        systemDiarization: SystemDiarization?
    ) -> [SpeakerInfo] {
        let activeIDs = Set(words.compactMap(\.speakerId))
        var speakers: [SpeakerInfo] = []

        if activeIDs.contains(AudioSource.microphone.rawValue) {
            speakers.append(SpeakerInfo(id: AudioSource.microphone.rawValue, label: AudioSource.microphone.displayLabel))
        }

        if activeIDs.contains(AudioSource.system.rawValue) {
            speakers.append(SpeakerInfo(id: AudioSource.system.rawValue, label: AudioSource.system.displayLabel))
        }

        if let systemDiarization {
            for speaker in systemDiarization.speakers where activeIDs.contains(speaker.id) {
                speakers.append(speaker)
            }
        }

        return speakers
    }

    private static func buildDiarizationSegments(from words: [WordTimestamp]) -> [DiarizationSegmentRecord] {
        guard let firstIndex = words.firstIndex(where: { $0.speakerId != nil }),
              let firstSpeaker = words[firstIndex].speakerId else {
            return []
        }

        var segments: [DiarizationSegmentRecord] = []
        var currentSpeaker = firstSpeaker
        var currentStart = words[firstIndex].startMs
        var currentEnd = words[firstIndex].endMs

        for word in words.dropFirst(firstIndex + 1) {
            guard let speakerId = word.speakerId else { continue }

            if speakerId == currentSpeaker, word.startMs - currentEnd <= 1500 {
                currentEnd = max(currentEnd, word.endMs)
            } else {
                segments.append(DiarizationSegmentRecord(
                    speakerId: currentSpeaker,
                    startMs: currentStart,
                    endMs: currentEnd
                ))
                currentSpeaker = speakerId
                currentStart = word.startMs
                currentEnd = word.endMs
            }
        }

        segments.append(DiarizationSegmentRecord(
            speakerId: currentSpeaker,
            startMs: currentStart,
            endMs: currentEnd
        ))
        return segments
    }

    private static func finalTranscriptText(
        from sourceTranscripts: [SourceTranscript],
        mergedWords: [WordTimestamp],
        forceMergedWordText: Bool = false
    ) -> String {
        if forceMergedWordText {
            return transcriptText(from: mergedWords)
        }

        let textualSourceTranscripts = sourceTranscripts.compactMap { sourceTranscript -> (source: AudioSource, text: String, hasWords: Bool)? in
            let text = sourceTranscript.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (sourceTranscript.source, text, !sourceTranscript.result.words.isEmpty)
        }
        let nonEmptyTexts = textualSourceTranscripts.map(\.text)

        if nonEmptyTexts.count == 1 {
            return nonEmptyTexts[0]
        }

        if mergedWords.isEmpty {
            return nonEmptyTexts.joined(separator: "\n\n")
        }

        if let orderedSourceTexts = orderedSourceTextsIfContiguous(
            from: textualSourceTranscripts,
            mergedWords: mergedWords
        ) {
            return orderedSourceTexts.joined(separator: " ")
        }

        return transcriptText(from: mergedWords)
    }

    private static func transcriptText(from words: [WordTimestamp]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(words.count)

        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if parts.isEmpty || shouldAttachWithoutLeadingSpace(token) {
                parts.append(token)
            } else {
                parts.append(" \(token)")
            }
        }

        return parts.joined()
    }

    private static func shouldAttachWithoutLeadingSpace(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return ",.!?;:%)]}".contains(first)
    }

    private static func sourceOrder(_ source: AudioSource) -> Int {
        switch source {
        case .microphone:
            return 0
        case .system:
            return 1
        }
    }

    private static func sourceOrder(id: String?) -> Int {
        if SpeakerID.isSourceOnly(id) {
            switch SpeakerID.source(for: id) {
            case .microphone:
                return 0
            case .system:
                return 1
            case nil:
                return 3
            }
        }

        if SpeakerID.source(for: id) == .system {
            return 2
        }
        return 3
    }

    private static func orderedSourceTextsIfContiguous(
        from sourceTranscripts: [(source: AudioSource, text: String, hasWords: Bool)],
        mergedWords: [WordTimestamp]
    ) -> [String]? {
        let runSources = contiguousSources(from: mergedWords)
        guard !runSources.isEmpty else { return nil }
        guard Set(runSources).count == runSources.count else { return nil }
        let timedTextSources = sourceTranscripts.filter(\.hasWords).map(\.source)
        guard runSources == timedTextSources else { return nil }

        var orderedTexts: [String] = []
        orderedTexts.reserveCapacity(sourceTranscripts.count)
        for sourceTranscript in sourceTranscripts {
            guard !sourceTranscript.text.isEmpty else { return nil }
            orderedTexts.append(sourceTranscript.text)
        }
        return orderedTexts
    }

    private static func contiguousSources(from words: [WordTimestamp]) -> [AudioSource] {
        var sources: [AudioSource] = []
        var lastSource: AudioSource?

        for word in words {
            guard let source = SpeakerID.source(for: word.speakerId) else { continue }
            guard source != lastSource else { continue }
            sources.append(source)
            lastSource = source
        }

        return sources
    }
}
