import XCTest
import GRDB
@testable import MacParakeetCore

final class FSRSSchedulerTests: XCTestCase {
    /// Reference vectors from open-spaced-repetition FSRS-6 (carried over
    /// from LinguaBrain-AI's scheduler self-check).
    func testFirstReviewMatchesReferenceStabilityAndDifficulty() {
        let scheduler = FSRSScheduler()
        let now = Date(timeIntervalSince1970: 1_672_315_800)
        let expectedStability = [0.212, 1.2931, 2.3065, 8.2956]
        let expectedDifficulty = [6.4133, 5.11217071, 2.11810397, 1.0]
        for (index, grade) in FlashcardGrade.allCases.enumerated() {
            let result = scheduler.schedule(previous: nil, grade: grade, now: now)
            XCTAssertEqual(result.state.stability, expectedStability[index], accuracy: 1e-7)
            XCTAssertEqual(result.state.difficulty, expectedDifficulty[index], accuracy: 1e-7)
        }
    }

    func testReviewSequenceMatchesReferenceIntervals() {
        let scheduler = FSRSScheduler()
        let grades: [FlashcardGrade] = [
            .good, .good, .good, .good, .good, .good, .again, .again, .good, .good, .good, .good, .good,
        ]
        var state: FSRSMemoryState?
        var date = Date(timeIntervalSince1970: 1_672_315_800)
        var intervals: [Int] = []
        for grade in grades {
            let result = scheduler.schedule(previous: state, grade: grade, now: date)
            intervals.append(Int(result.scheduledDays))
            state = result.state
            date = result.dueAt
        }
        XCTAssertEqual(intervals, [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21])
    }

    func testLapseIsCountedOnlyFromReviewPhase() {
        let scheduler = FSRSScheduler()
        let now = Date()
        var card = Flashcard(deckId: UUID(), front: "a", back: "b")
        card.apply(scheduler.schedule(previous: nil, grade: .again, now: now), grade: .again)
        XCTAssertEqual(card.lapses, 0)
        card.apply(scheduler.schedule(previous: card.memoryState, grade: .easy, now: now), grade: .easy)
        XCTAssertEqual(card.phase, .review)
        card.apply(scheduler.schedule(previous: card.memoryState, grade: .again, now: now), grade: .again)
        XCTAssertEqual(card.lapses, 1)
        XCTAssertEqual(card.phase, .relearning)
        XCTAssertEqual(card.reps, 3)
    }
}

final class FlashcardRepositoryTests: XCTestCase {
    var repo: FlashcardRepository!

    override func setUp() async throws {
        repo = FlashcardRepository(dbQueue: try DatabaseManager().dbQueue)
    }

    func testDueQueueReturnsDueCardsBeforeNewCardsAndSkipsFutureCards() throws {
        let deck = try repo.findOrCreateDeck(named: "German")
        let now = Date()
        let fresh = Flashcard(deckId: deck.id, front: "new", back: "x", createdAt: now)
        let due = Flashcard(
            deckId: deck.id, front: "due", back: "x", phase: .review, stability: 3, difficulty: 5,
            lastReviewAt: now.addingTimeInterval(-86_400 * 3), dueAt: now.addingTimeInterval(-60))
        let future = Flashcard(
            deckId: deck.id, front: "later", back: "x", phase: .review, stability: 3, difficulty: 5,
            lastReviewAt: now, dueAt: now.addingTimeInterval(86_400))
        try repo.insert([fresh, due, future])

        XCTAssertEqual(try repo.dueCards(deckId: deck.id, now: now, limit: 10).map(\.front), ["due", "new"])

        let summary = try XCTUnwrap(repo.deckSummaries(now: now).first)
        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.dueCount, 1)
        XCTAssertEqual(summary.newCount, 1)
    }

    func testFindOrCreateDeckReusesExistingName() throws {
        let first = try repo.findOrCreateDeck(named: "Meeting words")
        let second = try repo.findOrCreateDeck(named: "  Meeting words ")
        XCTAssertEqual(first.id, second.id)
    }

    func testUpsertByGuidUpdatesTextAndKeepsReviewState() throws {
        let deck = try repo.findOrCreateDeck(named: "D")
        var card = Flashcard(deckId: deck.id, front: "Hund", back: "dog", ankiGuid: "g1")
        card.phase = .review
        card.reps = 4
        try repo.insert([card])

        let result = try repo.upsertByGuid([
            Flashcard(deckId: deck.id, front: "der Hund", back: "the dog", ankiGuid: "g1"),
            Flashcard(deckId: deck.id, front: "Katze", back: "cat", ankiGuid: "g2"),
        ])
        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.updated, 1)
        let stored = try repo.cards(deckId: deck.id).first { $0.ankiGuid == "g1" }
        XCTAssertEqual(stored?.front, "der Hund")
        XCTAssertEqual(stored?.reps, 4)
        XCTAssertEqual(stored?.phase, .review)
    }

    func testDeletingDeckCascadesToCards() throws {
        let deck = try repo.findOrCreateDeck(named: "Temp")
        try repo.insert([Flashcard(deckId: deck.id, front: "a", back: "b")])
        try repo.deleteDeck(id: deck.id)
        XCTAssertTrue(try repo.cards(deckId: deck.id).isEmpty)
    }
}

