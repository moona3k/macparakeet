import Foundation
import GRDB

public protocol TranscriptionMeetingLabelRepositoryProtocol: Sendable {
    func labels(for transcriptionId: UUID) throws -> [MeetingLabel]
    func labelIDs(for transcriptionId: UUID) throws -> Set<UUID>
    func add(labelId: UUID, to transcriptionId: UUID) throws
    func remove(labelId: UUID, from transcriptionId: UUID) throws
    func replaceLabels(for transcriptionId: UUID, with labelIds: Set<UUID>) throws
}

public final class TranscriptionMeetingLabelRepository: TranscriptionMeetingLabelRepositoryProtocol,
    @unchecked Sendable
{
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func labels(for transcriptionId: UUID) throws -> [MeetingLabel] {
        try dbQueue.read { db in
            try MeetingLabel.fetchAll(
                db,
                sql: """
                    SELECT ml.*
                    FROM meeting_labels ml
                    JOIN transcription_meeting_labels tml ON tml.labelId = ml.id
                    WHERE tml.transcriptionId = ?
                    ORDER BY ml.sortOrder ASC, ml.name COLLATE NOCASE ASC
                    """,
                arguments: [transcriptionId]
            )
        }
    }

    public func labelIDs(for transcriptionId: UUID) throws -> Set<UUID> {
        try dbQueue.read { db in
            let rows =
                try TranscriptionMeetingLabel
                .filter(TranscriptionMeetingLabel.Columns.transcriptionId == transcriptionId)
                .fetchAll(db)
            return Set(rows.map(\.labelId))
        }
    }

    public func add(labelId: UUID, to transcriptionId: UUID) throws {
        try dbQueue.write { db in
            try TranscriptionMeetingLabel(
                transcriptionId: transcriptionId,
                labelId: labelId
            ).insert(db, onConflict: .ignore)
        }
    }

    public func remove(labelId: UUID, from transcriptionId: UUID) throws {
        try dbQueue.write { db in
            _ =
                try TranscriptionMeetingLabel
                .filter(TranscriptionMeetingLabel.Columns.transcriptionId == transcriptionId)
                .filter(TranscriptionMeetingLabel.Columns.labelId == labelId)
                .deleteAll(db)
        }
    }

    public func replaceLabels(for transcriptionId: UUID, with labelIds: Set<UUID>) throws {
        try dbQueue.write { db in
            try Self.replaceLabels(in: db, for: transcriptionId, with: labelIds)
        }
    }

    static func replaceLabels(in db: Database, for transcriptionId: UUID, with labelIds: Set<UUID>) throws {
        _ =
            try TranscriptionMeetingLabel
            .filter(TranscriptionMeetingLabel.Columns.transcriptionId == transcriptionId)
            .deleteAll(db)
        for labelId in labelIds {
            try TranscriptionMeetingLabel(
                transcriptionId: transcriptionId,
                labelId: labelId
            ).insert(db)
        }
    }
}
