import Foundation
import GRDB

/// One immutable set of values that affects a prompt's LLM request.
public struct PromptVersion: Codable, Identifiable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable, CaseIterable {
        case user
        case restore
        case systemUpdate
        case `import`
    }

    public var id: UUID
    public var promptId: UUID
    public var versionNumber: Int
    public var content: String
    public var inferenceSettings: PromptInferenceSettings?
    public var modelOverride: String?
    public var origin: Origin
    public var changeNote: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        promptId: UUID,
        versionNumber: Int,
        content: String,
        inferenceSettings: PromptInferenceSettings? = nil,
        modelOverride: String? = nil,
        origin: Origin = .user,
        changeNote: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.promptId = promptId
        self.versionNumber = versionNumber
        self.content = content
        self.inferenceSettings = inferenceSettings?.normalized
        self.modelOverride = modelOverride
        self.origin = origin
        self.changeNote = changeNote
        self.createdAt = createdAt
    }
}

extension PromptVersion: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompt_versions"

    public enum Columns: String, ColumnExpression {
        case id, promptId, versionNumber, content, inferenceSettings
        case modelOverride, origin, changeNote, createdAt
    }
}
