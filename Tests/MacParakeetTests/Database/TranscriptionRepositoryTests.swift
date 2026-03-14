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

    // MARK: - Summary Persistence

    func testUpdateSummary() throws {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(transcription)

        try repo.updateSummary(id: transcription.id, summary: "This is a summary.")
        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertEqual(fetched?.summary, "This is a summary.")
    }

    func testUpdateSummaryToNil() throws {
        let transcription = Transcription(fileName: "test.mp3", summary: "Old summary", status: .completed)
        try repo.save(transcription)

        try repo.updateSummary(id: transcription.id, summary: nil)
        let fetched = try repo.fetch(id: transcription.id)
        XCTAssertNil(fetched?.summary)
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
}
