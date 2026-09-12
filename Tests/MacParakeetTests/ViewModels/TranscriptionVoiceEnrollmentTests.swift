import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// Records what the view model asks of the voiceprint service and returns
/// scripted answers, so the offer's conditions can be exercised without a
/// database or a diarizer.
private final class StubVoiceprintService: SpeakerVoiceprintServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let candidate: SpeakerClusterObservation?
    private let enrollment: SpeakerProfileEnrollment
    private let enrollError: Error?

    private var storedCandidateRequests: [(UUID, String, String)] = []
    private var storedEnrollments: [(String, Bool)] = []

    var candidateRequests: [(UUID, String, String)] {
        lock.lock(); defer { lock.unlock() }
        return storedCandidateRequests
    }
    var enrollments: [(String, Bool)] {
        lock.lock(); defer { lock.unlock() }
        return storedEnrollments
    }

    /// `mergeEnrollment` mirrors the real service: an accepted merge skips the
    /// pollution guard, so it cannot answer with the same conflict twice.
    private let mergeEnrollment: SpeakerProfileEnrollment?
    private let suggestions: [SpeakerVoiceprintSuggestion]
    private let heldForTranscription: UUID?
    /// Suspends instead of blocking: `DispatchSemaphore.wait` would occupy a
    /// cooperative executor thread, and the attribution work this test waits
    /// for runs on that same pool.
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    private var storedConfirmed: [String] = []
    private var storedDismissed: [String] = []

    var confirmed: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedConfirmed
    }
    var dismissed: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedDismissed
    }

    init(
        candidate: SpeakerClusterObservation?,
        enrollment: SpeakerProfileEnrollment = .rejectedEmptyName,
        mergeEnrollment: SpeakerProfileEnrollment? = nil,
        enrollError: Error? = nil,
        suggestions: [SpeakerVoiceprintSuggestion] = [],
        heldForTranscription: UUID? = nil
    ) {
        self.candidate = candidate
        self.enrollment = enrollment
        self.mergeEnrollment = mergeEnrollment
        self.enrollError = enrollError
        self.suggestions = suggestions
        self.heldForTranscription = heldForTranscription
    }

    func evaluate(
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint,
        clusters _: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion] { [] }

    func enrollmentCandidate(
        transcriptionId: UUID,
        speakerId: String,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerClusterObservation? {
        lock.lock()
        storedCandidateRequests.append((transcriptionId, speakerId, fingerprint.rawValue))
        lock.unlock()
        return candidate
    }

    func pruneExpiredCandidates() async throws {}

    func enroll(
        displayName: String,
        observation _: SpeakerClusterObservation,
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment {
        lock.lock()
        storedEnrollments.append((displayName, allowMergeIntoExistingName))
        lock.unlock()
        if let enrollError { throw enrollError }
        if allowMergeIntoExistingName, let mergeEnrollment { return mergeEnrollment }
        return enrollment
    }

    func confirm(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {
        lock.lock()
        storedConfirmed.append(suggestion.speakerId)
        lock.unlock()
    }

    /// `heldForTranscription` parks the answer for one recording so a later
    /// selection can land first, which is the only way to exercise the
    /// in-flight guard deterministically.
    func pendingSuggestions(
        transcriptionId: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws -> [SpeakerVoiceprintSuggestion] {
        lock.lock()
        let held = heldForTranscription == transcriptionId
        lock.unlock()
        if held {
            await waitForRelease()
            return suggestions
        }
        return heldForTranscription == nil ? suggestions : []
    }

    /// Records the release when it arrives first, so either ordering is safe.
    func releaseHeldSuggestions() {
        lock.lock()
        let waiting = releaseContinuation
        releaseContinuation = nil
        released = true
        lock.unlock()
        waiting?.resume()
    }

    private func waitForRelease() async {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            releaseContinuation = continuation
            lock.unlock()
        }
    }

    // Administration is exercised in its own suite; these are unused here.
    func enrolledVoices() async throws -> [EnrolledVoice] { [] }
    func samples(profileId _: UUID) async throws -> [SpeakerProfileExemplar] { [] }
    func renameProfile(id _: UUID, to _: String) async throws {}
    func deleteSample(id _: UUID, profileId _: UUID) async throws -> Bool { false }
    func forgetVoice(profileId _: UUID) async throws {}
    func forgetAllVoices() async throws {}

    func dismiss(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId _: UUID,
        fingerprint _: TranscriptFingerprint
    ) async throws {
        lock.lock()
        storedDismissed.append(suggestion.speakerId)
        lock.unlock()
    }
}

/// Resolves each snapshot it is handed rather than replaying a fixed one, so a
/// re-diarized transcription yields a different fingerprint — which is what the
/// staleness guards are about.
private final class StubAttributionReader: SpeakerAttributionReading, @unchecked Sendable {
    private let fallback: Transcription

    init(fallback: Transcription) {
        self.fallback = fallback
    }

    func resolve(transcriptionId _: UUID) throws -> SpeakerAttributionProjection? {
        try resolve(transcription: fallback)
    }

    func resolve(transcription: Transcription) throws -> SpeakerAttributionProjection {
        SpeakerAttributionProjection(
            automaticTranscription: transcription,
            attribution: SpeakerAttributionResolver.resolve(transcription: transcription),
            correctionsApplied: false
        )
    }
}

/// Applies renames to the snapshot it was built from, so a confirmed
/// suggestion actually changes the published label — a stub that replayed a
/// fixed attribution would let a broken rename path look correct.
private final class StubCorrectionService: SpeakerCorrectionServicing, @unchecked Sendable {
    struct Rejected: Error {}

    let result: SpeakerCorrectionResult
    let failsApply: Bool
    private let base: Transcription?

    init(result: SpeakerCorrectionResult, failsApply: Bool = false, base: Transcription? = nil) {
        self.result = result
        self.failsApply = failsApply
        self.base = base
    }

    func apply(
        transcriptionId _: UUID,
        command: SpeakerCorrectionCommand,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult {
        if failsApply { throw Rejected() }
        guard case .rename(let speakerID, let label) = command, var renamed = base,
              var speakers = renamed.speakers,
              let index = speakers.firstIndex(where: { $0.id == speakerID })
        else { return result }
        speakers[index].label = label
        renamed.speakers = speakers
        return SpeakerCorrectionResult(
            attribution: SpeakerAttributionResolver.resolve(transcription: renamed),
            revision: result.revision + 1,
            canUndo: true,
            canRedo: false
        )
    }

    func undo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult { result }

    func redo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult { result }
}

@MainActor
final class TranscriptionVoiceEnrollmentTests: XCTestCase {
    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    // MARK: Suggestions

    /// `renameSpeaker` returns as soon as the write is scheduled, and that
    /// write can still be refused. Recording first would teach the profile
    /// from an answer the transcript never shows.
    func testARejectedRenameDoesNotRecordTheConfirmation() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(
            candidate: observation(), suggestions: [suggestion()]
        )
        let viewModel = try await configured(
            transcription, voiceprints: service, correctionFails: true
        )
        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }

        viewModel.confirmVoiceSuggestion(try XCTUnwrap(viewModel.voiceSuggestions.first))

        // The offer comes back, since the user's answer never took effect.
        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }
        XCTAssertTrue(service.confirmed.isEmpty)
    }

    func testPendingSuggestionsLoadWithTheTranscript() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(
            candidate: observation(), suggestions: [suggestion()]
        )
        let viewModel = try await configured(transcription, voiceprints: service)

        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }
        XCTAssertEqual(viewModel.voiceSuggestions.map(\.displayName), ["Sarah"])
    }

    /// Confirming applies the label through the correction layer, which is what
    /// carries undo and provenance — the voiceprint layer only records the
    /// answer.
    func testConfirmingASuggestionRenamesAndRecordsTheAnswer() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(
            candidate: observation(), suggestions: [suggestion()]
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }

        viewModel.confirmVoiceSuggestion(try XCTUnwrap(viewModel.voiceSuggestions.first))

        try await waitUntil { service.confirmed == ["S1"] }
        XCTAssertTrue(viewModel.voiceSuggestions.isEmpty)
        // The point of confirming is the label; recording the answer without
        // applying it would be the failure this ordering exists to prevent.
        try await waitUntil {
            viewModel.effectiveCurrentTranscription?.speakers?.first?.label == "Sarah"
        }
    }

    /// The legacy branch handles transcripts the correction layer cannot own.
    /// Returning without reporting would drop a suggestion the user accepted
    /// and never record it.
    func testConfirmingWorksOnTheLegacyRenamePath() async throws {
        var transcription = makeTranscription()
        // No word timestamps: the correction path is unavailable.
        transcription.wordTimestamps = nil
        let service = StubVoiceprintService(
            candidate: observation(), suggestions: [suggestion()]
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }

        viewModel.confirmVoiceSuggestion(try XCTUnwrap(viewModel.voiceSuggestions.first))

        try await waitUntil { service.confirmed == ["S1"] }
    }

    func testDismissingASuggestionRecordsTheRefusalAndAppliesNoLabel() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(
            candidate: observation(), suggestions: [suggestion()]
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }

        viewModel.dismissVoiceSuggestion(try XCTUnwrap(viewModel.voiceSuggestions.first))

        try await waitUntil { service.dismissed == ["S1"] }
        XCTAssertTrue(viewModel.voiceSuggestions.isEmpty)
        XCTAssertTrue(service.confirmed.isEmpty)
        // The speaker keeps the label the transcript had.
        XCTAssertEqual(viewModel.currentTranscription?.speakers?.first?.label, "Others 1")
    }

    /// Suggestions name positional speakers, so a re-diarization must clear
    /// them rather than let them point at whoever "S1" now is.
    func testRetranscribingClearsPendingSuggestions() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(
            candidate: observation(), suggestions: [suggestion()]
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }

        var rediarized = transcription
        rediarized.wordTimestamps = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S2")
        ]
        viewModel.currentTranscription = rediarized

        XCTAssertTrue(viewModel.voiceSuggestions.isEmpty)
    }

    /// Confirming a suggestion renames through the same path as a manual
    /// rename, so without suppression the app would immediately ask to
    /// remember the voice it just matched — and past the pollution guard it
    /// would claim another Sarah exists, contradicting the confirmation.
    func testConfirmingASuggestionDoesNotAlsoOfferEnrollment() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(
            candidate: observation(), suggestions: [suggestion()]
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        try await waitUntil { !viewModel.voiceSuggestions.isEmpty }

        viewModel.confirmVoiceSuggestion(try XCTUnwrap(viewModel.voiceSuggestions.first))

        try await waitUntil { service.confirmed == ["S1"] }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
        XCTAssertNil(viewModel.voiceEnrollmentConflict)
        XCTAssertTrue(service.candidateRequests.isEmpty)
    }

    /// Two recordings can hash alike — the fingerprint contains no
    /// transcription — so the id has to be checked too.
    func testSuggestionsAreNotRepublishedOntoAnotherTranscript() async throws {
        let transcription = makeTranscription()
        // The first recording's answer is parked, so the second selection lands
        // before it returns.
        let service = StubVoiceprintService(
            candidate: observation(),
            suggestions: [suggestion()],
            heldForTranscription: transcription.id
        )
        let viewModel = try await configured(transcription, voiceprints: service)

        // A different recording carrying the same words and segments, so the
        // fingerprint collides — it has no transcription in it. Built by
        // sharing the segments, since their ids feed the hash and fresh ones
        // would diverge.
        var twin = makeTranscription()
        twin.wordTimestamps = transcription.wordTimestamps
        twin.transcriptSegments = transcription.transcriptSegments
        twin.speakers = transcription.speakers
        twin.diarizationSegments = transcription.diarizationSegments
        XCTAssertNotEqual(twin.id, transcription.id)
        XCTAssertEqual(
            SpeakerAttributionResolver.resolve(transcription: twin).fingerprint,
            SpeakerAttributionResolver.resolve(transcription: transcription).fingerprint
        )
        viewModel.currentTranscription = twin
        try await waitUntil { viewModel.speakerAttribution != nil }

        service.releaseHeldSuggestions()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(
            viewModel.voiceSuggestions.isEmpty,
            "an in-flight load for the previous recording must not republish here"
        )
    }

    func testAFailedEnrollmentIsReportedAsAFailure() async throws {
        struct Boom: Error {}
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation(), enrollError: Boom())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.confirmVoiceEnrollment()

        try await waitUntil { viewModel.voiceEnrollmentMessage != nil }
        XCTAssertEqual(viewModel.voiceEnrollmentMessage?.kind, .failure)
    }

    // MARK: Offering

    /// A speaker is renamed once, so after a relaunch there is no second rename
    /// to trigger the offer — and the retained voice would expire unused.
    func testOpeningATranscriptReoffersEnrollmentForANamedSpeaker() async throws {
        var transcription = makeTranscription()
        transcription.speakers = [SpeakerInfo(id: "S1", label: "Sarah")]
        let service = StubVoiceprintService(candidate: observation())

        let viewModel = try await configured(transcription, voiceprints: service)

        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }
        XCTAssertEqual(viewModel.pendingVoiceEnrollment?.displayName, "Sarah")
        XCTAssertTrue(service.enrollments.isEmpty, "offering must store nothing")
    }

    /// A speaker still carrying its generated label was never named, so there
    /// is nothing to remember it as.
    func testOpeningATranscriptDoesNotReofferForUnnamedSpeakers() async throws {
        let transcription = makeTranscription()
        XCTAssertEqual(transcription.speakers?.first?.label, "Others 1")
        let service = StubVoiceprintService(candidate: observation())

        let viewModel = try await configured(transcription, voiceprints: service)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
        XCTAssertTrue(service.candidateRequests.isEmpty)
    }

    /// The commit callback can land after the user moved on. Reading the
    /// current transcript there would offer the *new* transcript's positional
    /// speaker under the name typed on the old one.
    func testAnOfferIsNotMadeAgainstATranscriptTheUserMovedTo() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)

        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        // Same words and segments, so the fingerprint matches too: only the
        // captured transcription id can tell these apart.
        var twin = makeTranscription()
        twin.wordTimestamps = transcription.wordTimestamps
        twin.transcriptSegments = transcription.transcriptSegments
        twin.speakers = transcription.speakers
        twin.diarizationSegments = transcription.diarizationSegments
        viewModel.currentTranscription = twin
        try await waitUntil { viewModel.speakerAttribution != nil }

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
        XCTAssertTrue(service.candidateRequests.isEmpty)
    }

    /// `renameSpeaker` returns as soon as the write is scheduled, and that
    /// write can still be refused. Offering then would let the user store a
    /// voice under a name the transcript never kept.
    func testARefusedRenameOffersNothing() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(
            transcription, voiceprints: service, correctionFails: true
        )

        viewModel.renameSpeaker(id: "S1", to: "Sarah")

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
        XCTAssertTrue(service.candidateRequests.isEmpty)
    }

    func testRenamingASpeakerOffersToRememberTheVoice() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)

        XCTAssertTrue(viewModel.renameSpeaker(id: "S1", to: "  Sarah  "))

        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }
        let offer = try XCTUnwrap(viewModel.pendingVoiceEnrollment)
        // The trimmed label, since that is what the profile will be named.
        XCTAssertEqual(offer.displayName, "Sarah")
        XCTAssertEqual(offer.speakerId, "S1")
        XCTAssertEqual(service.candidateRequests.count, 1)
        XCTAssertEqual(service.candidateRequests.first?.1, "S1")
        // Nothing is stored by merely offering.
        XCTAssertTrue(service.enrollments.isEmpty)
    }

    /// The offer must not promise what enrollment would refuse: with no
    /// candidate left — window lapsed, feature off at capture, or too little
    /// speech — the rename stays silent.
    func testNoOfferWhenNoCandidateRemains() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: nil)
        let viewModel = try await configured(transcription, voiceprints: service)

        viewModel.renameSpeaker(id: "S1", to: "Sarah")

        try await waitUntil { service.candidateRequests.count == 1 }
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    func testNoOfferWhenTheServiceIsAbsent() async throws {
        let transcription = makeTranscription()
        let viewModel = try await configured(transcription, voiceprints: nil)

        viewModel.renameSpeaker(id: "S1", to: "Sarah")

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    /// The lookup is async, so the user can have moved on by the time it
    /// returns. Offering then would attach a prompt to the wrong transcript.
    func testAnOfferIsDroppedIfTheTranscriptChanged() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)

        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        viewModel.currentTranscription = makeTranscription()

        // The offer now waits for the label to commit, so moving away first
        // means it is never published rather than published and discarded —
        // either way, no prompt lands on the wrong transcript.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    /// Selecting another transcript must take the offer with it, or the user
    /// would be asked to keep a voice while looking at a different meeting.
    func testSelectingAnotherTranscriptDropsAStandingOffer() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.currentTranscription = makeTranscription()

        XCTAssertNil(viewModel.pendingVoiceEnrollment)
        XCTAssertNil(viewModel.voiceEnrollmentConflict)
        XCTAssertNil(viewModel.voiceEnrollmentMessage)
    }

    /// Re-transcribing reloads the *same row*, so the id never changes while
    /// the speakers do. An offer that survived would enroll a vector from a
    /// diarization that no longer exists, under a positional speaker id that
    /// can now mean someone else.
    func testRetranscribingTheSameRowDropsAStandingOffer() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        var rediarized = transcription
        rediarized.wordTimestamps = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S2"),
            WordTimestamp(word: "there", startMs: 450, endMs: 800, confidence: 0.9, speakerId: "S1"),
        ]
        viewModel.currentTranscription = rediarized

        XCTAssertEqual(viewModel.currentTranscription?.id, transcription.id)
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    /// The offer is a public value, so the guard is re-checked at confirmation
    /// rather than trusted from the banner's state.
    func testConfirmingAnOfferFromAnotherDiarizationEnrollsNothing() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }
        let stale = try XCTUnwrap(viewModel.pendingVoiceEnrollment)

        // Put the offer back after the diarization moved underneath it.
        var rediarized = transcription
        rediarized.wordTimestamps = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S2")
        ]
        viewModel.currentTranscription = rediarized
        try await waitUntil { viewModel.speakerAttribution != nil }
        viewModel.pendingVoiceEnrollment = stale

        viewModel.confirmVoiceEnrollment()

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(service.enrollments.isEmpty)
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    // MARK: Answering

    func testAcceptingEnrollsAndReportsSuccess() async throws {
        let transcription = makeTranscription()
        let profile = SpeakerProfile(displayName: "Sarah", identity: identity)
        let service = StubVoiceprintService(
            candidate: observation(), enrollment: .created(profile)
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.confirmVoiceEnrollment()

        try await waitUntil { viewModel.voiceEnrollmentMessage != nil }
        XCTAssertEqual(service.enrollments.map(\.0), ["Sarah"])
        XCTAssertEqual(service.enrollments.first?.1, false)
        XCTAssertNil(viewModel.pendingVoiceEnrollment)
    }

    func testDismissingStoresNothing() async throws {
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.dismissVoiceEnrollment()

        XCTAssertNil(viewModel.pendingVoiceEnrollment)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(service.enrollments.isEmpty)
    }

    /// Two colleagues called Sarah is the likely cause, not a mistake, so the
    /// conflict is a question rather than an error — and merging happens only
    /// on a second, explicit answer.
    func testANameConflictAsksBeforeMerging() async throws {
        let transcription = makeTranscription()
        let existing = SpeakerProfile(displayName: "Sarah", identity: identity)
        let service = StubVoiceprintService(
            candidate: observation(),
            enrollment: .needsDisambiguation(existing: existing, distance: 0.62),
            mergeEnrollment: .addedExemplar(existing)
        )
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.confirmVoiceEnrollment()

        try await waitUntil { viewModel.voiceEnrollmentConflict != nil }
        XCTAssertNil(viewModel.voiceEnrollmentMessage)
        XCTAssertEqual(service.enrollments.count, 1)

        viewModel.confirmVoiceEnrollment(allowMerge: true)

        try await waitUntil { service.enrollments.count == 2 }
        XCTAssertEqual(service.enrollments.last?.1, true)
        XCTAssertNil(viewModel.voiceEnrollmentConflict)
    }

    func testAFailedEnrollmentSaysSoWithoutBlocking() async throws {
        struct Boom: Error {}
        let transcription = makeTranscription()
        let service = StubVoiceprintService(candidate: observation(), enrollError: Boom())
        let viewModel = try await configured(transcription, voiceprints: service)
        viewModel.renameSpeaker(id: "S1", to: "Sarah")
        try await waitUntil { viewModel.pendingVoiceEnrollment != nil }

        viewModel.confirmVoiceEnrollment()

        try await waitUntil { viewModel.voiceEnrollmentMessage != nil }
        // The rename itself is untouched: only the voice was not remembered.
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: Helpers

    private func configured(
        _ transcription: Transcription,
        voiceprints: SpeakerVoiceprintServicing?,
        correctionFails: Bool = false
    ) async throws -> TranscriptionViewModel {
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: StubAttributionReader(fallback: transcription),
            speakerCorrectionService: StubCorrectionService(
                result: SpeakerCorrectionResult(
                    attribution: attribution, revision: 1, canUndo: true, canRedo: false
                ),
                failsApply: correctionFails,
                base: transcription
            ),
            speakerVoiceprints: voiceprints
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { viewModel.speakerAttribution != nil }
        return viewModel
    }

    private func suggestion() -> SpeakerVoiceprintSuggestion {
        SpeakerVoiceprintSuggestion(
            speakerId: "S1",
            profileId: UUID(),
            displayName: "Sarah",
            distance: 0.12,
            runnerUpDistance: 0.48
        )
    }

    private func observation() -> SpeakerClusterObservation {
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[0] = 1
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return SpeakerClusterObservation(
            speakerId: "S1", embedding: embedding, speechSeconds: 30, captureDomain: .system
        )
    }

    private func makeTranscription() -> Transcription {
        let words = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "there", startMs: 450, endMs: 800, confidence: 0.9, speakerId: "S1"),
        ]
        return Transcription(
            fileName: "meeting.wav",
            rawTranscript: "hello there",
            wordTimestamps: words,
            speakerCount: 1,
            speakers: [SpeakerInfo(id: "S1", label: "Others 1")],
            diarizationSegments: [.init(speakerId: "S1", startMs: 0, endMs: 800)],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 0,
                    endMs: 800,
                    speakerId: "S1",
                    speakerLabel: "Others 1",
                    text: "hello there",
                    wordRange: .init(startIndex: 0, endIndexExclusive: 2)
                )
            ],
            status: .completed
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { XCTFail("condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
