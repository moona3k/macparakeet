import Foundation
import GRDB

/// Refusals the store raises to keep a profile's samples comparable.
public enum SpeakerProfileStoreError: Error, Equatable {
    /// The exemplar was produced by a different embedding model than the
    /// profile it targets, so matching could never score it.
    case incompatibleEmbeddingModel(profile: String, exemplar: String)
    /// A profile's embedding model cannot change while it holds samples in the
    /// old one. Re-enrollment creates fresh samples instead.
    case embeddingModelChangeWithExemplars(UUID)
    /// A name that normalizes to nothing has no lookup key, so it could neither
    /// be found again nor keep a second blank name from colliding with it.
    case emptyDisplayName
    /// A replacement may contain only pending links for its requested scope.
    case invalidSuggestionScope
    /// A decision the user already made is not overwritten by a fresh
    /// suggestion.
    case terminalDecisionAlreadyRecorded(status: SpeakerProfileLink.Status)
    /// Another profile already holds this name. Raised instead of letting the
    /// unique index surface a raw `DatabaseError`, so a caller racing another
    /// enrollment of the same name can add a sample to the winner instead.
    case nameAlreadyTaken(normalizedName: String)
}

/// What the store did with a sample offered under a cap.
public enum SpeakerExemplarInsertion: Sendable, Equatable {
    case inserted
    /// The cap was reached, so this sample replaced the evicted one.
    case insertedEvicting(UUID)
    /// The cap is reached and nothing may be evicted.
    case rejectedProfileFull
    /// The profile already holds a sample from this recording.
    case rejectedAlreadySampled
}

public protocol SpeakerProfileRepositoryProtocol: Sendable {
    func profiles() throws -> [SpeakerProfile]
    func profile(id: UUID) throws -> SpeakerProfile?
    /// Case-insensitive; what enrollment uses to choose between adding a sample
    /// and creating a profile.
    func profile(named name: String) throws -> SpeakerProfile?
    /// Creates a profile, claiming its name in the same transaction. Use this
    /// rather than `save` for a new profile: a lookup followed by `save` lets
    /// two concurrent enrollments of one name both find nothing.
    func insert(_ profile: SpeakerProfile) throws
    /// Creates a profile and its first sample together. A racing enrollment of
    /// the same name must not be able to observe an empty profile and skip the
    /// pollution guard. Failures and cap refusals leave no row.
    func insert(
        _ profile: SpeakerProfile,
        firstExemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin
    ) throws -> SpeakerExemplarInsertion
    /// Updates an existing profile; a stale write cannot recreate a deleted one.
    func save(_ profile: SpeakerProfile) throws
    func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar]
    /// One read for a whole matching pass.
    func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]]
    func insert(_ exemplar: SpeakerProfileExemplar) throws
    /// Enforces the sample cap in the same transaction as the insert, evicting
    /// the oldest sample of `evicting` to make room. Checking the count from
    /// outside cannot hold the cap: two callers both read a count below it and
    /// both insert.
    func insertExemplar(
        _ exemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin
    ) throws -> SpeakerExemplarInsertion
    func deleteExemplar(id: UUID) throws -> Bool
    /// Ownership, the last-sample rule and the delete in one write.
    func deleteExemplar(id: UUID, profileId: UUID, keepingAtLeastOne: Bool) throws -> Bool
    /// Rows from an earlier fingerprint are deliberately invisible here.
    func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink]
    func save(_ link: SpeakerProfileLink) throws
    /// Replaces pending offers for one run atomically, preserving terminal choices.
    /// Returns the offers still allowed after checking current terminal decisions.
    func replaceSuggestions(
        transcriptionId: UUID, fingerprint: String, with links: [SpeakerProfileLink]
    ) throws -> [SpeakerProfileLink]
    /// Removes a profile with its samples and decisions in one transaction.
    /// Transcripts and labels already applied are untouched.
    /// Recordings where this voice was accepted — what "recognized in N
    /// recordings" counts. Suggestions and refusals are excluded.
    func confirmedLinkCount(profileId: UUID) throws -> Int
    func deleteProfile(id: UUID) throws -> Bool
    func deleteAllProfiles() throws
}

