import Foundation

/// What happened when the user asked to remember a voice.
public enum SpeakerProfileEnrollment: Sendable, Equatable {
    case created(SpeakerProfile)
    /// The name was blank once trimmed. It would have no lookup key, so the
    /// profile could never be found again nor collide with a second blank one.
    case rejectedEmptyName
    /// The retained voice expired or was deleted before enrollment.
    case candidateUnavailable
    case addedExemplar(SpeakerProfile)
    /// The name is taken by a profile whose voice does not match. Merging would
    /// fuse two people, so the caller must ask.
    case needsDisambiguation(existing: SpeakerProfile, distance: Double)
    case rejectedTooShort(speechSeconds: Double)
    /// The profile already holds a sample from this recording.
    case alreadySampled(SpeakerProfile)
    /// The profile is at its sample cap and every sample is a manual
    /// enrollment, so there is nothing to evict without weakening the anchor
    /// that lets it learn.
    case rejectedProfileFull(SpeakerProfile)
}

/// What happened when the user named a speaker themselves.
public enum SpeakerManualAssignment: Sendable, Equatable {
    case assigned(SpeakerProfile)
    /// Another speaker in this same transcript is already confirmed as this
    /// profile. One voice cannot be two people in one meeting.
    case profileAlreadyUsed(bySpeakerId: String)
    /// Deleted between the menu being built and the choice being made.
    case unknownProfile
    /// The speaker id is a meeting capture channel (`microphone` / `system`),
    /// not a diarized cluster. Identity belongs to people, not tracks.
    case unsupportedSpeaker
}

/// One enrolled voice, as the administration surface needs to show it.
///
/// Carries the diagnostic fields deliberately: "this profile never matches" is
/// the feature's first failure mode, and the answer is a number the user can
/// compare against the threshold, not a mystery.
public struct EnrolledVoice: Sendable, Equatable, Identifiable {
    public var id: UUID { profile.id }
    public let profile: SpeakerProfile
    public let sampleCount: Int
    public let maxSamples: Int
    /// Recordings this voice has been confirmed in.
    public let recognizedCount: Int
    /// `true` when the samples were produced by a model the current pipeline no
    /// longer uses, so they can never score. Re-enrollment is the way out.
    public let usesRetiredModel: Bool
    /// Closest distance at the last scoring, and the threshold it had to beat.
    public let lastEvaluatedDistance: Double?
    public let acceptanceThreshold: Double

    public init(
        profile: SpeakerProfile,
        sampleCount: Int,
        maxSamples: Int,
        recognizedCount: Int,
        usesRetiredModel: Bool,
        lastEvaluatedDistance: Double?,
        acceptanceThreshold: Double
    ) {
        self.profile = profile
        self.sampleCount = sampleCount
        self.maxSamples = maxSamples
        self.recognizedCount = recognizedCount
        self.usesRetiredModel = usesRetiredModel
        self.lastEvaluatedDistance = lastEvaluatedDistance
        self.acceptanceThreshold = acceptanceThreshold
    }

    /// Scored but never accepted, with a number to show for it.
    public var scoredButNeverMatched: Bool {
        profile.lastMatchedAt == nil && lastEvaluatedDistance != nil
    }
}

public protocol SpeakerVoiceprintServicing: Sendable {
    /// Names worth proposing, and the voices this run leaves available for
    /// enrollment. Applies nothing, and does no work when off.
    func evaluate(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        clusters: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion]

