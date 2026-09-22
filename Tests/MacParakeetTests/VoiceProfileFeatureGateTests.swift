import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// A store that answers every administration call, so the gate can be checked
/// against the shape production actually has: the service is wired even when the
/// flag is off. It holds whatever the case needs — nothing for a release user
/// who never enrolled anyone, a voice for a build that enrolled under the flag
/// and then launched without it.
private final class FakeVoiceStore: SpeakerVoiceprintServicing, @unchecked Sendable {
    private let storedVoices: [EnrolledVoice]

    init(voices: [EnrolledVoice] = []) {
        self.storedVoices = voices
    }

    func evaluate(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint,
        clusters _: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion] { [] }
    func enrollmentCandidate(
        transcriptionId _: UUID, speakerId _: String, fingerprint _: TranscriptFingerprint
    ) async throws -> SpeakerClusterObservation? { nil }
    func pruneExpiredCandidates() async throws {}
    func enroll(
        displayName _: String, observation _: SpeakerClusterObservation,
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint,
        allowMergeIntoExistingName _: Bool
    ) async throws -> SpeakerProfileEnrollment { .rejectedEmptyName }
    func confirm(
        _: SpeakerVoiceprintSuggestion, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {}
    func dismiss(
        _: SpeakerVoiceprintSuggestion, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {}
    func assign(
        profileId _: UUID, toSpeakerId _: String, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws -> SpeakerManualAssignment { .unknownProfile }
    func pendingSuggestions(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint
    ) async throws -> [SpeakerVoiceprintSuggestion] { [] }
    func confirmedVoiceHolders(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint
    ) async throws -> [UUID: String] { [:] }
    func recognitionVoices() async throws -> [EnrolledVoice] { [] }
    func validateAssignment(
        profileId _: UUID, toSpeakerId _: String, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws -> SpeakerManualAssignment { .unknownProfile }
    func enrollCandidate(
        displayName _: String, speakerId _: String, transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint, allowMergeIntoExistingName _: Bool
    ) async throws -> SpeakerProfileEnrollment { .candidateUnavailable }

    func enrolledVoices() async throws -> [EnrolledVoice] { storedVoices }
    func samples(profileId _: UUID) async throws -> [SpeakerProfileExemplar] { [] }
    func renameProfile(id _: UUID, to _: String) async throws {}
    func deleteSample(id _: UUID, profileId _: UUID) async throws -> Bool { false }
    func forgetVoice(profileId _: UUID) async throws {}
    func forgetAllVoices() async throws {}
}

final class VoiceProfileFeatureGateTests: XCTestCase {
    /// Both halves of the settings gate are false for a release user who never
    /// enrolled anyone, so no profile administration is offered at all. The
    /// "Forget stored voices" row in Reset & Cleanup is deliberately outside
    /// this gate and stays reachable whatever this answers.
    @MainActor
    func testNoManagementSurfaceWithoutTheFlagOrStoredVoices() async {
        let viewModel = VoiceProfilesViewModel(service: FakeVoiceStore())

        await viewModel.load()

        XCTAssertFalse(AppFeatures.isVoiceProfilesAvailable(arguments: []))
        XCTAssertFalse(viewModel.hasEnrolledVoices)
    }

    /// The other half of the same gate, and the half that carries the privacy
    /// argument: with the flag off and voices stored, administration is still
    /// offered. Gating this on the flag alone would strand biometric data with
    /// no way to remove it — the one outcome this feature must never produce.
    /// The "Forget…" row in Reset & Cleanup answers to neither half, and stays
    /// reachable regardless.
    @MainActor
    func testStoredVoicesKeepTheManagementSurfaceWithTheFlagOff() async {
        let identity = SpeakerModelIdentity(
            embeddingModelId: "test-model",
            aggregationProfileId: "test-aggregation"
        )
        let stored = EnrolledVoice(
            profile: SpeakerProfile(displayName: "Marie", identity: identity),
            sampleCount: 1,
            maxSamples: 10,
            recognizedCount: 0,
            usesRetiredModel: false,
            lastEvaluatedDistance: nil,
            acceptanceThreshold: 0.25
        )
        let viewModel = VoiceProfilesViewModel(service: FakeVoiceStore(voices: [stored]))

        await viewModel.load()

        XCTAssertFalse(AppFeatures.isVoiceProfilesAvailable(arguments: []))
        XCTAssertTrue(viewModel.hasEnrolledVoices)
    }

    func testVoiceProfilesAreNotReleased() {
        XCTAssertFalse(AppFeatures.voiceProfilesEnabled)
        XCTAssertFalse(AppFeatures.isVoiceProfilesAvailable(arguments: []))
        #if DEBUG
        XCTAssertTrue(AppFeatures.isVoiceProfilesAvailable(arguments: ["--enable-voice-profiles"]))
        #else
        XCTAssertFalse(AppFeatures.isVoiceProfilesAvailable(arguments: ["--enable-voice-profiles"]))
        #endif
    }

    func testSavedOptInAndConsentCannotBypassReleaseGate() {
        let suite = "VoiceProfileFeatureGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.rememberSpeakersKey)
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.meetingSpeakerDiarizationKey)
        defaults.set(Date(), forKey: UserDefaultsAppRuntimePreferences.voiceprintConsentAcknowledgedAtKey)
        XCTAssertFalse(
            UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
                defaults: defaults, arguments: []
            ))
        let withOverride = UserDefaultsAppRuntimePreferences.rememberSpeakersEnabled(
            defaults: defaults, arguments: ["--enable-voice-profiles"]
        )
        #if DEBUG
        XCTAssertTrue(withOverride)
        #else
        XCTAssertFalse(withOverride)
        #endif
    }
}
