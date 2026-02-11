import Foundation
import GRDB

public struct CustomWord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var word: String
    public var replacement: String?
    public var source: Source
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public enum Source: String, Codable, Sendable {
        case manual
        case learned
    }

    public init(
        id: UUID = UUID(),
        word: String,
        replacement: String? = nil,
        source: Source = .manual,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.source = source
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension CustomWord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "custom_words"
}
