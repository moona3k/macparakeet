import XCTest
@testable import CLI
@testable import MacParakeetCore

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

    func testDeleteDictationCommandRemovesAudioFile() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = DictationRepository(dbQueue: db.dbQueue)

        try AppPaths.ensureDirectories()
        let audioURL = URL(fileURLWithPath: AppPaths.dictationsDir, isDirectory: true)
            .appendingPathComponent("macparakeet-cli-dictation-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))

        let dictation = Dictation(durationMs: 2000, rawTranscript: "Delete me", audioPath: audioURL.path)
        try repo.save(dictation)

        let command = try DeleteDictationSubcommand.parse([
            dictation.id.uuidString,
            "--database", dbURL.path,
        ])
        _ = try captureStandardOutput {
            try command.run()
        }

        XCTAssertNil(try repo.fetch(id: dictation.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDeleteDictationCommandLeavesExternalAudioFile() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = DictationRepository(dbQueue: db.dbQueue)

        let audioURL = temporaryAssetURL(pathExtension: "m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))

        let dictation = Dictation(durationMs: 2000, rawTranscript: "Delete me", audioPath: audioURL.path)
        try repo.save(dictation)

        let command = try DeleteDictationSubcommand.parse([
            dictation.id.uuidString,
            "--database", dbURL.path,
        ])
        _ = try captureStandardOutput {
            try command.run()
        }

        XCTAssertNil(try repo.fetch(id: dictation.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
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

    func testDeleteTranscriptionCommandRemovesOwnedYouTubeAudio() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        try AppPaths.ensureDirectories()
        let audioURL = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
            .appendingPathComponent("macparakeet-cli-asset-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))

        let transcription = Transcription(
            fileName: "delete-me.m4a",
            filePath: audioURL.path,
            rawTranscript: "Goodbye",
            status: .completed,
            sourceType: .youtube
        )
        try repo.save(transcription)

        let command = try DeleteTranscriptionSubcommand.parse([
            transcription.id.uuidString,
            "--database", dbURL.path,
        ])
        _ = try captureStandardOutput {
            try command.run()
        }

        XCTAssertNil(try repo.fetch(id: transcription.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
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

        let results = try repo.search(query: "meeting")
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

        let results = try repo.search(query: "fox")
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
        let results = try repo.search(query: "proposal")
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

        let results = try repo.search(query: "common", limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-\(UUID().uuidString).db")
    }

    private func temporaryAssetURL(pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-asset-\(UUID().uuidString).\(pathExtension)")
    }

}
