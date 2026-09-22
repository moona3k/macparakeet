import Foundation
import GRDB

public protocol SpeakerEmbeddingCandidateRepositoryProtocol: Sendable {
    /// Records this run's candidates and drops anything already expired.
    /// Re-recording the same speaker replaces the row rather than failing.
    func upsert(_ candidates: [SpeakerEmbeddingCandidate], now: Date) throws
    /// The candidate still available for this speaker, or `nil` once it has
    /// expired or been promoted.
    func candidate(
        transcriptionId: UUID,
        speakerId: String,
        fingerprint: String,
        now: Date
    ) throws -> SpeakerEmbeddingCandidate?
    /// Called once a candidate has become an exemplar: the vector now lives in
    /// the profile, so a second copy would be biometric data kept for nothing.
    func delete(transcriptionId: UUID, speakerId: String, fingerprint: String) throws
    /// Removes everything past its own `expiresAt`. Safe to call at any time.
    func pruneExpired(now: Date) throws
    func deleteAll() throws
}

/// Short-lived voices awaiting a name.
///
/// Expiry is per row rather than computed from a constant at read time, so the
/// window a user was told about is the window that applies to their data.
public final class SpeakerEmbeddingCandidateRepository: SpeakerEmbeddingCandidateRepositoryProtocol {
    /// Long enough to name a speaker after the fact, short enough that this is
    /// never a record of who was in the room. Anarlog keeps 45 days; naming is a
    /// same-week action, and unnamed vectors earn nothing by waiting.
    public static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Writes and prunes in one transaction.
    public func upsert(_ candidates: [SpeakerEmbeddingCandidate], now: Date = Date()) throws {
        try dbQueue.write { db in
            for candidate in candidates {
                let key = try SpeakerTranscriptionPersistence.key(candidate.transcriptionId, in: db)
                // Re-diarization keeps the transcription and speaker ids while
                // changing the fingerprint, so the natural key can collide with
                // a row that no longer describes the same person.
                try db.execute(
                    sql: """
                        DELETE FROM speaker_embedding_candidates
                        WHERE transcriptionId = ? AND speakerId = ?
                          AND transcriptFingerprint = ?
                        """,
                    arguments: [
                        key,
                        candidate.speakerId,
                        candidate.transcriptFingerprint,
                    ]
                )
                try SpeakerTranscriptionRecord(
                    record: candidate, column: "transcriptionId", transcriptionKey: key
                ).insert(db)
            }
            try deleteExpired(db, now: now)
        }
    }

    /// Expired rows are removed before reading, so a lapsed candidate can never
    /// be handed out even if no write has happened since it lapsed.
    public func candidate(
        transcriptionId: UUID,
        speakerId: String,
        fingerprint: String,
        now: Date = Date()
    ) throws -> SpeakerEmbeddingCandidate? {
        try pruneExpired(now: now)
        return try dbQueue.read { db in
            let key = try SpeakerTranscriptionPersistence.key(transcriptionId, in: db)
            return
                try SpeakerEmbeddingCandidate
                .filter(Column("transcriptionId") == key)
                .filter(Column("speakerId") == speakerId)
                .filter(Column("transcriptFingerprint") == fingerprint)
                .fetchOne(db)
        }
    }

    public func delete(transcriptionId: UUID, speakerId: String, fingerprint: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM speaker_embedding_candidates
                    WHERE transcriptionId = ? AND speakerId = ?
                      AND transcriptFingerprint = ?
                    """,
                arguments: [try SpeakerTranscriptionPersistence.key(transcriptionId, in: db), speakerId, fingerprint]
            )
        }
    }

    /// Expiry cannot ride on writes alone: someone who stops recording stops
    /// writing, and a seven-day window would quietly become permanent.
    public func pruneExpired(now: Date = Date()) throws {
        try dbQueue.write { db in
            try deleteExpired(db, now: now)
        }
    }

    private func deleteExpired(_ db: Database, now: Date) throws {
        try db.execute(
            sql: "DELETE FROM speaker_embedding_candidates WHERE expiresAt <= ?",
            arguments: [now]
        )
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try SpeakerEmbeddingCandidate.deleteAll(db)
        }
    }
}
