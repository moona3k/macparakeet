import Foundation
import GRDB

public struct PromptResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptionId: UUID
    /// Nullable for historical and externally imported results.
    public var promptId: UUID?
    /// Immutable prompt version used to assemble this request. Nullable for
    /// results created before prompt versioning or without a library prompt.
    public var promptVersionId: UUID?
    public var promptName: String
    public var promptContent: String
    public var extraInstructions: String?
    public var content: String
    /// Exact effective notes supplied to the LLM for this result, after blank
    /// normalization and the prompt-context word cap. Nil means no notes were
    /// sent. Editing canonical meeting notes never changes this receipt.
    public var userNotesSnapshot: String?
    /// Snapshot of the per-prompt automatic meeting-notes preference used for
    /// this generation. This remains meaningful when no notes existed, so a
    /// later regeneration can apply the same preference to newly added notes.
    public var includeMeetingNotesSnapshot: Bool
    /// Effective generation settings actually sent to the provider for this
    /// result. Nil means no effective receipt was recorded; regeneration then
    /// inherits the current MacParakeet prompt-result defaults.
    public var inferenceSettingsSnapshot: PromptInferenceSettings?
    /// Provider and model reported by the successful terminal response.
    /// These are receipts, not live references to the current LLM settings.
    public var providerSnapshot: String?
    public var modelSnapshot: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// Legacy JSON predates the meeting-notes preference. Only an absent key
    /// defaults to false; malformed or null values remain decoding errors.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        transcriptionId = try container.decode(UUID.self, forKey: .transcriptionId)
        promptId = try container.decodeIfPresent(UUID.self, forKey: .promptId)
        promptVersionId = try container.decodeIfPresent(UUID.self, forKey: .promptVersionId)
        promptName = try container.decode(String.self, forKey: .promptName)
        promptContent = try container.decode(String.self, forKey: .promptContent)
        extraInstructions = try container.decodeIfPresent(String.self, forKey: .extraInstructions)
        content = try container.decode(String.self, forKey: .content)
        userNotesSnapshot = try container.decodeIfPresent(String.self, forKey: .userNotesSnapshot)
        includeMeetingNotesSnapshot =
            container.contains(.includeMeetingNotesSnapshot)
            ? try container.decode(Bool.self, forKey: .includeMeetingNotesSnapshot) : false
        inferenceSettingsSnapshot = try container.decodeIfPresent(
            PromptInferenceSettings.self, forKey: .inferenceSettingsSnapshot)
        providerSnapshot = try container.decodeIfPresent(String.self, forKey: .providerSnapshot)
        modelSnapshot = try container.decodeIfPresent(String.self, forKey: .modelSnapshot)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        promptId: UUID? = nil,
        promptVersionId: UUID? = nil,
        promptName: String,
        promptContent: String,
        extraInstructions: String? = nil,
        content: String,
        userNotesSnapshot: String? = nil,
        includeMeetingNotesSnapshot: Bool = false,
        inferenceSettingsSnapshot: PromptInferenceSettings? = nil,
        providerSnapshot: String? = nil,
        modelSnapshot: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.promptId = promptId
        self.promptVersionId = promptVersionId
        self.promptName = promptName
        self.promptContent = promptContent
        self.extraInstructions = extraInstructions
        self.content = content
        self.userNotesSnapshot = userNotesSnapshot
        self.includeMeetingNotesSnapshot = includeMeetingNotesSnapshot
        self.inferenceSettingsSnapshot = inferenceSettingsSnapshot?.normalized
        self.providerSnapshot = providerSnapshot
        self.modelSnapshot = modelSnapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension PromptResult: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "summaries"

    public enum Columns: String, ColumnExpression {
        case id, transcriptionId, promptId, promptVersionId
        case promptName, promptContent, extraInstructions, content
        case userNotesSnapshot, includeMeetingNotesSnapshot, inferenceSettingsSnapshot
        case providerSnapshot, modelSnapshot
        case createdAt, updatedAt
    }
}
