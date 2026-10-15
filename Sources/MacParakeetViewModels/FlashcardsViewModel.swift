import Foundation
import MacParakeetCore
import OSLog

/// Decks, the review session, `.apkg` import/export, and card generation
/// from transcripts.
@MainActor
@Observable
public final class FlashcardsViewModel {
    // MARK: Decks

    public private(set) var decks: [FlashcardDeckSummary] = []
    /// `nil` means "all decks" for review.
    public var selectedDeckId: UUID?
    public private(set) var browsedCards: [Flashcard] = []

    // MARK: Review

    public private(set) var reviewQueue: [Flashcard] = []
    public private(set) var isReviewing = false
    public var isAnswerShown = false
    public private(set) var reviewedThisSession = 0

    // MARK: Generation

    public var drafts: [FlashcardDraft] = []
    public private(set) var isGenerating = false

    // MARK: Status

    public var statusMessage: String?
    public var errorMessage: String?

    private var repository: FlashcardRepositoryProtocol?
    private var generator: FlashcardGenerating?
    private var generationTask: Task<Void, Never>?
    private let scheduler = FSRSScheduler()
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "FlashcardsViewModel")

    static let sessionLimit = 200

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func configure(repository: FlashcardRepositoryProtocol?, generator: FlashcardGenerating?) {
        self.repository = repository
        self.generator = generator
        reload()
    }

    public func updateGenerator(_ generator: FlashcardGenerating?) {
        self.generator = generator
    }

    public var canGenerate: Bool { generator != nil }

    public var selectedDeck: FlashcardDeckSummary? {
        decks.first { $0.id == selectedDeckId }
    }

    public var totalDue: Int { decks.reduce(0) { $0 + $1.dueCount + $1.newCount } }

    // MARK: - Loading

    public func reload() {
        guard let repository else { return }
        do {
            decks = try repository.deckSummaries(now: now())
            if let selectedDeckId, !decks.contains(where: { $0.id == selectedDeckId }) {
                self.selectedDeckId = nil
            }
            browsedCards = try selectedDeckId.map { try repository.cards(deckId: $0) } ?? []
        } catch {
            report(error, context: "load")
        }
    }

    public func selectDeck(_ id: UUID?) {
        selectedDeckId = id
        endReview()
        reload()
    }

    public func createDeck(named name: String) {
        guard let repository else { return }
        do {
            let deck = try repository.findOrCreateDeck(named: name)
            selectedDeckId = deck.id
            reload()
        } catch {
            report(error, context: "create_deck")
        }
    }

    public func renameDeck(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try repository?.renameDeck(id: id, to: trimmed)
            reload()
        } catch {
            errorMessage = "A deck named “\(trimmed)” already exists."
        }
    }

    public func deleteDeck(_ id: UUID) {
        do {
            try repository?.deleteDeck(id: id)
            if selectedDeckId == id { selectedDeckId = nil }
            reload()
        } catch {
            report(error, context: "delete_deck")
        }
    }

    // MARK: - Cards

    public func addCard(front: String, back: String, context: String?, deckId: UUID) {
        let draft = FlashcardDraft(front: front, back: back, context: context)
        guard draft.isValid else { return }
        do {
            try repository?.insert([makeCard(from: draft, deckId: deckId, sourceTranscriptionId: nil)])
            reload()
        } catch {
            report(error, context: "add_card")
        }
    }

    public func updateCard(_ card: Flashcard) {
        var card = card
        card.updatedAt = now()
        do {
            try repository?.save(card)
            reload()
        } catch {
            report(error, context: "update_card")
        }
    }

    public func deleteCard(_ id: UUID) {
        do {
            try repository?.deleteCard(id: id)
            reviewQueue.removeAll { $0.id == id }
            reload()
        } catch {
            report(error, context: "delete_card")
        }
    }

    // MARK: - Review

    public var currentCard: Flashcard? { reviewQueue.first }

    public func startReview() {
        guard let repository else { return }
        do {
            reviewQueue = try repository.dueCards(deckId: selectedDeckId, now: now(), limit: Self.sessionLimit)
            reviewedThisSession = 0
            isAnswerShown = false
            isReviewing = true
        } catch {
            report(error, context: "start_review")
        }
    }

    public func endReview() {
        isReviewing = false
        reviewQueue = []
        isAnswerShown = false
        reload()
    }

    /// The interval each rating would schedule, for the button labels.
    public func preview(_ grade: FlashcardGrade) -> String {
        guard let card = currentCard else { return "" }
        return scheduler.schedule(previous: card.memoryState, grade: grade, now: now()).intervalLabel
    }

    public func answer(_ grade: FlashcardGrade) {
        guard var card = currentCard, let repository else { return }
        let reviewedAt = now()
        let schedule = scheduler.schedule(previous: card.memoryState, grade: grade, now: reviewedAt)
        card.apply(schedule, grade: grade)
        do {
            try repository.recordReview(
                card: card,
                review: FlashcardReview(
                    cardId: card.id, grade: grade, reviewedAt: reviewedAt, scheduledDays: schedule.scheduledDays)
            )
        } catch {
            report(error, context: "record_review")
            return
        }

        reviewQueue.removeFirst()
        reviewedThisSession += 1
        isAnswerShown = false
        // Short learning steps come back in this session, like Anki.
        if schedule.scheduledDays < 1 {
            let index = reviewQueue.firstIndex { $0.phase != .new && $0.dueAt > card.dueAt } ?? reviewQueue.endIndex
            reviewQueue.insert(card, at: index)
        }
    }

    // MARK: - Import / export

    public func importPackage(from url: URL) async {
        guard let repository else { return }
        errorMessage = nil
        statusMessage = "Importing \(url.lastPathComponent)…"
        do {
            let imported = try await Task.detached {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try AnkiPackageReader().readCards(at: url)
            }.value

            var deckIds: [String: UUID] = [:]
            var cards: [Flashcard] = []
            for item in imported {
                let deckId: UUID
                if let cached = deckIds[item.deckName] {
                    deckId = cached
                } else {
                    deckId = try repository.findOrCreateDeck(named: item.deckName).id
                    deckIds[item.deckName] = deckId
                }
                cards.append(
                    Flashcard(
                        deckId: deckId, front: item.front, back: item.back, context: item.context,
                        tags: item.tags, ankiGuid: item.guid, dueAt: now()))
            }
            let result = try repository.upsertByGuid(cards)
            statusMessage =
                "Imported \(result.inserted) new card\(result.inserted == 1 ? "" : "s")"
                + (result.updated > 0 ? ", updated \(result.updated)" : "")
                + " into \(deckIds.count) deck\(deckIds.count == 1 ? "" : "s")."
            if deckIds.count == 1 { selectedDeckId = deckIds.values.first }
            reload()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            logger.error("flashcard_import_failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Exports the selected deck, or every deck when none is selected.
    public func exportPackage(to url: URL) async {
        guard let repository else { return }
        errorMessage = nil
        do {
            let targets = decks.filter { selectedDeckId == nil || $0.id == selectedDeckId }.map(\.deck)
            let payload = try targets.map { (deck: $0, cards: try repository.cards(deckId: $0.id)) }
            let count = payload.reduce(0) { $0 + $1.cards.count }
            guard count > 0 else {
                errorMessage = "There are no cards to export."
                return
            }
            try await Task.detached {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try AnkiPackageWriter().write(decks: payload, to: url)
            }.value
            statusMessage = "Exported \(count) card\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
            logger.error("flashcard_export_failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - Generation from transcripts

    public func generateDrafts(
        from transcript: String,
        style: FlashcardStyle,
        meaningLanguage: TranslationLanguage,
        maxCards: Int,
        focus: FlashcardFocus = FlashcardFocus()
    ) {
        guard let generator, !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        // Words already saved in any deck or waiting as drafts are not re-made.
        let savedFronts = (try? repository?.allFronts()) ?? []
        let known = Set((savedFronts + drafts.map(\.front)).map(FlashcardDraft.duplicateKey))
        generationTask = Task { [weak self] in
            do {
                let result = try await generator.generate(
                    from: transcript, style: style, meaningLanguage: meaningLanguage, maxCards: maxCards,
                    focus: focus, excluding: known)
                guard let self else { return }
                var seen = Set(self.drafts.map { FlashcardDraft.duplicateKey($0.front) })
                self.drafts.append(contentsOf: result.filter { seen.insert(FlashcardDraft.duplicateKey($0.front)).inserted })
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.logger.error(
                    "flashcard_generation_failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
            self?.isGenerating = false
            self?.generationTask = nil
        }
    }

    public func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    public func addEmptyDraft(front: String = "", context: String? = nil) {
        drafts.append(FlashcardDraft(front: front, back: "", context: context))
    }

    public func clearDrafts() {
        drafts = []
        errorMessage = nil
    }

    /// Saves valid drafts into the named deck. Returns how many were saved.
    @discardableResult
    public func saveDrafts(toDeckNamed deckName: String, sourceTranscriptionId: UUID?, tag: String?) -> Int {
        guard let repository else { return 0 }
        let valid = drafts.filter(\.isValid)
        guard !valid.isEmpty else { return 0 }
        do {
            let deck = try repository.findOrCreateDeck(named: deckName)
            // Skip words any deck already has, and repeats within this batch.
            var seen = Set(try repository.allFronts().map(FlashcardDraft.duplicateKey))
            let fresh = valid.filter { seen.insert(FlashcardDraft.duplicateKey($0.front)).inserted }
            let skipped = valid.count - fresh.count
            let cards = fresh.map {
                var card = makeCard(from: $0, deckId: deck.id, sourceTranscriptionId: sourceTranscriptionId)
                card.tags = tag
                return card
            }
            if !cards.isEmpty { try repository.insert(cards) }
            drafts = []
            statusMessage = "Added \(cards.count) card\(cards.count == 1 ? "" : "s") to “\(deck.name)”."
                + (skipped > 0 ? " Skipped \(skipped) already in your decks." : "")
            reload()
            return cards.count
        } catch {
            report(error, context: "save_drafts")
            return 0
        }
    }

    // MARK: - Helpers

    private func makeCard(from draft: FlashcardDraft, deckId: UUID, sourceTranscriptionId: UUID?) -> Flashcard {
        let context = draft.context?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Flashcard(
            deckId: deckId,
            front: draft.front.trimmingCharacters(in: .whitespacesAndNewlines),
            back: draft.back.trimmingCharacters(in: .whitespacesAndNewlines),
            context: (context?.isEmpty ?? true) ? nil : context,
            sourceTranscriptionId: sourceTranscriptionId,
            dueAt: now()
        )
    }

    private func report(_ error: Error, context: String) {
        errorMessage = error.localizedDescription
        logger.error(
            "flashcards_\(context, privacy: .public)_failed error=\(String(describing: type(of: error)), privacy: .public)")
    }
}
