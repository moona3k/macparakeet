import XCTest
@testable import MacParakeetCore

/// Edge case tests for both repositories: special characters, empty data, concurrent operations.
final class RepositoryEdgeCaseTests: XCTestCase {
    var dbManager: DatabaseManager!
    var dictationRepo: DictationRepository!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        dbManager = try DatabaseManager()
        dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
    }

    // MARK: - Dictation Edge Cases

    func testSearchWithEmptyQuery() throws {
        let d = Dictation(durationMs: 1000, rawTranscript: "Hello world")
        try dictationRepo.save(d)

        let results = try dictationRepo.search(query: "", limit: nil)
        XCTAssertTrue(results.isEmpty, "Empty query should return no results")
    }

    func testSearchWithUnicodeContent() throws {
        let d = Dictation(durationMs: 1000, rawTranscript: "The caf\u{00E9} is on Stra\u{00DF}e in Z\u{00FC}rich")
        try dictationRepo.save(d)

        let results = try dictationRepo.search(query: "caf\u{00E9}", limit: nil)
        XCTAssertEqual(results.count, 1)
    }

    func testSearchWithNoMatches() throws {
        let d = Dictation(durationMs: 1000, rawTranscript: "Hello world")
        try dictationRepo.save(d)

        let results = try dictationRepo.search(query: "nonexistent", limit: nil)
        XCTAssertTrue(results.isEmpty)
    }

    func testFetchNonExistentDictation() throws {
        let result = try dictationRepo.fetch(id: UUID())
        XCTAssertNil(result)
    }

    func testDeleteNonExistentDictation() throws {
        let deleted = try dictationRepo.delete(id: UUID())
        XCTAssertFalse(deleted)
    }

    func testDeleteAllEmptyTable() throws {
        // Should not throw even if table is empty
        try dictationRepo.deleteAll()
        let stats = try dictationRepo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
    }

    func testFetchAllWithLimitZero() throws {
        try dictationRepo.save(Dictation(durationMs: 1000, rawTranscript: "Test"))
        let results = try dictationRepo.fetchAll(limit: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testLargeTranscriptStorage() throws {
        let longText = String(repeating: "Hello world. ", count: 10000)
        let d = Dictation(durationMs: 300000, rawTranscript: longText)
        try dictationRepo.save(d)

        let fetched = try dictationRepo.fetch(id: d.id)
        XCTAssertEqual(fetched?.rawTranscript.count, longText.count)
    }

    func testStatsWithMultipleDictations() throws {
        try dictationRepo.save(Dictation(durationMs: 1000, rawTranscript: "One"))
        try dictationRepo.save(Dictation(durationMs: 2000, rawTranscript: "Two"))
        try dictationRepo.save(Dictation(durationMs: 3000, rawTranscript: "Three"))

        let stats = try dictationRepo.stats()
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.totalDurationMs, 6000)
    }

    func testUpdateDictation() throws {
        var d = Dictation(durationMs: 1000, rawTranscript: "Original")
        try dictationRepo.save(d)

        d.rawTranscript = "Updated"
        d.cleanTranscript = "Updated clean"
        d.status = .completed
        try dictationRepo.save(d)

        let fetched = try dictationRepo.fetch(id: d.id)
        XCTAssertEqual(fetched?.rawTranscript, "Updated")
        XCTAssertEqual(fetched?.cleanTranscript, "Updated clean")

        // Verify count didn't increase (save should upsert)
        let all = try dictationRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
    }

    func testSearchAfterUpdateFindsNewContent() throws {
        var d = Dictation(durationMs: 1000, rawTranscript: "Original content")
        try dictationRepo.save(d)

        d.rawTranscript = "Updated Kubernetes content"
        try dictationRepo.save(d)

        let results = try dictationRepo.search(query: "Kubernetes", limit: nil)
        XCTAssertEqual(results.count, 1)

        let oldResults = try dictationRepo.search(query: "Original", limit: nil)
        // After update, FTS trigger should remove old content
        XCTAssertTrue(oldResults.isEmpty)
    }

    // MARK: - Transcription Edge Cases

    func testFetchNonExistentTranscription() throws {
        let result = try transcriptionRepo.fetch(id: UUID())
        XCTAssertNil(result)
    }

    func testTranscriptionWithSpecialFileNames() throws {
        let t = Transcription(
            fileName: "interview (final copy) [2024].mp3",
            filePath: "/Users/test/interview (final copy) [2024].mp3"
        )
        try transcriptionRepo.save(t)

        let fetched = try transcriptionRepo.fetch(id: t.id)
        XCTAssertEqual(fetched?.fileName, "interview (final copy) [2024].mp3")
    }

    func testTranscriptionWithEmptyWordTimestamps() throws {
        let t = Transcription(
            fileName: "empty.wav",
            rawTranscript: "Hello",
            wordTimestamps: [],
            status: .completed
        )
        try transcriptionRepo.save(t)

        let fetched = try transcriptionRepo.fetch(id: t.id)
        XCTAssertEqual(fetched?.wordTimestamps?.count, 0)
    }

    func testUpdateStatusNonExistentIDIsNoOp() throws {
        // Updating a non-existent transcription silently does nothing
        try transcriptionRepo.updateStatus(id: UUID(), status: .completed, errorMessage: nil)

        // Verify no records were created
        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteAllTranscriptions() throws {
        try transcriptionRepo.save(Transcription(fileName: "a.mp3", status: .completed))
        try transcriptionRepo.save(Transcription(fileName: "b.wav", status: .completed))

        try transcriptionRepo.deleteAll()

        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertTrue(all.isEmpty)
    }

    func testFetchAllOrdering() throws {
        let older = Transcription(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1000),
            fileName: "older.mp3",
            status: .completed,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let newer = Transcription(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2000),
            fileName: "newer.mp3",
            status: .completed,
            updatedAt: Date(timeIntervalSince1970: 2000)
        )

        try transcriptionRepo.save(older)
        try transcriptionRepo.save(newer)

        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].fileName, "newer.mp3")
        XCTAssertEqual(all[1].fileName, "older.mp3")
    }
}
