import Foundation
import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerVoiceprintLegacyTranscriptionTests: XCTestCase {
    private let transcriptionId = UUID(uuidString: "DDBBAAEE-1111-1111-1111-111111111111")!

    func testBlobParentSupportsAllVoiceprintChildren() throws {
        try exerciseChildren(parentKey: transcriptionId.databaseValue)
    }

    func testUppercaseTextParentSupportsAllVoiceprintChildren() throws {
        try exerciseChildren(parentKey: transcriptionId.uuidString.databaseValue)
    }

    func testLowercaseTextParentSupportsAllVoiceprintChildren() throws {
        try exerciseChildren(parentKey: transcriptionId.uuidString.lowercased().databaseValue)
    }

    private func exerciseChildren(parentKey: DatabaseValue) throws {
        let database = try DatabaseManager()
        let profiles = SpeakerProfileRepository(dbQueue: database.dbQueue)
        let candidates = SpeakerEmbeddingCandidateRepository(dbQueue: database.dbQueue)
        let journal = SpeakerMatchJournalRepository(dbQueue: database.dbQueue)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcriptions (id, createdAt, fileName, updatedAt, sourceType)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [parentKey, now, "Legacy meeting", now, "meeting"]
            )
        }
        let identity = SpeakerModelIdentity(embeddingModelId: "test", aggregationProfileId: "test")
        var vector = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        vector[0] = 1
        let embedding = try XCTUnwrap(SpeakerEmbedding(rawVector: vector, identity: identity))
        let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        let exemplar = SpeakerProfileExemplar(
            profileId: profile.id, embedding: embedding, speechSeconds: 30,
            captureDomain: .system, origin: .manualEnrollment,
            sourceTranscriptionId: transcriptionId, sourceSpeakerId: "S1"
        )
        XCTAssertEqual(
            try profiles.insert(profile, firstExemplar: exemplar, maxPerProfile: 5, evicting: .confirmedSuggestion),
            .inserted
        )
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).first?.sourceTranscriptionId, transcriptionId)
        XCTAssertEqual(
            try profiles.insertExemplar(exemplar, maxPerProfile: 5, evicting: .confirmedSuggestion),
            .rejectedAlreadySampled
        )

        // Both other exemplar insertion paths must resolve the same source FK.
        for (name, capped) in [("Alex", false), ("Jordan", true)] {
            let other = SpeakerProfile(displayName: name, identity: identity)
            try profiles.insert(other)
            var sample = exemplar
            sample.id = UUID()
            sample.profileId = other.id
            if capped {
                XCTAssertEqual(
                    try profiles.insertExemplar(sample, maxPerProfile: 5, evicting: .confirmedSuggestion), .inserted
                )
            } else {
                try profiles.insert(sample)
            }
        }

        var candidate = SpeakerEmbeddingCandidate(
            transcriptionId: transcriptionId, speakerId: "S1", transcriptFingerprint: "fingerprint",
            embedding: embedding, speechSeconds: 30, captureDomain: .system,
            createdAt: now, expiresAt: now.addingTimeInterval(60)
        )
        try candidates.upsert([candidate], now: now)
        candidate.id = UUID()
        candidate.speechSeconds = 45
        try candidates.upsert([candidate], now: now)
        XCTAssertEqual(
            try candidates.candidate(
                transcriptionId: transcriptionId, speakerId: "S1", fingerprint: "fingerprint", now: now
            ), candidate
        )
        try candidates.delete(transcriptionId: transcriptionId, speakerId: "S1", fingerprint: "fingerprint")
        XCTAssertNil(
            try candidates.candidate(
                transcriptionId: transcriptionId, speakerId: "S1", fingerprint: "fingerprint", now: now
            )
        )
        try candidates.upsert([candidate], now: now)

        var link = SpeakerProfileLink(
            transcriptionId: transcriptionId, speakerId: "S1", transcriptFingerprint: "fingerprint",
            profileId: profile.id, status: .suggested, distance: 0.1, createdAt: now, updatedAt: now
        )
        try profiles.save(link)
        link.status = .confirmed
        try profiles.save(link)
        XCTAssertEqual(try profiles.links(transcriptionId: transcriptionId, fingerprint: "fingerprint"), [link])

        var pending = link
        pending.status = .suggested
        pending.transcriptFingerprint = "other-fingerprint"
        XCTAssertEqual(
            try profiles.replaceSuggestions(
                transcriptionId: transcriptionId, fingerprint: "other-fingerprint", with: [pending]
            ), [pending]
        )
        _ = try profiles.replaceSuggestions(
            transcriptionId: transcriptionId, fingerprint: "other-fingerprint", with: [])
        XCTAssertTrue(try profiles.links(transcriptionId: transcriptionId, fingerprint: "other-fingerprint").isEmpty)
        XCTAssertEqual(try profiles.links(transcriptionId: transcriptionId, fingerprint: "fingerprint"), [link])

        let entry = SpeakerMatchJournalEntry(
            transcriptionId: transcriptionId, speakerId: "S1", transcriptFingerprint: "fingerprint",
            profileId: profile.id, outcome: .suggested, speechSeconds: 30, createdAt: now
        )
        try journal.append([entry], retention: 60, now: now)
        XCTAssertEqual(try journal.entries(retention: 60, now: now), [entry])

        try database.dbQueue.write { db in
            for (table, column) in [
                ("speaker_profile_exemplars", "sourceTranscriptionId"),
                ("speaker_profile_links", "transcriptionId"),
                ("speaker_embedding_candidates", "transcriptionId"),
                ("speaker_match_journal", "transcriptionId"),
            ] {
                for row in try Row.fetchAll(db, sql: "SELECT \(column) AS storedKey FROM \(table)") {
                    XCTAssertEqual(row["storedKey"] as DatabaseValue, parentKey)
                }
            }
            let parent = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT id FROM transcriptions"))
            XCTAssertEqual(parent["id"] as DatabaseValue, parentKey)
            // Delete the actual parent key. The unrelated legacy behavior of
            // TranscriptionRepository.delete is deliberately outside this test.
            try db.execute(sql: "DELETE FROM transcriptions WHERE id = ?", arguments: [parentKey])
            XCTAssertEqual(try SpeakerProfileLink.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerEmbeddingCandidate.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerMatchJournalEntry.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerProfileExemplar.fetchCount(db), 3)
            XCTAssertTrue(try SpeakerProfileExemplar.fetchAll(db).allSatisfy { $0.sourceTranscriptionId == nil })
        }
    }
}
