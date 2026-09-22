import Foundation

public struct MeetingTranscriptUpdate: Sendable, Equatable {
    public let words: [WordTimestamp]
    public let speakers: [SpeakerInfo]
    /// `true` when live-preview chunks were recently dropped due to STT backpressure.
    /// The UI can use this to show a "transcription lagging" indicator.
    public let isTranscriptionLagging: Bool

    public init(words: [WordTimestamp], speakers: [SpeakerInfo], isTranscriptionLagging: Bool = false) {
        self.words = words
        self.speakers = speakers
        self.isTranscriptionLagging = isTranscriptionLagging
    }
}

public struct MeetingRealtimeTranscript: Sendable, Equatable {
    public let rawTranscript: String
    public let words: [WordTimestamp]
    public let speakerCount: Int
    public let speakers: [SpeakerInfo]
    public let diarizationSegments: [DiarizationSegmentRecord]
    public let durationMs: Int?

    public init(
        rawTranscript: String,
        words: [WordTimestamp],
        speakerCount: Int,
        speakers: [SpeakerInfo],
        diarizationSegments: [DiarizationSegmentRecord],
        durationMs: Int?
    ) {
        self.rawTranscript = rawTranscript
        self.words = words
        self.speakerCount = speakerCount
        self.speakers = speakers
        self.diarizationSegments = diarizationSegments
        self.durationMs = durationMs
    }
}

struct MeetingTranscriptAssembler {
    private static let orderedSources: [AudioSource] = [.microphone, .system]
    private static let syntheticOverlapAnchorLength = 6

    private var wordsBySource: [AudioSource: [WordTimestamp]] = [:]
    private var lastCommittedEndMs: [AudioSource: Int] = [:]

    mutating func reset() {
        wordsBySource = [:]
        lastCommittedEndMs = [:]
    }

    mutating func apply(
        result: STTResult,
        chunk: AudioChunker.AudioChunk,
        source: AudioSource
    ) -> MeetingTranscriptUpdate {
        let cutoff = lastCommittedEndMs[source]
        let offsetWords = Self.offsetWords(
            from: result,
            chunk: chunk,
            source: source,
            committedWords: wordsBySource[source] ?? [],
            committedThroughMs: cutoff
        )
        let deduplicated = offsetWords.filter { word in
            guard let cutoff else { return true }
            return word.endMs > cutoff
        }

        if !deduplicated.isEmpty {
            wordsBySource[source, default: []].append(contentsOf: deduplicated)
            lastCommittedEndMs[source] = deduplicated.last?.endMs
        }

        return currentUpdate
    }

    private static func offsetWords(
        from result: STTResult,
        chunk: AudioChunker.AudioChunk,
        source: AudioSource,
        committedWords: [WordTimestamp],
        committedThroughMs: Int?
    ) -> [WordTimestamp] {
        if !result.words.isEmpty {
            return result.words.map {
                WordTimestamp(
                    word: $0.word,
                    startMs: $0.startMs + chunk.startMs,
                    endMs: $0.endMs + chunk.startMs,
                    confidence: $0.confidence,
                    speakerId: source.rawValue
                )
            }
        }

        return synthesizeWords(
            from: result.text,
            chunk: chunk,
            source: source,
            committedWords: committedWords,
            committedThroughMs: committedThroughMs
        )
    }

    private static func synthesizeWords(
        from text: String,
        chunk: AudioChunker.AudioChunk,
        source: AudioSource,
        committedWords: [WordTimestamp],
        committedThroughMs: Int?
    ) -> [WordTimestamp] {
        let rawTokens = text.split { $0.isWhitespace }.map(String.init)
        let hasTemporalOverlap = committedThroughMs.map { $0 > chunk.startMs } ?? false
        let tokens = hasTemporalOverlap
            ? trimOverlappingPrefix(rawTokens, committedWords: committedWords)
            : rawTokens
        guard !tokens.isEmpty else { return [] }

        let startBoundary = committedThroughMs
            .map { max(chunk.startMs, min($0, chunk.endMs)) }
            ?? chunk.startMs
        guard startBoundary < chunk.endMs else { return [] }

        let durationMs = max(chunk.endMs - startBoundary, tokens.count)
        return tokens.enumerated().map { index, token in
            let startMs = startBoundary + (durationMs * index / tokens.count)
            let endMs = startBoundary + (durationMs * (index + 1) / tokens.count)
            return WordTimestamp(
                word: token,
                startMs: startMs,
                endMs: endMs,
                confidence: 0,
                speakerId: source.rawValue
            )
        }
    }