/// Stores enrolled voices. Persistence only — thresholds and matching policy
/// live in the matcher.
public final class SpeakerProfileRepository: SpeakerProfileRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: Profiles

    public func profiles() throws -> [SpeakerProfile] {
        try dbQueue.read { db in
            try SpeakerProfile
                .order(Column("displayName").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func profile(id: UUID) throws -> SpeakerProfile? {
        try dbQueue.read { db in
            try SpeakerProfile.fetchOne(db, key: id)
        }
    }

    /// Queries the stored normalized key, the same one the unique index uses.
    /// A collation here instead would let lookup and constraint disagree:
    /// `NOCASE` folds only ASCII, so two rows a Unicode-aware lookup considers
    /// equal could both exist and `fetchOne` would pick arbitrarily.
    public func profile(named name: String) throws -> SpeakerProfile? {
        let key = SpeakerProfile.normalizedName(for: name)
        return try dbQueue.read { db in
            try SpeakerProfile.filter(Column("normalizedName") == key).fetchOne(db)
        }
    }

    /// Claims the name in the transaction that creates the profile. A caller
    /// that looks the name up first and then saves leaves a window where two
    /// enrollments of "Sarah" both find nothing; the unique index would then
    /// fail the loser with a raw `DatabaseError` instead of a refusal it can
    /// act on.
    public func insert(_ profile: SpeakerProfile) throws {
        let profile = try normalized(profile)
        try dbQueue.write { db in
            try claimAndInsert(profile, db: db)
        }
    }

    /// Profile and first sample commit together, or neither does. Returning a
    /// cap refusal from inside `write` would still commit the empty profile,
    /// so a refused first sample deletes that row before the transaction ends.
    public func insert(
        _ profile: SpeakerProfile,
        firstExemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin
    ) throws -> SpeakerExemplarInsertion {
        let profile = try normalized(profile)
        return try dbQueue.write { db in
            try claimAndInsert(profile, db: db)
            let result = try insertCappedExemplar(
                firstExemplar, maxPerProfile: maxPerProfile, evicting: evicting, db: db
            )
            switch result {
            case .inserted, .insertedEvicting:
                return result
            case .rejectedAlreadySampled, .rejectedProfileFull:
                _ = try SpeakerProfile.deleteOne(db, key: profile.id)
                return result
            }
        }
    }

    private func claimAndInsert(_ profile: SpeakerProfile, db: Database) throws {
        if try SpeakerProfile
            .filter(Column("normalizedName") == profile.normalizedName)
            .fetchCount(db) > 0
        {
            throw SpeakerProfileStoreError.nameAlreadyTaken(
                normalizedName: profile.normalizedName
            )
        }
        try profile.insert(db)
    }

    /// Recomputes the normalized key before writing: `displayName` is mutable,
    /// so a rename would otherwise leave the old key enforcing uniqueness while
    /// a lookup by the new name found nothing.
    ///
    /// Throws when the embedding model changes on a profile that already holds
    /// samples: those samples would stay in the old representation and become
    /// unscoreable, leaving a profile that looks populated and matches nothing.
    public func save(_ profile: SpeakerProfile) throws {
        let profile = try normalized(profile)
        try dbQueue.write { db in
            if let existing = try SpeakerProfile.fetchOne(db, key: profile.id),
                existing.embeddingModelId != profile.embeddingModelId,
                try SpeakerProfileExemplar
                    .filter(Column("profileId") == profile.id)
                    .fetchCount(db) > 0
            {
                throw SpeakerProfileStoreError.embeddingModelChangeWithExemplars(profile.id)
            }
            try profile.update(db)
        }
    }

    private func normalized(_ profile: SpeakerProfile) throws -> SpeakerProfile {
        var profile = profile
        profile.displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.normalizedName = SpeakerProfile.normalizedName(for: profile.displayName)
        guard !profile.normalizedName.isEmpty else {
            throw SpeakerProfileStoreError.emptyDisplayName
        }
        return profile
    }

    // MARK: Exemplars

    public func exemplars(profileId: UUID) throws -> [SpeakerProfileExemplar] {
        try dbQueue.read { db in
            try SpeakerProfileExemplar
                .filter(Column("profileId") == profileId)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// One read for a whole matching pass rather than one per profile.
    public func exemplarsByProfile() throws -> [UUID: [SpeakerProfileExemplar]] {
        let all = try dbQueue.read { db in
            try SpeakerProfileExemplar.order(Column("createdAt")).fetchAll(db)
        }
        return Dictionary(grouping: all, by: \.profileId)
    }

    /// Throws when the exemplar comes from a different embedding model than its
    /// profile. Vectors from two models share no space, so such a sample would
    /// be stored, counted and shown to the user while never scoring against
    /// anything — a ghost with no signal to reveal it.
    ///
    /// A differing aggregation profile is accepted: that stays comparable, at a
    /// tightened threshold the matcher applies.
    public func insert(_ exemplar: SpeakerProfileExemplar) throws {
        try dbQueue.write { db in
            if let profile = try SpeakerProfile.fetchOne(db, key: exemplar.profileId),
                profile.embeddingModelId != exemplar.embeddingModelId
            {
                throw SpeakerProfileStoreError.incompatibleEmbeddingModel(
                    profile: profile.embeddingModelId,
                    exemplar: exemplar.embeddingModelId
                )
            }
            try insertExemplarRecord(exemplar, db: db)
        }
    }

    /// Count, eviction and insert in one transaction, so the cap holds under
    /// concurrent enrollments. The caller owns the policy — how many, and which
    /// origin may be evicted — while the store owns the atomicity.
    ///
    /// `rejectedAlreadySampled` comes from the existing-row read inside the
    /// same write transaction; the schema also enforces uniqueness.
    public func insertExemplar(
        _ exemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin
    ) throws -> SpeakerExemplarInsertion {
        try dbQueue.write { db in
            try insertCappedExemplar(
                exemplar, maxPerProfile: maxPerProfile, evicting: evicting, db: db
            )
        }
    }

    /// Zero refuses without touching stored samples. A reduced cap that the
    /// profile already exceeds also refuses: shrinking the policy must not
    /// silently delete several user samples to make room for one more. At the
    /// exact cap, one eligible sample is evicted as before.
    private func insertCappedExemplar(
        _ exemplar: SpeakerProfileExemplar,
        maxPerProfile: Int,
        evicting: SpeakerProfileExemplar.Origin,
        db: Database
    ) throws -> SpeakerExemplarInsertion {
        if let profile = try SpeakerProfile.fetchOne(db, key: exemplar.profileId),
            profile.embeddingModelId != exemplar.embeddingModelId
        {
            throw SpeakerProfileStoreError.incompatibleEmbeddingModel(
                profile: profile.embeddingModelId,
                exemplar: exemplar.embeddingModelId
            )
        }

        let existing =
            try SpeakerProfileExemplar
            .filter(Column("profileId") == exemplar.profileId)
            .order(Column("createdAt"))
            .fetchAll(db)
        if let sampled = exemplar.sourceTranscriptionId,
            existing.contains(where: { $0.sourceTranscriptionId == sampled })
        {
            return .rejectedAlreadySampled
        }

        let cap = max(0, maxPerProfile)
        if cap == 0 || existing.count > cap {
            return .rejectedProfileFull
        }

        var evicted: UUID?
        if existing.count == cap {
            guard let target = existing.first(where: { $0.origin == evicting }) else {
                return .rejectedProfileFull
            }
            _ = try SpeakerProfileExemplar.deleteOne(db, key: target.id)
            evicted = target.id
        }

        try insertExemplarRecord(exemplar, db: db)
        return evicted.map { .insertedEvicting($0) } ?? .inserted
    }

    private func insertExemplarRecord(_ exemplar: SpeakerProfileExemplar, db: Database) throws {
        guard let sourceId = exemplar.sourceTranscriptionId else {
            try exemplar.insert(db)
            return
        }
        try SpeakerTranscriptionRecord(
            record: exemplar, column: "sourceTranscriptionId",
            transcriptionKey: SpeakerTranscriptionPersistence.key(sourceId, in: db)
        ).insert(db)
    }

    /// Ownership, the last-sample rule and the delete in one write.
    ///
    /// Checking the count outside cannot hold the rule — two callers both see
    /// more than one and both delete — and deleting by id alone would let a
    /// mismatched id take another profile's final sample.
    public func deleteExemplar(id: UUID, profileId: UUID, keepingAtLeastOne: Bool) throws -> Bool {
        try dbQueue.write { db in
            let owned = try SpeakerProfileExemplar
                .filter(Column("profileId") == profileId)
                .fetchAll(db)
            guard owned.contains(where: { $0.id == id }) else { return false }
            if keepingAtLeastOne, owned.count <= 1 { return false }
            return try SpeakerProfileExemplar.deleteOne(db, key: id)
        }
    }

    public func deleteExemplar(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try SpeakerProfileExemplar.deleteOne(db, key: id)
        }
    }

    // MARK: Links

    public func links(transcriptionId: UUID, fingerprint: String) throws -> [SpeakerProfileLink] {
        try dbQueue.read { db in
            let key = try SpeakerTranscriptionPersistence.key(transcriptionId, in: db)
            return
                try SpeakerProfileLink
                .filter(Column("transcriptionId") == key)
                .filter(Column("transcriptFingerprint") == fingerprint)
                .fetchAll(db)
        }
    }

    /// Upserts a decision, keeping the original `createdAt`: status moves from
    /// suggested to confirmed or dismissed, and each caller builds a fresh
    /// value, so otherwise the offer time is overwritten by the answer time.
    public func save(_ link: SpeakerProfileLink) throws {
        try dbQueue.write { db in
            var link = link
            let key = try SpeakerTranscriptionPersistence.key(link.transcriptionId, in: db)
            let existing =
                try SpeakerProfileLink
                .filter(Column("transcriptionId") == key)
                .filter(Column("speakerId") == link.speakerId)
                .filter(Column("transcriptFingerprint") == link.transcriptFingerprint)
                .fetchOne(db)
            if let existing {
                // A suggestion may become confirmed or dismissed. A terminal
                // choice does not flip, and it does not move to another profile:
                // repeating the same status and profile is the only no-op.
                if existing.status != .suggested {
                    let sameChoice =
                        existing.status == link.status && existing.profileId == link.profileId
                    guard sameChoice else {
                        throw SpeakerProfileStoreError.terminalDecisionAlreadyRecorded(
                            status: existing.status
                        )
                    }
                }
                link.createdAt = existing.createdAt
            }
            try SpeakerTranscriptionRecord(
                record: link, column: "transcriptionId", transcriptionKey: key
            ).save(db)
        }
    }

    public func replaceSuggestions(
        transcriptionId: UUID, fingerprint: String, with links: [SpeakerProfileLink]
    ) throws -> [SpeakerProfileLink] {
        guard
            links.allSatisfy({
                $0.status == .suggested && $0.transcriptionId == transcriptionId
                    && $0.transcriptFingerprint == fingerprint
            })
        else {
            throw SpeakerProfileStoreError.invalidSuggestionScope
        }
        return try dbQueue.write { db in
            let key = try SpeakerTranscriptionPersistence.key(transcriptionId, in: db)
            let scope =
                SpeakerProfileLink
                .filter(Column("transcriptionId") == key)
                .filter(Column("transcriptFingerprint") == fingerprint)
            let existing = try scope.fetchAll(db)
            let terminalSpeakers = Set(existing.filter { $0.status != .suggested }.map(\.speakerId))
            let reservedProfiles = Set(existing.filter { $0.status == .confirmed }.map(\.profileId))
            let originalDates = Dictionary(uniqueKeysWithValues: existing.map { ($0.speakerId, $0.createdAt) })
            try scope.filter(Column("status") == SpeakerProfileLink.Status.suggested.rawValue).deleteAll(db)

            var stored: [SpeakerProfileLink] = []
            for var link in links {
                // Recheck inside this write: a user may have answered while the
                // matcher was scoring. Never replace that answer or its name.
                guard !terminalSpeakers.contains(link.speakerId), !reservedProfiles.contains(link.profileId) else {
                    continue
                }
                link.createdAt = originalDates[link.speakerId] ?? link.createdAt
                try SpeakerTranscriptionRecord(
                    record: link, column: "transcriptionId", transcriptionKey: key
                ).insert(db)
                stored.append(link)
            }
            return stored
        }
    }

    // MARK: Deletion

    /// Exemplars and links go with it through their cascades; transcripts and
    /// any label already applied are untouched.
    /// Distinct recordings, not rows: links are fingerprint-scoped, so one
    /// transcription re-diarized and re-confirmed holds several rows for the
    /// same profile and would inflate "recognized in N recordings".
    public func confirmedLinkCount(profileId: UUID) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT transcriptionId) FROM speaker_profile_links
                    WHERE profileId = ? AND status = ?
                    """,
                arguments: [profileId, SpeakerProfileLink.Status.confirmed.rawValue]
            ) ?? 0
        }
    }

    public func deleteProfile(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try SpeakerProfile.deleteOne(db, key: id)
        }
    }

    public func deleteAllProfiles() throws {
        try dbQueue.write { db in
            // Candidates and unmatched decisions have no profile foreign key.
            // The explicit global delete must remove these too, atomically.
            _ = try SpeakerEmbeddingCandidate.deleteAll(db)
            _ = try SpeakerMatchJournalEntry.deleteAll(db)
            _ = try SpeakerProfile.deleteAll(db)
        }
    }
}
