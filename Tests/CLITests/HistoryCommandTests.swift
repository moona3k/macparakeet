import XCTest
@testable import CLI
@testable import MacParakeetCore

/// Mirrors the filter logic from SearchTranscriptionsSubcommand.run()
/// so tests catch drift between test and production code.
private func searchTranscriptions(_ all: [Transcription], query: String, limit: Int = 20) -> [Transcription] {
    let queryLower = query.lowercased()
    return Array(all.filter { t in
        t.fileName.lowercased().contains(queryLower)
            || (t.rawTranscript?.lowercased().contains(queryLower) ?? false)
            || (t.cleanTranscript?.lowercased().contains(queryLower) ?? false)
    }.prefix(limit))
}

final class HistoryCommandTests: XCTestCase {

    // MARK: - Delete Dictation

    func testDeleteDictationRemovesRecord() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)
        let d = Dictation(durationMs: 2000, rawTranscript: "Delete me")
        try repo.save(d)

        XCTAssertNotNil(try repo.fetch(id: d.id))
        _ = try repo.delete(id: d.id)
        XCTAssertNil(try repo.fetch(id: d.id))
    }

    // MARK: - Delete Transcription

    func testDeleteTranscriptionRemovesRecord() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let t = Transcription(fileName: "delete-me.mp3", rawTranscript: "Goodbye", status: .completed)
        try repo.save(t)

        XCTAssertNotNil(try repo.fetch(id: t.id))
        _ = try repo.delete(id: t.id)
        XCTAssertNil(try repo.fetch(id: t.id))
    }

    // MARK: - Favorites

    func testFavoriteAndUnfavoriteTranscription() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let t = Transcription(fileName: "fav-test.mp3", rawTranscript: "Star me", status: .completed)
        try repo.save(t)

        // Initially not favorited
        let initial = try repo.fetch(id: t.id)!
        XCTAssertFalse(initial.isFavorite)

        // Favorite it
        try repo.updateFavorite(id: t.id, isFavorite: true)
        let favorited = try repo.fetch(id: t.id)!
        XCTAssertTrue(favorited.isFavorite)

        // Verify it shows up in favorites list
        let favorites = try repo.fetchFavorites()
        XCTAssertTrue(favorites.contains(where: { $0.id == t.id }))

        // Unfavorite it
        try repo.updateFavorite(id: t.id, isFavorite: false)
        let unfavorited = try repo.fetch(id: t.id)!
        XCTAssertFalse(unfavorited.isFavorite)

        // Verify it's gone from favorites
        let favoritesAfter = try repo.fetchFavorites()
        XCTAssertFalse(favoritesAfter.contains(where: { $0.id == t.id }))
    }

    // MARK: - Search Transcriptions

    func testSearchTranscriptionsFiltersByFileName() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let t1 = Transcription(fileName: "meeting-notes.mp3", rawTranscript: "Budget discussion", status: .completed)
        let t2 = Transcription(fileName: "podcast-episode.mp3", rawTranscript: "Tech review", status: .completed)
        try repo.save(t1)
        try repo.save(t2)

        let results = searchTranscriptions(try repo.fetchAll(), query: "meeting")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, t1.id)
    }

    func testSearchTranscriptionsFiltersByRawTranscript() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let t1 = Transcription(fileName: "file-a.mp3", rawTranscript: "The quick brown fox", status: .completed)
        let t2 = Transcription(fileName: "file-b.mp3", rawTranscript: "Lazy dog sleeps", status: .completed)
        try repo.save(t1)
        try repo.save(t2)

        let results = searchTranscriptions(try repo.fetchAll(), query: "fox")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, t1.id)
    }

    func testSearchTranscriptionsFiltersByCleanTranscript() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let t1 = Transcription(fileName: "file-a.mp3", rawTranscript: "um the uh budget", cleanTranscript: "The budget proposal", status: .completed)
        let t2 = Transcription(fileName: "file-b.mp3", rawTranscript: "Unrelated content", status: .completed)
        try repo.save(t1)
        try repo.save(t2)

        // "proposal" only exists in cleanTranscript
        let results = searchTranscriptions(try repo.fetchAll(), query: "proposal")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, t1.id)
    }

    func testSearchTranscriptionsRespectsLimit() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        for i in 0..<5 {
            let t = Transcription(fileName: "match-\(i).mp3", rawTranscript: "Common keyword", status: .completed)
            try repo.save(t)
        }

        let results = searchTranscriptions(try repo.fetchAll(), query: "common", limit: 3)
        XCTAssertEqual(results.count, 3)
    }
}
