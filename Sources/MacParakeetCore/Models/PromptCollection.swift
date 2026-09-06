import Foundation
import GRDB

/// User-defined organization for prompts.
///
/// This is deliberately separate from `Prompt.Category`, which describes the
/// technical execution kind (`result` or `transform`). A prompt belongs to at
/// most one collection through `prompts.collectionId`.
public struct PromptCollection: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var colorToken: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorToken: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension PromptCollection: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompt_collections"

    public enum Columns: String, ColumnExpression {
        case id, name, colorToken, sortOrder, createdAt, updatedAt
    }
}
