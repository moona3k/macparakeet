import ArgumentParser
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

    func testDeleteTranscriptionCommandKeepsRecordWhenOwnedAudioCleanupFails() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        try AppPaths.ensureDirectories()
        let protectedDir = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
            .appendingPathComponent("macparakeet-cli-protected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedDir, withIntermediateDirectories: true)
        let audioURL = protectedDir.appendingPathComponent("asset.m4a")
        _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDir.path)
            try? FileManager.default.removeItem(at: protectedDir)
        }

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
        XCTAssertThrowsError(try captureStandardOutput {
            try command.run()
        })

        XCTAssertNotNil(try repo.fetch(id: transcription.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDeleteMeetingAudioCommandKeepsTranscriptAndClearsFilePath() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        try AppPaths.ensureDirectories()
        let folder = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent("macparakeet-cli-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting.m4a")
        let systemAudioURL = folder.appendingPathComponent("system.m4a")
        let notesURL = folder.appendingPathComponent("notes.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemAudioURL.path, contents: Data("system".utf8)))
        try "notes".write(to: notesURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folder) }

        let transcription = Transcription(
            fileName: "meeting.m4a",
            filePath: audioURL.path,
            rawTranscript: "Discuss retention",
            status: .completed,
            sourceType: .meeting
        )
        try repo.save(transcription)

        let command = try DeleteMeetingAudioSubcommand.parse([
            transcription.id.uuidString,
            "--database", dbURL.path,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        let fetched = try XCTUnwrap(repo.fetch(id: transcription.id))
        XCTAssertNil(fetched.filePath)
        XCTAssertEqual(fetched.meetingArtifactFolderPath, folder.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesURL.path))
        XCTAssertTrue(output.contains("Detached managed meeting audio"))
    }

    func testClearMeetingAudioCommandRemovesAudioAndPreservesArtifactFolders() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let meetingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-meetings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: meetingRoot) }
        let folder = meetingRoot.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting.m4a")
        let notesURL = folder.appendingPathComponent("notes.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        try Data("notes".utf8).write(to: notesURL)

        let meeting = Transcription(
            fileName: "meeting.m4a",
            filePath: audioURL.path,
            rawTranscript: "Discuss retention",
            status: .completed,
            sourceType: .meeting
        )
        let local = Transcription(
            fileName: "local.m4a",
            filePath: "/tmp/local.m4a",
            rawTranscript: "Local",
            status: .completed,
            sourceType: .file
        )
        let externalMeeting = Transcription(
            fileName: "external-meeting.m4a",
            filePath: "/tmp/external-meeting-\(UUID().uuidString).m4a",
            rawTranscript: "External",
            status: .completed,
            sourceType: .meeting
        )
        try repo.save(meeting)
        try repo.save(local)
        try repo.save(externalMeeting)

        let command = try ClearMeetingAudioSubcommand.parse([
            "--database", dbURL.path,
            "--meeting-recordings-directory", meetingRoot.path,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesURL.path))
        let fetchedMeeting = try XCTUnwrap(repo.fetch(id: meeting.id))
        XCTAssertNil(fetchedMeeting.filePath)
        XCTAssertEqual(fetchedMeeting.meetingArtifactFolderPath, folder.standardizedFileURL.path)
        XCTAssertEqual(try repo.fetch(id: local.id)?.filePath, local.filePath)
        XCTAssertEqual(try repo.fetch(id: externalMeeting.id)?.filePath, externalMeeting.filePath)
        XCTAssertTrue(output.contains("Deleted all stored meeting audio"))
    }

    func testClearMeetingAudioCommandRefusesWhileARecordingIsLive() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let meetingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-meetings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: meetingRoot) }
        let folder = meetingRoot.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))

        // A lock file owned by this (alive) test process stands in for a live
        // recording. The CLI must refuse rather than wipe the active folder.
        try MeetingRecordingLockFileStore().write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pid: ProcessInfo.processInfo.processIdentifier,
                displayName: "Live Meeting"
            ),
            folderURL: folder
        )

        let meeting = Transcription(
            fileName: "meeting.m4a",
            filePath: audioURL.path,
            rawTranscript: "In progress",
            status: .completed,
            sourceType: .meeting
        )
        try repo.save(meeting)

        let command = try ClearMeetingAudioSubcommand.parse([
            "--database", dbURL.path,
            "--meeting-recordings-directory", meetingRoot.path,
        ])
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue(error is ValidationError, "Expected a ValidationError, got \(error)")
        }

        // Nothing was deleted and no path was detached.
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(try repo.fetch(id: meeting.id)?.filePath, audioURL.path)
    }

    func testClearMeetingAudioCommandRefusesAwaitingTranscriptionLockEvenWhenOwnerIsDead() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let meetingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-meetings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: meetingRoot) }
        let folder = meetingRoot.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))

        try MeetingRecordingLockFileStore().write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pid: 0,
                displayName: "Awaiting Meeting",
                state: .awaitingTranscription
            ),
            folderURL: folder
        )

        let meeting = Transcription(
            fileName: "meeting.m4a",
            filePath: audioURL.path,
            rawTranscript: nil,
            status: .processing,
            sourceType: .meeting
        )
        try repo.save(meeting)

        let command = try ClearMeetingAudioSubcommand.parse([
            "--database", dbURL.path,
            "--meeting-recordings-directory", meetingRoot.path,
        ])
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue(error is ValidationError, "Expected a ValidationError, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(try repo.fetch(id: meeting.id)?.filePath, audioURL.path)
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

    func testSearchTranscriptionsCommandSearchesChannelName() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let t1 = Transcription(fileName: "video.mp3", status: .completed, channelName: "Swift Talks")
        let t2 = Transcription(fileName: "other.mp3", status: .completed, channelName: "Other Channel")
        try repo.save(t1)
        try repo.save(t2)

        let command = try SearchTranscriptionsSubcommand.parse([
            "swift",
            "--database", dbURL.path,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        XCTAssertTrue(output.contains("video.mp3"))
        XCTAssertFalse(output.contains("other.mp3"))
    }

    func testSearchTranscriptionsCommandMatchesUnicodeCaseInsensitively() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let match = Transcription(
            fileName: "CAFÉ-notes.m4a",
            rawTranscript: "Travel guide for İSTANBUL",
            cleanTranscript: "Résumé follow-up",
            status: .completed
        )
        let other = Transcription(fileName: "other.mp3", rawTranscript: "Unrelated", status: .completed)
        try repo.save(match)
        try repo.save(other)

        let command = try SearchTranscriptionsSubcommand.parse([
            "istanbul",
            "--database", dbURL.path,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        XCTAssertTrue(output.contains("CAFÉ-notes.m4a"))
        XCTAssertFalse(output.contains("other.mp3"))
    }

    func testSearchTranscriptionsCommandEmptyQueryReturnsNoRows() throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        try repo.save(Transcription(fileName: "video.mp3", status: .completed))

        let command = try SearchTranscriptionsSubcommand.parse([
            "   ",
            "--database", dbURL.path,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        XCTAssertTrue(output.contains("No transcriptions matching"))
        XCTAssertFalse(output.contains("video.mp3"))
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
