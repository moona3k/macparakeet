import Foundation

/// Frozen versioned rules for deriving the rebuildable transcript search layer.
public enum KnowledgeSegmenter {
    public static let currentVersion = 1

    private static let targetMinimumScalars = 200
    private static let targetMaximumScalars = 500

    /// Materializes durable file/URL transcript JSON from word timings. Meeting
    /// capture keeps its existing speaker-turn materialization path.
    public static func materializeFileTranscriptSegments(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]? = nil,
        idGenerator: () -> UUID = { UUID() }
    ) -> [TranscriptSegmentRecord] {
        guard !words.isEmpty else { return [] }
        var labels: [String: String] = [:]
        for speaker in speakers ?? [] where labels[speaker.id] == nil {
            labels[speaker.id] = speaker.label
        }
        var result: [TranscriptSegmentRecord] = []
        var startIndex = 0
        var currentWords: [String] = []
        var currentScalarCount = 0
        var currentSpeaker = words[0].speakerId

        func append(endIndexExclusive: Int) {
            guard !currentWords.isEmpty else { return }
            let first = words[startIndex]
            let last = words[endIndexExclusive - 1]
            let speakerLabel: String
            if let currentSpeaker {
                speakerLabel =
                    labels[currentSpeaker]
                    ?? AudioSource(rawValue: currentSpeaker)?.displayLabel
                    ?? currentSpeaker
            } else {
                speakerLabel = "Unknown Speaker"
            }
            result.append(
                TranscriptSegmentRecord(
                    id: idGenerator(),
                    startMs: first.startMs,
                    endMs: last.endMs,
                    speakerId: currentSpeaker,
                    speakerLabel: speakerLabel,
                    text: currentWords.joined(separator: " "),
                    wordRange: TranscriptSegmentWordRange(
                        startIndex: startIndex,
                        endIndexExclusive: endIndexExclusive
                    )
                ))
        }

        for index in words.indices {
            let word = words[index]
            let speakerChanged = word.speakerId != nil && word.speakerId != currentSpeaker
            let wordScalarCount = word.word.unicodeScalars.count
            let candidateCount = currentScalarCount + (currentWords.isEmpty ? 0 : 1) + wordScalarCount
            if !currentWords.isEmpty && (speakerChanged || candidateCount > targetMaximumScalars) {
                append(endIndexExclusive: index)
                currentWords.removeAll(keepingCapacity: true)
                currentScalarCount = 0
                startIndex = index
                currentSpeaker = word.speakerId
            }

            currentWords.append(word.word)
            currentScalarCount += (currentWords.count == 1 ? 0 : 1) + wordScalarCount
            if let speakerId = word.speakerId { currentSpeaker = speakerId }
            let sentenceEnded = word.word.unicodeScalars.last.map(isSentenceTerminator) ?? false
            let longGap = index + 1 < words.count && words[index + 1].startMs - word.endMs > 1_500
            let isLast = index == words.index(before: words.endIndex)
            if isLast || longGap || (sentenceEnded && currentScalarCount >= targetMinimumScalars) {
                append(endIndexExclusive: index + 1)
                currentWords.removeAll(keepingCapacity: true)
                currentScalarCount = 0
                if !isLast {
                    startIndex = index + 1
                    currentSpeaker = words[index + 1].speakerId ?? currentSpeaker
                }
            }
        }
        return result
    }

    public static func deriveSegments(for transcription: Transcription) -> [Segment] {
        guard transcription.status == .completed else { return [] }

        let durableSegments: [TranscriptSegmentRecord]
        if let stored = transcription.transcriptSegments, !stored.isEmpty {
            durableSegments = stored
        } else if let words = transcription.wordTimestamps, !words.isEmpty {
            durableSegments = materializeFileTranscriptSegments(
                words: words,
                speakers: transcription.speakers
            )
        } else {
            durableSegments = []
        }

        if !durableSegments.isEmpty {
            return durableSegments.enumerated().map { seq, source in
                Segment(
                    transcriptionId: transcription.id,
                    seq: seq,
                    startMs: source.startMs,
                    endMs: source.endMs,
                    speaker: source.speakerId == nil ? nil : normalizedSpeaker(source.speakerLabel),
                    text: source.text,
                    segmenterVersion: currentVersion
                )
            }
        }

        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        return pseudoSegment(text).enumerated().map { seq, chunk in
            Segment(
                transcriptionId: transcription.id,
                seq: seq,
                startMs: nil,
                endMs: nil,
                speaker: nil,
                text: chunk,
                segmenterVersion: currentVersion
            )
        }
    }

    /// Pure, locale-independent version-1 pseudo-segmentation. Only explicit
    /// Unicode scalar values participate in whitespace and sentence rules.
    public static func pseudoSegment(_ text: String) -> [String] {
        let normalized = normalizeWhitespace(text)
        guard !normalized.isEmpty else { return [] }
        let scalars = Array(normalized.unicodeScalars)
        var chunks: [String] = []
        var start = 0
        var lastSentenceBoundary: Int?
        var lastSpace: Int?

        func append(end: Int) {
            guard end > start else { return }
            let chunk = String(String.UnicodeScalarView(scalars[start..<end]))
                .trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if !chunk.isEmpty { chunks.append(chunk) }
            start = end
            while start < scalars.count && scalars[start].value == 0x20 { start += 1 }
            lastSentenceBoundary = nil
            lastSpace = nil
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x20 { lastSpace = index + 1 }
            if isSentenceTerminator(scalar) { lastSentenceBoundary = index + 1 }
            let length = index - start + 1
            if length >= targetMaximumScalars {
                let sentenceSplit = lastSentenceBoundary.flatMap {
                    $0 - start >= targetMinimumScalars ? $0 : nil
                }
                append(end: sentenceSplit ?? lastSpace ?? (index + 1))
                index = start
                continue
            }
            if let boundary = lastSentenceBoundary,
                boundary == index + 1,
                length >= targetMinimumScalars
            {
                append(end: boundary)
            }
            index += 1
        }
        append(end: scalars.count)
        return chunks
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isExplicitWhitespace(scalar) {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace { output.append(" ") }
                output.append(scalar)
                pendingSpace = false
            }
        }
        return String(output)
    }

    private static func isExplicitWhitespace(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
            true
        default:
            false
        }
    }

    private static func isSentenceTerminator(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x21, 0x2E, 0x3F, 0x3002, 0xFF01, 0xFF1F:
            true
        default:
            false
        }
    }

    private static func normalizedSpeaker(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Unknown Speaker" ? nil : trimmed
    }
}
