import Foundation
import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerVoiceprintDeletionTests: XCTestCase {
    func testDeletingAllProfilesAlsoDeletesUnownedCandidatesAndJournalRows() async throws {
        let (database, profiles) = try await populatedStore()
        try profiles.deleteAllProfiles()
        XCTAssertTrue(try voiceRowCounts(database).allSatisfy { $0 == 0 })
        XCTAssertEqual(try transcriptionCount(database), 1)
    }

    func testGlobalDeletionRollsBackEveryTableWhenProfileDeletionFails() async throws {
        let (database, profiles) = try await populatedStore()
        let before = try voiceRowCounts(database)
        try await database.dbQueue.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_profile_delete BEFORE DELETE ON speaker_profiles
                    BEGIN SELECT RAISE(ABORT, 'test deletion failure'); END
                    """)
        }
        XCTAssertThrowsError(try profiles.deleteAllProfiles())
        XCTAssertEqual(try voiceRowCounts(database), before)
        XCTAssertEqual(try transcriptionCount(database), 1)
    }

    func testAnUpdateCannotRecreateADeletedProfile() throws {
        let database = try DatabaseManager()
        let profiles = SpeakerProfileRepository(dbQueue: database.dbQueue)
        let profile = SpeakerProfile(
            displayName: "Forgotten Person",
            identity: SpeakerModelIdentity(embeddingModelId: "test", aggregationProfileId: "test")
        )
        try profiles.insert(profile)
        XCTAssertTrue(try profiles.deleteProfile(id: profile.id))
        XCTAssertThrowsError(try profiles.save(profile))
        XCTAssertNil(try profiles.profile(id: profile.id))
    }

    private func populatedStore() async throws -> (DatabaseManager, SpeakerProfileRepository) {
        let database = try DatabaseManager()
        let profiles = SpeakerProfileRepository(dbQueue: database.dbQueue)
        let journal = SpeakerMatchJournalRepository(dbQueue: database.dbQueue)
        let service = SpeakerVoiceprintService(
            profiles: profiles,
            candidates: SpeakerEmbeddingCandidateRepository(dbQueue: database.dbQueue),
            journal: journal, isEnabled: { true }
        )
        let recording = Transcription(fileName: "meeting.wav", status: .completed)
        try TranscriptionRepository(dbQueue: database.dbQueue).save(recording)
        var vector = [Float](repeating: 0, count: 256)
        vector[0] = 1
        let observation = SpeakerClusterObservation(
            speakerId: "system:S1",
            embedding: try XCTUnwrap(
                SpeakerEmbedding(
                    rawVector: vector,
                    identity: SpeakerModelIdentity(embeddingModelId: "test", aggregationProfileId: "test")
                )),
            speechSeconds: 30, captureDomain: .system
        )
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: recording)
        _ = try await service.enroll(
            displayName: "Remembered Person", observation: observation,
            transcriptionId: recording.id, fingerprint: fingerprint, allowMergeIntoExistingName: false
        )
        _ = try await service.evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint, clusters: [observation]
        )
        // This decision has no profile FK, so deleting profile rows cannot
        // remove it through a cascade.
        try journal.append(
            [
                SpeakerMatchJournalEntry(
                    transcriptionId: recording.id, speakerId: "system:S2",
                    transcriptFingerprint: fingerprint.rawValue,
                    outcome: .noComparableProfile, speechSeconds: 30, createdAt: Date()
                )
            ], retention: SpeakerMatchJournalRepository.defaultRetention, now: Date())
        XCTAssertTrue(try voiceRowCounts(database).allSatisfy { $0 > 0 })
        return (database, profiles)
    }

    private func voiceRowCounts(_ database: DatabaseManager) throws -> [Int] {
        try database.dbQueue.read { db in
            try [
                "speaker_profiles", "speaker_profile_exemplars", "speaker_profile_links",
                "speaker_embedding_candidates", "speaker_match_journal",
            ].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!
            }
        }
    }

    private func transcriptionCount(_ database: DatabaseManager) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcriptions")!
        }
    }
}
