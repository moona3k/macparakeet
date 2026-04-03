import XCTest
@testable import CLI
@testable import MacParakeetCore

final class StatsCommandTests: XCTestCase {

    func testEmptyDatabaseProducesZeroStats() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)
        let stats = try repo.stats()

        XCTAssertEqual(stats.visibleCount, 0)
        XCTAssertEqual(stats.totalWords, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
        XCTAssertTrue(stats.isEmpty)
    }

    func testStatsReflectSavedDictations() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)

        let d1 = Dictation(durationMs: 5000, rawTranscript: "Hello world test", wordCount: 3)
        let d2 = Dictation(durationMs: 10000, rawTranscript: "Another dictation here with more words", wordCount: 6)
        try repo.save(d1)
        try repo.save(d2)

        let stats = try repo.stats()
        XCTAssertEqual(stats.visibleCount, 2)
        XCTAssertEqual(stats.totalWords, 9)
        XCTAssertEqual(stats.totalDurationMs, 15000)
        XCTAssertFalse(stats.isEmpty)
    }

    func testHiddenDictationsExcludedFromVisibleCount() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)

        let visible = Dictation(durationMs: 3000, rawTranscript: "Visible", wordCount: 1)
        var hidden = Dictation(durationMs: 4000, rawTranscript: "Hidden", wordCount: 1)
        hidden.hidden = true
        try repo.save(visible)
        try repo.save(hidden)

        let stats = try repo.stats()
        // visibleCount should only include non-hidden
        XCTAssertEqual(stats.visibleCount, 1)
        // totalCount includes hidden
        XCTAssertEqual(stats.totalCount, 2)
    }

    func testTranscriptionCountAndFavorites() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let t1 = Transcription(fileName: "a.mp3", status: .completed)
        let t2 = Transcription(fileName: "b.mp3", status: .completed)
        try repo.save(t1)
        try repo.save(t2)

        try repo.updateFavorite(id: t2.id, isFavorite: true)

        let all = try repo.fetchAll()
        let favorites = try repo.fetchFavorites()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites.first?.id, t2.id)
    }
}
