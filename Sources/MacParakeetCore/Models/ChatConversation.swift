import Foundation
import GRDB

public struct ChatConversation: Codable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptionId: UUID
    public var title: String
    public var messages: [ChatMessage]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        title: String = "",
        messages: [ChatMessage]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension ChatConversation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat_conversations"

    public enum Columns: String, ColumnExpression {
        case id, transcriptionId, title, messages, createdAt, updatedAt
    }
}
