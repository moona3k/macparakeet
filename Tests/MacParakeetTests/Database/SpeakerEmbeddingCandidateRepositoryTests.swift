import XCTest
import GRDB
@testable import MacParakeetCore

final class SpeakerEmbeddingCandidateRepositoryTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var repo: SpeakerEmbeddingCandidateRepository!
    private var transcriptions: TranscriptionRepository!

    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )
    private let epoch = Date(timeIntervalSince1970: 1_757_000_000)

    override func setUp() async throws {
        let manager = try DatabaseManager()
        dbQueue = manager.dbQueue
        repo = SpeakerEmbeddingCandidateRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    // MARK: Schema

    func testMigrationCreatesTheCandidateTable() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("speaker_embedding_candidates"))
            XCTAssertEqual(
                Set(try db.columns(in: "speaker_embedding_candidates").map(\.name)),
                [
                    "id", "transcriptionId", "speakerId", "transcriptFingerprint",
                    "vector", "speechSeconds", "captureDomain", "embeddingModelId",
                    "aggregationProfileId", "createdAt", "expiresAt",
                ]
            )
        }
    }

    func testAVectorOfTheWrongLengthIsRejected() throws {
        let recording = try savedTranscription()
        try dbQueue.write { db in
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        INSERT INTO speaker_embedding_candidates
                        (id, transcriptionId, speakerId, transcriptFingerprint, vector,
                         speechSeconds, captureDomain, embeddingModelId,
                         aggregationProfileId, createdAt, expiresAt)
                        VALUES (?, ?, 'S1', 'fp', ?, 30, 'system', 'm', 'a', ?, ?)
                        """,
                    arguments: [
                        UUID(), recording.id, Data(repeating: 0, count: 1020), epoch, epoch,
                    ]
                )
            )
        }
    }

    // MARK: Round trip

    func testTheVectorRoundTripsBitExact() throws {
        let recording = try savedTranscription()
        let embedding = makeEmbedding(index: 7)
        try repo.upsert([candidate(recording.id, embedding: embedding)], now: epoch)

        let stored = try XCTUnwrap(
            repo.candidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: "fp", now: epoch
            )
        )
        XCTAssertEqual(stored.vector.count, 1024)
        let observation = try XCTUnwrap(stored.observation)
        XCTAssertEqual(observation.embedding.vector, embedding.vector)
        XCTAssertEqual(observation.speakerId, "S1")
        XCTAssertEqual(observation.captureDomain, .system)
    }

    // MARK: Expiry

    /// The window is stored per row, so lengthening the constant later cannot
    /// bring back vectors that were promised a shorter life.
    func testACandidateIsGoneOnceItsOwnWindowLapses() throws {
        let recording = try savedTranscription()
        try repo.upsert(
            [candidate(recording.id, expiresAt: epoch.addingTimeInterval(60))], now: epoch
        )

        XCTAssertNotNil(
            try repo.candidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: "fp",
                now: epoch.addingTimeInterval(59)
            )
        )
        XCTAssertNil(
            try repo.candidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: "fp",
                now: epoch.addingTimeInterval(60)
            )
        )
        XCTAssertEqual(try count(), 0, "the lapsed row must be deleted, not just hidden")
    }

    /// A user who stops recording stops writing, so expiry cannot ride on
    /// writes alone.
    func testPruningRemovesLapsedRowsWithoutAnyWrite() throws {
        let recording = try savedTranscription()
        try repo.upsert([candidate(recording.id, expiresAt: epoch.addingTimeInterval(60))], now: epoch)

        try repo.pruneExpired(now: epoch.addingTimeInterval(3600))

        XCTAssertEqual(try count(), 0)
    }

    // MARK: Scoping

    func testAnotherFingerprintIsANotherCandidate() throws {
        let recording = try savedTranscription()
        try repo.upsert([candidate(recording.id, fingerprint: "fp-1")], now: epoch)

        XCTAssertNil(
            try repo.candidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: "fp-2", now: epoch
            )
        )
    }

    /// Rescoring the same transcript must replace the row, not fail on the
    /// natural key.
    func testRecordingTheSameSpeakerTwiceReplacesTheRow() throws {
        let recording = try savedTranscription()
        try repo.upsert([candidate(recording.id, embedding: makeEmbedding(index: 3))], now: epoch)
        try repo.upsert([candidate(recording.id, embedding: makeEmbedding(index: 9))], now: epoch)

        XCTAssertEqual(try count(), 1)
        let stored = try XCTUnwrap(
            repo.candidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: "fp", now: epoch
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(stored.observation).embedding.vector, makeEmbedding(index: 9).vector
        )
    }

    /// The natural key does not carry the model or clustering identity, which is
    /// deliberate: two rows per speaker, one per configuration, would store more
    /// biometric data and leave promotion with no defined winner. Instead the
    /// row carries its own identity and the replacement is atomic, so a rescore
    /// under a new configuration cannot leave a stale one behind.
    func testReplacementCarriesTheNewConfigurationIdentity() throws {
        let recording = try savedTranscription()
        try repo.upsert([candidate(recording.id)], now: epoch)

        let retuned = SpeakerModelIdentity(
            embeddingModelId: identity.embeddingModelId,
            aggregationProfileId: "retuned-aggregation"
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[5] = 1
        let reclustered = try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: retuned))
        try repo.upsert([candidate(recording.id, embedding: reclustered)], now: epoch)

        XCTAssertEqual(try count(), 1)
        let stored = try XCTUnwrap(
            repo.candidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: "fp", now: epoch
            )
        )
        XCTAssertEqual(stored.identity, retuned)
        XCTAssertEqual(try XCTUnwrap(stored.observation).embedding.identity, retuned)
    }

    // MARK: Deletion

    func testDeletingTheTranscriptionTakesItsCandidates() throws {
        let recording = try savedTranscription()
        try repo.upsert([candidate(recording.id)], now: epoch)

        try dbQueue.write { db in
            _ = try Transcription.deleteOne(db, key: recording.id)
        }

        XCTAssertEqual(try count(), 0)
    }

    func testDeleteAllRemovesEveryCandidate() throws {
        let first = try savedTranscription()
        let second = try savedTranscription()
        try repo.upsert([candidate(first.id), candidate(second.id)], now: epoch)

        try repo.deleteAll()

        XCTAssertEqual(try count(), 0)
    }

    // MARK: Helpers

    private func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_candidates") ?? -1
        }
    }

    private func savedTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try transcriptions.save(transcription)
        return transcription
    }

    private func candidate(
        _ transcriptionId: UUID,
        speakerId: String = "S1",
        fingerprint: String = "fp",
        embedding: SpeakerEmbedding? = nil,
        expiresAt: Date? = nil
    ) -> SpeakerEmbeddingCandidate {
        SpeakerEmbeddingCandidate(
            transcriptionId: transcriptionId,
            speakerId: speakerId,
            transcriptFingerprint: fingerprint,
            embedding: embedding ?? makeEmbedding(index: 0),
            speechSeconds: 30,
            captureDomain: .system,
            createdAt: epoch,
            expiresAt: expiresAt ?? epoch.addingTimeInterval(7 * 24 * 60 * 60)
        )
    }

    private func makeEmbedding(index: Int) -> SpeakerEmbedding {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[index] = 1
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }
}