final class AnkiPackageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExportedPackageReadsBackWithDecksGuidsAndText() throws {
        let deckA = FlashcardDeck(name: "German::Meetings")
        let deckB = FlashcardDeck(name: "Facts")
        let cards = [
            Flashcard(deckId: deckA.id, front: "die Besprechung", back: "meeting <b>", context: "Die Besprechung beginnt.", tags: "macparakeet", ankiGuid: "guid-1"),
            Flashcard(deckId: deckA.id, front: "Line\nbreak & more", back: "جلسه", ankiGuid: "guid-2"),
        ]
        let facts = [Flashcard(deckId: deckB.id, front: "When is launch?", back: "Friday", ankiGuid: "guid-3")]
        let url = tempDir.appendingPathComponent("out.apkg")

        try AnkiPackageWriter().write(decks: [(deckA, cards), (deckB, facts)], to: url)
        let imported = try AnkiPackageReader().readCards(at: url)

        XCTAssertEqual(imported.count, 3)
        let first = try XCTUnwrap(imported.first { $0.guid == "guid-1" })
        XCTAssertEqual(first.deckName, "German::Meetings")
        XCTAssertEqual(first.front, "die Besprechung")
        XCTAssertEqual(first.back, "meeting <b>")
        XCTAssertEqual(first.context, "Die Besprechung beginnt.")
        XCTAssertEqual(first.tags, "macparakeet")
        let second = try XCTUnwrap(imported.first { $0.guid == "guid-2" })
        XCTAssertEqual(second.front, "Line\nbreak & more")
        XCTAssertEqual(second.back, "جلسه")
        XCTAssertEqual(imported.first { $0.guid == "guid-3" }?.deckName, "Facts")
    }

    func testExportedCollectionUsesStandardAnkiSchema() throws {
        let deck = FlashcardDeck(name: "D")
        let dbURL = tempDir.appendingPathComponent("collection.anki2")
        try AnkiPackageWriter().buildCollection(
            decks: [(deck, [Flashcard(deckId: deck.id, front: "a", back: "b")])], at: dbURL)

        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT ver FROM col"), 11)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT queue FROM cards"), 0)
            let csum = try Int64.fetchOne(db, sql: "SELECT csum FROM notes")
            XCTAssertEqual(csum, AnkiPackageWriter.checksum("a"))
        }
    }

    func testRejectsNonZipAndModernOnlyPackages() throws {
        let junk = tempDir.appendingPathComponent("junk.apkg")
        try Data("not a zip".utf8).write(to: junk)
        XCTAssertThrowsError(try AnkiPackageReader().readCards(at: junk)) {
            XCTAssertEqual($0 as? AnkiPackageError, .malformedArchive)
        }

        var zip = StoredZipBuilder()
        zip.append(name: "collection.anki21b", data: Data([1, 2, 3]))
        zip.append(name: "collection.anki2", data: Data([1, 2, 3]))
        let modern = tempDir.appendingPathComponent("modern.apkg")
        try zip.finalize().write(to: modern)
        XCTAssertThrowsError(try AnkiPackageReader().readCards(at: modern)) {
            XCTAssertEqual($0 as? AnkiPackageError, .unsupportedModernCollection)
        }
    }

    func testRejectsPathTraversalEntries() throws {
        var zip = StoredZipBuilder()
        zip.append(name: "../evil", data: Data([1]))
        let url = tempDir.appendingPathComponent("evil.apkg")
        try zip.finalize().write(to: url)
        XCTAssertThrowsError(try AnkiPackageReader().readCards(at: url)) {
            XCTAssertEqual($0 as? AnkiPackageError, .unsafePath("../evil"))
        }
    }

    func testMapsCommonFieldNamesAndStripsHTML() {
        let card = AnkiPackageReader.mapCard(
            fields: ["<div>Haus</div>[sound:haus.mp3]", "house&nbsp;<br>home", "Das Haus ist groß."],
            names: ["Word", "Meaning", "Example"],
            guid: "g", tags: "", deckName: "D")
        XCTAssertEqual(card?.front, "Haus")
        XCTAssertEqual(card?.back, "house\nhome")
        XCTAssertEqual(card?.context, "Das Haus ist groß.")
        XCTAssertNil(card?.tags)
    }
}

final class FlashcardGenerationParsingTests: XCTestCase {
    func testParsesJSONInsideCodeFenceAndDropsDuplicatesAndBlanks() {
        let response = """
            Here you go:
            ```json
            [
              {"front": "die Frist", "back": "deadline", "context": "Die Frist ist Freitag."},
              {"front": "Die Frist", "back": "deadline again"},
              {"front": "", "back": "x"},
              {"front": "umsetzen", "back": "to implement", "context": ""}
            ]
            ```
            """
        let drafts = FlashcardGenerationService.parse(response)
        XCTAssertEqual(drafts.map(\.front), ["die Frist", "umsetzen"])
        XCTAssertEqual(drafts[0].context, "Die Frist ist Freitag.")
        XCTAssertNil(drafts[1].context)
    }

    func testReturnsEmptyForNonJSON() {
        XCTAssertTrue(FlashcardGenerationService.parse("Sorry, I can't.").isEmpty)
    }
}
