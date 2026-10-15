import Foundation
import GRDB

/// A named collection of flashcards. Maps 1:1 to an Anki deck on import and
/// export.
public struct FlashcardDeck: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

extension FlashcardDeck: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "flashcard_decks"

    public enum Columns: String, ColumnExpression {
        case id, name, createdAt
    }
}

/// The four Anki/FSRS answer buttons.
public enum FlashcardGrade: Int, Codable, CaseIterable, Identifiable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

public enum FlashcardPhase: String, Codable, Sendable {
    case new, learning, review, relearning
}

/// One front/back card with its FSRS memory state. `context` holds the
/// transcript sentence the card came from, when there is one.
public struct Flashcard: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var deckId: UUID
    public var front: String
    public var back: String
    public var context: String?
    public var tags: String?
    public var sourceTranscriptionId: UUID?
    /// Stable identity used as the Anki note GUID so re-importing an exported
    /// deck does not create duplicates.
    public var ankiGuid: String

    public var phase: FlashcardPhase
    public var stability: Double
    public var difficulty: Double
    public var learningStep: Int
    public var lastReviewAt: Date?
    public var dueAt: Date
    public var reps: Int
    public var lapses: Int

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        deckId: UUID,
        front: String,
        back: String,
        context: String? = nil,
        tags: String? = nil,
        sourceTranscriptionId: UUID? = nil,
        ankiGuid: String? = nil,
        phase: FlashcardPhase = .new,
        stability: Double = 0,
        difficulty: Double = 0,
        learningStep: Int = 0,
        lastReviewAt: Date? = nil,
        dueAt: Date = Date(),
        reps: Int = 0,
        lapses: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.deckId = deckId
        self.front = front
        self.back = back
        self.context = context
        self.tags = tags
        self.sourceTranscriptionId = sourceTranscriptionId
        self.ankiGuid = ankiGuid ?? id.uuidString
        self.phase = phase
        self.stability = stability
        self.difficulty = difficulty
        self.learningStep = learningStep
        self.lastReviewAt = lastReviewAt
        self.dueAt = dueAt
        self.reps = reps
        self.lapses = lapses
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The scheduler's view of this card; `nil` while the card is new.
    public var memoryState: FSRSMemoryState? {
        guard phase != .new, let lastReviewAt else { return nil }
        return FSRSMemoryState(
            stability: stability,
            difficulty: difficulty,
            phase: phase,
            learningStep: learningStep,
            lastReview: lastReviewAt
        )
    }

    public mutating func apply(_ schedule: FSRSSchedule, grade: FlashcardGrade) {
        if grade == .again, phase == .review { lapses += 1 }
        phase = schedule.state.phase
        stability = schedule.state.stability
        difficulty = schedule.state.difficulty
        learningStep = schedule.state.learningStep
        lastReviewAt = schedule.state.lastReview
        dueAt = schedule.dueAt
        reps += 1
        updatedAt = schedule.state.lastReview
    }
}

extension Flashcard: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "flashcards"

    public enum Columns: String, ColumnExpression {
        case id, deckId, front, back, context, tags, sourceTranscriptionId, ankiGuid
        case phase, stability, difficulty, learningStep, lastReviewAt, dueAt, reps, lapses
        case createdAt, updatedAt
    }
}

/// Immutable review history, one row per answer.
public struct FlashcardReview: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var cardId: UUID
    public var grade: Int
    public var reviewedAt: Date
    public var scheduledDays: Double

    public init(id: UUID = UUID(), cardId: UUID, grade: FlashcardGrade, reviewedAt: Date, scheduledDays: Double) {
        self.id = id
        self.cardId = cardId
        self.grade = grade.rawValue
        self.reviewedAt = reviewedAt
        self.scheduledDays = scheduledDays
    }
}

extension FlashcardReview: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "flashcard_reviews"
}

/// Deck row for list views.
public struct FlashcardDeckSummary: Identifiable, Sendable, Equatable, Hashable {
    public var deck: FlashcardDeck
    public var totalCount: Int
    public var dueCount: Int
    public var newCount: Int

    public var id: UUID { deck.id }

    public init(deck: FlashcardDeck, totalCount: Int, dueCount: Int, newCount: Int) {
        self.deck = deck
        self.totalCount = totalCount
        self.dueCount = dueCount
        self.newCount = newCount
    }
}

/// An unsaved card proposed by the generator or typed by the user.
public struct FlashcardDraft: Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var front: String
    public var back: String
    public var context: String?

    public init(id: UUID = UUID(), front: String, back: String, context: String? = nil) {
        self.id = id
        self.front = front
        self.back = back
        self.context = context
    }

    /// Leading articles (and English "to") dropped when comparing fronts, so
    /// "die Bank", "Bank", and "eine Bank" count as the same word.
    static let ignoredLeadingWords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "the", "a", "an", "to",
        "le", "la", "les", "un", "une",
        "el", "los", "las", "una",
        "il", "lo", "gli",
        "de", "het", "een",
    ]

    /// Normalized front used to spot the same word twice: case, punctuation,
    /// repeated whitespace, and a leading article are ignored.
    public static func duplicateKey(_ front: String) -> String {
        var words = front.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        // French/Italian elision: "l'école" -> "école".
        if let first = words.first, first.hasPrefix("l'"), first.count > 2 {
            words[0] = String(first.dropFirst(2))
        }
        if words.count > 1, ignoredLeadingWords.contains(words[0]) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    public var isValid: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
