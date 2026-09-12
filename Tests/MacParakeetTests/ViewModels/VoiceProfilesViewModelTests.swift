import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// Answers administration calls from memory and records what was asked, so the
/// sheet's behaviour can be pinned without a database.
private final class StubAdminService: SpeakerVoiceprintServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedVoices: [EnrolledVoice]
    private var storedSamples: [UUID: [SpeakerProfileExemplar]]
    private let renameError: Error?
    private let refusesLastSample: Bool
    private let forgetFailsFor: Set<UUID>

    private var storedForgotten: [UUID] = []
    private var storedSampleReads: [UUID] = []
    private var forgotAll = false

    var forgotten: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return storedForgotten
    }
    var sampleReads: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return storedSampleReads
    }
    var didForgetAll: Bool {
        lock.lock(); defer { lock.unlock() }
        return forgotAll
    }

    init(
        voices: [EnrolledVoice],
        samples: [UUID: [SpeakerProfileExemplar]] = [:],
        renameError: Error? = nil,
        refusesLastSample: Bool = false,
        forgetFailsFor: Set<UUID> = []
    ) {
        self.storedVoices = voices
        self.storedSamples = samples
        self.renameError = renameError
        self.refusesLastSample = refusesLastSample
        self.forgetFailsFor = forgetFailsFor
    }

    func enrolledVoices() async throws -> [EnrolledVoice] {
        lock.lock(); defer { lock.unlock() }
        return storedVoices
    }

    func samples(profileId: UUID) async throws -> [SpeakerProfileExemplar] {
        lock.lock()
        storedSampleReads.append(profileId)
        let result = storedSamples[profileId] ?? []
        lock.unlock()
        return result
    }

    func renameProfile(id: UUID, to displayName: String) async throws {
        if let renameError { throw renameError }
        lock.lock()
        storedVoices = storedVoices.map { voice in
            guard voice.id == id else { return voice }
            var profile = voice.profile
            profile.displayName = displayName
            return EnrolledVoice(
                profile: profile,
                sampleCount: voice.sampleCount,
                maxSamples: voice.maxSamples,
                recognizedCount: voice.recognizedCount,
                usesRetiredModel: voice.usesRetiredModel,
                lastEvaluatedDistance: voice.lastEvaluatedDistance,
                acceptanceThreshold: voice.acceptanceThreshold
            )
        }
        lock.unlock()
    }

    func deleteSample(id: UUID, profileId: UUID) async throws -> Bool {
        if refusesLastSample { return false }
        lock.lock()
        storedSamples[profileId]?.removeAll { $0.id == id }
        lock.unlock()
        return true
    }

    struct ForgetFailed: Error {}

    func forgetVoice(profileId: UUID) async throws {
        if forgetFailsFor.contains(profileId) { throw ForgetFailed() }
        lock.lock()
        storedForgotten.append(profileId)
        storedVoices.removeAll { $0.id == profileId }
        lock.unlock()
    }

    func forgetAllVoices() async throws {
        lock.lock()
        forgotAll = true
        storedVoices = []
        storedSamples = [:]
        lock.unlock()
    }

    // Unused here.
    func evaluate(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint,
        clusters _: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion] { [] }
    func pendingSuggestions(
        transcriptionId _: UUID, fingerprint _: TranscriptFingerprint
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
}

@MainActor
final class VoiceProfilesViewModelTests: XCTestCase {
    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    // MARK: Listing

