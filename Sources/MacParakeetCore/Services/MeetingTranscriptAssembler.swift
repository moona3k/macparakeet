import Foundation

public struct MeetingTranscriptUpdate: Sendable, Equatable {
    public let words: [WordTimestamp]
    public let speakers: [SpeakerInfo]

    public init(words: [WordTimestamp], speakers: [SpeakerInfo]) {
        self.words = words
        self.speakers = speakers
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
        let offsetWords = result.words.map {
            WordTimestamp(
                word: $0.word,
                startMs: $0.startMs + chunk.startMs,
                endMs: $0.endMs + chunk.startMs,
                confidence: $0.confidence,
                speakerId: source.rawValue
            )
        }

        let cutoff = lastCommittedEndMs[source] ?? Int.min
        let deduplicated = offsetWords.filter { $0.endMs > cutoff }

        if !deduplicated.isEmpty {
            wordsBySource[source, default: []].append(contentsOf: deduplicated)
            lastCommittedEndMs[source] = deduplicated.last?.endMs
        }

        return currentUpdate
    }

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
        var text = ""

        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if text.isEmpty || Self.shouldAttachWithoutLeadingSpace(token) {
                text += token
            } else {
                text += " \(token)"
            }
        }

        return text
    }

    private static func shouldAttachWithoutLeadingSpace(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return ",.!?;:%)]}".contains(first)
    }
}
