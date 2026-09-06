import Foundation
import GRDB

/// Controls whether a result prompt is available for transcriptions carrying
/// a label. An `all` row is the fallback; matching label rows take precedence.
public struct PromptLabelPolicy: Codable, Identifiable, Sendable, Equatable {
    public enum ScopeKind: String, Codable, Sendable, CaseIterable {
        case all
        case label
    }

    public var id: UUID
    public var promptId: UUID
    public var scopeKind: ScopeKind
    public var labelId: UUID?
    public var isAvailable: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        promptId: UUID,
        scopeKind: ScopeKind,
        labelId: UUID? = nil,
        isAvailable: Bool,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.promptId = promptId
        self.scopeKind = scopeKind
        self.labelId = labelId
        self.isAvailable = isAvailable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension PromptLabelPolicy: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompt_label_policies"

    public enum Columns: String, ColumnExpression {
        case id, promptId, scopeKind, labelId, isAvailable, createdAt, updatedAt
    }
}
