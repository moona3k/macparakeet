import CryptoKit
import Foundation
import GRDB

public struct CardProvenance: Sendable, Equatable {
    public var transcriptHash: String
    public var segmenterVersion: Int
    public var promptVersion: String
    public var cardSchemaVersion: Int

    public init(
        transcriptHash: String,
        segmenterVersion: Int,
        promptVersion: String,
        cardSchemaVersion: Int
    ) {
        self.transcriptHash = transcriptHash
        self.segmenterVersion = segmenterVersion
        self.promptVersion = promptVersion
        self.cardSchemaVersion = cardSchemaVersion
    }
}

public struct CardGenerationSnapshot: Sendable, Equatable {
    public var transcriptHash: String
    public var segmentsHash: String

    public init(transcriptHash: String, segmentsHash: String) {
        self.transcriptHash = transcriptHash
        self.segmentsHash = segmentsHash
    }
}

public enum CardContentFingerprint {
    public static func transcriptHash(for transcription: Transcription) -> String {
        transcriptHash(
            for: TranscriptAIContextFormatter.format(transcription: transcription)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public static func transcriptHash(for context: String) -> String {
        sha256(Data(context.utf8))
    }

    public static func segmentsHash(_ segments: [Segment]) -> String {
        let payload = segments.sorted { lhs, rhs in
            if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
            return lhs.transcriptionId.uuidString < rhs.transcriptionId.uuidString
        }.map(SegmentFingerprint.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            preconditionFailure("Card segment fingerprint encoding failed")
        }
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct SegmentFingerprint: Encodable {
        var transcriptionId: UUID
        var seq: Int
        var startMs: Int?
        var endMs: Int?
        var speaker: String?
        var text: String
        var segmenterVersion: Int

        init(_ segment: Segment) {
            transcriptionId = segment.transcriptionId
            seq = segment.seq
            startMs = segment.startMs
            endMs = segment.endMs
            speaker = segment.speaker
            text = segment.text
            segmenterVersion = segment.segmenterVersion
        }
    }
}

public struct CardDecision: Codable, Sendable, Equatable {
    public var text: String
    public var seqStart: Int
    public var seqEnd: Int
    public var startMs: Int?
    public var endMs: Int?

    public init(text: String, seqStart: Int, seqEnd: Int, startMs: Int?, endMs: Int?) {
        self.text = text
        self.seqStart = seqStart
        self.seqEnd = seqEnd
        self.startMs = startMs
        self.endMs = endMs
    }

    private enum CodingKeys: String, CodingKey {
        case text, seqStart, seqEnd, startMs, endMs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(seqStart, forKey: .seqStart)
        try container.encode(seqEnd, forKey: .seqEnd)
        try container.encode(startMs, forKey: .startMs)
        try container.encode(endMs, forKey: .endMs)
    }
}

public struct CardAction: Codable, Sendable, Equatable {
    public var text: String
    public var owner: String?
    public var seqStart: Int
    public var seqEnd: Int
    public var startMs: Int?
    public var endMs: Int?

    public init(
        text: String,
        owner: String?,
        seqStart: Int,
        seqEnd: Int,
        startMs: Int?,
        endMs: Int?
    ) {
        self.text = text
        self.owner = owner
        self.seqStart = seqStart
        self.seqEnd = seqEnd
        self.startMs = startMs
        self.endMs = endMs
    }

    private enum CodingKeys: String, CodingKey {
        case text, owner, seqStart, seqEnd, startMs, endMs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(owner, forKey: .owner)
        try container.encode(seqStart, forKey: .seqStart)
        try container.encode(seqEnd, forKey: .seqEnd)
        try container.encode(startMs, forKey: .startMs)
        try container.encode(endMs, forKey: .endMs)
    }
}

public struct Card: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "cards"
    public static let currentSchemaVersion = 1
    public static let currentPromptVersion = "knowledge-card-v1"

    public var transcriptionId: UUID
    public var cardSchemaVersion: Int
    public var transcriptHash: String
    public var segmenterVersion: Int
    public var promptVersion: String
    public var model: String
    public var generatedAt: Date
    public var synopsis: String
    public var topics: [String]
    public var decisions: [CardDecision]
    public var actions: [CardAction]

    public init(
        transcriptionId: UUID,
        cardSchemaVersion: Int,
        transcriptHash: String,
        segmenterVersion: Int,
        promptVersion: String,
        model: String,
        generatedAt: Date,
        synopsis: String,
        topics: [String],
        decisions: [CardDecision],
        actions: [CardAction]
    ) {
        self.transcriptionId = transcriptionId
        self.cardSchemaVersion = cardSchemaVersion
        self.transcriptHash = transcriptHash
        self.segmenterVersion = segmenterVersion
        self.promptVersion = promptVersion
        self.model = model
        self.generatedAt = generatedAt
        self.synopsis = synopsis
        self.topics = topics
        self.decisions = decisions
        self.actions = actions
    }

    public var provenance: CardProvenance {
        CardProvenance(
            transcriptHash: transcriptHash,
            segmenterVersion: segmenterVersion,
            promptVersion: promptVersion,
            cardSchemaVersion: cardSchemaVersion
        )
    }

    public enum Columns: String, ColumnExpression {
        case transcriptionId, cardSchemaVersion, transcriptHash, segmenterVersion
        case promptVersion, model, generatedAt, synopsis, topics, decisions, actions
    }
}

public enum CardSource: String, Codable, Sendable, CaseIterable {
    case meeting
    case file
    case url

    public init(sourceType: Transcription.SourceType) {
        switch sourceType {
        case .meeting: self = .meeting
        case .file: self = .file
        case .youtube, .podcast: self = .url
        }
    }
}

public struct CardListQuery: Sendable, Equatable {
    public var since: Date?
    public var until: Date?
    public var source: CardSource?
    public var limit: Int

    public init(since: Date? = nil, until: Date? = nil, source: CardSource? = nil, limit: Int = 100) {
        self.since = since
        self.until = until
        self.source = source
        self.limit = limit
    }
}

public struct CardListItem: Encodable, Sendable, Equatable {
    public var transcriptionId: UUID
    public var title: String
    public var date: Date
    public var durationMs: Int?
    public var source: CardSource
    public var attendees: [CardAttendee]?
    public var cardSchemaVersion: Int
    public var transcriptHash: String
    public var segmenterVersion: Int
    public var promptVersion: String
    public var model: String
    public var generatedAt: Date
    public var synopsis: String
    public var topics: [String]
    public var decisions: [CardDecision]
    public var actions: [CardAction]

    private enum CodingKeys: String, CodingKey {
        case transcriptionId, title, date, durationMs, source, attendees
        case cardSchemaVersion, transcriptHash, segmenterVersion, promptVersion
        case model, generatedAt, synopsis, topics, decisions, actions
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptionId, forKey: .transcriptionId)
        try container.encode(title, forKey: .title)
        try container.encode(date, forKey: .date)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(source, forKey: .source)
        try container.encode(attendees, forKey: .attendees)
        try container.encode(cardSchemaVersion, forKey: .cardSchemaVersion)
        try container.encode(transcriptHash, forKey: .transcriptHash)
        try container.encode(segmenterVersion, forKey: .segmenterVersion)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(model, forKey: .model)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(synopsis, forKey: .synopsis)
        try container.encode(topics, forKey: .topics)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(actions, forKey: .actions)
    }
}

public struct CardAttendee: Encodable, Sendable, Equatable {
    public var name: String?
    public var email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }

