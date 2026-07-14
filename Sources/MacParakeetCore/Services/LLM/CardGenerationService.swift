import Foundation

public protocol CardCompletionProviding: Sendable {
    func generateKnowledgeCard(transcript: String, source: CardSource) async throws -> LLMResult
}

extension LLMService: CardCompletionProviding {}

public protocol CardGenerating: Sendable {
    func generate(transcriptionId: UUID, force: Bool) async throws -> CardGenerationOutcome
}

public struct CardGenerationOutcome: Sendable, Equatable {
    public var card: Card?
    public var usage: LLMUsage?
    public var wasSkipped: Bool

    public init(card: Card?, usage: LLMUsage?, wasSkipped: Bool) {
        self.card = card
        self.usage = usage
        self.wasSkipped = wasSkipped
    }
}

public enum CardGenerationError: Error, LocalizedError, Sendable, Equatable {
    case transcriptionNotFound
    case transcriptionIncomplete
    case emptyTranscript
    case malformedResponse
    case emptySynopsis
    case sourceChangedDuringGeneration

    public var errorDescription: String? {
        switch self {
        case .transcriptionNotFound: "Transcription not found."
        case .transcriptionIncomplete: "Knowledge cards require a completed transcription."
        case .emptyTranscript: "Knowledge cards require non-empty transcript content."
        case .malformedResponse: "The LLM returned a malformed knowledge card."
        case .emptySynopsis: "The LLM returned a knowledge card without a synopsis."
        case .sourceChangedDuringGeneration:
            "The transcript changed while its knowledge card was being generated."
        }
    }
}

public final class CardGenerationService: CardGenerating, @unchecked Sendable {
    private let transcriptionRepository: TranscriptionRepositoryProtocol
    private let segmentRepository: SegmentRepositoryProtocol
    private let cardRepository: CardRepositoryProtocol
    private let completionProvider: CardCompletionProviding
    private let now: @Sendable () -> Date

    public init(
        transcriptionRepository: TranscriptionRepositoryProtocol,
        segmentRepository: SegmentRepositoryProtocol,
        cardRepository: CardRepositoryProtocol,
        completionProvider: CardCompletionProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transcriptionRepository = transcriptionRepository
        self.segmentRepository = segmentRepository
        self.cardRepository = cardRepository
        self.completionProvider = completionProvider
        self.now = now
    }

