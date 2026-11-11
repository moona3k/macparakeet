import XCTest
import GRDB
@testable import MacParakeetCore

/// The user's own voice: enrolled from the microphone track, recognised there
/// in later meetings, and kept out of suggestions for everyone else.
final class SpeakerOwnerVoiceTests: XCTestCase {
    private var profiles: SpeakerProfileRepository!
    private var candidates: SpeakerEmbeddingCandidateRepository!
    private var journal: SpeakerMatchJournalRepository!
    private var transcriptions: TranscriptionRepository!
    private var enabled = true
    private var owner: OwnerPointer!

    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )
    private let fingerprint = TranscriptFingerprint(rawValue: "fingerprint-1")

    override func setUp() async throws {
        let manager = try DatabaseManager()
        profiles = SpeakerProfileRepository(dbQueue: manager.dbQueue)
        candidates = SpeakerEmbeddingCandidateRepository(dbQueue: manager.dbQueue)
        journal = SpeakerMatchJournalRepository(dbQueue: manager.dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        enabled = true
        owner = OwnerPointer()
    }

    func testMicrophoneVoiceIsRetainedButNeverOfferedAName() async throws {
        let service = makeService()
        let first = try savedTranscription()
        let enrollment = try await service.enroll(
            displayName: "Sarah", observation: observation("system:S1", voice: 0),
            transcriptionId: first.id, fingerprint: fingerprint, allowMergeIntoExistingName: false
        )
        // Without a profile to match, empty suggestions would prove nothing.
        guard case .created = enrollment else { return XCTFail("expected Sarah enrollment") }

        let meeting = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: meeting.id, fingerprint: fingerprint,
            clusters: [observation("microphone", voice: 0, domain: .microphone)]
        )

        XCTAssertTrue(suggestions.isEmpty)
        let ownerCandidate = try await service.ownerEnrollmentCandidate(
            transcriptionId: meeting.id, fingerprint: fingerprint
        )
        XCTAssertNotNil(ownerCandidate)
        XCTAssertTrue(try profiles.links(transcriptionId: meeting.id, fingerprint: fingerprint.rawValue).isEmpty)
    }

    func testOwnerEnrollmentCreatesTheProfileAndPointsAtIt() async throws {
        let service = makeService()
        let meeting = try await evaluatedMeeting(service, ownerVoice: 0)

        let outcome = try await service.enrollOwnerVoice(
            displayName: "Liam", transcriptionId: meeting.id, fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        guard case .created(let profile) = outcome else { return XCTFail("expected a new profile, got \(outcome)") }
        XCTAssertEqual(owner.id, profile.id)
        XCTAssertEqual(try profiles.exemplars(profileId: profile.id).first?.captureDomain, .microphone)
        let consumed = try await service.ownerEnrollmentCandidate(transcriptionId: meeting.id, fingerprint: fingerprint)
        XCTAssertNil(consumed)
        let ownerVoice = try await service.ownerVoice()
        XCTAssertEqual(ownerVoice?.profileId, profile.id)
    }

    /// The ordinary rename-and-remember path keeps refusing the capture track.
    func testOrdinaryEnrollmentStillRefusesTheMicrophoneTrack() async throws {
        let service = makeService()
        let meeting = try await evaluatedMeeting(service, ownerVoice: 0)

        let outcome = try await service.enrollCandidate(
            displayName: "Liam", speakerId: "microphone", transcriptionId: meeting.id,
            fingerprint: fingerprint, allowMergeIntoExistingName: false
        )

        XCTAssertEqual(outcome, .candidateUnavailable)
        XCTAssertNil(owner.id)
        XCTAssertTrue(try profiles.profiles().isEmpty)
    }

    func testOwnerEnrollmentWithoutASampleRecordsNothing() async throws {
        let meeting = try savedTranscription()

        let outcome = try await makeService().enrollOwnerVoice(
            displayName: "Liam", transcriptionId: meeting.id, fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )

        XCTAssertEqual(outcome, .candidateUnavailable)
        XCTAssertNil(owner.id)
    }

    func testLaterMeetingsRecordWhetherTheOwnerWasRecognised() async throws {
        let service = makeService()
        let profile = try await enrolledOwner(service, voice: 0)

        _ = try await evaluatedMeeting(service, ownerVoice: 0, degrees: 12)
        let recognised = try XCTUnwrap(try profiles.profile(id: profile.id))
        XCTAssertNotNil(recognised.lastMatchedAt)
        XCTAssertEqual(try XCTUnwrap(recognised.lastEvaluatedDistance), 1 - cos(12 * Double.pi / 180), accuracy: 1e-4)

        _ = try await evaluatedMeeting(service, ownerVoice: 3)
        let missed = try XCTUnwrap(try profiles.profile(id: profile.id))
        XCTAssertEqual(try XCTUnwrap(missed.lastEvaluatedDistance), 1, accuracy: 1e-4)
        XCTAssertEqual(missed.lastMatchedAt, recognised.lastMatchedAt)
    }

    func testTheOwnersVoiceIsNotSuggestedForOtherSpeakers() async throws {
        let service = makeService()
        _ = try await enrolledOwner(service, voice: 0)

        let meeting = try savedTranscription()
        let suggestions = try await service.evaluate(
            transcriptionId: meeting.id, fingerprint: fingerprint,
            clusters: [observation("system:S1", voice: 0, degrees: 5)]
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testForgettingTheOwnersVoiceClearsThePointer() async throws {
        let service = makeService()
        let profile = try await enrolledOwner(service, voice: 0)

        try await service.forgetVoice(profileId: profile.id)
        XCTAssertNil(owner.id)

        _ = try await enrolledOwner(service, voice: 0)
        XCTAssertNotNil(owner.id)
        try await service.forgetAllVoices()
        XCTAssertNil(owner.id)
    }

    func testDisabledServiceHasNoOwnerVoiceAndRefusesEnrollment() async throws {
        let service = makeService()
        let meeting = try await evaluatedMeeting(service, ownerVoice: 0)
        enabled = false
        let disabled = makeService()

        let ownerVoice = try await disabled.ownerVoice()
        XCTAssertNil(ownerVoice)
        do {
            _ = try await disabled.enrollOwnerVoice(
                displayName: "Liam", transcriptionId: meeting.id, fingerprint: fingerprint,
                allowMergeIntoExistingName: false
            )
            XCTFail("expected a disabled refusal")
        } catch SpeakerVoiceprintServiceError.disabled {
        }
    }

    // MARK: Fixtures

    private final class OwnerPointer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UUID?
        var id: UUID? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func makeService() -> SpeakerVoiceprintService {
        let enabled = enabled
        let owner = owner!
        return SpeakerVoiceprintService(
            profiles: profiles, candidates: candidates, journal: journal,
            policy: .v1, identity: identity,
            isEnabled: { enabled },
            ownerProfileID: { owner.id },
            setOwnerProfileID: { owner.id = $0 }
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

    private func observation(
        _ speakerId: String, voice: Int, degrees: Double = 0, domain: SpeakerCaptureDomain = .system
    ) -> SpeakerClusterObservation {
        SpeakerClusterObservation(
            speakerId: speakerId, embedding: embedding(voice: voice, degrees: degrees),
            speechSeconds: 60, captureDomain: domain
        )
    }

    private func savedTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try transcriptions.save(transcription)
        return transcription
    }

    private func evaluatedMeeting(
        _ service: SpeakerVoiceprintService, ownerVoice voice: Int, degrees: Double = 0
    ) async throws -> Transcription {
        let meeting = try savedTranscription()
        _ = try await service.evaluate(
            transcriptionId: meeting.id, fingerprint: fingerprint,
            clusters: [observation("microphone", voice: voice, degrees: degrees, domain: .microphone)]
        )
        return meeting
    }

    private func enrolledOwner(_ service: SpeakerVoiceprintService, voice: Int) async throws -> SpeakerProfile {
        let meeting = try await evaluatedMeeting(service, ownerVoice: voice)
        let outcome = try await service.enrollOwnerVoice(
            displayName: "Liam", transcriptionId: meeting.id, fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )
        switch outcome {
        case .created(let profile), .addedExemplar(let profile): return profile
        default: preconditionFailure("fixture owner enrollment failed: \(outcome)")
        }
    }
}