    private enum CodingKeys: String, CodingKey {
        case name, email
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
    }
}

public enum CardTextBudget {
    public static let maximumTokens = 350

    public static func estimatedTokenCount(_ card: Card) -> Int {
        var fields = [card.synopsis]
        fields.append(contentsOf: card.topics)
        fields.append(contentsOf: card.decisions.map(\.text))
        fields.append(contentsOf: card.actions.map(\.text))
        fields.append(contentsOf: card.actions.compactMap(\.owner))
        return fields.reduce(0) { $0 + estimatedTokenCount($1) }
    }

    static func enforce(_ input: Card) -> Card {
        var card = input
        var totalTokens = estimatedTokenCount(card)
        while totalTokens > maximumTokens, let topic = card.topics.popLast() {
            totalTokens -= estimatedTokenCount(topic)
        }

        // Preserve room for a non-empty synopsis if unusually verbose
        // candidate fields alone consume the budget.
        let synopsisTokens = estimatedTokenCount(card.synopsis)
        var reservedTokens = totalTokens - synopsisTokens
        while reservedTokens >= maximumTokens, let action = card.actions.popLast() {
            let removedTokens =
                estimatedTokenCount(action.text)
                + (action.owner.map(estimatedTokenCount) ?? 0)
            reservedTokens -= removedTokens
            totalTokens -= removedTokens
        }
        while reservedTokens >= maximumTokens, let decision = card.decisions.popLast() {
            let removedTokens = estimatedTokenCount(decision.text)
            reservedTokens -= removedTokens
            totalTokens -= removedTokens
        }

        if totalTokens > maximumTokens {
            card.synopsis = truncate(
                card.synopsis,
                maximumTokens: max(1, maximumTokens - reservedTokens)
            )
        }
        return card
    }

    private static func truncate(_ text: String, maximumTokens: Int) -> String {
        guard maximumTokens > 0 else { return "" }
        let scalars = Array(text.unicodeScalars)
        var lower = 0
        var upper = scalars.count
        while lower < upper {
            let candidate = (lower + upper + 1) / 2
            let prefix = String(String.UnicodeScalarView(scalars.prefix(candidate)))
            if estimatedTokenCount(prefix) <= maximumTokens {
                lower = candidate
            } else {
                upper = candidate - 1
            }
        }
        return String(String.UnicodeScalarView(scalars.prefix(lower)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func estimatedTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        var denseScalars = 0
        var sparseScalars = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if isDenseTokenScalar(scalar) {
                denseScalars += 1
            } else {
                sparseScalars += 1
            }
        }
        let scriptAwareEstimate = denseScalars + (sparseScalars + 3) / 4
        return max(wordCount, scriptAwareEstimate)
    }

    private static func isDenseTokenScalar(_ scalar: UnicodeScalar) -> Bool {
        if CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
        {
            return true
        }
        switch scalar.value {
        case 0x0E00...0x0E7F,  // Thai
            0x3040...0x30FF,  // Hiragana + Katakana
            0x31F0...0x31FF,  // Katakana extensions
            0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // Han BMP
            0xFF65...0xFF9F,  // Halfwidth Katakana
            0x1AFF0...0x1AFFF, 0x1B000...0x1B16F,  // Kana supplementary planes
            0x20000...0x2EBEF, 0x2F800...0x2FA1F, 0x30000...0x3134F:  // Han supplementary planes
            return true
        default:
            return false
        }
    }
}