    func testLoadingPublishesTheStoredVoices() async {
        let service = StubAdminService(voices: [voice(named: "Sarah")])
        let viewModel = VoiceProfilesViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.voices.map(\.profile.displayName), ["Sarah"])
        XCTAssertFalse(viewModel.isEmpty)
    }

    /// A silent empty state would be a product bug, so the sheet has to be able
    /// to tell one apart from a list that has not loaded.
    func testAnEmptyStoreReportsEmptyOnlyAfterLoading() async {
        let viewModel = VoiceProfilesViewModel(service: StubAdminService(voices: []))

        await viewModel.load()

        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertTrue(viewModel.voices.isEmpty)
    }

    /// Built without a service when the feature is unavailable. It must show an
    /// empty sheet rather than crash or hang.
    func testWithoutAServiceItLoadsNothingAndDoesNotFail() async {
        let viewModel = VoiceProfilesViewModel(service: nil)

        await viewModel.load()

        XCTAssertTrue(viewModel.voices.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: Samples

    func testSamplesAreReadOnlyWhenARowIsExpanded() async {
        let sarah = voice(named: "Sarah")
        let service = StubAdminService(
            voices: [sarah], samples: [sarah.id: [sample(profileId: sarah.id)]]
        )
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()
        XCTAssertTrue(service.sampleReads.isEmpty)

        await viewModel.toggleExpansion(sarah.id)

        XCTAssertEqual(service.sampleReads, [sarah.id])
        XCTAssertEqual(viewModel.samplesByProfile[sarah.id]?.count, 1)

        // Collapsing keeps what was read; re-expanding does not read again.
        await viewModel.toggleExpansion(sarah.id)
        await viewModel.toggleExpansion(sarah.id)
        XCTAssertEqual(service.sampleReads, [sarah.id])
    }

    func testTheStoreRefusingTheLastSampleIsReportedAsFalse() async {
        let sarah = voice(named: "Sarah")
        let only = sample(profileId: sarah.id)
        let service = StubAdminService(
            voices: [sarah], samples: [sarah.id: [only]], refusesLastSample: true
        )
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()

        let deleted = await viewModel.deleteSample(id: only.id, profileId: sarah.id)

        XCTAssertFalse(deleted)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: Renaming

    func testRenamingTrimsAndReloads() async {
        let sarah = voice(named: "Sarah")
        let service = StubAdminService(voices: [sarah])
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()

        await viewModel.rename(sarah.id, to: "  Sarah Chen  ")

        XCTAssertEqual(viewModel.voices.map(\.profile.displayName), ["Sarah Chen"])
    }

    /// The rename sheet dismisses itself before this runs, so a silent refusal
    /// would read as the rename having worked.
    func testRenamingToABlankNameSaysWhyItWasRefused() async {
        let sarah = voice(named: "Sarah")
        let viewModel = VoiceProfilesViewModel(service: StubAdminService(voices: [sarah]))
        await viewModel.load()

        await viewModel.rename(sarah.id, to: "   ")

        XCTAssertEqual(viewModel.voices.map(\.profile.displayName), ["Sarah"])
        XCTAssertEqual(viewModel.errorMessage, "A voice needs a name.")
    }

    func testASuccessfulLoadClearsAStaleError() async {
        let service = StubAdminService(voices: [voice(named: "Sarah")])
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.rename(UUID(), to: "  ")
        XCTAssertNotNil(viewModel.errorMessage)

        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
    }

    /// One failure must not abandon the rest: on a deletion path for biometric
    /// samples, a silent early abort leaves voices the user asked to delete.
    func testBulkDeletionContinuesPastAFailure() async {
        let sarah = voice(named: "Sarah")
        let nadia = voice(named: "Nadia")
        let service = StubAdminService(voices: [sarah, nadia], forgetFailsFor: [sarah.id])
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()
        viewModel.selectedProfileIDs = [sarah.id, nadia.id]

        await viewModel.forgetSelected()

        XCTAssertEqual(service.forgotten, [nadia.id])
        XCTAssertEqual(viewModel.voices.map(\.profile.displayName), ["Sarah"])
        XCTAssertEqual(viewModel.errorMessage, "Could not forget 1 voice. The rest were removed.")
    }

    func testATakenNameIsReportedInPlainLanguage() async {
        let sarah = voice(named: "Sarah")
        let service = StubAdminService(
            voices: [sarah],
            renameError: SpeakerProfileStoreError.nameAlreadyTaken(normalizedName: "nadia")
        )
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()

        await viewModel.rename(sarah.id, to: "Nadia")

        XCTAssertEqual(viewModel.errorMessage, "Another voice is already named Nadia.")
    }

    // MARK: Deleting

    func testForgettingSelectedVoicesClearsTheSelection() async {
        let sarah = voice(named: "Sarah")
        let nadia = voice(named: "Nadia")
        let service = StubAdminService(voices: [sarah, nadia])
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()
        viewModel.selectedProfileIDs = [sarah.id, nadia.id]

        await viewModel.forgetSelected()

        XCTAssertEqual(Set(service.forgotten), [sarah.id, nadia.id])
        XCTAssertTrue(viewModel.selectedProfileIDs.isEmpty)
        XCTAssertTrue(viewModel.voices.isEmpty)
    }

    /// Selection and expansion are keyed by id, so a voice deleted elsewhere
    /// must not leave a stale id selected — the next bulk delete would act on
    /// something that no longer exists.
    func testLoadingDropsSelectionForVoicesThatAreGone() async {
        let sarah = voice(named: "Sarah")
        let service = StubAdminService(voices: [sarah])
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()
        viewModel.selectedProfileIDs = [sarah.id]
        viewModel.expandedProfileIDs = [sarah.id]

        try? await service.forgetVoice(profileId: sarah.id)
        await viewModel.load()

        XCTAssertTrue(viewModel.selectedProfileIDs.isEmpty)
        XCTAssertTrue(viewModel.expandedProfileIDs.isEmpty)
        XCTAssertNil(viewModel.samplesByProfile[sarah.id])
    }

    func testForgettingEverythingEmptiesTheList() async {
        let service = StubAdminService(voices: [voice(named: "Sarah"), voice(named: "Nadia")])
        let viewModel = VoiceProfilesViewModel(service: service)
        await viewModel.load()

        await viewModel.forgetAll()

        XCTAssertTrue(service.didForgetAll)
        XCTAssertTrue(viewModel.voices.isEmpty)
    }

    // MARK: Status wording

    func testAVoiceThatNeverMatchedShowsItsDistanceAgainstTheThreshold() {
        let viewModel = VoiceProfilesViewModel(service: nil)
        let never = voice(named: "Sarah", lastEvaluatedDistance: 0.34)

        let detail = viewModel.statusDetail(for: never)

        XCTAssertTrue(detail.contains("Never recognized"), detail)
        XCTAssertTrue(detail.contains("0.34"), detail)
        XCTAssertTrue(detail.contains("0.25"), detail)
    }

    func testARetiredModelExplainsWhatToDo() {
        let viewModel = VoiceProfilesViewModel(service: nil)
        let retired = voice(named: "Sarah", usesRetiredModel: true)

        let detail = viewModel.statusDetail(for: retired)

        XCTAssertTrue(detail.contains("older voice model"), detail)
        XCTAssertTrue(detail.contains("name this speaker again"), detail)
    }

    func testAVoiceNeverComparedSaysSoRatherThanShowingANumber() {
        let viewModel = VoiceProfilesViewModel(service: nil)

        let detail = viewModel.statusDetail(for: voice(named: "Sarah"))

        XCTAssertEqual(detail, "Never compared against a recording yet.")
    }

    // MARK: Helpers

    private func voice(
        named name: String,
        usesRetiredModel: Bool = false,
        lastEvaluatedDistance: Double? = nil,
        lastMatchedAt: Date? = nil
    ) -> EnrolledVoice {
        EnrolledVoice(
            profile: SpeakerProfile(
                displayName: name, identity: identity, lastMatchedAt: lastMatchedAt
            ),
            sampleCount: 2,
            maxSamples: 10,
            recognizedCount: 1,
            usesRetiredModel: usesRetiredModel,
            lastEvaluatedDistance: lastEvaluatedDistance,
            acceptanceThreshold: 0.25
        )
    }

    private func sample(profileId: UUID) -> SpeakerProfileExemplar {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return SpeakerProfileExemplar(
            profileId: profileId,
            embedding: embedding,
            speechSeconds: 30,
            captureDomain: .system,
            origin: .manualEnrollment
        )
    }
}