    /// Offers awaiting an answer for this version of the transcript.
    func pendingSuggestions(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> [SpeakerVoiceprintSuggestion]

    /// The voice still available for this speaker, or `nil` when the window has
    /// lapsed, the cluster was too short, or the feature was off at capture.
    /// This is what makes "remember this voice" possible after the fact.
    func enrollmentCandidate(
        transcriptionId: UUID,
        speakerId: String,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerClusterObservation?

    /// Drops candidates past their window. Reads and writes prune too; this
    /// covers the user who stops recording and stops naming.
    func pruneExpiredCandidates() async throws

    /// Creates the profile or adds a sample. Refuses short clusters, and asks
    /// rather than merges when the name is taken by a voice that differs.
    func enroll(
        displayName: String,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment

    /// Enrollment from a UI offer resolves the retained voice again, so a stale
    /// offer cannot recreate a deleted or expired candidate.
    func enrollCandidate(
        displayName: String,
        speakerId: String,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment

    /// Consent-gated voices for transcript actions. Administration has a separate read.
    func recognitionVoices() async throws -> [EnrolledVoice]

    /// Checks availability and reservation before a caller changes a transcript label.
    func validateAssignment(
        profileId: UUID,
        toSpeakerId speakerId: String,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerManualAssignment

    /// Records acceptance and, once two manual enrollments anchor the profile,
    /// lets it learn. The label is written by the correction layer, not here.
    func confirm(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws

    /// Records a name the user chose rather than one the matcher proposed.
    /// The label is written by the correction layer, as with `confirm`.
    func assign(
        profileId: UUID,
        toSpeakerId speakerId: String,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerManualAssignment

    /// Which voice each speaker already holds in this version of the
    /// transcript, keyed by profile. A menu that keeps offering a voice
    /// another speaker holds is offering what `assign` will refuse.
    func confirmedVoiceHolders(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> [UUID: String]

    /// Every enrolled voice with what the administration surface needs to
    /// explain it, including why one may never be matching.
    func enrolledVoices() async throws -> [EnrolledVoice]

    /// The samples behind one profile, oldest first.
    func samples(profileId: UUID) async throws -> [SpeakerProfileExemplar]

    /// Renames a profile. Throws when the name is taken by another one.
    func renameProfile(id: UUID, to displayName: String) async throws

    /// Removes one sample. Refuses the last one, which would leave a profile
    /// that is listed, named, and can never match.
    @discardableResult
    func deleteSample(id: UUID, profileId: UUID) async throws -> Bool

    /// Forgets a voice. Labels already written to transcripts are untouched.
    func forgetVoice(profileId: UUID) async throws

    /// Forgets every voice, its samples, decisions and retained candidates.
    func forgetAllVoices() async throws

    /// Not offered again for this version of the transcript.
    func dismiss(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws
}

/// Refusals the service raises before it touches stored voices.
public enum SpeakerVoiceprintServiceError: Error, Equatable, Sendable {
    /// The preference is off. Enrollment and decisions must not write, and
    /// must not look like they succeeded. Pruning expired candidates stays
    /// available so turning the feature off can still drop retained voice candidates.
    case disabled
    case profileAlreadyUsed(bySpeakerId: String)
    case unknownProfile
    case unsupportedSpeaker
}

/// Owns enrolled voices: scoring, enrolling, and recording what the user chose.
///
/// Serializes complete voice operations, including candidate lookup followed by
/// enrollment. Repository transactions protect individual writes; this actor also
/// prevents Forget All from interleaving between those writes in the app.
public actor SpeakerVoiceprintService: SpeakerVoiceprintServicing {
    private let profiles: SpeakerProfileRepositoryProtocol
    private let candidates: SpeakerEmbeddingCandidateRepositoryProtocol
    private let journal: SpeakerMatchJournalRepositoryProtocol
    private let policy: SpeakerMatchPolicy
    private let candidateRetention: TimeInterval
    /// The representation the pipeline produces today. The model half decides
    /// whether samples can score at all; the aggregation half decides which
    /// threshold they are judged against.
    private let identity: SpeakerModelIdentity
    /// Read per call, so turning the preference off takes effect immediately.
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    public init(
        profiles: SpeakerProfileRepositoryProtocol,
        candidates: SpeakerEmbeddingCandidateRepositoryProtocol,
        journal: SpeakerMatchJournalRepositoryProtocol,
        policy: SpeakerMatchPolicy = .v1,
        identity: SpeakerModelIdentity = DiarizationService.defaultModelIdentity,
        candidateRetention: TimeInterval = SpeakerEmbeddingCandidateRepository.defaultRetention,
        isEnabled: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profiles = profiles
        self.candidates = candidates
        self.journal = journal
        self.policy = policy
        self.identity = identity
        self.candidateRetention = candidateRetention
        self.isEnabled = isEnabled
        self.now = now
    }

    // MARK: Matching

    /// Suggestions only; nothing is applied. When off, reads nothing and writes
    /// nothing, so no voiceprint work happens behind a user who never opted in.
    public func evaluate(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        clusters: [SpeakerClusterObservation]
    ) async throws -> [SpeakerVoiceprintSuggestion] {
        guard isEnabled() else { return [] }
        guard !clusters.isEmpty else {
            _ = try profiles.replaceSuggestions(
                transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue, with: []
            )
            return []
        }

        // Ahead of every matching early return: the run that matters most for
        // enrollment is the first one, when no profile exists yet and there is
        // nothing to score against.
        try retainCandidates(clusters, transcriptionId: transcriptionId, fingerprint: fingerprint)

        let candidates = try profileCandidates()
        guard !candidates.isEmpty else {
            _ = try profiles.replaceSuggestions(
                transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue, with: []
            )
            return []
        }

        // Terminal clusters still compete: dropping them before scoring lets a
        // sibling inherit the same voice with a manufactured margin. Confirmed
        // profile ids are reserved afterwards so a second cluster cannot be
        // assigned a name the user already gave.
        let existingLinks = try profiles.links(
            transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue
        )
        let terminalSpeakerIds = Set(
            existingLinks.filter { $0.status != .suggested }.map(\.speakerId)
        )
        let reservedProfileIds = Set(
            existingLinks.filter { $0.status == .confirmed }.map(\.profileId)
        )

        let scored = SpeakerVoiceprintMatcher.decisions(
            clusters: clusters,
            profiles: candidates,
            policy: policy
        )
        // User decisions suppress publication without changing the matcher's
        // evidence in the calibration journal.
        let suggestions = scored.compactMap(\.suggestion).filter { suggestion in
            !terminalSpeakerIds.contains(suggestion.speakerId)
                && !reservedProfileIds.contains(suggestion.profileId)
        }

        return try record(
            scored, suggestions: suggestions, transcriptionId: transcriptionId, fingerprint: fingerprint
        )
    }

    // MARK: Enrollment

    /// Gated on the preference like everything else: a candidate captured while
    /// the feature was on must not stay reachable after it is turned off.
    /// Offers still awaiting an answer for this version of the transcript.
    ///
    /// Read back from the store rather than held in memory: scoring happens
    /// when the meeting finishes, and the user opens the transcript later —
    /// often after a relaunch.
    public func pendingSuggestions(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> [SpeakerVoiceprintSuggestion] {
        guard isEnabled() else { return [] }
        let links = try profiles.links(
            transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue
        )
        .filter { $0.status == .suggested }
        guard !links.isEmpty else { return [] }

        return try links.compactMap { link in
            // A profile deleted since scoring leaves its link cascaded away, so
            // a missing one here means the row is mid-deletion: skip it rather
            // than offer a name that no longer exists.
            guard let profile = try profiles.profile(id: link.profileId) else { return nil }
            return SpeakerVoiceprintSuggestion(
                speakerId: link.speakerId,
                profileId: link.profileId,
                displayName: profile.displayName,
                distance: link.distance,
                runnerUpDistance: link.runnerUpDistance
            )
        }
    }

    public func enrollmentCandidate(
        transcriptionId: UUID,
        speakerId: String,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerClusterObservation? {
        guard isEnabled() else { return nil }
        guard !AudioSource.isMeetingCaptureTrack(speakerId) else { return nil }
        return try candidates.candidate(
            transcriptionId: transcriptionId,
            speakerId: speakerId,
            fingerprint: fingerprint.rawValue,
            now: now()
        )?.observation
    }

    public func pruneExpiredCandidates() async throws {
        try candidates.pruneExpired(now: now())
    }

    public func enrollCandidate(
        displayName: String,
        speakerId: String,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment {
        guard isEnabled() else { throw SpeakerVoiceprintServiceError.disabled }
        guard !AudioSource.isMeetingCaptureTrack(speakerId) else { return .candidateUnavailable }
        guard
            let observation = try candidates.candidate(
                transcriptionId: transcriptionId, speakerId: speakerId,
                fingerprint: fingerprint.rawValue, now: now()
            )?.observation
        else { return .candidateUnavailable }
        return try enrollObservation(
            displayName: displayName, observation: observation,
            transcriptionId: transcriptionId, fingerprint: fingerprint,
            allowMergeIntoExistingName: allowMergeIntoExistingName
        )
    }

    public func recognitionVoices() async throws -> [EnrolledVoice] {
        guard isEnabled() else { return [] }
        return try storedVoices()
    }

    public func validateAssignment(
        profileId: UUID,
        toSpeakerId speakerId: String,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerManualAssignment {
        guard isEnabled() else { throw SpeakerVoiceprintServiceError.disabled }
        guard !AudioSource.isMeetingCaptureTrack(speakerId) else { return .unsupportedSpeaker }
        guard let profile = try profiles.profile(id: profileId) else { return .unknownProfile }
        if let holder = try profiles.links(
            transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue
        ).first(where: {
            $0.profileId == profileId && $0.status == .confirmed && $0.speakerId != speakerId
        }) {
            return .profileAlreadyUsed(bySpeakerId: holder.speakerId)
        }
        return .assigned(profile)
    }

    /// The pollution guard lives here, not in the matcher: naming a speaker is
    /// a user action that bypasses every threshold, so two colleagues called
    /// Sarah, or one misclick, would fuse two voices with no way back.
    ///
    /// On success the candidate is dropped: its vector now lives in the profile.
    public func enroll(
        displayName: String,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) async throws -> SpeakerProfileEnrollment {
        try enrollObservation(
            displayName: displayName, observation: observation,
            transcriptionId: transcriptionId, fingerprint: fingerprint,
            allowMergeIntoExistingName: allowMergeIntoExistingName
        )
    }

    private func enrollObservation(
        displayName: String,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) throws -> SpeakerProfileEnrollment {
        guard isEnabled() else { throw SpeakerVoiceprintServiceError.disabled }
        guard !AudioSource.isMeetingCaptureTrack(observation.speakerId) else {
            return .candidateUnavailable
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SpeakerProfile.normalizedName(for: name).isEmpty else {
            return .rejectedEmptyName
        }
        guard observation.speechSeconds >= policy.minSpeechSecondsToEnroll else {
            return .rejectedTooShort(speechSeconds: observation.speechSeconds)
        }

        if let existing = try profiles.profile(named: name) {
            return try sample(
                existing,
                observation: observation,
                transcriptionId: transcriptionId,
                fingerprint: fingerprint,
                allowMergeIntoExistingName: allowMergeIntoExistingName
            )
        }

        let profile = SpeakerProfile(
            displayName: name,
            identity: observation.embedding.identity,
            createdAt: now(),
            updatedAt: now()
        )
        do {
            switch try profiles.insert(
                profile,
                firstExemplar: exemplar(
                    for: profile,
                    observation: observation,
                    origin: .manualEnrollment,
                    transcriptionId: transcriptionId
                ),
                maxPerProfile: policy.maxReferencesPerProfile,
                evicting: .confirmedSuggestion
            ) {
            case .inserted, .insertedEvicting:
                try consumeCandidate(
                    transcriptionId: transcriptionId,
                    speakerId: observation.speakerId,
                    fingerprint: fingerprint
                )
                return .created(profile)
            case .rejectedAlreadySampled:
                return .alreadySampled(profile)
            case .rejectedProfileFull:
                return .rejectedProfileFull(profile)
            }
        } catch SpeakerProfileStoreError.nameAlreadyTaken {
            // Another enrollment claimed the name between the lookup and the
            // insert. The user asked for a name, not for a row, so the second
            // one samples the winner instead of failing. The winner already
            // holds its first sample, so the pollution guard can run.
            guard let winner = try profiles.profile(named: name) else {
                throw SpeakerProfileStoreError.nameAlreadyTaken(
                    normalizedName: SpeakerProfile.normalizedName(for: name)
                )
            }
            return try sample(
                winner,
                observation: observation,
                transcriptionId: transcriptionId,
                fingerprint: fingerprint,
                allowMergeIntoExistingName: allowMergeIntoExistingName
            )
        }
    }

    /// Adds this voice to a profile that already exists, which is where the
    /// pollution guard applies: the name is a claim about identity that no
    /// threshold has checked.
    private func sample(
        _ profile: SpeakerProfile,
        observation: SpeakerClusterObservation,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint,
        allowMergeIntoExistingName: Bool
    ) throws -> SpeakerProfileEnrollment {
        // Checked before the pollution guard and regardless of the override:
        // the store refuses samples from another embedding model, and a forced
        // merge is the caller overriding a judgement about *which person* this
        // is, not about whether the two vectors can be compared at all.
        guard profile.embeddingModelId == observation.embedding.identity.embeddingModelId else {
            return .needsDisambiguation(existing: profile, distance: 1)
        }

        let references = try references(for: profile.id)
        if !allowMergeIntoExistingName, !references.isEmpty {
            let candidate = SpeakerProfileCandidate(
                profileId: profile.id,
                displayName: profile.displayName,
                references: references
            )
            // A nil distance is less evidence than a far one, not more: treat
            // it as a mismatch rather than a silent merge.
            let distance = SpeakerVoiceprintMatcher.distance(
                from: observation, to: candidate, policy: policy
            )
            if distance ?? .infinity > policy.pollutionGuardDistance {
                return .needsDisambiguation(existing: profile, distance: distance ?? 1)
            }
        }

        switch try addExemplar(
            to: profile,
            observation: observation,
            origin: .manualEnrollment,
            transcriptionId: transcriptionId
        ) {
        case .rejectedProfileFull:
            return .rejectedProfileFull(profile)
        case .rejectedAlreadySampled:
            return .alreadySampled(profile)
        case .inserted, .insertedEvicting:
            try consumeCandidate(
                transcriptionId: transcriptionId,
                speakerId: observation.speakerId,
                fingerprint: fingerprint
            )
            let updated = try profiles.updateProfile(id: profile.id) { $0.updatedAt = now() }
            return .addedExemplar(updated ?? profile)
        }
    }

    // MARK: Decisions

    /// The label is not written here — that goes through
    /// `SpeakerCorrectionService`, inheriting undo and provenance. The caller
    /// renames first, so a crash between the two leaves a correct name and a
    /// profile that did not learn, rather than a poisoned profile.
    public func confirm(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws {
        guard isEnabled() else { throw SpeakerVoiceprintServiceError.disabled }
        guard !AudioSource.isMeetingCaptureTrack(suggestion.speakerId) else {
            throw SpeakerVoiceprintServiceError.unsupportedSpeaker
        }
        guard let profile = try profiles.profile(id: suggestion.profileId) else {
            throw SpeakerVoiceprintServiceError.unknownProfile
        }

        // Resolved here rather than taken from the caller: the vector belongs
        // to this speaker in this version of the transcript, and a UI holding
        // the wrong one would teach the profile someone else's voice. `nil`
        // once the window has lapsed, which records the decision without
        // learning from it.
        let observation = try candidates.candidate(
            transcriptionId: transcriptionId,
            speakerId: suggestion.speakerId,
            fingerprint: fingerprint.rawValue,
            now: now()
        )?.observation

        if let holder = try profiles.claimProfile(
            SpeakerProfileLink(
                transcriptionId: transcriptionId,
                speakerId: suggestion.speakerId,
                transcriptFingerprint: fingerprint.rawValue,
                profileId: suggestion.profileId,
                status: .confirmed,
                distance: suggestion.distance,
                runnerUpDistance: suggestion.runnerUpDistance,
                createdAt: now(),
                updatedAt: now()
            ), replacingUserDecision: false
        ) {
            throw SpeakerVoiceprintServiceError.profileAlreadyUsed(bySpeakerId: holder)
        }

        // A profile born of one enrollment cannot amplify itself on its own
        // suggestion: two manual enrollments must anchor the voice first. The
        // one-sample-per-recording rule is the store's. A short match can be
        // confirmed, but it cannot bypass the minimum duration for learning.
        let exemplars = try profiles.exemplars(profileId: profile.id)
        if let observation,
            observation.speechSeconds >= policy.minSpeechSecondsToEnroll,
            observation.embedding.identity.embeddingModelId == profile.embeddingModelId,
            exemplars.filter({ $0.origin == .manualEnrollment }).count >= 2
        {
            switch try addExemplar(
                to: profile,
                observation: observation,
                origin: .confirmedSuggestion,
                transcriptionId: transcriptionId
            ) {
            case .inserted, .insertedEvicting:
                try consumeCandidate(
                    transcriptionId: transcriptionId,
                    speakerId: suggestion.speakerId,
                    fingerprint: fingerprint
                )
            case .rejectedAlreadySampled, .rejectedProfileFull:
                break
            }
        }

        _ = try profiles.updateProfile(id: profile.id) {
            $0.lastMatchedAt = now()
            $0.updatedAt = now()
        }
    }

    /// Same ordering as `confirm`, with two differences the store can see: there
    /// was no score, so the link carries the sentinel, and the sample it keeps is
    /// a manual enrollment rather than an accepted suggestion. Choosing a name
    /// from a list of enrolled voices is the same claim as typing that name into
    /// the enrollment field. Calibration must still be able to tell a decision
    /// from a measurement, which is what the sentinel is for.
    public func assign(
        profileId: UUID,
        toSpeakerId speakerId: String,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> SpeakerManualAssignment {
        guard isEnabled() else { throw SpeakerVoiceprintServiceError.disabled }
        guard !AudioSource.isMeetingCaptureTrack(speakerId) else { return .unsupportedSpeaker }
        guard let profile = try profiles.profile(id: profileId) else { return .unknownProfile }

        // The same reservation `evaluate` applies to its own suggestions. The
        // manual path must not be the way around it: two speakers wearing one
        // name in a single transcript is a state nothing downstream can undo.
        // The store checks and records under one write, because two people
        // named from the same voice at once would each find it free here.
        //
        // The write replaces whatever this speaker carried, a dismissal
        // included: the contract stops a re-evaluation from overruling an
        // answer, not the person who gave it from changing their mind.
        let previousConfirmed = try profiles.links(
            transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue
        ).first { $0.speakerId == speakerId && $0.status == .confirmed && $0.profileId != profileId }
        if let holder = try profiles.claimProfile(
            SpeakerProfileLink(
                transcriptionId: transcriptionId,
                speakerId: speakerId,
                transcriptFingerprint: fingerprint.rawValue,
                profileId: profileId,
                status: .confirmed,
                distance: SpeakerProfileLink.manualDecisionDistance,
                runnerUpDistance: nil,
                createdAt: now(),
                updatedAt: now()
            ), replacingUserDecision: true
        ) {
            return .profileAlreadyUsed(bySpeakerId: holder)
        }

        // A correction must not leave the first profile taught by a name the
        // transcript no longer shows. Read the stolen sample before deleting
        // it, so the new profile can still learn after the candidate was spent.
        let stolen: SpeakerProfileExemplar?
        if let previous = previousConfirmed {
            stolen = try profiles.exemplars(profileId: previous.profileId).first {
                $0.sourceTranscriptionId == transcriptionId
                    && ($0.sourceSpeakerId == nil || $0.sourceSpeakerId == speakerId)
            }
        } else {
            stolen = nil
        }
        var observation = try candidates.candidate(
            transcriptionId: transcriptionId,
            speakerId: speakerId,
            fingerprint: fingerprint.rawValue,
            now: now()
        )?.observation
        if observation == nil, let stolen, let embedding = stolen.embedding {
            observation = SpeakerClusterObservation(
                speakerId: stolen.sourceSpeakerId ?? speakerId,
                embedding: embedding,
                speechSeconds: stolen.speechSeconds,
                captureDomain: stolen.captureDomain
            )
        }

        // Kept even when this voice sits far from everything the profile holds:
        // that distance is why the matcher stayed quiet, and it is what a changed
        // microphone or a hoarse morning sounds like. The two anchors `confirm`
        // demands do not apply here — the person naming the speaker is the
        // anchor. Only the duration guard survives, because it judges signal
        // rather than identity.
        if let observation,
            observation.speechSeconds >= policy.minSpeechSecondsToEnroll,
            observation.embedding.identity.embeddingModelId == profile.embeddingModelId
        {
            switch try addExemplar(
                to: profile,
                observation: observation,
                origin: .manualEnrollment,
                transcriptionId: transcriptionId
            ) {
            case .inserted, .insertedEvicting:
                try consumeCandidate(
                    transcriptionId: transcriptionId,
                    speakerId: speakerId,
                    fingerprint: fingerprint
                )
            case .rejectedAlreadySampled, .rejectedProfileFull:
                break
            }
        }

        if let stolen {
            _ = try profiles.deleteExemplar(id: stolen.id)
        }

        let updated = try profiles.updateProfile(id: profile.id) {
            $0.lastMatchedAt = now()
            $0.updatedAt = now()
        }
        return .assigned(updated ?? profile)
    }

    public func confirmedVoiceHolders(
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws -> [UUID: String] {
        // Empty rather than thrown: this only feeds a menu, and that menu is
        // already gone when the feature is off.
        guard isEnabled() else { return [:] }
        let links = try profiles.links(
            transcriptionId: transcriptionId, fingerprint: fingerprint.rawValue
        )
        return links.reduce(into: [:]) { holders, link in
            guard link.status == .confirmed else { return }
            holders[link.profileId] = link.speakerId
        }
    }

    public func dismiss(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws {
        guard isEnabled() else { throw SpeakerVoiceprintServiceError.disabled }
        try profiles.save(
            SpeakerProfileLink(
                transcriptionId: transcriptionId,
                speakerId: suggestion.speakerId,
                transcriptFingerprint: fingerprint.rawValue,
                profileId: suggestion.profileId,
                status: .dismissed,
                distance: suggestion.distance,
                runnerUpDistance: suggestion.runnerUpDistance,
                createdAt: now(),
                updatedAt: now()
            )
        )
    }

    // MARK: Administration

    /// None of these check `isEnabled`. Turning the feature off must never trap
    /// a user's stored voices behind it — reading and deleting what is already
    /// there is exactly what they need once they change their mind.

    public func enrolledVoices() async throws -> [EnrolledVoice] {
        try storedVoices()
    }

    private func storedVoices() throws -> [EnrolledVoice] {
        let stored = try profiles.profiles()
        guard !stored.isEmpty else { return [] }
        let samples = try profiles.exemplarsByProfile()

        return stored.map { profile in
            let references = samples[profile.id] ?? []
            return EnrolledVoice(
                profile: profile,
                sampleCount: references.count,
                maxSamples: policy.maxReferencesPerProfile,
                recognizedCount: (try? profiles.confirmedLinkCount(profileId: profile.id)) ?? 0,
                usesRetiredModel: profile.embeddingModelId != identity.embeddingModelId,
                lastEvaluatedDistance: profile.lastEvaluatedDistance,
                acceptanceThreshold: acceptanceThreshold(for: references)
            )
        }
    }

    /// The threshold this profile's samples can actually be judged against.
    ///
    /// The matcher tightens by `crossAggregationPenalty` when the winning
    /// reference came from another clustering configuration, so reporting
    /// `tau` unconditionally would show a distance as acceptable that the
    /// matcher rejects. Where samples are mixed the stricter figure is shown:
    /// a screen that explains why nothing matches must not overstate what will.
    private func acceptanceThreshold(for references: [SpeakerProfileExemplar]) -> Double {
        guard !references.isEmpty else { return policy.tau }
        let allCurrent = references.allSatisfy {
            $0.aggregationProfileId == identity.aggregationProfileId
        }
        return allCurrent ? policy.tau : policy.tau - policy.crossAggregationPenalty
    }

    public func samples(profileId: UUID) async throws -> [SpeakerProfileExemplar] {
        try profiles.exemplars(profileId: profileId)
    }

    public func renameProfile(id: UUID, to displayName: String) async throws {
        _ = try profiles.updateProfile(id: id) {
            $0.displayName = displayName
            $0.updatedAt = now()
        }
    }

    /// Refuses the last sample: a profile with none is listed and named but can
    /// never match, which reads as a bug rather than as a choice. Forgetting
    /// the voice is the way to remove the last one.
    @discardableResult
    public func deleteSample(id: UUID, profileId: UUID) async throws -> Bool {
        // The store checks ownership and the count in the same write. Doing it
        // here would let two callers both see more than one sample and both
        // delete, and would delete by id alone — taking another profile's last
        // sample on a mismatched id.
        try profiles.deleteExemplar(id: id, profileId: profileId, keepingAtLeastOne: true)
    }

    public func forgetVoice(profileId: UUID) async throws {
        _ = try profiles.deleteProfile(id: profileId)
    }

    /// Candidates go too. They are not owned by any profile, so no cascade
    /// reaches them, and leaving retained voices behind after "forget every
    /// voice" would be the one deletion a user cannot see or explain.
    public func forgetAllVoices() async throws {
        try profiles.deleteAllProfiles()
        try candidates.deleteAll()
        try journal.deleteAll()
    }

    // MARK: Internals

    /// Only clusters the enrollment gate would accept are retained. A vector
    /// below it can never become an exemplar, so keeping it would be biometric
    /// data stored for an offer the user will never be shown.
    private func retainCandidates(
        _ clusters: [SpeakerClusterObservation],
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) throws {
        let enrollable = clusters.filter { $0.speechSeconds >= policy.minSpeechSecondsToEnroll }
        guard !enrollable.isEmpty else { return }

        let captured = now()
        try candidates.upsert(
            enrollable.map { cluster in
                SpeakerEmbeddingCandidate(
                    transcriptionId: transcriptionId,
                    speakerId: cluster.speakerId,
                    transcriptFingerprint: fingerprint.rawValue,
                    embedding: cluster.embedding,
                    speechSeconds: cluster.speechSeconds,
                    captureDomain: cluster.captureDomain,
                    createdAt: captured,
                    expiresAt: captured.addingTimeInterval(candidateRetention)
                )
            },
            now: captured
        )
    }

    private func consumeCandidate(
        transcriptionId: UUID,
        speakerId: String,
        fingerprint: TranscriptFingerprint
    ) throws {
        try candidates.delete(
            transcriptionId: transcriptionId,
            speakerId: speakerId,
            fingerprint: fingerprint.rawValue
        )
    }

    private func profileCandidates() throws -> [SpeakerProfileCandidate] {
        let stored = try profiles.profiles()
        guard !stored.isEmpty else { return [] }

        let exemplars = try profiles.exemplarsByProfile()
        return stored.compactMap { profile in
            let references = (exemplars[profile.id] ?? [])
                .sorted { $0.createdAt > $1.createdAt }
                .compactMap(reference(from:))
            guard !references.isEmpty else { return nil }
            return SpeakerProfileCandidate(
                profileId: profile.id,
                displayName: profile.displayName,
                references: references
            )
        }
    }

    /// Newest first: the matcher scores only the first `maxReferencesPerProfile`,
    /// and the repository returns exemplars oldest first, so passing them
    /// straight through would hide every sample added after the cap was reached
    /// — the ones most likely to share the current aggregation identity.
    private func references(for profileId: UUID) throws -> [SpeakerProfileCandidate.Reference] {
        try profiles.exemplars(profileId: profileId)
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap(reference(from:))
    }

    private func reference(
        from exemplar: SpeakerProfileExemplar
    ) -> SpeakerProfileCandidate.Reference? {
        guard let embedding = exemplar.embedding else { return nil }
        return SpeakerProfileCandidate.Reference(
            embedding: embedding,
            captureDomain: exemplar.captureDomain
        )
    }

    /// Adds a sample under the cap, in the store's transaction.
    ///
    /// The cap bounds storage, not just scoring: keeping vectors the matcher
    /// will never reach would accumulate biometric data for nothing. Eviction
    /// spares manual enrollments because `confirm` counts them to decide
    /// whether a profile may learn at all — evicting them oldest-first would
    /// drop a mature profile back below that anchor for no visible reason.
    private func exemplar(
        for profile: SpeakerProfile,
        observation: SpeakerClusterObservation,
        origin: SpeakerProfileExemplar.Origin,
        transcriptionId: UUID?
    ) -> SpeakerProfileExemplar {
        SpeakerProfileExemplar(
            profileId: profile.id,
            embedding: observation.embedding,
            speechSeconds: observation.speechSeconds,
            captureDomain: observation.captureDomain,
            origin: origin,
            sourceTranscriptionId: transcriptionId,
            sourceSpeakerId: observation.speakerId,
            createdAt: now()
        )
    }

    @discardableResult
    private func addExemplar(
        to profile: SpeakerProfile,
        observation: SpeakerClusterObservation,
        origin: SpeakerProfileExemplar.Origin,
        transcriptionId: UUID?
    ) throws -> SpeakerExemplarInsertion {
        try profiles.insertExemplar(
            exemplar(
                for: profile,
                observation: observation,
                origin: origin,
                transcriptionId: transcriptionId
            ),
            maxPerProfile: policy.maxReferencesPerProfile,
            evicting: .confirmedSuggestion
        )
    }

    /// Pending links for publishable suggestions, and every matcher decision
    /// to the local journal, including matches withheld by a user decision.
    private func record(
        _ decisions: [SpeakerMatchDecision],
        suggestions: [SpeakerVoiceprintSuggestion],
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) throws -> [SpeakerVoiceprintSuggestion] {
        let stored = try profiles.replaceSuggestions(
            transcriptionId: transcriptionId,
            fingerprint: fingerprint.rawValue,
            with: suggestions.map { suggestion in
                SpeakerProfileLink(
                    transcriptionId: transcriptionId,
                    speakerId: suggestion.speakerId,
                    transcriptFingerprint: fingerprint.rawValue,
                    profileId: suggestion.profileId,
                    status: .suggested,
                    distance: suggestion.distance,
                    runnerUpDistance: suggestion.runnerUpDistance,
                    createdAt: now(),
                    updatedAt: now()
                )
            }
        )
        let offeredSpeakers = Set(stored.map(\.speakerId))

        // Scored is not matched: this is what tells "never recognized" apart
        // from "recognized and wrong".
        var evaluated: [UUID: (date: Date, distance: Double)] = [:]
        for decision in decisions {
            guard let profileId = decision.profileId, let distance = decision.distance else { continue }
            if let current = evaluated[profileId], current.distance <= distance { continue }
            evaluated[profileId] = (now(), distance)
        }
        for (profileId, evaluation) in evaluated {
            _ = try profiles.updateProfile(id: profileId) {
                $0.lastEvaluatedAt = evaluation.date
                $0.lastEvaluatedDistance = evaluation.distance
            }
        }

        try journal.append(
            decisions.map { decision in
                SpeakerMatchJournalEntry(
                    transcriptionId: transcriptionId,
                    speakerId: decision.speakerId,
                    transcriptFingerprint: fingerprint.rawValue,
                    profileId: decision.profileId,
                    outcome: decision.outcome,
                    topDistance: decision.distance,
                    runnerUpDistance: decision.runnerUpDistance,
                    speechSeconds: decision.speechSeconds,
                    createdAt: now()
                )
            },
            retention: SpeakerMatchJournalRepository.defaultRetention,
            now: now()
        )
        return suggestions.filter { offeredSpeakers.contains($0.speakerId) }
    }
}
