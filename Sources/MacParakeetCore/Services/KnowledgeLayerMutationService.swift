import Foundation
import GRDB

public protocol KnowledgeLayerMutating: Sendable {
    func replaceSegmentsAndInvalidateCard(for transcription: Transcription) throws
}

/// Coordinates cross-table derived-state changes that must commit together.
/// The canonical transcription is saved by TranscriptionService first; this
/// service then publishes its replacement segments and removes the old card in
/// one transaction. A stale card can therefore never survive alongside newly
/// committed citation targets.
public final class KnowledgeLayerMutationService: KnowledgeLayerMutating, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func replaceSegmentsAndInvalidateCard(for transcription: Transcription) throws {
        try dbQueue.write { db in
            let current = try Transcription.fetchOne(db, key: transcription.id) ?? transcription
            let derived = try SegmentRepository.deriveResolvedSegments(
                for: current,
                in: db
            )
            try Self.replaceSegmentsAndInvalidateCard(
                derived,
                transcriptionId: current.id,
                in: db
            )
        }
    }

    static func replaceSegmentsAndInvalidateCard(
        _ segments: [Segment],
        transcriptionId: UUID,
        in db: Database
    ) throws {
        try SegmentRepository.replaceSegments(
            segments,
            transcriptionId: transcriptionId,
            in: db
        )
        _ = try Card.deleteOne(db, key: transcriptionId)
    }
}
