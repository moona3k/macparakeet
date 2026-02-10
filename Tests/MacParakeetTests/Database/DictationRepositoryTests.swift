import XCTest
import GRDB
@testable import MacParakeetCore

final class DictationRepositoryTests: XCTestCase {
    var repo: DictationRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = DictationRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - CRUD

    func testSaveAndFetch() throws {
        let dictation = Dictation(
            durationMs: 5000,
            rawTranscript: "Hello world"
        )
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.rawTranscript, "Hello world")
        XCTAssertEqual(fetched?.durationMs, 5000)
        XCTAssertEqual(fetched?.status, .completed)
        XCTAssertEqual(fetched?.processingMode, .raw)
    }

    func testFetchNonExistent() throws {
        let fetched = try repo.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    func testFetchAll() throws {
        let d1 = Dictation(
            createdAt: Date(timeIntervalSinceNow: -100),
            durationMs: 1000,
            rawTranscript: "First",
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let d2 = Dictation(
            createdAt: Date(timeIntervalSinceNow: -50),
            durationMs: 2000,
            rawTranscript: "Second",
            updatedAt: Date(timeIntervalSinceNow: -50)
        )
        let d3 = Dictation(
            durationMs: 3000,
            rawTranscript: "Third"
        )

        try repo.save(d1)
        try repo.save(d2)
        try repo.save(d3)

        let all = try repo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 3)
        // Most recent first
        XCTAssertEqual(all[0].rawTranscript, "Third")
        XCTAssertEqual(all[1].rawTranscript, "Second")
        XCTAssertEqual(all[2].rawTranscript, "First")
    }

    func testFetchAllWithLimit() throws {
        for i in 0..<5 {
            try repo.save(Dictation(
                durationMs: i * 1000,
                rawTranscript: "Dictation \(i)"
            ))
        }

        let limited = try repo.fetchAll(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    func testDelete() throws {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "To be deleted"
        )
        try repo.save(dictation)

        let deleted = try repo.delete(id: dictation.id)
        XCTAssertTrue(deleted)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertNil(fetched)
    }

    func testDeleteNonExistent() throws {
        let deleted = try repo.delete(id: UUID())
        XCTAssertFalse(deleted)
    }

    func testDeleteAll() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "One"))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "Two"))

        try repo.deleteAll()

        let all = try repo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 0)
    }

    // MARK: - FTS5 Search

    func testSearchFindsMatchingDictations() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Meeting about budget"))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "Call with Sarah"))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "Budget review notes"))

        let results = try repo.search(query: "budget", limit: nil)
        XCTAssertEqual(results.count, 2)
    }

    func testSearchReturnsEmptyForNoMatch() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Hello world"))

        let results = try repo.search(query: "nonexistent", limit: nil)
        XCTAssertEqual(results.count, 0)
    }

    func testSearchWithLimit() throws {
        for i in 0..<5 {
            try repo.save(Dictation(durationMs: 1000, rawTranscript: "Meeting item \(i)"))
        }

        let results = try repo.search(query: "meeting", limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testSearchEmptyQuery() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Hello"))
        let results = try repo.search(query: "", limit: nil)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Stats

    func testStats() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "One"))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "Two"))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "Three"))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.totalDurationMs, 6000)
    }

    func testStatsEmpty() throws {
        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
    }

    // MARK: - Update (save existing)

    func testUpdateDictation() throws {
        var dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "Original"
        )
        try repo.save(dictation)

        dictation.rawTranscript = "Updated"
        dictation.updatedAt = Date()
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertEqual(fetched?.rawTranscript, "Updated")
    }
}
