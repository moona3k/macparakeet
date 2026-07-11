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
        let usableIndices = words.indices.filter { usableText(words[$0].word) != nil }
        guard let firstUsableIndex = usableIndices.first else { return [] }
        var labels: [String: String] = [:]
        for speaker in speakers ?? [] where labels[speaker.id] == nil {
            labels[speaker.id] = speaker.label
        }
        var result: [TranscriptSegmentRecord] = []
        var startPosition = 0
        var currentWords: [String] = []
        var currentScalarCount = 0
        var currentSpeaker = words[firstUsableIndex].speakerId

        func append(endPositionExclusive: Int) {
            guard !currentWords.isEmpty else { return }
            let firstIndex = usableIndices[startPosition]
            let lastIndex = usableIndices[endPositionExclusive - 1]
            let first = words[firstIndex]
            let last = words[lastIndex]
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
                        startIndex: firstIndex,
                        endIndexExclusive: lastIndex + 1
                    )
                ))
        }

        for position in usableIndices.indices {
            let index = usableIndices[position]
            let word = words[index]
            guard let wordText = usableText(word.word) else { continue }
            let speakerChanged = word.speakerId != nil && word.speakerId != currentSpeaker
            let wordScalarCount = wordText.unicodeScalars.count
            let candidateCount = currentScalarCount + (currentWords.isEmpty ? 0 : 1) + wordScalarCount
            if !currentWords.isEmpty && (speakerChanged || candidateCount > targetMaximumScalars) {
                append(endPositionExclusive: position)
                currentWords.removeAll(keepingCapacity: true)
                currentScalarCount = 0
                startPosition = position
                currentSpeaker = word.speakerId
            }

            currentWords.append(wordText)
            currentScalarCount += (currentWords.count == 1 ? 0 : 1) + wordScalarCount
            if let speakerId = word.speakerId { currentSpeaker = speakerId }
            let sentenceEnded = wordText.unicodeScalars.last.map(isSentenceTerminator) ?? false
            let nextPosition = position + 1
            let longGap =
                nextPosition < usableIndices.count
                && words[usableIndices[nextPosition]].startMs - word.endMs > 1_500
            let isLast = nextPosition == usableIndices.count
            if isLast || longGap || (sentenceEnded && currentScalarCount >= targetMinimumScalars) {
                append(endPositionExclusive: nextPosition)
                currentWords.removeAll(keepingCapacity: true)
                currentScalarCount = 0
                if !isLast {
                    startPosition = nextPosition
                    currentSpeaker = words[usableIndices[nextPosition]].speakerId ?? currentSpeaker
                }
            }
        }
        return result
    }

    public static func deriveSegments(for transcription: Transcription) -> [Segment] {
        guard transcription.status == .completed else { return [] }

        let storedSegments = (transcription.transcriptSegments ?? []).compactMap {
            source -> TranscriptSegmentRecord? in
            guard let text = usableText(source.text) else { return nil }
            var normalized = source
            normalized.text = text
            return normalized
        }
        let durableSegments: [TranscriptSegmentRecord]
        if !storedSegments.isEmpty {
            durableSegments = storedSegments
        } else if let words = transcription.wordTimestamps,
            words.contains(where: { usableText($0.word) != nil })
        {
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

        let text =
            usableText(transcription.cleanTranscript)
            ?? usableText(transcription.rawTranscript)
            ?? ""
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

    private static func usableText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
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
