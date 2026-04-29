import XCTest
import GRDB
@testable import MacParakeetCore

final class TranscriptionRepositoryTests: XCTestCase {
    var repo: TranscriptionRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - CRUD

    func testSaveAndFetch() throws {
        let transcription = Transcription(
            fileName: "interview.mp3",
            filePath: "/tmp/interview.mp3",
            fileSizeBytes: 1024000
        )
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.fileName, "interview.mp3")
        XCTAssertEqual(fetched?.status, .processing)
        XCTAssertEqual(fetched?.language, "en")
    }

    func testFetchNonExistent() throws {
        let fetched = try repo.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    func testEngineAttributionRoundTrips() throws {
        let transcription = Transcription(
            fileName: "engine.mp3",
            engine: SpeechEnginePreference.whisper.rawValue,
            engineVariant: SpeechEnginePreference.defaultWhisperModelVariant
        )
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.engine, "whisper")
        XCTAssertEqual(fetched?.engineVariant, SpeechEnginePreference.defaultWhisperModelVariant)
    }

    func testLegacyTranscriptionDecodesWithNilEngineFields() throws {
        let transcription = Transcription(fileName: "legacy.mp3")
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNil(fetched?.engine)
        XCTAssertNil(fetched?.engineVariant)
    }

    func testFetchAll() throws {
        let t1 = Transcription(
            createdAt: Date(timeIntervalSinceNow: -100),
            fileName: "first.mp3",
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let t2 = Transcription(
            createdAt: Date(timeIntervalSinceNow: -50),
            fileName: "second.mp3",
            updatedAt: Date(timeIntervalSinceNow: -50)
        )
        let t3 = Transcription(
            fileName: "third.mp3"
        )

        try repo.save(t1)
        try repo.save(t2)
        try repo.save(t3)

        let all = try repo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 3)
        // Most recent first
        XCTAssertEqual(all[0].fileName, "third.mp3")
    }

    func testFetchAllWithLimit() throws {
        for i in 0..<5 {
            try repo.save(Transcription(fileName: "file\(i).mp3"))
        }

        let limited = try repo.fetchAll(limit: 2)
        XCTAssertEqual(limited.count, 2)
    }

    func testFetchByFilePathFiltersBySourceTypeAndOrdersNewestFirst() throws {
        let path = "/tmp/meeting.m4a"
        let olderMeeting = Transcription(
            createdAt: Date(timeIntervalSinceNow: -100),
            fileName: "older meeting",
            filePath: path,
            sourceType: .meeting,
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let newerMeeting = Transcription(
            createdAt: Date(timeIntervalSinceNow: -10),
            fileName: "newer meeting",
            filePath: path,
            sourceType: .meeting,
            updatedAt: Date(timeIntervalSinceNow: -10)
        )
        let fileTranscription = Transcription(
            fileName: "regular file",
            filePath: path,
            sourceType: .file
        )
        let otherMeeting = Transcription(
            fileName: "other meeting",
            filePath: "/tmp/other.m4a",
            sourceType: .meeting
        )

        try repo.save(olderMeeting)
        try repo.save(newerMeeting)
        try repo.save(fileTranscription)
        try repo.save(otherMeeting)

        let results = try repo.fetchByFilePath(path, sourceType: .meeting)

        XCTAssertEqual(results.map(\.id), [newerMeeting.id, olderMeeting.id])
    }

    func testFetchBySourceTypeFiltersAndOrdersNewestFirst() throws {
        let olderMeeting = Transcription(
            createdAt: Date(timeIntervalSinceNow: -100),
            fileName: "older meeting",
            sourceType: .meeting,
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let newerMeeting = Transcription(
            createdAt: Date(timeIntervalSinceNow: -10),
            fileName: "newer meeting",
            sourceType: .meeting,
            updatedAt: Date(timeIntervalSinceNow: -10)
        )
        let fileTranscription = Transcription(fileName: "regular file", sourceType: .file)

        try repo.save(olderMeeting)
        try repo.save(newerMeeting)
        try repo.save(fileTranscription)

        let results = try repo.fetchBySourceType(.meeting)

        XCTAssertEqual(results.map(\.id), [newerMeeting.id, olderMeeting.id])
    }

    func testFetchBySourceTypeAndIDPrefixFiltersInDatabase() throws {
        let meetingID = UUID(uuidString: "AABBCCDD-1111-1111-1111-111111111111")!
        let otherMeetingID = UUID(uuidString: "CCDDEEFF-1111-1111-1111-111111111111")!
        let meeting = Transcription(id: meetingID, fileName: "Planning", sourceType: .meeting)
        let otherMeeting = Transcription(id: otherMeetingID, fileName: "Other", sourceType: .meeting)
        let file = Transcription(
            id: UUID(uuidString: "AABBCCDD-2222-2222-2222-222222222222")!,
            fileName: "File",
            sourceType: .file
        )
        try repo.save(meeting)
        try repo.save(otherMeeting)
        try repo.save(file)

        let results = try repo.fetchBySourceType(.meeting, idPrefix: "aabbccdd")

        XCTAssertEqual(results.map(\.id), [meetingID])
        XCTAssertEqual(try repo.fetchBySourceType(.meeting, idPrefix: "AABBCCDD-1111").map(\.id), [meetingID])
    }

    func testFetchByIDPrefixFiltersInDatabaseAcrossSourceTypes() throws {
        let olderID = UUID(uuidString: "AABBCCDD-1111-1111-1111-111111111111")!
        let newerID = UUID(uuidString: "AABBCCDD-2222-2222-2222-222222222222")!
        let otherID = UUID(uuidString: "CCDDEEFF-1111-1111-1111-111111111111")!
        let older = Transcription(
            id: olderID,
            createdAt: Date(timeIntervalSinceNow: -100),
            fileName: "Older",
            sourceType: .file,
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let newer = Transcription(
            id: newerID,
            createdAt: Date(timeIntervalSinceNow: -10),
            fileName: "Newer",
            sourceType: .meeting,
            updatedAt: Date(timeIntervalSinceNow: -10)
        )
        let other = Transcription(id: otherID, fileName: "Other", sourceType: .file)
        try repo.save(older)
        try repo.save(newer)
        try repo.save(other)

        let results = try repo.fetchByIDPrefix("aabbccdd")

        XCTAssertEqual(results.map(\.id), [newerID, olderID])
        XCTAssertEqual(try repo.fetchByIDPrefix("AABBCCDD-1111").map(\.id), [olderID])
    }

    func testFetchBySourceTypeAndFileNameIsCaseInsensitive() throws {
        let meeting = Transcription(fileName: "Design Review", sourceType: .meeting)
        let file = Transcription(fileName: "Design Review", sourceType: .file)
        try repo.save(meeting)
        try repo.save(file)

        let results = try repo.fetchBySourceType(.meeting, fileName: "design review")

        XCTAssertEqual(results.map(\.id), [meeting.id])
    }

    func testUpdateUserNotesPreservesOtherFields() throws {
        let transcription = Transcription(
            fileName: "Meeting Apr 5",
            rawTranscript: "Transcript",
            status: .completed,
            sourceType: .meeting
        )
        try repo.save(transcription)

        try repo.updateUserNotes(id: transcription.id, userNotes: "Decision: ship it")

        let fetched = try XCTUnwrap(repo.fetch(id: transcription.id))
        XCTAssertEqual(fetched.userNotes, "Decision: ship it")
        XCTAssertEqual(fetched.rawTranscript, "Transcript")
        XCTAssertEqual(fetched.sourceType, .meeting)
    }

    func testDelete() throws {
        let transcription = Transcription(fileName: "delete-me.mp3")
        try repo.save(transcription)

        let deleted = try repo.delete(id: transcription.id)
        XCTAssertTrue(deleted)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNil(fetched)
    }

    func testDeleteNonExistent() throws {
        let deleted = try repo.delete(id: UUID())
        XCTAssertFalse(deleted)
    }

    func testDeleteAll() throws {
        try repo.save(Transcription(fileName: "one.mp3"))
        try repo.save(Transcription(fileName: "two.mp3"))

        try repo.deleteAll()

        let all = try repo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 0)
    }

    // MARK: - Search

    func testSearchMatchesUnicodeCaseInsensitively() throws {
        try repo.save(
            Transcription(
                fileName: "CAFÉ-notes.m4a",
                rawTranscript: "Travel guide for İSTANBUL",
                cleanTranscript: "Met at the Café",
                status: .completed
            )
        )

        let fileNameResults = try repo.search(query: "café", limit: nil)
        XCTAssertEqual(fileNameResults.count, 1)

        let transcriptResults = try repo.search(query: "istanbul", limit: nil)
        XCTAssertEqual(transcriptResults.count, 1)
    }

    // MARK: - Status Transitions

    func testUpdateStatus() throws {
        let transcription = Transcription(fileName: "test.mp3")
        try repo.save(transcription)
        XCTAssertEqual(try repo.fetch(id: transcription.id)?.status, .processing)

        try repo.updateStatus(id: transcription.id, status: .completed)
        XCTAssertEqual(try repo.fetch(id: transcription.id)?.status, .completed)
    }

    func testUpdateStatusWithError() throws {
        let transcription = Transcription(fileName: "test.mp3")
        try repo.save(transcription)

        try repo.updateStatus(id: transcription.id, status: .error, errorMessage: "Failed to decode audio")

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.status, .error)
        XCTAssertEqual(fetched?.errorMessage, "Failed to decode audio")
    }

    func testUpdateStatusCancelled() throws {
        let transcription = Transcription(fileName: "test.mp3")
        try repo.save(transcription)

        try repo.updateStatus(id: transcription.id, status: .cancelled)
        XCTAssertEqual(try repo.fetch(id: transcription.id)?.status, .cancelled)
    }

    func testUpdateFileName() throws {
        let transcription = Transcription(
            fileName: "Meeting Apr 5",
            status: .completed,
            derivedTitle: "Auto Derived Title"
        )
        try repo.save(transcription)

        try repo.updateFileName(id: transcription.id, fileName: "Design Review")

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.fileName, "Design Review")
        XCTAssertEqual(fetched?.derivedTitle, "Design Review")
    }

    // MARK: - Chat Messages Persistence

    func testUpdateChatMessages() throws {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(transcription)

        let messages = [
            ChatMessage(role: .user, content: "What is this about?"),
            ChatMessage(role: .assistant, content: "This is about testing.")
        ]
        try repo.updateChatMessages(id: transcription.id, chatMessages: messages)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.chatMessages?.count, 2)
        XCTAssertEqual(fetched?.chatMessages?[0].role, .user)
        XCTAssertEqual(fetched?.chatMessages?[0].content, "What is this about?")
        XCTAssertEqual(fetched?.chatMessages?[1].role, .assistant)
    }

    func testUpdateChatMessagesToNil() throws {
        let messages = [ChatMessage(role: .user, content: "Hello")]
        let transcription = Transcription(fileName: "test.mp3", chatMessages: messages, status: .completed)
        try repo.save(transcription)

        try repo.updateChatMessages(id: transcription.id, chatMessages: nil)
        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNil(fetched?.chatMessages)
    }

    func testChatMessagesRoundTrip() throws {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(transcription)

        let messages = [
            ChatMessage(role: .user, content: "First question"),
            ChatMessage(role: .assistant, content: "First answer"),
            ChatMessage(role: .user, content: "Second question"),
            ChatMessage(role: .assistant, content: "Second answer")
        ]
        try repo.updateChatMessages(id: transcription.id, chatMessages: messages)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.chatMessages?.count, 4)
        XCTAssertEqual(fetched?.chatMessages?[2].content, "Second question")
        XCTAssertEqual(fetched?.chatMessages?[3].content, "Second answer")
    }

    // MARK: - Word Timestamps (JSON)

    func testWordTimestampsSaveAndFetch() throws {
        let timestamps = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.98),
            WordTimestamp(word: "world", startMs: 520, endMs: 1000, confidence: 0.95)
        ]
        var transcription = Transcription(
            fileName: "test.mp3",
            rawTranscript: "Hello world",
            wordTimestamps: timestamps
        )
        transcription.status = .completed
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNotNil(fetched?.wordTimestamps)
        XCTAssertEqual(fetched?.wordTimestamps?.count, 2)
        XCTAssertEqual(fetched?.wordTimestamps?[0].word, "Hello")
        XCTAssertEqual(fetched?.wordTimestamps?[0].startMs, 0)
        XCTAssertEqual(fetched?.wordTimestamps?[0].confidence, 0.98)
        XCTAssertEqual(fetched?.wordTimestamps?[1].word, "world")
    }

    // MARK: - Speakers Persistence

    func testUpdateSpeakers() throws {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(transcription)

        let speakers = [
            SpeakerInfo(id: "S1", label: "Alice"),
            SpeakerInfo(id: "S2", label: "Bob")
        ]
        try repo.updateSpeakers(id: transcription.id, speakers: speakers)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.speakers?.count, 2)
        XCTAssertEqual(fetched?.speakers?[0].id, "S1")
        XCTAssertEqual(fetched?.speakers?[0].label, "Alice")
        XCTAssertEqual(fetched?.speakers?[1].label, "Bob")
    }

    func testUpdateSpeakersToNil() throws {
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        let transcription = Transcription(fileName: "test.mp3", speakers: speakers, status: .completed)
        try repo.save(transcription)

        try repo.updateSpeakers(id: transcription.id, speakers: nil)
        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNil(fetched?.speakers)
    }

    func testUpdateSpeakersRoundTrip() throws {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(transcription)

        let speakers = [
            SpeakerInfo(id: "S1", label: "Speaker 1"),
            SpeakerInfo(id: "S2", label: "Speaker 2")
        ]
        try repo.updateSpeakers(id: transcription.id, speakers: speakers)

        // Rename one speaker
        var updated = speakers
        updated[0].label = "Sarah"
        try repo.updateSpeakers(id: transcription.id, speakers: updated)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.speakers?[0].label, "Sarah")
        XCTAssertEqual(fetched?.speakers?[1].label, "Speaker 2")
    }

    // MARK: - Update (save existing)

    func testUpdateTranscription() throws {
        var transcription = Transcription(fileName: "test.mp3")
        try repo.save(transcription)

        transcription.rawTranscript = "Hello world"
        transcription.durationMs = 5000
        transcription.status = .completed
        transcription.updatedAt = Date()
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.rawTranscript, "Hello world")
        XCTAssertEqual(fetched?.durationMs, 5000)
        XCTAssertEqual(fetched?.status, .completed)
    }

    // MARK: - Video Metadata

    func testVideoMetadataRoundTrip() throws {
        let transcription = Transcription(
            fileName: "YouTube Video Title",
            status: .completed,
            sourceURL: "https://www.youtube.com/watch?v=abc123",
            thumbnailURL: "https://i.ytimg.com/vi/abc123/maxresdefault.jpg",
            channelName: "Tech Channel",
            videoDescription: "A great video about Swift"
        )
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.thumbnailURL, "https://i.ytimg.com/vi/abc123/maxresdefault.jpg")
        XCTAssertEqual(fetched?.channelName, "Tech Channel")
        XCTAssertEqual(fetched?.videoDescription, "A great video about Swift")
    }

    func testVideoMetadataNilByDefault() throws {
        let transcription = Transcription(fileName: "audio.mp3", status: .completed)
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNil(fetched?.thumbnailURL)
        XCTAssertNil(fetched?.channelName)
        XCTAssertNil(fetched?.videoDescription)
    }

    // MARK: - Favorites

    func testIsFavoriteDefaultsFalse() throws {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(transcription)

        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.isFavorite, false)
    }

    func testUpdateFavorite() throws {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(transcription)

        try repo.updateFavorite(id: transcription.id, isFavorite: true)
        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.isFavorite, true)

        try repo.updateFavorite(id: transcription.id, isFavorite: false)
        let unfavorited = try repo.fetch(id: transcription.id)
        XCTAssertEqual(unfavorited?.isFavorite, false)
    }

    func testFetchFavorites() throws {
        let fav1 = Transcription(fileName: "fav1.mp3", status: .completed, isFavorite: true)
        let fav2 = Transcription(fileName: "fav2.mp3", status: .completed, isFavorite: true)
        let notFav = Transcription(fileName: "normal.mp3", status: .completed)
        try repo.save(fav1)
        try repo.save(fav2)
        try repo.save(notFav)

        let favorites = try repo.fetchFavorites()
        XCTAssertEqual(favorites.count, 2)
        XCTAssertTrue(favorites.allSatisfy(\.isFavorite))
    }
}
