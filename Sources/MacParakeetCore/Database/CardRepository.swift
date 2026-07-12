import Foundation
import GRDB

public protocol CardRepositoryProtocol: Sendable {
    func save(_ card: Card) throws
    func saveIfCurrent(_ card: Card, expected: CardGenerationSnapshot) throws -> Card?
    func fetch(transcriptionId: UUID) throws -> Card?
    func delete(transcriptionId: UUID) throws
    func isStale(transcriptionId: UUID, current: CardProvenance) throws -> Bool
}

public final class CardRepository: CardRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let listBatchSize: Int

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        self.listBatchSize = 200
    }

    init(dbQueue: DatabaseQueue, listBatchSize: Int) {
        precondition(listBatchSize > 0)
        self.dbQueue = dbQueue
        self.listBatchSize = listBatchSize
    }

    public func save(_ card: Card) throws {
        let validated = CardTextBudget.enforce(card)
        try dbQueue.write { db in
            try validated.save(db)
        }
    }

    public func saveIfCurrent(_ card: Card, expected: CardGenerationSnapshot) throws -> Card? {
        let validated = CardTextBudget.enforce(card)
        return try dbQueue.write { db in
            guard let transcription = try Transcription.fetchOne(db, key: card.transcriptionId),
                transcription.status == .completed,
                CardContentFingerprint.transcriptHash(for: transcription) == expected.transcriptHash
            else {
                return nil
            }
            let segments =
                try Segment
                .filter(Segment.Columns.transcriptionId == card.transcriptionId)
                .order(Segment.Columns.seq.asc)
                .fetchAll(db)
            guard CardContentFingerprint.segmentsHash(segments) == expected.segmentsHash else {
                return nil
            }
            try validated.save(db)
            return validated
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

    public func staleCompletedTranscriptionIDs() throws -> [UUID] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.*, c.transcriptHash AS currentCardTranscriptHash
                    FROM transcriptions t
                    LEFT JOIN cards c
                      ON c.transcriptionId = t.id
                     AND c.segmenterVersion = ?
                     AND c.promptVersion = ?
                     AND c.cardSchemaVersion = ?
                    WHERE t.status = ?
                    ORDER BY t.createdAt DESC, t.id ASC
                    """,
                arguments: [
                    KnowledgeSegmenter.currentVersion,
                    Card.currentPromptVersion,
                    Card.currentSchemaVersion,
                    Transcription.TranscriptionStatus.completed.rawValue,
                ]
            )
            return try rows.compactMap { row in
                let transcription = try Transcription(row: row)
                let currentCardTranscriptHash: String? = row["currentCardTranscriptHash"]
                return currentCardTranscriptHash == CardContentFingerprint.transcriptHash(for: transcription)
                    ? nil
                    : transcription.id
            }
        }
    }

    public func rebuildFTS() throws {
        try dbQueue.write { db in
            // Phase 3 consumes this index through the planned `cards search`
            // verb. Rebuild it during card backfill so integrity recovery is
            // available before that public consumer ships.
            try db.execute(sql: "INSERT INTO cards_fts(cards_fts) VALUES('rebuild')")
        }
    }

    public func list(_ query: CardListQuery) throws -> [CardListItem] {
        guard query.limit > 0 else { return [] }
        return try dbQueue.read { db in
            var predicates = ["t.status = ?"]
            var arguments: [any DatabaseValueConvertible] = [
                Transcription.TranscriptionStatus.completed.rawValue
            ]
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

            var sql = "SELECT c.*, t.* FROM cards c JOIN transcriptions t ON t.id = c.transcriptionId"
            if !predicates.isEmpty {
                sql += " WHERE " + predicates.joined(separator: " AND ")
            }
            sql += " ORDER BY t.createdAt DESC, c.transcriptionId ASC LIMIT ? OFFSET ?"

            var currentItems: [CardListItem] = []
            var offset = 0
            while currentItems.count < query.limit {
                var batchArguments = arguments
                batchArguments.append(listBatchSize)
                batchArguments.append(offset)
                let rows = try Row.fetchAll(
                    db,
                    sql: sql,
                    arguments: StatementArguments(batchArguments)
                )
                guard !rows.isEmpty else { break }
                for row in rows {
                    let card = try Card(row: row)
                    let transcription = try Transcription(row: row)
                    guard Self.isCurrent(card: card, transcription: transcription) else {
                        continue
                    }
                    currentItems.append(Self.listItem(card: card, transcription: transcription))
                    if currentItems.count == query.limit { break }
                }
                offset += rows.count
                if rows.count < listBatchSize { break }
            }
            return currentItems
        }
    }

    private static func isCurrent(card: Card, transcription: Transcription) -> Bool {
        card.provenance
            == CardProvenance(
                transcriptHash: CardContentFingerprint.transcriptHash(for: transcription),
                segmenterVersion: KnowledgeSegmenter.currentVersion,
                promptVersion: Card.currentPromptVersion,
                cardSchemaVersion: Card.currentSchemaVersion
            )
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
