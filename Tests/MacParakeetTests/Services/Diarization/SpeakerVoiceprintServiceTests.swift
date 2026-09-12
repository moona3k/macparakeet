import XCTest
import GRDB
@testable import MacParakeetCore

final class SpeakerVoiceprintServiceTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var profiles: SpeakerProfileRepository!
    private var candidates: SpeakerEmbeddingCandidateRepository!
    private var journal: SpeakerMatchJournalRepository!
    private var transcriptions: TranscriptionRepository!
    private var enabled = true

    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )
    private let fingerprint = TranscriptFingerprint(rawValue: "fingerprint-1")

    override func setUp() async throws {
        let manager = try DatabaseManager()
        dbQueue = manager.dbQueue
        profiles = SpeakerProfileRepository(dbQueue: manager.dbQueue)
        candidates = SpeakerEmbeddingCandidateRepository(dbQueue: manager.dbQueue)
        journal = SpeakerMatchJournalRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        enabled = true
    }

    // MARK: Gating

    func testDisabledServiceReadsNothingAndWritesNothing() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        enabled = false

        let suggestions = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(
            try journal.entries(retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()).isEmpty)
        XCTAssertTrue(try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue).isEmpty)
    }

    func testEnrollThrowsWhenDisabledAndDoesNotWrite() async throws {
        let recording = try savedTranscription()
        enabled = false

        do {
            _ = try await makeService().enroll(
                displayName: "Sarah",
                observation: cluster("S1", voice: 0, degrees: 0),
                transcriptionId: recording.id,
                fingerprint: fingerprint,
                allowMergeIntoExistingName: false
            )
            XCTFail("expected a disabled refusal")
        } catch SpeakerVoiceprintServiceError.disabled {
        }

        XCTAssertTrue(try profiles.profiles().isEmpty)
        XCTAssertNil(
            try candidates.candidate(
                transcriptionId: recording.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
    }

    func testConfirmAndDismissThrowWhenDisabledAndLeaveLinksUntouched() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let enabledService = makeService()
        let suggestions = try await enabledService.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        let suggestion = try XCTUnwrap(suggestions.first)

        enabled = false
        let disabled = makeService()
        do {
            try await disabled.confirm(
                suggestion,
                transcriptionId: next.id,
                fingerprint: fingerprint
            )
            XCTFail("expected a disabled refusal")
        } catch SpeakerVoiceprintServiceError.disabled {
        }
        do {
            try await disabled.dismiss(
                suggestion, transcriptionId: next.id, fingerprint: fingerprint
            )
            XCTFail("expected a disabled refusal")
        } catch SpeakerVoiceprintServiceError.disabled {
        }

        XCTAssertEqual(
            try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
                .map(\.status),
            [.suggested]
        )
    }

    /// Turning the preference off must not strand biometric candidates.
    func testPruningStillRunsWhenTheFeatureIsOff() async throws {
        let recording = try savedTranscription()
        let captured = Date(timeIntervalSince1970: 1_757_000_000)
        _ = try await makeService(retention: 60, now: captured).evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        enabled = false
        try await makeService(retention: 60, now: captured.addingTimeInterval(120))
            .pruneExpiredCandidates()

        XCTAssertNil(
            try candidates.candidate(
                transcriptionId: recording.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: captured.addingTimeInterval(120)
            )
        )
    }

    func testNoEnrolledProfilesYieldsNoSuggestionsAndNoJournal() async throws {
        let recording = try savedTranscription()

        let suggestions = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(
            try journal.entries(retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()).isEmpty)
    }

    // MARK: Evaluation

    func testSuggestsAnEnrolledVoiceAndRecordsAPendingLink() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        let suggestions = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )

        XCTAssertEqual(suggestions.map(\.displayName), ["Sarah"])
        let links = try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(links.map(\.status), [.suggested])
        XCTAssertEqual(links.first?.profileId, profile.id)
    }

    func testDismissedSpeakersAreNotSuggestedAgainForTheSameFingerprint() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.dismiss(
            try XCTUnwrap(first.first), transcriptionId: next.id, fingerprint: fingerprint
        )

        let second = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(
            try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue).map(\.status),
            [.dismissed]
        )
        XCTAssertEqual(try journal.entries().map(\.outcome), [.suggested, .suggested])
    }

    /// Re-diarization changes the fingerprint, and speaker ids are positional,
    /// so an old refusal must not silence a fresh, possibly correct suggestion.
    func testANewFingerprintReconsidersADismissedSpeaker() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.dismiss(
            try XCTUnwrap(first.first), transcriptionId: next.id, fingerprint: fingerprint
        )

        let afterRerun = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: TranscriptFingerprint(rawValue: "fingerprint-2"),
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertEqual(afterRerun.map(\.displayName), ["Sarah"])
    }

    func testJournalRecordsRejectionsWithTheirReason() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [
                cluster("S1", voice: 0, degrees: 14.1),
                cluster("S2", voice: 3, degrees: 0),
                cluster("S3", voice: 0, degrees: 0, speechSeconds: 2),
            ]
        )

        let outcomes = Dictionary(
            uniqueKeysWithValues: try journal.entries(
                retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()
            ).map { ($0.speakerId, $0.outcome) }
        )
        XCTAssertEqual(outcomes["S1"], .suggested)
        XCTAssertEqual(outcomes["S2"], .pastThreshold)
        XCTAssertEqual(outcomes["S3"], .belowSpeechGate)
    }

    func testEvaluationStampsTheProfileEvenWhenNothingIsSuggested() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 3, degrees: 0)]
        )

        let stored = try XCTUnwrap(try profiles.profile(id: profile.id))
        XCTAssertNotNil(stored.lastEvaluatedAt)
        XCTAssertEqual(try XCTUnwrap(stored.lastEvaluatedDistance), 1, accuracy: 0.01)
        // Scored, but never matched.
        XCTAssertNil(stored.lastMatchedAt)
    }

    func testJournalDropsEntriesPastRetention() throws {
        let recording = try savedTranscription()
        try journal.append(
            [
                SpeakerMatchJournalEntry(
                    transcriptionId: recording.id,
                    speakerId: "S1",
                    transcriptFingerprint: fingerprint.rawValue,
                    outcome: .noComparableProfile,
                    speechSeconds: 30,
                    createdAt: Date(timeIntervalSinceNow: -100 * 24 * 60 * 60)
                )
            ],
            retention: SpeakerMatchJournalRepository.defaultRetention,
            now: Date()
        )
        XCTAssertTrue(
            try journal.entries(retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()).isEmpty)
    }

    /// Expiry cannot ride on writes alone: a user who stops recording stops
    /// appending, and a ninety-day journal would quietly become permanent.
    func testJournalExpiresEvenWhenNothingIsWrittenAgain() throws {
        let recording = try savedTranscription()
        let longAgo = Date(timeIntervalSinceNow: -10 * 24 * 60 * 60)
        try journal.append(
            [
                SpeakerMatchJournalEntry(
                    transcriptionId: recording.id,
                    speakerId: "S1",
                    transcriptFingerprint: fingerprint.rawValue,
                    outcome: .noComparableProfile,
                    speechSeconds: 30,
                    createdAt: longAgo
                )
            ],
            retention: SpeakerMatchJournalRepository.defaultRetention,
            now: longAgo
        )
        XCTAssertEqual(
            try journal.entries(
                retention: SpeakerMatchJournalRepository.defaultRetention, now: longAgo
            ).count,
            1
        )

        // Same rows, read once the window has passed, with no write in between.
        XCTAssertTrue(
            try journal.entries(retention: 24 * 60 * 60, now: Date()).isEmpty
        )
        try dbQueue.read { db in
            XCTAssertEqual(try SpeakerMatchJournalEntry.fetchCount(db), 0)
        }
    }

    // MARK: Enrollment

    func testEnrollCreatesAProfileWithOneManualExemplar() async throws {
        let recording = try savedTranscription()
        let result = try await makeService().enroll(
            displayName: "  Sarah  ",
            observation: cluster("S1", voice: 0, degrees: 0),
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .created(let profile) = result else {
            return XCTFail("expected a new profile, got \(result)")
        }
        XCTAssertEqual(profile.displayName, "Sarah")
        let exemplars = try profiles.exemplars(profileId: profile.id)
        XCTAssertEqual(exemplars.map(\.origin), [.manualEnrollment])
        XCTAssertEqual(exemplars.first?.sourceTranscriptionId, recording.id)
    }

    func testEnrollRefusesAClusterBelowTheEnrollGate() async throws {
        let recording = try savedTranscription()
        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 0, speechSeconds: 12),
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .rejectedTooShort = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertTrue(try profiles.profiles().isEmpty)
    }

    func testEnrollingTheSameNameWithTheSameVoiceAddsASample() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let result = try await makeService().enroll(
            displayName: "sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .addedExemplar = result else {
            return XCTFail("expected an added exemplar, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 2)
        XCTAssertEqual(try profiles.profiles().count, 1)
    }

    /// The widest hole in the design: naming a speaker bypasses every
    /// threshold, so two colleagues called Sarah would silently fuse.
    func testEnrollingAKnownNameWithADifferentVoiceAsksInstead() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 4, degrees: 0),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .needsDisambiguation(let existing, let distance) = result else {
            return XCTFail("expected disambiguation, got \(result)")
        }
        XCTAssertEqual(existing.id, profile.id)
        XCTAssertGreaterThan(distance, SpeakerMatchPolicy.v1.pollutionGuardDistance)
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    func testTheUserCanOverrideTheDisambiguationGuard() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 4, degrees: 0),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: true
        )

        guard case .addedExemplar = result else {
            return XCTFail("expected an added exemplar, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 2)
    }

    func testAProfileTakesAtMostOneSamplePerRecording() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S2", voice: 0, degrees: 14.1),
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .alreadySampled = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    /// speakerId is positional, so a decision is only joinable to the label
    /// that answered it when the transcript version is recorded with it.
    func testJournalRecordsTheTranscriptVersionOfEachDecision() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )

        let entries = try journal.entries(
            retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()
        )
        XCTAssertEqual(entries.map(\.transcriptFingerprint), [fingerprint.rawValue])
    }

    /// An embedding from another model carries no comparable evidence, so it
    /// must not slip past the guard into a silent merge.
    func testEnrollingWithAnIncomparableModelAsksInstead() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let otherModel = SpeakerModelIdentity(
            embeddingModelId: "other-model",
            aggregationProfileId: identity.aggregationProfileId
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        let observation = SpeakerClusterObservation(
            speakerId: "S1",
            embedding: try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherModel)),
            speechSeconds: 30,
            captureDomain: .system
        )

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: observation,
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .needsDisambiguation = result else {
            return XCTFail("expected disambiguation, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    /// Forcing a merge overrides a judgement about which person this is, not
    /// about whether two vectors can be compared: the store would refuse the
    /// sample anyway, so the service must stop first.
    func testForcingAMergeStillRefusesAnIncomparableModel() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()

        let otherModel = SpeakerModelIdentity(
            embeddingModelId: "other-model",
            aggregationProfileId: identity.aggregationProfileId
        )
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        let observation = SpeakerClusterObservation(
            speakerId: "S1",
            embedding: try XCTUnwrap(SpeakerEmbedding(rawVector: values, identity: otherModel)),
            speechSeconds: 30,
            captureDomain: .system
        )

        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: observation,
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: true
        )

        guard case .needsDisambiguation = result else {
            return XCTFail("expected disambiguation, got \(result)")
        }
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
    }

    func testEnrollRefusesABlankName() async throws {
        let recording = try savedTranscription()
        for blank in ["", "   ", "\n\t"] {
            let result = try await makeService().enroll(
                displayName: blank,
                observation: cluster("S1", voice: 0, degrees: 0),
                transcriptionId: recording.id,
                fingerprint: fingerprint,
                allowMergeIntoExistingName: false
            )
            XCTAssertEqual(result, .rejectedEmptyName)
        }
        XCTAssertTrue(try profiles.profiles().isEmpty)
    }

    /// Re-evaluation preserves the answer while recording the matcher outcome.
    func testConfirmedSpeakersAreNotSuggestedAgain() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(first.first),
            transcriptionId: next.id,
            fingerprint: fingerprint
        )

        let second = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(
            try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
                .map(\.status),
            [.confirmed]
        )
        XCTAssertEqual(try journal.entries().map(\.outcome), [.suggested, .suggested])
    }

    func testJournalPreservesAMatchWithheldForAnAlreadyConfirmedProfile() async throws {
        let enrollment = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: enrollment.id)
        let recording = try savedTranscription()
        try profiles.save(
            SpeakerProfileLink(
                transcriptionId: recording.id, speakerId: "S1",
                transcriptFingerprint: fingerprint.rawValue, profileId: profile.id,
                status: .confirmed, distance: 0.03
            ))

        let suggestions = try await makeService().evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint,
            clusters: [cluster("S2", voice: 0, degrees: 14.1)]
        )

        XCTAssertTrue(suggestions.isEmpty)
        let links = try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(links.map(\.speakerId), ["S1"])
        XCTAssertEqual(links.map(\.status), [.confirmed])
        let entries = try journal.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.speakerId, "S2")
        XCTAssertEqual(entry.profileId, profile.id)
        XCTAssertEqual(entry.outcome, .suggested)
    }

    /// 14.1° clears tau; 41.4° is exactly tau. Together they keep the margin.
    /// Filtering the confirmed cluster *before* scoring would let S2 inherit
    /// Sarah with a manufactured singleton confidence.
    func testConfirmingDoesNotGiveTheSameVoiceToASiblingCluster() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()
        let close = cluster("S1", voice: 0, degrees: 14.1)
        let sibling = cluster("S2", voice: 0, degrees: 41.4)

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [close, sibling]
        )
        XCTAssertEqual(first.map(\.speakerId), ["S1"])
        XCTAssertEqual(first.map(\.displayName), ["Sarah"])

        try await service.confirm(
            try XCTUnwrap(first.first),
            transcriptionId: next.id,
            fingerprint: fingerprint
        )

        let second = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [close, sibling]
        )
        XCTAssertTrue(second.isEmpty)
        let links = try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(
            links.filter { $0.status == .confirmed }.map(\.speakerId),
            ["S1"]
        )
        XCTAssertFalse(links.contains { $0.speakerId == "S2" })
        let entries = try journal.entries()
        XCTAssertEqual(entries.filter { $0.speakerId == "S1" }.map(\.outcome), [.suggested, .suggested])
        XCTAssertEqual(
            entries.filter { $0.speakerId == "S2" }.map(\.outcome),
            [.notMutualBestMatch, .notMutualBestMatch]
        )
    }

    /// Dismissing the closer cluster must not manufacture a suggestion for the
    /// farther one: it still lost the original competition.
    func testDismissingACloserClusterDoesNotManufactureASuggestionForASibling() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()
        let close = cluster("S1", voice: 0, degrees: 14.1)
        let sibling = cluster("S2", voice: 0, degrees: 41.4)

        let first = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [close, sibling]
        )
        try await service.dismiss(
            try XCTUnwrap(first.first), transcriptionId: next.id, fingerprint: fingerprint
        )

        let second = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [close, sibling]
        )
        XCTAssertTrue(second.isEmpty)
        let links = try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(
            links.filter { $0.status == .dismissed }.map(\.speakerId),
            ["S1"]
        )
        XCTAssertFalse(links.contains { $0.speakerId == "S2" && $0.status == .suggested })
    }

    /// The cap has to bound storage, not just scoring: vectors the matcher can
    /// never reach would be biometric data kept for nothing.
    func testTheOldestConfirmationIsEvictedAtTheCap() async throws {
        let service = makeService()
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)

        // A second manual enrollment unlocks learning from confirmations.
        let second = try savedTranscription()
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        // Fill the rest of the cap with confirmations.
        var confirmedRecordings: [UUID] = []
        while try profiles.exemplars(profileId: profile.id).count
            < SpeakerMatchPolicy.v1.maxReferencesPerProfile
        {
            let recording = try savedTranscription()
            confirmedRecordings.append(recording.id)
            let suggestions = try await service.evaluate(
                transcriptionId: recording.id,
                fingerprint: fingerprint,
                clusters: [cluster("S1", voice: 0, degrees: 14.1)]
            )
            try await service.confirm(
                try XCTUnwrap(suggestions.first),
                transcriptionId: recording.id,
                fingerprint: fingerprint
            )
        }
        XCTAssertEqual(
            try profiles.exemplars(profileId: profile.id).count,
            SpeakerMatchPolicy.v1.maxReferencesPerProfile
        )
        let oldestConfirmation = try XCTUnwrap(confirmedRecordings.first)

        // One more recording: the count holds and the oldest confirmation goes.
        let extra = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: extra.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            transcriptionId: extra.id,
            fingerprint: fingerprint
        )

        let stored = try profiles.exemplars(profileId: profile.id)
        XCTAssertEqual(stored.count, SpeakerMatchPolicy.v1.maxReferencesPerProfile)
        XCTAssertFalse(stored.contains { $0.sourceTranscriptionId == oldestConfirmation })
        XCTAssertTrue(stored.contains { $0.sourceTranscriptionId == extra.id })
        // Both manual anchors survive, so the profile keeps its right to learn.
        XCTAssertEqual(stored.filter { $0.origin == .manualEnrollment }.count, 2)
    }

    /// Ten manual enrollments are the strongest evidence there is; there is
    /// nothing to evict without weakening the anchor.
    func testAProfileFullOfManualEnrollmentsRefusesMore() async throws {
        let service = makeService()
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)

        while try profiles.exemplars(profileId: profile.id).count
            < SpeakerMatchPolicy.v1.maxReferencesPerProfile
        {
            let recording = try savedTranscription()
            _ = try await service.enroll(
                displayName: "Sarah",
                observation: cluster("S1", voice: 0, degrees: 14.1),
                transcriptionId: recording.id,
                fingerprint: fingerprint,
                allowMergeIntoExistingName: false
            )
        }

        let overflow = try savedTranscription()
        let result = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: overflow.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .rejectedProfileFull = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(
            try profiles.exemplars(profileId: profile.id).count,
            SpeakerMatchPolicy.v1.maxReferencesPerProfile
        )
    }

    /// The user asked for a name, not for a row: when another enrollment claims
    /// it between the lookup and the insert, the second one samples the winner
    /// rather than failing.
    func testAnEnrollmentThatLosesTheNameRaceSamplesTheWinner() async throws {
        let first = try savedTranscription()
        let winner = try await enrolledSarah(transcriptionId: first.id)

        let racing = SpeakerVoiceprintService(
            profiles: NameHidingStore(profiles),
            candidates: candidates,
            journal: journal,
            policy: .v1,
            isEnabled: { true }
        )
        let second = try savedTranscription()
        let result = try await racing.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .addedExemplar(let profile) = result else {
            return XCTFail("expected the loser to sample the winner, got \(result)")
        }
        XCTAssertEqual(profile.id, winner.id)
        XCTAssertEqual(try profiles.profiles().count, 1)
        XCTAssertEqual(try profiles.exemplars(profileId: winner.id).count, 2)
    }

    /// The first sample has to exist before a loser can judge voices. An empty
    /// winner would skip the pollution guard and fuse two people.
    func testConcurrentConflictingNameEnrollmentsDoNotSkipThePollutionGuard() async throws {
        let first = try savedTranscription()
        let second = try savedTranscription()
        let service = makeService()

        let firstObservation = cluster("S1", voice: 0, degrees: 0)
        let secondObservation = cluster("S2", voice: 4, degrees: 0)
        let transcriptFingerprint = fingerprint
        async let left = service.enroll(
            displayName: "Sarah",
            observation: firstObservation,
            transcriptionId: first.id,
            fingerprint: transcriptFingerprint,
            allowMergeIntoExistingName: false
        )
        async let right = service.enroll(
            displayName: "Sarah",
            observation: secondObservation,
            transcriptionId: second.id,
            fingerprint: transcriptFingerprint,
            allowMergeIntoExistingName: false
        )
        let results = [try await left, try await right]

        XCTAssertEqual(try profiles.profiles().count, 1)
        let profile = try XCTUnwrap(try profiles.profiles().first)
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
        XCTAssertTrue(
            results.contains {
                if case .created = $0 { return true }; return false
            })
        XCTAssertTrue(
            results.contains {
                if case .needsDisambiguation = $0 { return true }; return false
            }
        )
        XCTAssertFalse(
            results.contains {
                if case .addedExemplar = $0 { return true }; return false
            })
    }

    // MARK: Enrollment candidates

    /// The run that matters most for enrollment is the first one, when there is
    /// no profile to score against and every matching path returns early.
    func testAVoiceIsRetainedEvenWhenThereIsNothingToMatchAgainst() async throws {
        let recording = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        let observation = try await makeService().enrollmentCandidate(
            transcriptionId: recording.id, speakerId: "S1", fingerprint: fingerprint
        )
        XCTAssertEqual(
            try XCTUnwrap(observation).embedding.vector, embedding(voice: 0, degrees: 0).vector
        )
    }

    func testNothingIsRetainedWhileTheFeatureIsOff() async throws {
        let recording = try savedTranscription()
        enabled = false

        _ = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        XCTAssertNil(
            try candidates.candidate(
                transcriptionId: recording.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
    }

    /// A vector below the enrollment gate can never become an exemplar, so
    /// keeping it would store biometric data for an offer never made.
    func testAClusterTooShortToEnrollIsNotRetained() async throws {
        let recording = try savedTranscription()

        _ = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0, speechSeconds: 14)]
        )

        XCTAssertNil(
            try candidates.candidate(
                transcriptionId: recording.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
    }

    /// Captured while on, unreachable once off: the preference governs reads as
    /// well as writes.
    func testARetainedVoiceIsUnreachableAfterTheFeatureIsTurnedOff() async throws {
        let recording = try savedTranscription()
        _ = try await makeService().evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        enabled = false

        let offered = try await makeService().enrollmentCandidate(
            transcriptionId: recording.id, speakerId: "S1", fingerprint: fingerprint
        )
        XCTAssertNil(offered)
    }

    func testARetainedVoiceStopsBeingOfferedOnceTheWindowLapses() async throws {
        let recording = try savedTranscription()
        let captured = Date(timeIntervalSince1970: 1_757_000_000)
        let service = makeService(retention: 60, now: captured)
        _ = try await service.evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        let withinWindow = try await makeService(retention: 60, now: captured.addingTimeInterval(59))
            .enrollmentCandidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: fingerprint
            )
        XCTAssertNotNil(withinWindow)

        let lapsed = try await makeService(retention: 60, now: captured.addingTimeInterval(60))
            .enrollmentCandidate(
                transcriptionId: recording.id, speakerId: "S1", fingerprint: fingerprint
            )
        XCTAssertNil(lapsed)
    }

    /// Once promoted, the vector lives in the profile; a second copy would be
    /// biometric data kept for nothing.
    func testEnrollingConsumesTheCandidate() async throws {
        let recording = try savedTranscription()
        let service = makeService()
        _ = try await service.evaluate(
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 0)]
        )

        let offered = try await service.enrollmentCandidate(
            transcriptionId: recording.id, speakerId: "S1", fingerprint: fingerprint
        )
        let observation = try XCTUnwrap(offered)
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: observation,
            transcriptionId: recording.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        XCTAssertNil(
            try candidates.candidate(
                transcriptionId: recording.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
    }

    func testConfirmingConsumesTheCandidateOnceTheProfileLearns() async throws {
        let first = try savedTranscription()
        try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()
        let service = makeService()
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        let third = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: third.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            transcriptionId: third.id,
            fingerprint: fingerprint
        )

        XCTAssertNil(
            try candidates.candidate(
                transcriptionId: third.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
    }

    func testConfirmingKeepsTheCandidateWhenTheProfileIsFull() async throws {
        let service = makeService()
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        while try profiles.exemplars(profileId: profile.id).count
            < SpeakerMatchPolicy.v1.maxReferencesPerProfile
        {
            let recording = try savedTranscription()
            _ = try await service.enroll(
                displayName: "Sarah",
                observation: cluster("S1", voice: 0, degrees: 14.1),
                transcriptionId: recording.id,
                fingerprint: fingerprint,
                allowMergeIntoExistingName: false
            )
        }

        let extra = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: extra.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertNotNil(
            try candidates.candidate(
                transcriptionId: extra.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            transcriptionId: extra.id,
            fingerprint: fingerprint
        )

        XCTAssertNotNil(
            try candidates.candidate(
                transcriptionId: extra.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
        XCTAssertEqual(
            try profiles.exemplars(profileId: profile.id).count,
            SpeakerMatchPolicy.v1.maxReferencesPerProfile
        )
    }

    func testConfirmingKeepsTheCandidateWhenAlreadySampled() async throws {
        let first = try savedTranscription()
        try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()
        let service = makeService()
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        let suggestions = try await service.evaluate(
            transcriptionId: second.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            transcriptionId: second.id,
            fingerprint: fingerprint
        )

        XCTAssertNotNil(
            try candidates.candidate(
                transcriptionId: second.id, speakerId: "S1",
                fingerprint: fingerprint.rawValue, now: Date()
            )
        )
        XCTAssertEqual(try profiles.exemplars(profileId: try XCTUnwrap(try profiles.profiles().first).id).count, 2)
    }

    // MARK: Reading offers back

    /// Scoring happens when the meeting ends; the user opens the transcript
    /// later, often after a relaunch, so offers have to be readable from the
    /// store rather than held in memory.
    func testPendingSuggestionsAreReadBackForTheSameFingerprint() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )

        let offers = try await makeService().pendingSuggestions(
            transcriptionId: next.id, fingerprint: fingerprint
        )

        XCTAssertEqual(offers.map(\.displayName), ["Sarah"])
        XCTAssertEqual(offers.first?.profileId, profile.id)
        XCTAssertEqual(offers.first?.speakerId, "S1")
    }

    func testAnsweredSuggestionsAreNotReadBack() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()
        let offers = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )

        try await service.dismiss(
            try XCTUnwrap(offers.first), transcriptionId: next.id, fingerprint: fingerprint
        )

        let pending = try await service.pendingSuggestions(
            transcriptionId: next.id, fingerprint: fingerprint
        )
        XCTAssertTrue(pending.isEmpty)
    }

    /// Speaker ids are positional, so offers from an earlier diarization must
    /// not surface against the current one.
    func testPendingSuggestionsAreScopedToTheFingerprint() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )

        let pending = try await makeService().pendingSuggestions(
            transcriptionId: next.id,
            fingerprint: TranscriptFingerprint(rawValue: "fingerprint-2")
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testPendingSuggestionsAreEmptyWhileTheFeatureIsOff() async throws {
        let recording = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        _ = try await makeService().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        enabled = false

        let pending = try await makeService().pendingSuggestions(
            transcriptionId: next.id, fingerprint: fingerprint
        )
        XCTAssertTrue(pending.isEmpty)
    }

    /// The vector comes from the store, not the caller: a UI holding the wrong
    /// one would teach the profile someone else's voice. With the window
    /// lapsed the decision is still recorded — it just teaches nothing.
    func testConfirmingRecordsTheDecisionEvenWithoutACandidate() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()
        let service = makeService()
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        let third = try savedTranscription()
        let offers = try await service.evaluate(
            transcriptionId: third.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        // Drop the candidate the way expiry would.
        try candidates.deleteAll()

        try await service.confirm(
            try XCTUnwrap(offers.first), transcriptionId: third.id, fingerprint: fingerprint
        )

        XCTAssertEqual(
            try profiles.links(transcriptionId: third.id, fingerprint: fingerprint.rawValue)
                .map(\.status),
            [.confirmed]
        )
        XCTAssertNotNil(try profiles.profile(id: profile.id)?.lastMatchedAt)
        // Two manual enrollments anchor it, so only the missing vector stopped
        // it from learning.
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 2)
    }

    // MARK: Confirmation

    func testConfirmingRecordsTheLinkButDoesNotAmplifyAYoungProfile() async throws {
        let recording = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: recording.id)
        let next = try savedTranscription()
        let service = makeService()

        let suggestions = try await service.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        let observation = cluster("S1", voice: 0, degrees: 14.1)
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            transcriptionId: next.id,
            fingerprint: fingerprint
        )

        let links = try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(links.map(\.status), [.confirmed])
        // One manual enrollment only: a confirmation must not let the profile
        // amplify itself on the strength of its own suggestion.
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).count, 1)
        XCTAssertNotNil(try profiles.profile(id: profile.id)?.lastMatchedAt)
    }

    func testConfirmingAddsASampleOnceTwoManualEnrollmentsAnchorTheVoice() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()
        let service = makeService()
        _ = try await service.enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        let third = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: third.id,
            fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        try await service.confirm(
            try XCTUnwrap(suggestions.first),
            transcriptionId: third.id,
            fingerprint: fingerprint
        )

        let exemplars = try profiles.exemplars(profileId: profile.id)
        XCTAssertEqual(exemplars.count, 3)
        XCTAssertEqual(exemplars.filter { $0.origin == .confirmedSuggestion }.count, 1)
    }

    func testConfirmedShortMatchesDoNotLearnUntilTheEnrollmentDurationBoundary() async throws {
        let first = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: first.id)
        let second = try savedTranscription()
        let matchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let service = makeService(now: matchedAt)
        _ = try await service.enroll(
            displayName: "Sarah", observation: cluster("S1", voice: 0, degrees: 14.1),
            transcriptionId: second.id, fingerprint: fingerprint, allowMergeIntoExistingName: false
        )

        for duration in [3.0, 14.999, 15.0] {
            let recording = try savedTranscription()
            let observation = cluster("S1", voice: 0, degrees: 14.1, speechSeconds: duration)
            let offers = try await service.evaluate(
                transcriptionId: recording.id, fingerprint: fingerprint, clusters: [observation]
            )
            try await service.confirm(
                try XCTUnwrap(offers.first),
                transcriptionId: recording.id, fingerprint: fingerprint
            )
            XCTAssertEqual(
                try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue).map(\.status),
                [.confirmed]
            )
            XCTAssertEqual(try profiles.profile(id: profile.id)?.lastMatchedAt, matchedAt)
            let learned = try profiles.exemplars(profileId: profile.id).filter { $0.origin == .confirmedSuggestion }
            XCTAssertEqual(learned.count, duration < 15 ? 0 : 1)
            if duration == 15 {
                XCTAssertEqual(learned.first?.sourceTranscriptionId, recording.id)
                XCTAssertEqual(learned.first?.speechSeconds, 15)
            }
        }
    }

    func testRescoringPastThresholdRemovesThePreviousPendingSuggestion() async throws {
        let enrollment = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: enrollment.id)
        let recording = try savedTranscription()
        let service = makeService()
        let first = try await service.evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 14.1)]
        )
        XCTAssertEqual(first.count, 1)
        let second = try await service.evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint,
            clusters: [cluster("S1", voice: 0, degrees: 80)]
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertTrue(try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue).isEmpty)
        XCTAssertTrue(try journal.entries().contains { $0.outcome == .pastThreshold })
    }

    func testRescoringWithAnAmbiguousProfileRemovesThePreviousPendingSuggestion() async throws {
        let enrollment = try savedTranscription()
        _ = try await enrolledSarah(transcriptionId: enrollment.id)
        let recording = try savedTranscription()
        let service = makeService()
        let observation = cluster("S1", voice: 0, degrees: 14.1)
        let first = try await service.evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint, clusters: [observation]
        )
        XCTAssertEqual(first.count, 1)
        let other = try savedTranscription()
        _ = try await service.enroll(
            displayName: "Alex", observation: cluster("S1", voice: 0, degrees: 20),
            transcriptionId: other.id, fingerprint: fingerprint, allowMergeIntoExistingName: false
        )
        let second = try await service.evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint, clusters: [observation]
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertTrue(try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue).isEmpty)
        XCTAssertTrue(try journal.entries().contains { $0.outcome == .marginTooSmall })
    }

    func testEmptyRescoringClearsPendingLinksButPreservesDecisionsAndOtherFingerprints() async throws {
        let enrollment = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: enrollment.id)
        let recording = try savedTranscription()
        let service = makeService()
        for (speaker, status, scope) in [
            ("S1", SpeakerProfileLink.Status.suggested, fingerprint.rawValue),
            ("S2", .confirmed, fingerprint.rawValue),
            ("S3", .dismissed, fingerprint.rawValue),
            ("S1", .suggested, "other-fingerprint"),
        ] {
            try profiles.save(
                SpeakerProfileLink(
                    transcriptionId: recording.id, speakerId: speaker, transcriptFingerprint: scope,
                    profileId: profile.id, status: status, distance: 0.1
                ))
        }
        _ = try await service.evaluate(transcriptionId: recording.id, fingerprint: fingerprint, clusters: [])
        let remaining = try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue)
        XCTAssertEqual(Set(remaining.map(\.speakerId)), ["S2", "S3"])
        XCTAssertEqual(remaining.first { $0.speakerId == "S2" }?.status, .confirmed)
        XCTAssertEqual(remaining.first { $0.speakerId == "S3" }?.status, .dismissed)
        XCTAssertEqual(try profiles.links(transcriptionId: recording.id, fingerprint: "other-fingerprint").count, 1)
    }

    func testNoComparableProfilesClearsPendingLinks() async throws {
        let enrollment = try savedTranscription()
        let profile = try await enrolledSarah(transcriptionId: enrollment.id)
        let recording = try savedTranscription()
        let service = makeService()
        let observation = cluster("S1", voice: 0, degrees: 14.1)
        let first = try await service.evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint, clusters: [observation]
        )
        XCTAssertEqual(first.count, 1)
        for exemplar in try profiles.exemplars(profileId: profile.id) {
            XCTAssertTrue(try profiles.deleteExemplar(id: exemplar.id))
        }
        let second = try await service.evaluate(
            transcriptionId: recording.id, fingerprint: fingerprint, clusters: [observation]
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertTrue(try profiles.links(transcriptionId: recording.id, fingerprint: fingerprint.rawValue).isEmpty)
    }

    // MARK: Helpers

    /// Reads `enabled` once, at construction: capturing it lazily would put the
    /// test case itself inside a `@Sendable` closure. Every test that flips the
    /// preference does so before building its service.
    private func makeService(
        retention: TimeInterval = SpeakerEmbeddingCandidateRepository.defaultRetention,
        now: Date? = nil
    ) -> SpeakerVoiceprintService {
        let enabled = enabled
        return SpeakerVoiceprintService(
            profiles: profiles,
            candidates: candidates,
            journal: journal,
            policy: .v1,
            candidateRetention: retention,
            isEnabled: { enabled },
            now: { now ?? Date() }
        )
    }

    private func embedding(voice: Int, degrees: Double) -> SpeakerEmbedding {
        let radians = degrees * Double.pi / 180
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[voice] = Float(cos(radians))
        values[SpeakerEmbedding.dimension - 1 - voice] = Float(sin(radians))
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    private func cluster(
        _ speakerId: String,
        voice: Int,
        degrees: Double,
        speechSeconds: Double = 30
    ) -> SpeakerClusterObservation {
        SpeakerClusterObservation(
            speakerId: speakerId,
            embedding: embedding(voice: voice, degrees: degrees),
            speechSeconds: speechSeconds,
            captureDomain: .system
        )
    }

    private func savedTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try transcriptions.save(transcription)
        return transcription
    }

    @discardableResult
    private func enrolledSarah(transcriptionId: UUID) async throws -> SpeakerProfile {
        let result = try await makeService().enroll(
            displayName: "Sarah",
            observation: cluster("S1", voice: 0, degrees: 0),
            transcriptionId: transcriptionId,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )
        guard case .created(let profile) = result else {
            preconditionFailure("fixture enrollment must create a profile")
        }
        return profile
    }
}

