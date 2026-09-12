import Foundation

/// What happened when the user asked to remember a voice.
public enum SpeakerProfileEnrollment: Sendable, Equatable {
    case created(SpeakerProfile)
    /// The name was blank once trimmed. It would have no lookup key, so the
    /// profile could never be found again nor collide with a second blank one.
    case rejectedEmptyName
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

    /// Records acceptance and, once two manual enrollments anchor the profile,
    /// lets it learn. The label is written by the correction layer, not here.
    func confirm(
        _ suggestion: SpeakerVoiceprintSuggestion,
        transcriptionId: UUID,
        fingerprint: TranscriptFingerprint
    ) async throws

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
}

/// Owns enrolled voices: scoring, enrolling, and recording what the user chose.
///
/// A `final class` like its neighbour `SpeakerCorrectionService`, not an actor:
/// GRDB already serializes through the database queue.
public final class SpeakerVoiceprintService: SpeakerVoiceprintServicing, @unchecked Sendable {
    private let profiles: SpeakerProfileRepositoryProtocol
    private let candidates: SpeakerEmbeddingCandidateRepositoryProtocol
    private let journal: SpeakerMatchJournalRepositoryProtocol
    private let policy: SpeakerMatchPolicy
    private let candidateRetention: TimeInterval
    /// Read per call, so turning the preference off takes effect immediately.
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    public init(
        profiles: SpeakerProfileRepositoryProtocol,
        candidates: SpeakerEmbeddingCandidateRepositoryProtocol,
        journal: SpeakerMatchJournalRepositoryProtocol,
        policy: SpeakerMatchPolicy = .v1,
        candidateRetention: TimeInterval = SpeakerEmbeddingCandidateRepository.defaultRetention,
        isEnabled: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profiles = profiles
        self.candidates = candidates
        self.journal = journal
        self.policy = policy
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
        guard isEnabled() else { throw SpeakerVoiceprintServiceError.disabled }
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
        var profile = profile
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
            profile.updatedAt = now()
            try profiles.save(profile)
            return .addedExemplar(profile)
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
        guard var profile = try profiles.profile(id: suggestion.profileId) else { return }

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

        try profiles.save(
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
            )
        )

        // A profile born of one enrollment cannot amplify itself on its own
        // suggestion: two manual enrollments must anchor the voice first. The
        // one-sample-per-recording rule is the store's. A short match can be
        // confirmed, but it cannot bypass the minimum duration for learning.
        let exemplars = try profiles.exemplars(profileId: profile.id)
        if let observation,
            observation.speechSeconds >= policy.minSpeechSecondsToEnroll,
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

        profile.lastMatchedAt = now()
        profile.updatedAt = now()
        try profiles.save(profile)
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
            guard var profile = try profiles.profile(id: profileId) else { continue }
            profile.lastEvaluatedAt = evaluation.date
            profile.lastEvaluatedDistance = evaluation.distance
            try profiles.save(profile)
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
