import Foundation
import GRDB

/// A derived transcript retrieval unit. Citations use `(transcriptionId, seq)`;
/// `id` is only the internal rowid required by the external-content FTS table.
public struct Segment: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "segments"

    public var id: Int64?
    public var transcriptionId: UUID
    public var seq: Int
    public var startMs: Int?
    public var endMs: Int?
    public var speaker: String?
    public var text: String
    public var segmenterVersion: Int

    public init(
        id: Int64? = nil,
        transcriptionId: UUID,
        seq: Int,
        startMs: Int?,
        endMs: Int?,
        speaker: String?,
        text: String,
        segmenterVersion: Int
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.seq = seq
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
        self.segmenterVersion = segmenterVersion
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, transcriptionId, seq, startMs, endMs, speaker, text, segmenterVersion
    }
}
