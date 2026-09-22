import XCTest
import GRDB
@testable import MacParakeetCore

/// Covers the seam between the meeting pipeline and the voiceprint service:
/// which observations reach it, in which unit, and under which ids.
final class SpeakerVoiceprintWiringTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var profiles: SpeakerProfileRepository!
    private var candidates: SpeakerEmbeddingCandidateRepository!
    private var journal: SpeakerMatchJournalRepository!
    private var transcriptions: TranscriptionRepository!

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
    }

    // MARK: The unit the gates read

    /// Durations cross this seam in milliseconds and the gates are in seconds.
    /// A missed conversion turns the 3 s gate into 50 minutes, so nothing ever
    /// qualifies and the feature simply never fires — silently.
    func testMillisecondsBecomeSecondsAcrossTheSeam() async throws {
        let recording = try savedTranscription()
        let profile = try await enrol(name: "Sarah", voice: 0, transcriptionId: recording.id)
        let next = try savedTranscription()

        // 4 000 ms is well past the 3 s match gate; 4 s read as 4 000 s would
        // be too, so the telling case is the one just under the gate.
        let belowGate = try await service().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [observation(id: "system:S1", voice: 0, speechMs: 2_500)]
        )
        XCTAssertTrue(belowGate.isEmpty)

        let aboveGate = try await service().evaluate(
            transcriptionId: next.id,
            fingerprint: TranscriptFingerprint(rawValue: "fingerprint-2"),
            clusters: [observation(id: "system:S1", voice: 0, speechMs: 30_000)]
        )
        XCTAssertEqual(aboveGate.map(\.profileId), [profile.id])
    }

    // MARK: The ids the seam carries

    /// The meeting path prefixes diarizer ids with their audio source, and the
    /// suggestion has to name the speaker the transcript knows — otherwise the
    /// UI would look up a speaker that does not exist.
    func testSuggestionsCarryTheSourcePrefixedSpeakerId() async throws {
        let recording = try savedTranscription()
        _ = try await enrol(name: "Sarah", voice: 0, transcriptionId: recording.id)
        let next = try savedTranscription()

        let suggestions = try await service().evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [observation(id: "system:S2", voice: 0, speechMs: 30_000)]
        )

        XCTAssertEqual(suggestions.map(\.speakerId), ["system:S2"])
        XCTAssertEqual(
            try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue)
                .map(\.speakerId),
            ["system:S2"]
        )
    }

    // MARK: Which speakers are scored

    /// The finalizer drops any cluster whose segments won no words, and only
    /// the surviving list is persisted. Scoring the diarizer's full output
    /// would write a suggestion keyed to a speaker the transcript does not
    /// have — one the UI could never resolve.
    func testOnlyPersistedSpeakersAreScored() {
        let diarization = MeetingTranscriptFinalizer.SystemDiarization(
            speakers: [
                SpeakerInfo(id: "system:S1", label: "Others 1"),
                SpeakerInfo(id: "system:S2", label: "Others 2"),
            ],
            segments: [],
            speakerEmbeddings: [
                "system:S1": embedding(voice: 0),
                "system:S2": embedding(voice: 1),
            ],
            speechMsBySpeaker: ["system:S1": 30_000, "system:S2": 30_000]
        )

        let observations = TranscriptionService.voiceprintObservations(
            systemDiarization: diarization,
            // S2 won no words, so the finalizer left it out of the transcript.
            persistedSpeakers: [SpeakerInfo(id: "system:S1", label: "Others 1")]
        )

        XCTAssertEqual(observations.map(\.speakerId), ["system:S1"])
    }

    func testASpeakerWithoutAnEmbeddingIsSkipped() {
        let diarization = MeetingTranscriptFinalizer.SystemDiarization(
            speakers: [SpeakerInfo(id: "system:S1", label: "Others 1")],
            segments: [],
            speakerEmbeddings: [:],
            speechMsBySpeaker: ["system:S1": 30_000]
        )

        XCTAssertTrue(
            TranscriptionService.voiceprintObservations(
                systemDiarization: diarization,
                persistedSpeakers: [SpeakerInfo(id: "system:S1", label: "Others 1")]
            ).isEmpty
        )
    }

    func testObservationsConvertDurationsToSeconds() throws {
        let diarization = MeetingTranscriptFinalizer.SystemDiarization(
            speakers: [SpeakerInfo(id: "system:S1", label: "Others 1")],
            segments: [],
            speakerEmbeddings: ["system:S1": embedding(voice: 0)],
            speechMsBySpeaker: ["system:S1": 12_500]
        )

        let observation = try XCTUnwrap(
            TranscriptionService.voiceprintObservations(
                systemDiarization: diarization,
                persistedSpeakers: [SpeakerInfo(id: "system:S1", label: "Others 1")]
            ).first
        )
        XCTAssertEqual(observation.speechSeconds, 12.5, accuracy: 1e-9)
        XCTAssertEqual(observation.captureDomain, .system)
    }

    // MARK: The gate

    func testNothingIsWrittenWhileTheFeatureIsOff() async throws {
        let recording = try savedTranscription()
        _ = try await enrol(name: "Sarah", voice: 0, transcriptionId: recording.id)
        let next = try savedTranscription()

        let off = SpeakerVoiceprintService(
            profiles: profiles,
            candidates: candidates,
            journal: journal,
            isEnabled: { false }
        )
        let suggestions = try await off.evaluate(
            transcriptionId: next.id,
            fingerprint: fingerprint,
            clusters: [observation(id: "system:S1", voice: 0, speechMs: 30_000)]
        )

        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(
            try profiles.links(transcriptionId: next.id, fingerprint: fingerprint.rawValue).isEmpty
        )
        XCTAssertTrue(
            try journal.entries(
                retention: SpeakerMatchJournalRepository.defaultRetention, now: Date()
            ).isEmpty
        )
    }

    /// `rememberSpeakers` is meaningless without clusters to match, so it reads
    /// as off whenever meeting speaker detection is.
    func testThePreferenceRequiresMeetingSpeakerDetection() {
        let defaults = UserDefaults(suiteName: "voiceprint-wiring-\(UUID().uuidString)")!
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.rememberSpeakersKey)
        defaults.set(
            Date(), forKey: UserDefaultsAppRuntimePreferences.voiceprintConsentAcknowledgedAtKey
        )

        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.meetingSpeakerDiarizationKey)
        XCTAssertFalse(
            UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
                defaults: defaults, arguments: [AppFeatures.voiceProfilesDeveloperLaunchArgument]
            ))

        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.meetingSpeakerDiarizationKey)
        let enabledWithOverride = UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
            defaults: defaults, arguments: [AppFeatures.voiceProfilesDeveloperLaunchArgument]
        )
        #if DEBUG
        XCTAssertTrue(enabledWithOverride)
        #else
        XCTAssertFalse(enabledWithOverride)
        #endif
    }

    func testThePreferenceIsOffUntilAsked() {
        let defaults = UserDefaults(suiteName: "voiceprint-wiring-\(UUID().uuidString)")!
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.meetingSpeakerDiarizationKey)
        XCTAssertFalse(
            UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
                defaults: defaults, arguments: [AppFeatures.voiceProfilesDeveloperLaunchArgument]
            ))
    }

    // MARK: Helpers

    private func service() -> SpeakerVoiceprintService {
        SpeakerVoiceprintService(
            profiles: profiles,
            candidates: candidates,
            journal: journal,
            isEnabled: { true }
        )
    }

    private func embedding(voice: Int) -> SpeakerEmbedding {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[voice] = 1
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    /// Mirrors what `TranscriptionService` builds from a `SystemDiarization`,
    /// including the millisecond-to-second conversion.
    private func observation(id: String, voice: Int, speechMs: Int) -> SpeakerClusterObservation {
        SpeakerClusterObservation(
            speakerId: id,
            embedding: embedding(voice: voice),
            speechSeconds: Double(speechMs) / 1000,
            captureDomain: .system
        )
    }

    private func savedTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try transcriptions.save(transcription)
        return transcription
    }

    private func enrol(name: String, voice: Int, transcriptionId: UUID) async throws -> SpeakerProfile {
        let result = try await service().enroll(
            displayName: name,
            observation: observation(id: "system:S1", voice: voice, speechMs: 30_000),
            transcriptionId: transcriptionId,
            fingerprint: fingerprint,
            allowMergeIntoExistingName: false
        )
        guard case .created(let profile) = result else {
            preconditionFailure("fixture enrollment must create a profile, got \(result)")
        }
        return profile
    }
}
