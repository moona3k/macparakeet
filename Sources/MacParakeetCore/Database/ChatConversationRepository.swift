import Foundation
import GRDB

public protocol ChatConversationRepositoryProtocol: Sendable {
    func save(_ conversation: ChatConversation) throws
    func fetch(id: UUID) throws -> ChatConversation?
    func fetchAll(transcriptionId: UUID) throws -> [ChatConversation]
    func delete(id: UUID) throws -> Bool
    func deleteAll(transcriptionId: UUID) throws
    func deleteEmpty(transcriptionId: UUID) throws
    func updateMessages(id: UUID, messages: [ChatMessage]?) throws
    func updateTitle(id: UUID, title: String) throws
    func hasConversations(transcriptionId: UUID) throws -> Bool
}

public final class ChatConversationRepository: ChatConversationRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ conversation: ChatConversation) throws {
        try dbQueue.write { db in
            try conversation.save(db)
        }
    }

    public func fetch(id: UUID) throws -> ChatConversation? {
        try dbQueue.read { db in
            try ChatConversation.fetchOne(db, key: id)
        }
    }

    public func fetchAll(transcriptionId: UUID) throws -> [ChatConversation] {
        try dbQueue.read { db in
            try ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .order(ChatConversation.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try ChatConversation.deleteOne(db, key: id)
        }
    }

    public func deleteAll(transcriptionId: UUID) throws {
        _ = try dbQueue.write { db in
            try ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .deleteAll(db)
        }
    }

    public func deleteEmpty(transcriptionId: UUID) throws {
        _ = try dbQueue.write { db in
            try ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .filter(ChatConversation.Columns.messages == nil)
                .deleteAll(db)
        }
    }

    public func updateMessages(id: UUID, messages: [ChatMessage]?) throws {
        try dbQueue.write { db in
            guard var conversation = try ChatConversation.fetchOne(db, key: id) else { return }
            conversation.messages = messages
            conversation.updatedAt = Date()
            try conversation.update(db)
        }
    }

    public func updateTitle(id: UUID, title: String) throws {
        try dbQueue.write { db in
            guard var conversation = try ChatConversation.fetchOne(db, key: id) else { return }
            conversation.title = title
            conversation.updatedAt = Date()
            try conversation.update(db)
        }
    }

    public func hasConversations(transcriptionId: UUID) throws -> Bool {
        try dbQueue.read { db in
            try !ChatConversation
                .filter(ChatConversation.Columns.transcriptionId == transcriptionId)
                .isEmpty(db)
        }
    }
}
