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
        let derived = KnowledgeSegmenter.deriveSegments(for: transcription)
        try dbQueue.write { db in
            try SegmentRepository.replaceSegments(
                derived,
                transcriptionId: transcription.id,
                in: db
            )
            _ = try Card.deleteOne(db, key: transcription.id)
        }
    }
}
