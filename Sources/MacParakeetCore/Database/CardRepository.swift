import Foundation
import GRDB

public protocol CardRepositoryProtocol: Sendable {
    func save(_ card: Card) throws
    func fetch(transcriptionId: UUID) throws -> Card?
    func delete(transcriptionId: UUID) throws
    func isStale(transcriptionId: UUID, current: CardProvenance) throws -> Bool
}

public final class CardRepository: CardRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ card: Card) throws {
        let validated = CardTextBudget.enforce(card)
        try dbQueue.write { db in
            try validated.save(db)
        }
    }

    public func fetch(transcriptionId: UUID) throws -> Card? {
        try dbQueue.read { db in
            try Card.fetchOne(db, key: transcriptionId)
        }
    }

    public func delete(transcriptionId: UUID) throws {
        try dbQueue.write { db in
            _ = try Card.deleteOne(db, key: transcriptionId)
        }
    }

    public func isStale(transcriptionId: UUID, current: CardProvenance) throws -> Bool {
        guard let card = try fetch(transcriptionId: transcriptionId) else { return true }
        return card.provenance != current
    }

    public func completedTranscriptionIDs() throws -> [UUID] {
        try dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM transcriptions WHERE status = ? ORDER BY createdAt DESC, id ASC",
                arguments: [Transcription.TranscriptionStatus.completed.rawValue]
            )
        }
    }

    public func list(_ query: CardListQuery) throws -> [CardListItem] {
        guard query.limit > 0 else { return [] }
        return try dbQueue.read { db in
            var predicates: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let since = query.since {
                predicates.append("t.createdAt >= ?")
                arguments.append(since)
            }
            if let until = query.until {
                predicates.append("t.createdAt <= ?")
                arguments.append(until)
            }
            if let source = query.source {
                predicates.append(Self.sourcePredicate(for: source))
            }

            var sql = "SELECT c.* FROM cards c JOIN transcriptions t ON t.id = c.transcriptionId"
            if !predicates.isEmpty {
                sql += " WHERE " + predicates.joined(separator: " AND ")
            }
            sql += " ORDER BY t.createdAt DESC, c.transcriptionId ASC LIMIT ?"
            arguments.append(query.limit)

            let storedCards = try Card.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            let transcriptions = try Transcription.fetchAll(
                db,
                keys: storedCards.map(\.transcriptionId)
            )
            let transcriptionsByID = Dictionary(
                uniqueKeysWithValues: transcriptions.map { ($0.id, $0) }
            )
            return storedCards.compactMap { card in
                guard let transcription = transcriptionsByID[card.transcriptionId] else {
                    return nil
                }
                return Self.listItem(card: card, transcription: transcription)
            }
        }
    }

    private static func listItem(card: Card, transcription: Transcription) -> CardListItem {
        let source = CardSource(sourceType: transcription.sourceType)
        let attendees: [CardAttendee]? =
            if source == .meeting,
                let people = transcription.calendarEventSnapshot?.attendees,
                !people.isEmpty
            {
                people.map { CardAttendee(name: $0.name, email: $0.email) }
            } else {
                nil
            }
        return CardListItem(
            transcriptionId: card.transcriptionId,
            title: transcription.effectiveDisplayTitle,
            date: transcription.createdAt,
            durationMs: transcription.durationMs,
            source: source,
            attendees: attendees,
            cardSchemaVersion: card.cardSchemaVersion,
            transcriptHash: card.transcriptHash,
            segmenterVersion: card.segmenterVersion,
            promptVersion: card.promptVersion,
            model: card.model,
            generatedAt: card.generatedAt,
            synopsis: card.synopsis,
            topics: card.topics,
            decisions: source == .meeting ? card.decisions : [],
            actions: source == .meeting ? card.actions : []
        )
    }

    private static func sourcePredicate(for source: CardSource) -> String {
        switch source {
        case .meeting:
            "t.sourceType = 'meeting'"
        case .file:
            "t.sourceType = 'file'"
        case .url:
            "t.sourceType IN ('youtube', 'podcast')"
        }
    }
}
