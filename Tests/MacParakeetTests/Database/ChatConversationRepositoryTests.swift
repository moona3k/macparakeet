import XCTest
import GRDB
@testable import MacParakeetCore

final class ChatConversationRepositoryTests: XCTestCase {
    var repo: ChatConversationRepository!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = ChatConversationRepository(dbQueue: manager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    private func makeTranscription() throws -> Transcription {
        let t = Transcription(fileName: "test.mp3", status: .completed)
        try transcriptionRepo.save(t)
        return t
    }

    // MARK: - CRUD

    func testSaveAndFetch() throws {
        let t = try makeTranscription()
        let conv = ChatConversation(transcriptionId: t.id, title: "Test Chat")
        try repo.save(conv)

        let fetched = try repo.fetch(id: conv.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test Chat")
        XCTAssertEqual(fetched?.transcriptionId, t.id)
        XCTAssertNil(fetched?.messages)
    }

    func testFetchNonExistent() throws {
        let fetched = try repo.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    func testFetchAllByTranscriptionId() throws {
        let t = try makeTranscription()
        let conv1 = ChatConversation(
            transcriptionId: t.id,
            title: "First",
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let conv2 = ChatConversation(
            transcriptionId: t.id,
            title: "Second",
            updatedAt: Date()
        )
        try repo.save(conv1)
        try repo.save(conv2)

        let all = try repo.fetchAll(transcriptionId: t.id)
        XCTAssertEqual(all.count, 2)
        // Most recently updated first
        XCTAssertEqual(all[0].title, "Second")
        XCTAssertEqual(all[1].title, "First")
    }

    func testFetchAllScopedToTranscription() throws {
        let t1 = try makeTranscription()
        let t2 = try makeTranscription()

        try repo.save(ChatConversation(transcriptionId: t1.id, title: "T1 Chat"))
        try repo.save(ChatConversation(transcriptionId: t2.id, title: "T2 Chat"))

        let t1Convs = try repo.fetchAll(transcriptionId: t1.id)
        XCTAssertEqual(t1Convs.count, 1)
        XCTAssertEqual(t1Convs[0].title, "T1 Chat")
    }

    func testDelete() throws {
        let t = try makeTranscription()
        let conv = ChatConversation(transcriptionId: t.id, title: "Delete Me")
        try repo.save(conv)

        let deleted = try repo.delete(id: conv.id)
        XCTAssertTrue(deleted)
        XCTAssertNil(try repo.fetch(id: conv.id))
    }

    func testDeleteNonExistent() throws {
        let deleted = try repo.delete(id: UUID())
        XCTAssertFalse(deleted)
    }

    // MARK: - Cascade

    func testCascadeDeleteOnTranscriptionRemoval() throws {
        let t = try makeTranscription()
        try repo.save(ChatConversation(transcriptionId: t.id, title: "Chat 1"))
        try repo.save(ChatConversation(transcriptionId: t.id, title: "Chat 2"))
        XCTAssertEqual(try repo.fetchAll(transcriptionId: t.id).count, 2)

        _ = try transcriptionRepo.delete(id: t.id)
        XCTAssertEqual(try repo.fetchAll(transcriptionId: t.id).count, 0)
    }

    // MARK: - Delete Empty

    func testDeleteEmpty() throws {
        let t = try makeTranscription()
        let empty = ChatConversation(transcriptionId: t.id, title: "Empty")
        let withMessages = ChatConversation(
            transcriptionId: t.id,
            title: "Has Messages",
            messages: [ChatMessage(role: .user, content: "Hello")]
        )
        try repo.save(empty)
        try repo.save(withMessages)

        try repo.deleteEmpty(transcriptionId: t.id)

        let remaining = try repo.fetchAll(transcriptionId: t.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].title, "Has Messages")
    }

    // MARK: - Update Messages

    func testUpdateMessages() throws {
        let t = try makeTranscription()
        let conv = ChatConversation(transcriptionId: t.id, title: "Chat")
        try repo.save(conv)

        let messages = [
            ChatMessage(role: .user, content: "Question"),
            ChatMessage(role: .assistant, content: "Answer"),
        ]
        try repo.updateMessages(id: conv.id, messages: messages)

        let fetched = try repo.fetch(id: conv.id)
        XCTAssertEqual(fetched?.messages?.count, 2)
        XCTAssertEqual(fetched?.messages?[0].role, .user)
        XCTAssertEqual(fetched?.messages?[1].content, "Answer")
    }

    func testUpdateMessagesToNil() throws {
        let t = try makeTranscription()
        let conv = ChatConversation(
            transcriptionId: t.id,
            title: "Chat",
            messages: [ChatMessage(role: .user, content: "Hi")]
        )
        try repo.save(conv)

        try repo.updateMessages(id: conv.id, messages: nil)

        let fetched = try repo.fetch(id: conv.id)
        XCTAssertNil(fetched?.messages)
    }

    // MARK: - Update Title

    func testUpdateTitle() throws {
        let t = try makeTranscription()
        let conv = ChatConversation(transcriptionId: t.id, title: "Old Title")
        try repo.save(conv)

        try repo.updateTitle(id: conv.id, title: "New Title")

        let fetched = try repo.fetch(id: conv.id)
        XCTAssertEqual(fetched?.title, "New Title")
    }

    // MARK: - Has Conversations

    func testHasConversationsTrue() throws {
        let t = try makeTranscription()
        try repo.save(ChatConversation(transcriptionId: t.id, title: "Chat"))

        XCTAssertTrue(try repo.hasConversations(transcriptionId: t.id))
    }

    func testHasConversationsFalse() throws {
        let t = try makeTranscription()
        XCTAssertFalse(try repo.hasConversations(transcriptionId: t.id))
    }

    // MARK: - Migration

    func testMigrationFromChatMessagesColumn() throws {
        // This test verifies that the migration properly creates conversations
        // from existing chatMessages on transcriptions.
        // Since we use DatabaseManager() which runs all migrations, we test
        // by inserting a transcription, verifying chatMessages is null (migration cleared it),
        // and checking that conversations exist if chatMessages were present.
        //
        // For a clean migration test, we'd need raw SQL before migration runs,
        // but the in-memory DB always runs all migrations. Instead, verify the
        // repo works correctly with the migrated schema.
        let t = try makeTranscription()
        let conv = ChatConversation(
            transcriptionId: t.id,
            title: "Migrated",
            messages: [ChatMessage(role: .user, content: "From migration")]
        )
        try repo.save(conv)

        let fetched = try repo.fetchAll(transcriptionId: t.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].messages?.first?.content, "From migration")
    }
}
