import Foundation
import GRDB

public struct PromptResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptionId: UUID
    public var promptName: String
    public var promptContent: String
    public var extraInstructions: String?
    public var content: String
    /// Snapshot of `Transcription.userNotes` at the moment this summary was
    /// generated. Editing notes after generation does not retroactively
    /// change this value — same self-contained-summary principle as the
    /// existing prompt snapshot (ADR-013, ADR-020 §6).
    public var userNotesSnapshot: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        promptName: String,
        promptContent: String,
        extraInstructions: String? = nil,
        content: String,
        userNotesSnapshot: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.promptName = promptName
        self.promptContent = promptContent
        self.extraInstructions = extraInstructions
        self.content = content
        self.userNotesSnapshot = userNotesSnapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension PromptResult: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "summaries"

    public enum Columns: String, ColumnExpression {
        case id, transcriptionId, promptName, promptContent, extraInstructions, content, userNotesSnapshot, createdAt, updatedAt
    }
}
