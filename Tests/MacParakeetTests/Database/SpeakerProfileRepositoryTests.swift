import XCTest
import GRDB
@testable import MacParakeetCore

final class SpeakerProfileRepositoryTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var repo: SpeakerProfileRepository!
    private var transcriptions: TranscriptionRepository!

    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    override func setUp() async throws {
        let manager = try DatabaseManager()
        dbQueue = manager.dbQueue
        repo = SpeakerProfileRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    // MARK: Schema

    func testMigrationCreatesTheThreeVoiceprintTables() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("speaker_profiles"))
            XCTAssertTrue(try db.tableExists("speaker_profile_exemplars"))
            XCTAssertTrue(try db.tableExists("speaker_profile_links"))

            XCTAssertEqual(
                Set(try db.columns(in: "speaker_profiles").map(\.name)),
                [
                    "id", "displayName", "normalizedName", "embeddingModelId", "aggregationProfileId",
                    "createdAt", "updatedAt", "lastMatchedAt", "lastEvaluatedAt",
                    "lastEvaluatedDistance",
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "speaker_profile_exemplars").map(\.name)),
                [
                    "id", "profileId", "vector", "speechSeconds", "captureDomain",
                    "origin", "embeddingModelId", "aggregationProfileId",
                    "sourceTranscriptionId", "sourceSpeakerId", "createdAt",
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "speaker_profile_links").map(\.name)),
                [
                    "transcriptionId", "speakerId", "transcriptFingerprint", "profileId",
                    "status", "distance", "runnerUpDistance", "createdAt", "updatedAt",
                ]
            )
        }
    }

    // MARK: Round trip

    func testExemplarVectorRoundTripsBitExact() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let embedding = makeEmbedding(index: 7)
        try repo.insert(exemplar(profileId: profile.id, embedding: embedding))

        let stored = try XCTUnwrap(try repo.exemplars(profileId: profile.id).first)
        XCTAssertEqual(stored.vector.count, 1024)
        XCTAssertEqual(try XCTUnwrap(stored.embedding).vector, embedding.vector)
        XCTAssertEqual(stored.identity, identity)
    }

    // MARK: Constraints

    func testRejectsVectorOfTheWrongLength() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO speaker_profile_exemplars
                        (id, profileId, vector, speechSeconds, captureDomain, origin,
                         embeddingModelId, aggregationProfileId, createdAt)
                        VALUES (?, ?, ?, ?, 'system', 'manualEnrollment', ?, ?, ?)
                        """,
                    arguments: [
                        UUID(), profile.id, Data(repeating: 0, count: 1020), 20.0,
                        identity.embeddingModelId, identity.aggregationProfileId, Date(),
                    ]
                )
            }
        )
    }

    func testRejectsNonPositiveSpeechDuration() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(
            try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1), speechSeconds: 0))
        )
    }

    func testRejectsUnknownCaptureDomainOrOrigin() throws {
        let profile = try enrolledProfile(named: "Sarah")
        for (domain, origin) in [("hologram", "manualEnrollment"), ("system", "osmosis")] {
            XCTAssertThrowsError(
                try dbQueue.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO speaker_profile_exemplars
                            (id, profileId, vector, speechSeconds, captureDomain, origin,
                             embeddingModelId, aggregationProfileId, createdAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            UUID(), profile.id, makeEmbedding(index: 1).data, 20.0,
                            domain, origin,
                            identity.embeddingModelId, identity.aggregationProfileId, Date(),
                        ]
                    )
                }
            )
        }
    }

    func testNamesAreUniqueCaseInsensitively() throws {
        _ = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(try repo.insert(SpeakerProfile(displayName: "sarah", identity: identity)))
    }

    func testOneExemplarPerProfilePerRecording() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()

        try repo.insert(
            exemplar(
                profileId: profile.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )
        XCTAssertThrowsError(
            try repo.insert(
                exemplar(
                    profileId: profile.id,
                    embedding: makeEmbedding(index: 2),
                    sourceTranscriptionId: transcription.id
                )
            )
        )
    }

    /// SQLite treats NULLs as distinct in a UNIQUE constraint, which is what we
    /// want: exemplars whose recording was deleted must not start colliding.
    func testExemplarsWithoutARecordingDoNotCollide() throws {
        let profile = try enrolledProfile(named: "Sarah")
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)))
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 2)))
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 2)
    }

    func testRejectsAnExemplarFromAnotherEmbeddingModel() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let otherModel = SpeakerModelIdentity(
            embeddingModelId: "other-model",
            aggregationProfileId: identity.aggregationProfileId
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        let foreign = try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherModel))

        XCTAssertThrowsError(
            try repo.insert(
                SpeakerProfileExemplar(
                    profileId: profile.id,
                    embedding: foreign,
                    speechSeconds: 20,
                    captureDomain: .system,
                    origin: .manualEnrollment
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .incompatibleEmbeddingModel(profile: "test-model", exemplar: "other-model")
            )
        }
        XCTAssertTrue(try repo.exemplars(profileId: profile.id).isEmpty)
    }

    /// A differing aggregation profile stays comparable — the matcher tightens
    /// its threshold for it — so the store must not refuse it.
    func testAcceptsAnExemplarFromAnotherAggregationProfile() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let otherAggregation = SpeakerModelIdentity(
            embeddingModelId: identity.embeddingModelId,
            aggregationProfileId: "other-aggregation"
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[1] = 1
        let embedding = try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherAggregation))

        XCTAssertNoThrow(
            try repo.insert(
                SpeakerProfileExemplar(
                    profileId: profile.id,
                    embedding: embedding,
                    speechSeconds: 20,
                    captureDomain: .system,
                    origin: .manualEnrollment
                )
            )
        )
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
    }

    func testRejectsAModelChangeOnAProfileThatHasSamples() throws {
        var profile = try enrolledProfile(named: "Sarah")
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)))

        profile = SpeakerProfile(
            id: profile.id,
            displayName: profile.displayName,
            identity: SpeakerModelIdentity(
                embeddingModelId: "next-model",
                aggregationProfileId: identity.aggregationProfileId
            )
        )
        XCTAssertThrowsError(try repo.save(profile)) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError, .embeddingModelChangeWithExemplars(profile.id)
            )
        }
        XCTAssertEqual(try repo.profile(id: profile.id)?.embeddingModelId, "test-model")
    }

    func testAModelChangeIsAllowedWhileAProfileHasNoSamples() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let migrated = SpeakerProfile(
            id: profile.id,
            displayName: profile.displayName,
            identity: SpeakerModelIdentity(
                embeddingModelId: "next-model",
                aggregationProfileId: identity.aggregationProfileId
            )
        )
        XCTAssertNoThrow(try repo.save(migrated))
        XCTAssertEqual(try repo.profile(id: profile.id)?.embeddingModelId, "next-model")
    }

    /// The stored key must not depend on the device locale: under a Turkish
    /// locale, localized folding maps "I" to a dotless i, and every profile
    /// whose name contains one would become unfindable after a locale change.
    func testNormalizedKeyIsIndependentOfLocale() throws {
        let profile = SpeakerProfile(displayName: "ISTANBUL", identity: identity)
        try repo.insert(profile)

        XCTAssertEqual(
            SpeakerProfile.normalizedName(for: "ISTANBUL"),
            SpeakerProfile.normalizedName(for: "Istanbul")
        )
        XCTAssertEqual(try repo.profile(named: "istanbul")?.id, profile.id)
        // Localized folding would give "ıstanbul" here; the canonical mapping
        // must not.
        XCTAssertEqual(SpeakerProfile.normalizedName(for: "ISTANBUL"), "istanbul")
    }

    func testRejectsAProfileWhoseNameNormalizesToNothing() throws {
        for blank in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(
                try repo.insert(SpeakerProfile(displayName: blank, identity: identity))
            ) { error in
                XCTAssertEqual(error as? SpeakerProfileStoreError, .emptyDisplayName)
            }
        }
        XCTAssertTrue(try repo.profiles().isEmpty)
    }

    func testASuggestionCannotOverwriteAConfirmedDecision() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()

        var confirmed = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmed.status = .confirmed
        try repo.save(confirmed)

        XCTAssertThrowsError(
            try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))
        ) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .terminalDecisionAlreadyRecorded(status: .confirmed)
            )
        }
        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
                .map(\.status),
            [.confirmed]
        )
    }

    func testASuggestionCannotOverwriteADismissedDecision() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()

        var dismissed = link(transcriptionId: transcription.id, profileId: profile.id)
        dismissed.status = .dismissed
        try repo.save(dismissed)

        XCTAssertThrowsError(
            try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))
        )
    }

    func testASuggestionStillBecomesTerminal() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        var confirmed = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmed.status = .confirmed
        XCTAssertNoThrow(try repo.save(confirmed))
        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
                .map(\.status),
            [.confirmed]
        )
    }

    func testAConfirmedLinkCannotBecomeDismissed() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        var confirmed = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmed.status = .confirmed
        try repo.save(confirmed)

        var dismissed = link(transcriptionId: transcription.id, profileId: profile.id)
        dismissed.status = .dismissed
        XCTAssertThrowsError(try repo.save(dismissed)) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .terminalDecisionAlreadyRecorded(status: .confirmed)
            )
        }
        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
                .map(\.status),
            [.confirmed]
        )
    }

    func testADismissedLinkCannotBecomeConfirmed() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        var dismissed = link(transcriptionId: transcription.id, profileId: profile.id)
        dismissed.status = .dismissed
        try repo.save(dismissed)

        var confirmed = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmed.status = .confirmed
        XCTAssertThrowsError(try repo.save(confirmed)) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .terminalDecisionAlreadyRecorded(status: .dismissed)
            )
        }
        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
                .map(\.status),
            [.dismissed]
        )
    }

    func testATerminalLinkCannotChangeProfile() throws {
        let sarah = try enrolledProfile(named: "Sarah")
        let dan = try enrolledProfile(named: "Dan")
        let transcription = try savedTranscription()
        var confirmed = link(transcriptionId: transcription.id, profileId: sarah.id)
        confirmed.status = .confirmed
        try repo.save(confirmed)

        var moved = link(transcriptionId: transcription.id, profileId: dan.id)
        moved.status = .confirmed
        XCTAssertThrowsError(try repo.save(moved)) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .terminalDecisionAlreadyRecorded(status: .confirmed)
            )
        }
        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
                .map(\.profileId),
            [sarah.id]
        )
    }

    func testRepeatingTheSameTerminalDecisionIsIdempotent() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        var confirmed = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmed.status = .confirmed
        confirmed.distance = 0.12
        try repo.save(confirmed)

        var again = link(transcriptionId: transcription.id, profileId: profile.id)
        again.status = .confirmed
        again.distance = 0.18
        XCTAssertNoThrow(try repo.save(again))
        let stored = try XCTUnwrap(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint").first
        )
        XCTAssertEqual(stored.status, .confirmed)
        XCTAssertEqual(stored.profileId, profile.id)
        XCTAssertEqual(stored.distance, 0.18, accuracy: 0.0001)
    }

    /// The composite foreign key is what makes the model invariant structural
    /// rather than merely enforced in Swift.
    func testTheDatabaseItselfRefusesAMismatchedExemplarModel() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertThrowsError(
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO speaker_profile_exemplars
                        (id, profileId, vector, speechSeconds, captureDomain, origin,
                         embeddingModelId, aggregationProfileId, createdAt)
                        VALUES (?, ?, ?, ?, 'system', 'manualEnrollment', 'other-model', 'a', ?)
                        """,
                    arguments: [UUID(), profile.id, makeEmbedding(index: 1).data, 20.0, Date()]
                )
            }
        )
    }

    // MARK: The sample cap

    func testASampleBelowTheCapIsSimplyInserted() throws {
        let profile = try enrolledProfile(named: "Sarah")

        let outcome = try repo.insertExemplar(
            exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)),
            maxPerProfile: 3,
            evicting: .confirmedSuggestion
        )

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
    }

    func testAtTheCapTheOldestEvictableSampleMakesRoom() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let epoch = Date(timeIntervalSince1970: 1_757_000_000)
        let oldest = exemplar(
            profileId: profile.id, embedding: makeEmbedding(index: 1),
            origin: .confirmedSuggestion, createdAt: epoch
        )
        try repo.insert(oldest)
        try repo.insert(
            exemplar(
                profileId: profile.id, embedding: makeEmbedding(index: 2),
                origin: .confirmedSuggestion, createdAt: epoch.addingTimeInterval(60)
            )
        )

        let outcome = try repo.insertExemplar(
            exemplar(profileId: profile.id, embedding: makeEmbedding(index: 3)),
            maxPerProfile: 2,
            evicting: .confirmedSuggestion
        )

        XCTAssertEqual(outcome, .insertedEvicting(oldest.id))
        let stored = try repo.exemplars(profileId: profile.id)
        XCTAssertEqual(stored.count, 2)
        XCTAssertFalse(stored.contains { $0.id == oldest.id })
    }

    func testAtTheCapWithNothingEvictableTheSampleIsRefused() throws {
        let profile = try enrolledProfile(named: "Sarah")
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)))

        let outcome = try repo.insertExemplar(
            exemplar(profileId: profile.id, embedding: makeEmbedding(index: 2)),
            maxPerProfile: 1,
            evicting: .confirmedSuggestion
        )

        XCTAssertEqual(outcome, .rejectedProfileFull)
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
    }

    func testASecondSampleFromOneRecordingIsRefused() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let recording = try savedTranscription()
        try repo.insert(
            exemplar(
                profileId: profile.id, embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: recording.id
            )
        )

        let outcome = try repo.insertExemplar(
            exemplar(
                profileId: profile.id, embedding: makeEmbedding(index: 2),
                sourceTranscriptionId: recording.id
            ),
            maxPerProfile: 5,
            evicting: .confirmedSuggestion
        )

        XCTAssertEqual(outcome, .rejectedAlreadySampled)
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
    }

    func testAZeroCapRefusesWithoutDeleting() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let kept = exemplar(
            profileId: profile.id, embedding: makeEmbedding(index: 1),
            origin: .confirmedSuggestion
        )
        try repo.insert(kept)

        let outcome = try repo.insertExemplar(
            exemplar(profileId: profile.id, embedding: makeEmbedding(index: 2)),
            maxPerProfile: 0,
            evicting: .confirmedSuggestion
        )

        XCTAssertEqual(outcome, .rejectedProfileFull)
        let stored = try repo.exemplars(profileId: profile.id)
        XCTAssertEqual(stored.map(\.id), [kept.id])
    }

    /// Shrinking the cap below a profile that already exceeds it must not
    /// silently delete several user samples just to insert one more.
    func testAReducedCapAboveTheStoredCountRefusesWithoutDeleting() throws {
        let profile = try enrolledProfile(named: "Sarah")
        try repo.insert(
            exemplar(
                profileId: profile.id, embedding: makeEmbedding(index: 1),
                origin: .confirmedSuggestion
            )
        )
        try repo.insert(
            exemplar(
                profileId: profile.id, embedding: makeEmbedding(index: 2),
                origin: .confirmedSuggestion
            )
        )
        try repo.insert(
            exemplar(
                profileId: profile.id, embedding: makeEmbedding(index: 3),
                origin: .confirmedSuggestion
            )
        )

        let outcome = try repo.insertExemplar(
            exemplar(profileId: profile.id, embedding: makeEmbedding(index: 4)),
            maxPerProfile: 1,
            evicting: .confirmedSuggestion
        )

        XCTAssertEqual(outcome, .rejectedProfileFull)
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 3)
    }

    /// The cap bounds stored biometric data, so it has to hold when several
    /// callers offer samples at once. Counting from outside the transaction
    /// lets each of them read a count below the cap and insert anyway.
    func testTheCapHoldsUnderConcurrentInserts() throws {
        let profile = try enrolledProfile(named: "Sarah")

        // Built up front, and only `store` and the samples cross into the
        // closure: reaching back through `self` for a helper would capture the
        // test case itself.
        let store = repo!
        let samples = (1...12).map {
            exemplar(profileId: profile.id, embedding: makeEmbedding(index: $0))
        }

        let lock = NSLock()
        var outcomes: [Result<SpeakerExemplarInsertion, Error>] = []
        outcomes.reserveCapacity(samples.count)

        DispatchQueue.concurrentPerform(iterations: samples.count) { index in
            let outcome = Result {
                try store.insertExemplar(
                    samples[index],
                    maxPerProfile: 3,
                    evicting: .confirmedSuggestion
                )
            }
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
        }

        let insertions = try outcomes.map { try $0.get() }
        let accepted = insertions.filter {
            switch $0 {
            case .inserted, .insertedEvicting: return true
            case .rejectedProfileFull, .rejectedAlreadySampled: return false
            }
        }
        XCTAssertEqual(accepted.count, 3)
        XCTAssertEqual(insertions.filter { $0 == .rejectedProfileFull }.count, 9)
        XCTAssertEqual(try store.exemplars(profileId: profile.id).count, 3)
    }

    /// The guard must survive on the capped path too: a sample from another
    /// embedding model would be stored and counted while scoring against
    /// nothing.
    func testTheCappedInsertStillRefusesAnotherEmbeddingModel() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let other = SpeakerModelIdentity(
            embeddingModelId: "other-model", aggregationProfileId: "test-aggregation"
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[4] = 1
        let foreign = try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: other))

        XCTAssertThrowsError(
            try repo.insertExemplar(
                exemplar(profileId: profile.id, embedding: foreign),
                maxPerProfile: 5,
                evicting: .confirmedSuggestion
            )
        )
        XCTAssertTrue(try repo.exemplars(profileId: profile.id).isEmpty)
    }

    // MARK: Deleting one sample

    /// Deleting by id alone would let a mismatched id take another profile's
    /// last sample, which the caller believes it is protecting.
    func testASampleFromAnotherProfileIsNotDeleted() throws {
        let sarah = try enrolledProfile(named: "Sarah")
        let nadia = try enrolledProfile(named: "Nadia")
        let nadiasOnly = exemplar(profileId: nadia.id, embedding: makeEmbedding(index: 2))
        try repo.insert(exemplar(profileId: sarah.id, embedding: makeEmbedding(index: 1)))
        try repo.insert(exemplar(profileId: sarah.id, embedding: makeEmbedding(index: 3)))
        try repo.insert(nadiasOnly)

        // Sarah has two, so the count check alone would allow this.
        let deleted = try repo.deleteExemplar(
            id: nadiasOnly.id, profileId: sarah.id, keepingAtLeastOne: true
        )

        XCTAssertFalse(deleted)
        XCTAssertEqual(try repo.exemplars(profileId: nadia.id).count, 1)
    }

    func testTheLastSampleIsRefusedInTheSameWrite() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let only = exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1))
        try repo.insert(only)

        XCTAssertFalse(
            try repo.deleteExemplar(id: only.id, profileId: profile.id, keepingAtLeastOne: true)
        )
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
    }

    /// The rule bounds what a profile keeps, so it has to hold when several
    /// callers delete at once. Counting outside the write cannot do that.
    func testConcurrentDeletesNeverEmptyAProfile() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let samples = (1...6).map { exemplar(profileId: profile.id, embedding: makeEmbedding(index: $0)) }
        for sample in samples { try repo.insert(sample) }
        let store = repo!

        DispatchQueue.concurrentPerform(iterations: samples.count) { index in
            _ = try? store.deleteExemplar(
                id: samples[index].id, profileId: profile.id, keepingAtLeastOne: true
            )
        }

        XCTAssertEqual(try store.exemplars(profileId: profile.id).count, 1)
    }

    // MARK: Counting recognitions

    /// Links are fingerprint-scoped, so one recording re-diarized and confirmed
    /// again holds several rows for the same profile. Counting rows would tell
    /// the user they were recognized in more recordings than exist.
    func testRecognitionsCountDistinctRecordings() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let recording = try savedTranscription()
        for fingerprint in ["fingerprint-1", "fingerprint-2"] {
            var confirmed = link(
                transcriptionId: recording.id, profileId: profile.id, fingerprint: fingerprint
            )
            confirmed.status = .confirmed
            try repo.save(confirmed)
        }

        XCTAssertEqual(try repo.confirmedLinkCount(profileId: profile.id), 1)
    }

    func testRecognitionsIgnoreSuggestionsAndRefusals() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let suggested = try savedTranscription()
        let dismissed = try savedTranscription()
        try repo.save(link(transcriptionId: suggested.id, profileId: profile.id))
        var refused = link(transcriptionId: dismissed.id, profileId: profile.id)
        refused.status = .dismissed
        try repo.save(refused)

        XCTAssertEqual(try repo.confirmedLinkCount(profileId: profile.id), 0)
    }

    // MARK: Claiming a name

    /// Two enrollments of one name can both find nothing before either writes,
    /// so the check belongs in the transaction that creates the profile.
    func testCreatingAProfileUnderATakenNameIsRefused() throws {
        try repo.insert(SpeakerProfile(displayName: "Sarah", identity: identity))

        XCTAssertThrowsError(
            try repo.insert(SpeakerProfile(displayName: "  SARAH ", identity: identity))
        ) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .nameAlreadyTaken(normalizedName: "sarah")
            )
        }
        XCTAssertEqual(try repo.profiles().count, 1)
    }

    func testCreatingAProfileWithABlankNameIsRefused() throws {
        XCTAssertThrowsError(
            try repo.insert(SpeakerProfile(displayName: "   ", identity: identity))
        ) { error in
            XCTAssertEqual(error as? SpeakerProfileStoreError, .emptyDisplayName)
        }
    }

    func testAFailedFirstExemplarLeavesNoEmptyProfile() throws {
        let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        let other = SpeakerModelIdentity(
            embeddingModelId: "other-model", aggregationProfileId: "test-aggregation"
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[4] = 1
        let foreign = try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: other))

        XCTAssertThrowsError(
            try repo.insert(
                profile,
                firstExemplar: exemplar(profileId: profile.id, embedding: foreign),
                maxPerProfile: 10,
                evicting: .confirmedSuggestion
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeakerProfileStoreError,
                .incompatibleEmbeddingModel(profile: "test-model", exemplar: "other-model")
            )
        }
        XCTAssertTrue(try repo.profiles().isEmpty)
        XCTAssertTrue(try repo.exemplars(profileId: profile.id).isEmpty)
    }

    func testAZeroCapFirstExemplarLeavesNoProfile() throws {
        let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        let outcome = try repo.insert(
            profile,
            firstExemplar: exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)),
            maxPerProfile: 0,
            evicting: .confirmedSuggestion
        )
        XCTAssertEqual(outcome, .rejectedProfileFull)
        XCTAssertTrue(try repo.profiles().isEmpty)
    }

    func testConcurrentFirstExemplarsOfOneNameLeaveOneInitializedProfile() throws {
        let store = repo!
        let identity = identity
        let attempts = (1...8).map { index -> (SpeakerProfile, SpeakerProfileExemplar) in
            let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
            return (
                profile,
                exemplar(profileId: profile.id, embedding: makeEmbedding(index: min(index, 10)))
            )
        }

        let lock = NSLock()
        var outcomes: [Result<SpeakerExemplarInsertion, Error>] = []
        outcomes.reserveCapacity(attempts.count)

        DispatchQueue.concurrentPerform(iterations: attempts.count) { index in
            let (profile, sample) = attempts[index]
            let outcome = Result {
                try store.insert(
                    profile,
                    firstExemplar: sample,
                    maxPerProfile: 10,
                    evicting: .confirmedSuggestion
                )
            }
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
        }

        let accepted = try outcomes.compactMap { result -> SpeakerExemplarInsertion? in
            switch result {
            case .success(let insertion):
                return insertion
            case .failure(let error as SpeakerProfileStoreError):
                guard case .nameAlreadyTaken = error else { throw error }
                return nil
            case .failure(let error):
                throw error
            }
        }
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(try XCTUnwrap(accepted.first), .inserted)
        XCTAssertEqual(try store.profiles().count, 1)
        let winner = try XCTUnwrap(try store.profiles().first)
        XCTAssertEqual(try store.exemplars(profileId: winner.id).count, 1)
    }

    // MARK: Deletion

    func testDeletingAProfileRemovesItsExemplarsAndLinks() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.insert(
            exemplar(
                profileId: profile.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        XCTAssertTrue(try repo.deleteProfile(id: profile.id))

        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerProfileExemplar.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerProfileLink.fetchCount(db), 0)
        }
        // The recording itself is untouched: deleting a voiceprint never
        // rewrites the user's transcripts.
        XCTAssertNotNil(try transcriptions.fetch(id: transcription.id))
    }

    func testDeletingARecordingKeepsTheExemplarButClearsItsSource() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.insert(
            exemplar(
                profileId: profile.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )

        XCTAssertTrue(try transcriptions.delete(id: transcription.id))

        let stored = try XCTUnwrap(try repo.exemplars(profileId: profile.id).first)
        XCTAssertNil(stored.sourceTranscriptionId)
        XCTAssertNotNil(stored.embedding)
    }

    func testDeletingARecordingRemovesItsLinks() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        XCTAssertTrue(try transcriptions.delete(id: transcription.id))

        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerProfileLink.fetchCount(db), 0)
        }
    }

    func testDeleteAllProfilesEmptiesEveryVoiceprintTable() throws {
        let first = try enrolledProfile(named: "Sarah")
        let second = try enrolledProfile(named: "Dan")
        let transcription = try savedTranscription()
        try repo.insert(
            exemplar(
                profileId: first.id,
                embedding: makeEmbedding(index: 1),
                sourceTranscriptionId: transcription.id
            )
        )
        try repo.save(link(transcriptionId: transcription.id, profileId: second.id))

        try repo.deleteAllProfiles()

        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerProfile.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerProfileExemplar.fetchCount(db), 0)
            XCTAssertEqual(try SpeakerProfileLink.fetchCount(db), 0)
        }
        XCTAssertNotNil(try transcriptions.fetch(id: transcription.id))
    }

    func testDeleteExemplarRemovesOnlyThatSample() throws {
        let profile = try enrolledProfile(named: "Sarah")
        try repo.insert(exemplar(profileId: profile.id, embedding: makeEmbedding(index: 1)))
        let second = exemplar(profileId: profile.id, embedding: makeEmbedding(index: 2))
        try repo.insert(second)

        XCTAssertTrue(try repo.deleteExemplar(id: second.id))
        XCTAssertEqual(try repo.exemplars(profileId: profile.id).count, 1)
        XCTAssertNotNil(try repo.profile(id: profile.id))
    }

    // MARK: Lookups

    func testProfileLookupByNameIgnoresCase() throws {
        let profile = try enrolledProfile(named: "Sarah")
        XCTAssertEqual(try repo.profile(named: "sarah")?.id, profile.id)
        XCTAssertEqual(try repo.profile(named: "SARAH")?.id, profile.id)
        XCTAssertNil(try repo.profile(named: "Dan"))
    }

    func testExemplarsByProfileGroupsEveryProfile() throws {
        let first = try enrolledProfile(named: "Sarah")
        let second = try enrolledProfile(named: "Dan")
        try repo.insert(exemplar(profileId: first.id, embedding: makeEmbedding(index: 1)))
        try repo.insert(exemplar(profileId: first.id, embedding: makeEmbedding(index: 2)))
        try repo.insert(exemplar(profileId: second.id, embedding: makeEmbedding(index: 3)))

        let grouped = try repo.exemplarsByProfile()
        XCTAssertEqual(grouped[first.id]?.count, 2)
        XCTAssertEqual(grouped[second.id]?.count, 1)
    }

    func testLinksAreScopedToTheirFingerprint() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(
            link(transcriptionId: transcription.id, profileId: profile.id, fingerprint: "before")
        )

        XCTAssertEqual(
            try repo.links(transcriptionId: transcription.id, fingerprint: "before").count,
            1
        )
        // After re-diarization the fingerprint changes and old decisions no
        // longer apply, so a stale dismissal cannot suppress a fresh suggestion.
        XCTAssertTrue(
            try repo.links(transcriptionId: transcription.id, fingerprint: "after").isEmpty
        )
    }

    func testProfileLookupHandlesNonAsciiCase() throws {
        // SQLite's NOCASE folds only ASCII, so this is the case that would
        // silently create a second profile for the same person.
        let profile = SpeakerProfile(displayName: "José", identity: identity)
        try repo.insert(profile)
        XCTAssertEqual(try repo.profile(named: "josé")?.id, profile.id)
        XCTAssertEqual(try repo.profile(named: "JOSÉ")?.id, profile.id)
    }

    /// The constraint and the lookup must agree on what one name is, otherwise
    /// two rows can exist that a lookup considers equal and picks between at
    /// random.
    func testNonAsciiCaseVariantsCannotBothBeStored() throws {
        try repo.insert(SpeakerProfile(displayName: "José", identity: identity))
        XCTAssertThrowsError(try repo.insert(SpeakerProfile(displayName: "JOSÉ", identity: identity)))
    }

    func testRenamingAProfileMovesItsLookupKey() throws {
        var profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        try repo.insert(profile)

        profile.displayName = "Sarah Chen"
        try repo.save(profile)

        XCTAssertEqual(try repo.profile(named: "sarah chen")?.id, profile.id)
        XCTAssertNil(try repo.profile(named: "Sarah"))
        // The old key must not keep enforcing uniqueness either.
        XCTAssertNoThrow(try repo.insert(SpeakerProfile(displayName: "Sarah", identity: identity)))
    }

    func testLookupIgnoresSurroundingWhitespace() throws {
        let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        try repo.insert(profile)
        XCTAssertEqual(try repo.profile(named: "  sarah  ")?.id, profile.id)
    }

    /// Accents are typography; dropping them would be a guess about identity.
    /// Two colleagues named Jose and José stay two people, and the enrollment
    /// guard is what catches a genuine name clash, by voice.
    func testAccentsDistinguishNames() throws {
        let plain = SpeakerProfile(displayName: "Jose", identity: identity)
        let accented = SpeakerProfile(displayName: "José", identity: identity)
        try repo.insert(plain)
        try repo.insert(accented)
        XCTAssertEqual(try repo.profile(named: "jose")?.id, plain.id)
        XCTAssertEqual(try repo.profile(named: "josé")?.id, accented.id)
    }

    func testUpdatingALinkKeepsItsOriginalCreationTime() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        let suggestedAt = Date(timeIntervalSince1970: 1_000_000)

        var suggestion = link(transcriptionId: transcription.id, profileId: profile.id)
        suggestion.createdAt = suggestedAt
        suggestion.updatedAt = suggestedAt
        try repo.save(suggestion)

        var confirmation = link(transcriptionId: transcription.id, profileId: profile.id)
        confirmation.status = .confirmed
        try repo.save(confirmation)

        let stored = try XCTUnwrap(
            try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint").first
        )
        XCTAssertEqual(stored.status, .confirmed)
        XCTAssertEqual(stored.createdAt.timeIntervalSince1970, suggestedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThan(stored.updatedAt, suggestedAt)
    }

    func testSavingALinkTwiceUpdatesItInPlace() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let transcription = try savedTranscription()
        try repo.save(link(transcriptionId: transcription.id, profileId: profile.id))

        var updated = link(transcriptionId: transcription.id, profileId: profile.id)
        updated.status = .dismissed
        try repo.save(updated)

        let stored = try repo.links(transcriptionId: transcription.id, fingerprint: "fingerprint")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, .dismissed)
    }

    func testReplacingSuggestionsRechecksTerminalDecisionsInsideTheWrite() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let otherProfile = try enrolledProfile(named: "Alex")
        let recording = try savedTranscription()
        let staleOffer = link(transcriptionId: recording.id, profileId: profile.id)
        try repo.save(staleOffer)

        // Simulate an answer after the matcher took its snapshot.
        var confirmed = staleOffer
        confirmed.status = .confirmed
        try repo.save(confirmed)
        var siblingOffer = staleOffer
        siblingOffer.speakerId = "system:S2"
        var unrelatedOffer = staleOffer
        unrelatedOffer.speakerId = "system:S3"
        unrelatedOffer.profileId = otherProfile.id
        var oldScope = staleOffer
        oldScope.transcriptFingerprint = "other-fingerprint"
        try repo.save(oldScope)

        let published = try repo.replaceSuggestions(
            transcriptionId: recording.id, fingerprint: "fingerprint",
            with: [staleOffer, siblingOffer, unrelatedOffer]
        )
        XCTAssertEqual(published.map(\.speakerId), ["system:S3"])
        let links = try repo.links(transcriptionId: recording.id, fingerprint: "fingerprint")
        XCTAssertEqual(Set(links.map(\.speakerId)), ["system:S1", "system:S3"])
        XCTAssertEqual(links.first { $0.speakerId == "system:S1" }?.status, .confirmed)
        let untouched = try repo.links(transcriptionId: recording.id, fingerprint: "other-fingerprint")
        XCTAssertEqual(untouched.count, 1)
        XCTAssertEqual(untouched.first?.status, .suggested)
        XCTAssertEqual(untouched.first?.profileId, profile.id)
    }

    func testFailedSuggestionReplacementRollsBackRemovedOffers() throws {
        let profile = try enrolledProfile(named: "Sarah")
        let recording = try savedTranscription()
        let original = link(transcriptionId: recording.id, profileId: profile.id)
        try repo.save(original)
        var invalid = original
        invalid.profileId = UUID()
        XCTAssertThrowsError(
            try repo.replaceSuggestions(transcriptionId: recording.id, fingerprint: "fingerprint", with: [invalid])
        )
        let remaining = try repo.links(transcriptionId: recording.id, fingerprint: "fingerprint")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.profileId, profile.id)
        XCTAssertEqual(remaining.first?.status, .suggested)
    }

    // MARK: Helpers

    private func makeEmbedding(index: Int) -> SpeakerEmbedding {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[index] = 1
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    private func enrolledProfile(named name: String) throws -> SpeakerProfile {
        let profile = SpeakerProfile(displayName: name, identity: identity)
        try repo.insert(profile)
        return profile
    }

    private func savedTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try transcriptions.save(transcription)
        return transcription
    }

    private func exemplar(
        profileId: UUID,
        embedding: SpeakerEmbedding,
        speechSeconds: Double = 20,
        origin: SpeakerProfileExemplar.Origin = .manualEnrollment,
        sourceTranscriptionId: UUID? = nil,
        createdAt: Date = Date()
    ) -> SpeakerProfileExemplar {
        SpeakerProfileExemplar(
            profileId: profileId,
            embedding: embedding,
            speechSeconds: speechSeconds,
            captureDomain: .system,
            origin: origin,
            sourceTranscriptionId: sourceTranscriptionId,
            sourceSpeakerId: "S1",
            createdAt: createdAt
        )
    }

    private func link(
        transcriptionId: UUID,
        profileId: UUID,
        fingerprint: String = "fingerprint"
    ) -> SpeakerProfileLink {
        SpeakerProfileLink(
            transcriptionId: transcriptionId,
            speakerId: "system:S1",
            transcriptFingerprint: fingerprint,
            profileId: profileId,
            status: .suggested,
            distance: 0.12,
            runnerUpDistance: 0.44
        )
    }
}
