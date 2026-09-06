import Foundation
import GRDB

public protocol SpeakerCorrectionRepositoryProtocol: Sendable {
    func fetchState(transcriptionId: UUID) throws -> SpeakerCorrectionState?
    func fetchActiveCorrections(transcriptionId: UUID) throws -> [SpeakerCorrection]
    func fetchHistory(transcriptionId: UUID) throws -> [SpeakerCorrection]
}

public enum SpeakerCorrectionHistoryError: Error, Equatable, Sendable {
    case missingHead(UUID)
    case mismatchedTranscription(UUID)
    case mismatchedFingerprint(UUID)
    case cycle(UUID)
    case concurrentModification
}

/// Storage for the append-only correction log and its per-transcript cursor.
/// Transactional commands use the `Database`-taking primitives below so the
/// log, cursor, retrieval segments, and card invalidation share one commit.
public final class SpeakerCorrectionRepository: SpeakerCorrectionRepositoryProtocol,
    @unchecked Sendable
{
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func fetchState(transcriptionId: UUID) throws -> SpeakerCorrectionState? {
        try dbQueue.read { db in
            try Self.fetchState(transcriptionId: transcriptionId, in: db)
        }
    }

    public func fetchActiveCorrections(transcriptionId: UUID) throws -> [SpeakerCorrection] {
        try dbQueue.read { db in
            guard let state = try Self.fetchState(transcriptionId: transcriptionId, in: db) else {
                return []
            }
            return try Self.fetchActiveCorrections(state: state, in: db)
        }
    }

    public func fetchHistory(transcriptionId: UUID) throws -> [SpeakerCorrection] {
        try dbQueue.read { db in
            try Self.fetchHistory(transcriptionId: transcriptionId, in: db)
        }
    }

    static func fetchState(
        transcriptionId: UUID,
        in db: Database
    ) throws -> SpeakerCorrectionState? {
        try SpeakerCorrectionState.fetchOne(db, key: transcriptionId)
    }

    static func fetchHistory(
        transcriptionId: UUID,
        in db: Database
    ) throws -> [SpeakerCorrection] {
        try SpeakerCorrection
            .filter(Column("transcriptionId") == transcriptionId)
            .order(Column("sequence").asc)
            .fetchAll(db)
    }

    static func fetchHistory(
        transcriptionId: UUID,
        fingerprint: String,
        in db: Database
    ) throws -> [SpeakerCorrection] {
        try SpeakerCorrection
            .filter(Column("transcriptionId") == transcriptionId)
            .filter(Column("transcriptFingerprint") == fingerprint)
            .order(Column("sequence").asc)
            .fetchAll(db)
    }

    static func fetchActiveCorrections(
        state: SpeakerCorrectionState,
        in db: Database
    ) throws -> [SpeakerCorrection] {
        guard var currentID = state.headId else { return [] }
        let history = try fetchHistory(transcriptionId: state.transcriptionId, in: db)
        let byID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        var visited: Set<UUID> = []
        var reversed: [SpeakerCorrection] = []

        while true {
            guard visited.insert(currentID).inserted else {
                throw SpeakerCorrectionHistoryError.cycle(currentID)
            }
            guard let correction = byID[currentID] else {
                throw SpeakerCorrectionHistoryError.missingHead(currentID)
            }
            guard correction.transcriptionId == state.transcriptionId else {
                throw SpeakerCorrectionHistoryError.mismatchedTranscription(currentID)
            }
            guard correction.transcriptFingerprint.rawValue == state.transcriptFingerprint else {
                throw SpeakerCorrectionHistoryError.mismatchedFingerprint(currentID)
            }
            reversed.append(correction)
            guard let parentID = correction.parentId else { break }
            currentID = parentID
        }
        return reversed.reversed()
    }

    static func nextSequence(transcriptionId: UUID, in db: Database) throws -> Int {
        let maximum =
            try Int.fetchOne(
                db,
                sql: "SELECT MAX(sequence) FROM speaker_corrections WHERE transcriptionId = ?",
                arguments: [transcriptionId]
            ) ?? 0
        return maximum + 1
    }

    static func insert(_ correction: SpeakerCorrection, in db: Database) throws {
        try correction.insert(db)
    }

    static func abandonRedoBranch(
        transcriptionId: UUID,
        fingerprint: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE speaker_corrections
                SET branchState = ?
                WHERE transcriptionId = ?
                  AND transcriptFingerprint = ?
                  AND branchState = ?
                """,
            arguments: [
                SpeakerCorrectionBranchState.abandoned.rawValue,
                transcriptionId,
                fingerprint,
                SpeakerCorrectionBranchState.redo.rawValue,
            ]
        )
    }

    static func updateBranchState(
        id: UUID,
        transcriptionId: UUID,
        from expected: SpeakerCorrectionBranchState,
        to desired: SpeakerCorrectionBranchState,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE speaker_corrections
                SET branchState = ?
                WHERE id = ? AND transcriptionId = ? AND branchState = ?
                """,
            arguments: [desired.rawValue, id, transcriptionId, expected.rawValue]
        )
        guard db.changesCount == 1 else {
            throw SpeakerCorrectionHistoryError.concurrentModification
        }
    }

    static func redoChild(
        transcriptionId: UUID,
        fingerprint: String,
        parentId: UUID?,
        in db: Database
    ) throws -> SpeakerCorrection? {
        let parentPredicate = parentId == nil ? "parentId IS NULL" : "parentId = ?"
        var arguments: [any DatabaseValueConvertible] = [
            transcriptionId,
            fingerprint,
            SpeakerCorrectionBranchState.redo.rawValue,
        ]
        if let parentId { arguments.append(parentId) }
        return try SpeakerCorrection.fetchOne(
            db,
            sql: """
                SELECT * FROM speaker_corrections
                WHERE transcriptionId = ?
                  AND transcriptFingerprint = ?
                  AND branchState = ?
                  AND \(parentPredicate)
                ORDER BY sequence ASC
                LIMIT 1
                """,
            arguments: StatementArguments(arguments)
        )
    }

    static func insertState(_ state: SpeakerCorrectionState, in db: Database) throws {
        try state.insert(db)
    }

    static func replaceStateForNewFingerprint(
        transcriptionId: UUID,
        oldFingerprint: String,
        oldRevision: Int,
        newFingerprint: String,
        updatedAt: Date,
        in db: Database
    ) throws -> SpeakerCorrectionState {
        try db.execute(
            sql: """
                UPDATE speaker_correction_states
                SET transcriptFingerprint = ?, headId = NULL, revision = 0, updatedAt = ?
                WHERE transcriptionId = ?
                  AND transcriptFingerprint = ?
                  AND revision = ?
                """,
            arguments: [
                newFingerprint, updatedAt, transcriptionId, oldFingerprint, oldRevision,
            ]
        )
        guard db.changesCount == 1 else {
            throw SpeakerCorrectionHistoryError.concurrentModification
        }
        return SpeakerCorrectionState(
            transcriptionId: transcriptionId,
            transcriptFingerprint: newFingerprint,
            headId: nil,
            revision: 0,
            updatedAt: updatedAt
        )
    }

    static func updateState(
        transcriptionId: UUID,
        fingerprint: String,
        headId: UUID?,
        expectedRevision: Int,
        updatedAt: Date,
        in db: Database
    ) throws -> SpeakerCorrectionState {
        let newRevision = expectedRevision + 1
        try db.execute(
            sql: """
                UPDATE speaker_correction_states
                SET transcriptFingerprint = ?, headId = ?, revision = ?, updatedAt = ?
                WHERE transcriptionId = ? AND revision = ?
                """,
            arguments: [
                fingerprint, headId, newRevision, updatedAt,
                transcriptionId, expectedRevision,
            ]
        )
        guard db.changesCount == 1 else {
            throw SpeakerCorrectionHistoryError.concurrentModification
        }
        return SpeakerCorrectionState(
            transcriptionId: transcriptionId,
            transcriptFingerprint: fingerprint,
            headId: headId,
            revision: newRevision,
            updatedAt: updatedAt
        )
    }
}
