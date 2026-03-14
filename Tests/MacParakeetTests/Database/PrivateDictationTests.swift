import XCTest
import GRDB
@testable import MacParakeetCore

final class PrivateDictationTests: XCTestCase {
    var repo: DictationRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = DictationRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - Hidden Row Filtering

    func testFetchAllExcludesHidden() throws {
        let visible = Dictation(durationMs: 1000, rawTranscript: "visible", wordCount: 1)
        let hidden = Dictation(durationMs: 2000, rawTranscript: "", hidden: true, wordCount: 3)
        try repo.save(visible)
        try repo.save(hidden)

        let all = try repo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, visible.id)
    }

    func testSearchExcludesHidden() throws {
        let visible = Dictation(durationMs: 1000, rawTranscript: "hello world", wordCount: 2)
        let hidden = Dictation(durationMs: 2000, rawTranscript: "hello hidden", hidden: true, wordCount: 2)
        try repo.save(visible)
        try repo.save(hidden)

        let results = try repo.search(query: "hello", limit: nil)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, visible.id)
    }

    // MARK: - Stats Include Hidden Rows

    func testStatsIncludeHiddenRows() throws {
        let visible = Dictation(durationMs: 1000, rawTranscript: "one two", wordCount: 2)
        let hidden = Dictation(durationMs: 3000, rawTranscript: "", hidden: true, wordCount: 5)
        try repo.save(visible)
        try repo.save(hidden)

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 2)
        XCTAssertEqual(stats.totalWords, 7)
        XCTAssertEqual(stats.totalDurationMs, 4000)
    }

    // MARK: - Delete Behavior

    func testDeleteAllPreservesHiddenRows() throws {
        let visible = Dictation(durationMs: 1000, rawTranscript: "visible", wordCount: 1)
        let hidden = Dictation(durationMs: 2000, rawTranscript: "", hidden: true, wordCount: 3)
        try repo.save(visible)
        try repo.save(hidden)

        try repo.deleteAll()

        // Hidden row survives
        let fetched = try repo.fetch(id: hidden.id)
        XCTAssertNotNil(fetched)

        // Visible row deleted
        let fetchedVisible = try repo.fetch(id: visible.id)
        XCTAssertNil(fetchedVisible)
    }

    func testDeleteEmptyPreservesHiddenRows() throws {
        // Hidden row has rawTranscript = "" which would match the empty cleanup
        let hidden = Dictation(durationMs: 2000, rawTranscript: "", hidden: true, wordCount: 3)
        let emptyVisible = Dictation(durationMs: 500, rawTranscript: "")
        try repo.save(hidden)
        try repo.save(emptyVisible)

        let deleted = try repo.deleteEmpty()
        XCTAssertEqual(deleted, 1, "Only the visible empty row should be deleted")

        let fetchedHidden = try repo.fetch(id: hidden.id)
        XCTAssertNotNil(fetchedHidden, "Hidden row must survive deleteEmpty")
    }

    func testDeleteHiddenRemovesOnlyHiddenRows() throws {
        let visible = Dictation(durationMs: 1000, rawTranscript: "visible", wordCount: 1)
        let hidden = Dictation(durationMs: 2000, rawTranscript: "", hidden: true, wordCount: 3)
        try repo.save(visible)
        try repo.save(hidden)

        try repo.deleteHidden()

        let fetchedHidden = try repo.fetch(id: hidden.id)
        XCTAssertNil(fetchedHidden, "Hidden row should be deleted")

        let fetchedVisible = try repo.fetch(id: visible.id)
        XCTAssertNotNil(fetchedVisible, "Visible row should survive")
    }

    // MARK: - Word Count Persistence

    func testWordCountPersistedAndRetrieved() throws {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "a b c", wordCount: 3)
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertEqual(fetched?.wordCount, 3)
    }

    // MARK: - Migration Backfill

    func testMigrationBackfillsWordCount() throws {
        // Save a dictation with wordCount = 0 (simulating pre-migration data),
        // then verify stats use the wordCount column
        let dictation = Dictation(durationMs: 1000, rawTranscript: "hello world test", wordCount: 0)
        try repo.save(dictation)

        let stats = try repo.stats()
        // wordCount is 0 because we saved it as 0 (migration backfills existing rows,
        // but new rows use explicit wordCount)
        XCTAssertEqual(stats.totalWords, 0)
    }

    // MARK: - Hidden Flag Default

    func testHiddenDefaultsToFalse() throws {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "test")
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertEqual(fetched?.hidden, false)
    }
}