    private static func trimOverlappingPrefix(
        _ tokens: [String],
        committedWords: [WordTimestamp]
    ) -> [String] {
        guard !tokens.isEmpty, !committedWords.isEmpty else { return tokens }

        let normalizedTokens = tokens.map(normalizeOverlapToken)
        let normalizedCommitted = committedWords
            .suffix(syntheticOverlapAnchorLength)
            .map { normalizeOverlapToken($0.word) }
        var overlap = min(normalizedTokens.count, normalizedCommitted.count)

        while overlap > 0 {
            if normalizedCommitted.suffix(overlap).elementsEqual(normalizedTokens.prefix(overlap)) {
                return Array(tokens.dropFirst(overlap))
            }
            overlap -= 1
        }

        return tokens
    }

    private static func normalizeOverlapToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: overlapTrimSet)
        return trimmed.isEmpty ? token.lowercased() : trimmed.lowercased()
    }

    private static let overlapTrimSet = CharacterSet.punctuationCharacters
        .union(.symbols)

    var currentUpdate: MeetingTranscriptUpdate {
        let words = normalizedWords()
        return MeetingTranscriptUpdate(words: words, speakers: activeSpeakers(for: words))
    }

    func finalizedTranscript(durationMs: Int?) -> MeetingRealtimeTranscript? {
        let words = normalizedWords()
        guard !words.isEmpty else { return nil }

        let speakers = activeSpeakers(for: words)
        let diarizationSegments = buildDiarizationSegments(from: words)

        return MeetingRealtimeTranscript(
            rawTranscript: transcriptText(from: words),
            words: words,
            speakerCount: speakers.count,
            speakers: speakers,
            diarizationSegments: diarizationSegments,
            durationMs: durationMs ?? words.last?.endMs
        )
    }

    private func mergedWords() -> [WordTimestamp] {
        Self.orderedSources
            .flatMap { wordsBySource[$0] ?? [] }
            .sorted {
                if $0.startMs == $1.startMs {
                    return ($0.speakerId ?? "") < ($1.speakerId ?? "")
                }
                return $0.startMs < $1.startMs
            }
    }

    private func normalizedWords() -> [WordTimestamp] {
        let words = mergedWords()
        guard let originMs = words.map(\.startMs).min(), originMs != 0 else {
            return words
        }

        return words.map { word in
            WordTimestamp(
                word: word.word,
                startMs: word.startMs - originMs,
                endMs: word.endMs - originMs,
                confidence: word.confidence,
                speakerId: word.speakerId
            )
        }
    }

    private func activeSpeakers(for words: [WordTimestamp]) -> [SpeakerInfo] {
        let activeIDs = Set(words.compactMap(\.speakerId))
        return Self.orderedSources.compactMap { source in
            guard activeIDs.contains(source.rawValue) else { return nil }
            return SpeakerInfo(id: source.rawValue, label: source.displayLabel)
        }
    }

    private func buildDiarizationSegments(from words: [WordTimestamp]) -> [DiarizationSegmentRecord] {
        guard let firstWord = words.first, let firstSpeaker = firstWord.speakerId else {
            return []
        }

        var segments: [DiarizationSegmentRecord] = []
        var currentSpeaker = firstSpeaker
        var currentStart = firstWord.startMs
        var currentEnd = firstWord.endMs

        for word in words.dropFirst() {
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

    private func transcriptText(from words: [WordTimestamp]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(words.count)

        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if parts.isEmpty || Self.shouldAttachWithoutLeadingSpace(token) {
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
}
