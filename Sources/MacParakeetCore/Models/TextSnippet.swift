import Foundation
import GRDB

public struct TextSnippet: Codable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var isEnabled: Bool
    public var useCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        trigger: String,
        expansion: String,
        isEnabled: Bool = true,
        useCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.isEnabled = isEnabled
        self.useCount = useCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension TextSnippet: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "text_snippets"
}