    public func generate(transcriptionId: UUID, force: Bool) async throws -> CardGenerationOutcome {
        guard let transcription = try transcriptionRepository.fetch(id: transcriptionId) else {
            throw CardGenerationError.transcriptionNotFound
        }
        guard transcription.status == .completed else {
            throw CardGenerationError.transcriptionIncomplete
        }
        let context = TranscriptAIContextFormatter.format(transcription: transcription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { throw CardGenerationError.emptyTranscript }

        let provenance = CardProvenance(
            transcriptHash: CardContentFingerprint.transcriptHash(for: context),
            segmenterVersion: KnowledgeSegmenter.currentVersion,
            promptVersion: Card.currentPromptVersion,
            cardSchemaVersion: Card.currentSchemaVersion
        )
        if !force,
            try !cardRepository.isStale(transcriptionId: transcriptionId, current: provenance)
        {
            return CardGenerationOutcome(card: nil, usage: nil, wasSkipped: true)
        }

        let source = CardSource(sourceType: transcription.sourceType)
        let result = try await completionProvider.generateKnowledgeCard(
            transcript: context,
            source: source
        )
        try Task.checkCancellation()
        guard let currentTranscription = try transcriptionRepository.fetch(id: transcriptionId),
            currentTranscription.status == .completed
        else {
            throw CardGenerationError.sourceChangedDuringGeneration
        }
        let currentContext = TranscriptAIContextFormatter.format(transcription: currentTranscription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentContext.isEmpty,
            CardContentFingerprint.transcriptHash(for: currentContext) == provenance.transcriptHash
        else {
            throw CardGenerationError.sourceChangedDuringGeneration
        }
        let draft: CardDraft
        do {
            draft = try JSONDecoder().decode(CardDraft.self, from: Data(result.output.utf8))
        } catch {
            throw CardGenerationError.malformedResponse
        }
        let synopsis = draft.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !synopsis.isEmpty else { throw CardGenerationError.emptySynopsis }

        var segments = try segmentRepository.fetch(transcriptionId: transcriptionId)
        if segments.isEmpty
            || segments.contains(where: {
                $0.segmenterVersion != KnowledgeSegmenter.currentVersion
            })
        {
            try Task.checkCancellation()
            try segmentRepository.replaceSegments(for: currentTranscription)
            segments = try segmentRepository.fetch(transcriptionId: transcriptionId)
        }
        let generationSnapshot = CardGenerationSnapshot(
            transcriptHash: provenance.transcriptHash,
            segmentsHash: CardContentFingerprint.segmentsHash(segments)
        )
        let decisions =
            source == .meeting
            ? draft.decisions.compactMap { item -> CardDecision? in
                guard let citation = Self.resolve(item: item, segments: segments) else { return nil }
                return CardDecision(
                    text: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    seqStart: citation.seqStart,
                    seqEnd: citation.seqEnd,
                    startMs: citation.startMs,
                    endMs: citation.endMs
                )
            }
            : []
        let actions =
            source == .meeting
            ? draft.actions.compactMap { item -> CardAction? in
                guard let citation = Self.resolve(item: item, segments: segments) else { return nil }
                return CardAction(
                    text: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    owner: Self.nonEmpty(item.owner),
                    seqStart: citation.seqStart,
                    seqEnd: citation.seqEnd,
                    startMs: citation.startMs,
                    endMs: citation.endMs
                )
            }
            : []
        let card = Card(
            transcriptionId: transcriptionId,
            cardSchemaVersion: provenance.cardSchemaVersion,
            transcriptHash: provenance.transcriptHash,
            segmenterVersion: provenance.segmenterVersion,
            promptVersion: provenance.promptVersion,
            model: result.model,
            generatedAt: now(),
            synopsis: synopsis,
            topics: draft.topics.compactMap(Self.nonEmpty),
            decisions: decisions.filter { !$0.text.isEmpty },
            actions: actions.filter { !$0.text.isEmpty }
        )
        // Failure-safe replacement: the previous row remains untouched until
        // parsing, citation resolution, source conditioning, and budgeting all
        // succeed. A failed save is atomic and never requires delete/restore.
        try Task.checkCancellation()
        guard let savedCard = try cardRepository.saveIfCurrent(card, expected: generationSnapshot) else {
            throw CardGenerationError.sourceChangedDuringGeneration
        }
        return CardGenerationOutcome(card: savedCard, usage: result.usage, wasSkipped: false)
    }

    private static func resolve(item: CardDraftCitation, segments: [Segment]) -> CardCitationRange? {
        CardCitationResolver.resolve(
            quote: item.quote,
            approximateStartMs: item.startMs.flatMap { $0 >= 0 ? $0 : nil },
            approximateEndMs: item.endMs.flatMap { $0 >= 0 ? $0 : nil },
            segments: segments
        )
    }

    private static func resolve(item: CardDraftAction, segments: [Segment]) -> CardCitationRange? {
        CardCitationResolver.resolve(
            quote: item.quote,
            approximateStartMs: item.startMs.flatMap { $0 >= 0 ? $0 : nil },
            approximateEndMs: item.endMs.flatMap { $0 >= 0 ? $0 : nil },
            segments: segments
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

}

private struct CardDraft: Decodable {
    var synopsis: String
    var topics: [String]
    var decisions: [CardDraftCitation]
    var actions: [CardDraftAction]
}

private struct CardDraftCitation: Decodable {
    var text: String
    var quote: String
    var startMs: Int?
    var endMs: Int?
}

private struct CardDraftAction: Decodable {
    var text: String
    var owner: String?
    var quote: String
    var startMs: Int?
    var endMs: Int?
}

public struct CardCitationRange: Sendable, Equatable {
    public var seqStart: Int
    public var seqEnd: Int
    public var startMs: Int?
    public var endMs: Int?
}

public enum CardCitationResolver {
    public static func resolve(
        quote: String,
        approximateStartMs: Int?,
        approximateEndMs: Int?,
        segments: [Segment]
    ) -> CardCitationRange? {
        guard !segments.isEmpty else { return nil }
        let normalizedQuote = normalize(quote)
        guard !normalizedQuote.isEmpty else { return nil }
        let matches = bestTextWindows(normalizedQuote, segments: segments)
        if matches.count == 1 { return range(for: matches[0]) }
        guard matches.count > 1, let approximateStartMs else { return nil }
        let upper = approximateEndMs ?? approximateStartMs
        let timestampMatches = matches.filter { window in
            guard let first = window.min(by: { $0.seq < $1.seq }),
                let last = window.max(by: { $0.seq < $1.seq }),
                let start = first.startMs
            else {
                return false
            }
            let end = last.endMs ?? last.startMs ?? start
            return start <= upper && end >= approximateStartMs
        }
        return timestampMatches.count == 1 ? range(for: timestampMatches[0]) : nil
    }

    private static func bestTextWindows(_ quote: String, segments: [Segment]) -> [[Segment]] {
        let quoteTokens = Set(tokens(quote))
        for length in 1...min(3, segments.count) {
            var exactMatches: [[Segment]] = []
            for start in 0...(segments.count - length) {
                let window = Array(segments[start..<(start + length)])
                let text = normalize(window.map(\.text).joined(separator: " "))
                if text.contains(quote) {
                    exactMatches.append(window)
                }
            }
            if !exactMatches.isEmpty { return exactMatches }
        }

        var bestScore = 0.0
        var bestLength = Int.max
        var bestMatches: [[Segment]] = []
        for start in segments.indices {
            for length in 1...min(3, segments.count - start) {
                let window = Array(segments[start..<(start + length)])
                let text = normalize(window.map(\.text).joined(separator: " "))
                guard quoteTokens.count >= 2 else { continue }
                let overlap = quoteTokens.intersection(Set(tokens(text))).count
                let score = Double(overlap) / Double(quoteTokens.count)
                guard score >= 0.6 else { continue }
                if score > bestScore || (score == bestScore && length < bestLength) {
                    bestScore = score
                    bestLength = length
                    bestMatches = [window]
                } else if score == bestScore, length == bestLength {
                    bestMatches.append(window)
                }
            }
        }
        return bestMatches
    }

    private static func range(for matched: [Segment]) -> CardCitationRange? {
        guard let first = matched.min(by: { $0.seq < $1.seq }),
            let last = matched.max(by: { $0.seq < $1.seq })
        else { return nil }
        return CardCitationRange(
            seqStart: first.seq,
            seqEnd: last.seq,
            startMs: first.startMs,
            endMs: last.endMs
        )
    }

    private static func normalize(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            guard !current.isEmpty else { return }
            result.append(String(current).lowercased())
            current.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value == 0x27 {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }
}