/// Hides a name from the first lookup so `enroll` takes the path where another
/// enrollment claimed it in between.
/// `@unchecked` because the lock is what makes `hidden` safe, and the compiler
/// cannot see that.
private final class NameHidingStore: SpeakerProfileRepositoryProtocol, @unchecked Sendable {
    private let wrapped: SpeakerProfileRepository
    private let lock = NSLock()
    private var hidden = true

    init(_ wrapped: SpeakerProfileRepository) {
        self.wrapped = wrapped
    }

    func profile(named name: String) throws -> SpeakerProfile? {
        lock.lock()
        let hide = hidden
        hidden = false
        lock.unlock()
        return hide ? nil : try wrapped.profile(named: name)
    }

    func profiles() throws -> [SpeakerProfile] { try wrapped.profiles() }
    func profile(id: UUID) throws -> SpeakerProfile? { try wrapped.profile(id: id) }
    func insert(_ profile: SpeakerProfile) throws { try wrapped.insert(profile) }
    func insert(
        _ profile: SpeakerProfile,
        firstExemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin
    ) throws -> SpeakerExemplarInsertion {
        try wrapped.insert(
            profile,
            firstExemplar: firstExemplar,
            maxPerProfile: maxPerProfile,
            evicting: evicting
        )
    }
    func save(_ profile: SpeakerProfile) throws { try wrapped.save(profile) }
    func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar] {
        try wrapped.exemplars(profileId: profileId)
    }
    func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]] {
        try wrapped.exemplarsByProfile()
    }
    func insert(_ exemplar: SpeakerProfileExemplar) throws { try wrapped.insert(exemplar) }
    func insertExemplar(
        _ exemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin
    ) throws -> SpeakerExemplarInsertion {
        try wrapped.insertExemplar(exemplar, maxPerProfile: maxPerProfile, evicting: evicting)
    }
    func deleteExemplar(id: UUID) throws -> Bool { try wrapped.deleteExemplar(id: id) }
    func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink] {
        try wrapped.links(transcriptionId: transcriptionId, fingerprint: fingerprint)
    }
    func save(_ link: SpeakerProfileLink) throws { try wrapped.save(link) }
    func replaceSuggestions(
        transcriptionId: UUID, fingerprint: String, with links: [SpeakerProfileLink]
    ) throws -> [SpeakerProfileLink] {
        try wrapped.replaceSuggestions(transcriptionId: transcriptionId, fingerprint: fingerprint, with: links)
    }
    func deleteProfile(id: UUID) throws -> Bool { try wrapped.deleteProfile(id: id) }
    func deleteAllProfiles() throws { try wrapped.deleteAllProfiles() }
}
