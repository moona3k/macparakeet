import Foundation
import GRDB

public struct PromptResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptionId: UUID
    public var promptName: String
    public var promptContent: String
    public var extraInstructions: String?
    public var content: String
    /// Snapshot of `Transcription.userNotes` at the moment this prompt was
    /// generated. Editing notes after generation does not retroactively
    /// change this value — same self-contained-summary principle as the
    /// existing prompt snapshot (ADR-013, ADR-020 §6). When the prompt
    /// template references `{{userNotes}}`, this is the receipt of which
    /// notes version was substituted into the LLM input, so the result
    /// stays reproducible even if the user later edits their notes.
    ///
    /// Captured unconditionally on every prompt run, even when the
    /// template doesn't reference `{{userNotes}}`. Harmless but not
    /// strictly load-bearing for those prompts; could be tightened to
    /// only capture when the renderer actually substituted notes —
    /// `PromptTemplateRenderer` already knows whether the variable was
    /// referenced, so the signal could be threaded through to the
    /// generation enqueue site. Defer until there's a reason to touch
    /// this code path (e.g. re-introducing a notes-using built-in).
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
