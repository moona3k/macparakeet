import Foundation
import GRDB

public struct PromptResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptionId: UUID
    public var promptName: String
    public var promptContent: String
    public var extraInstructions: String?
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        promptName: String,
        promptContent: String,
        extraInstructions: String? = nil,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.promptName = promptName
        self.promptContent = promptContent
        self.extraInstructions = extraInstructions
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension PromptResult: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "summaries"

    public enum Columns: String, ColumnExpression {
        case id, transcriptionId, promptName, promptContent, extraInstructions, content, createdAt, updatedAt
    }
}
