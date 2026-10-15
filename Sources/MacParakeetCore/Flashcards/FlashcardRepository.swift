import Foundation
import GRDB

public protocol FlashcardRepositoryProtocol: Sendable {
    func deckSummaries(now: Date) throws -> [FlashcardDeckSummary]
    func fetchDeck(named name: String) throws -> FlashcardDeck?
    /// Returns the deck with this name, creating it when missing.
    func findOrCreateDeck(named name: String) throws -> FlashcardDeck
    func renameDeck(id: UUID, to name: String) throws
    func deleteDeck(id: UUID) throws

    func cards(deckId: UUID) throws -> [Flashcard]
    func cards(sourceTranscriptionId: UUID) throws -> [Flashcard]
    /// Fronts of every card in every deck, for duplicate checks.
    func allFronts() throws -> [String]
    /// Due cards first (oldest due first), then new cards, up to `limit`.
    func dueCards(deckId: UUID?, now: Date, limit: Int) throws -> [Flashcard]
    func save(_ card: Flashcard) throws
    func insert(_ cards: [Flashcard]) throws
    /// Inserts cards, or updates text on cards whose `ankiGuid` already
    /// exists (keeping their review state). Returns (inserted, updated).
    func upsertByGuid(_ cards: [Flashcard]) throws -> (inserted: Int, updated: Int)
    func deleteCard(id: UUID) throws
    /// Saves the card's new schedule and appends the review to history.
    func recordReview(card: Flashcard, review: FlashcardReview) throws
}

public final class FlashcardRepository: FlashcardRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func deckSummaries(now: Date) throws -> [FlashcardDeckSummary] {
        try dbQueue.read { db in
            let decks = try FlashcardDeck.order(FlashcardDeck.Columns.name.collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT deckId,
                           COUNT(*) AS total,
                           SUM(CASE WHEN phase != 'new' AND dueAt <= ? THEN 1 ELSE 0 END) AS due,
                           SUM(CASE WHEN phase = 'new' THEN 1 ELSE 0 END) AS fresh
                    FROM flashcards GROUP BY deckId
                    """,
                arguments: [now]
            )
            var counts: [UUID: (Int, Int, Int)] = [:]
            for row in rows {
                // UUID decoding accepts both the blob and text encodings.
                guard let deckId = row["deckId"] as UUID? else { continue }
                counts[deckId] = (row["total"], row["due"] ?? 0, row["fresh"] ?? 0)
            }
            return decks.map { deck in
                let count = counts[deck.id] ?? (0, 0, 0)
                return FlashcardDeckSummary(deck: deck, totalCount: count.0, dueCount: count.1, newCount: count.2)
            }
        }
    }

    public func fetchDeck(named name: String) throws -> FlashcardDeck? {
        try dbQueue.read { db in
            try FlashcardDeck.filter(FlashcardDeck.Columns.name == name).fetchOne(db)
        }
    }

    public func findOrCreateDeck(named name: String) throws -> FlashcardDeck {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let deckName = trimmed.isEmpty ? "Default" : trimmed
        return try dbQueue.write { db in
            if let existing = try FlashcardDeck.filter(FlashcardDeck.Columns.name == deckName).fetchOne(db) {
                return existing
            }
            let deck = FlashcardDeck(name: deckName)
            try deck.insert(db)
            return deck
        }
    }

    public func renameDeck(id: UUID, to name: String) throws {
        try dbQueue.write { db in
            guard var deck = try FlashcardDeck.fetchOne(db, key: id) else { return }
            deck.name = name
            try deck.update(db)
        }
    }

    public func deleteDeck(id: UUID) throws {
        _ = try dbQueue.write { db in
            try FlashcardDeck.deleteOne(db, key: id)
        }
    }

    public func cards(deckId: UUID) throws -> [Flashcard] {
        try dbQueue.read { db in
            try Flashcard
                .filter(Flashcard.Columns.deckId == deckId)
                .order(Flashcard.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    public func allFronts() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, Flashcard.select(Flashcard.Columns.front))
        }
    }

    public func cards(sourceTranscriptionId: UUID) throws -> [Flashcard] {
        try dbQueue.read { db in
            try Flashcard
                .filter(Flashcard.Columns.sourceTranscriptionId == sourceTranscriptionId)
                .order(Flashcard.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    public func dueCards(deckId: UUID?, now: Date, limit: Int) throws -> [Flashcard] {
        try dbQueue.read { db in
            var due = Flashcard
                .filter(Flashcard.Columns.phase != FlashcardPhase.new.rawValue)
                .filter(Flashcard.Columns.dueAt <= now)
            var fresh = Flashcard.filter(Flashcard.Columns.phase == FlashcardPhase.new.rawValue)
            if let deckId {
                due = due.filter(Flashcard.Columns.deckId == deckId)
                fresh = fresh.filter(Flashcard.Columns.deckId == deckId)
            }
            let dueCards = try due.order(Flashcard.Columns.dueAt.asc).limit(limit).fetchAll(db)
            let remaining = max(0, limit - dueCards.count)
            let newCards = try fresh.order(Flashcard.Columns.createdAt.asc).limit(remaining).fetchAll(db)
            return dueCards + newCards
        }
    }

    public func save(_ card: Flashcard) throws {
        try dbQueue.write { db in
            try card.save(db)
        }
    }

    public func insert(_ cards: [Flashcard]) throws {
        try dbQueue.write { db in
            for card in cards {
                try card.insert(db)
            }
        }
    }

    public func upsertByGuid(_ cards: [Flashcard]) throws -> (inserted: Int, updated: Int) {
        try dbQueue.write { db in
            var inserted = 0
            var updated = 0
            for card in cards {
                if var existing = try Flashcard.filter(Flashcard.Columns.ankiGuid == card.ankiGuid).fetchOne(db) {
                    existing.front = card.front
                    existing.back = card.back
                    existing.context = card.context
                    existing.tags = card.tags
                    existing.deckId = card.deckId
                    existing.updatedAt = Date()
                    try existing.update(db)
                    updated += 1
                } else {
                    try card.insert(db)
                    inserted += 1
                }
            }
            return (inserted, updated)
        }
    }

    public func deleteCard(id: UUID) throws {
        _ = try dbQueue.write { db in
            try Flashcard.deleteOne(db, key: id)
        }
    }

    public func recordReview(card: Flashcard, review: FlashcardReview) throws {
        try dbQueue.write { db in
            try card.update(db)
            try review.insert(db)
        }
    }
}
