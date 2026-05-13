import Foundation
import GRDB

public struct WritingSample: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var text: String
    public var wordCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        text: String,
        wordCount: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.wordCount = wordCount ?? Self.countWords(in: text)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func countWords(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

extension WritingSample: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "writing_samples"

    public enum Columns: String, ColumnExpression {
        case id
        case title
        case text
        case wordCount
        case createdAt
        case updatedAt
    }
}
