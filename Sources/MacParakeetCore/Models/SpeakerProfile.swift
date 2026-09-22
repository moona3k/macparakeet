import Foundation
import GRDB

/// A voice the user has explicitly enrolled.
///
/// No centroid column: scoring takes the minimum distance over the exemplars,
/// which preserves per-domain modes, so an aggregate would be an unused cache.
public struct SpeakerProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// As the user typed it. Display only — never compared directly.
    public var displayName: String
    /// The key both uniqueness and lookup use, so the database constraint and
    /// the Swift lookup cannot disagree on what counts as the same name.
    public var normalizedName: String
    public var embeddingModelId: String
    public var aggregationProfileId: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastMatchedAt: Date?
    /// Scored at all, matched or not: what answers "why does this profile never
    /// match?" with a number.
    public var lastEvaluatedAt: Date?
    public var lastEvaluatedDistance: Double?

    public init(
        id: UUID = UUID(),
        displayName: String,
        identity: SpeakerModelIdentity,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMatchedAt: Date? = nil,
        lastEvaluatedAt: Date? = nil,
        lastEvaluatedDistance: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.normalizedName = Self.normalizedName(for: displayName)
        self.embeddingModelId = identity.embeddingModelId
        self.aggregationProfileId = identity.aggregationProfileId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMatchedAt = lastMatchedAt
        self.lastEvaluatedAt = lastEvaluatedAt
        self.lastEvaluatedDistance = lastEvaluatedDistance
    }

    public var identity: SpeakerModelIdentity {
        SpeakerModelIdentity(
            embeddingModelId: embeddingModelId,
            aggregationProfileId: aggregationProfileId
        )
    }

    /// Trimmed, then case-folded across all of Unicode. Accents are kept:
    /// folding them would decide that "Jose" and "José" are one person, which
    /// is a guess about identity, not typography.
    public static func normalizedName(for displayName: String) -> String {
        displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}

extension SpeakerProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_profiles"
}

/// One recording's worth of voice evidence for a profile.
///
/// At most one per profile per recording, enforced by the schema: segment
/// embeddings within a recording all derive from the same centroid, so several
/// would inflate the sample count without adding diversity.
public struct SpeakerProfileExemplar: Codable, Identifiable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        /// The user named this speaker themselves.
        case manualEnrollment
        /// The user confirmed a suggestion, which also improves the profile.
        case confirmedSuggestion
    }

    public var id: UUID
    public var profileId: UUID
    /// 1024 bytes of little-endian Float32. A blob rather than JSON so SQLite
    /// validates the length and an accidental serialization stays opaque.
    public var vector: Data
    public var speechSeconds: Double
    public var captureDomain: SpeakerCaptureDomain
    public var origin: Origin
    public var embeddingModelId: String
    public var aggregationProfileId: String
    /// Cleared rather than cascaded: the user enrolled a person, not a
    /// recording, so tidying the library must not degrade a profile.
    public var sourceTranscriptionId: UUID?
    public var sourceSpeakerId: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        profileId: UUID,
        embedding: SpeakerEmbedding,
        speechSeconds: Double,
        captureDomain: SpeakerCaptureDomain,
        origin: Origin,
        sourceTranscriptionId: UUID? = nil,
        sourceSpeakerId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.vector = embedding.data
        self.speechSeconds = speechSeconds
        self.captureDomain = captureDomain
        self.origin = origin
        self.embeddingModelId = embedding.identity.embeddingModelId
        self.aggregationProfileId = embedding.identity.aggregationProfileId
        self.sourceTranscriptionId = sourceTranscriptionId
        self.sourceSpeakerId = sourceSpeakerId
        self.createdAt = createdAt
    }

    public var identity: SpeakerModelIdentity {
        SpeakerModelIdentity(
            embeddingModelId: embeddingModelId,
            aggregationProfileId: aggregationProfileId
        )
    }

    /// `nil` when the blob no longer satisfies the embedding invariants, in
    /// which case this exemplar cannot take part in matching.
    public var embedding: SpeakerEmbedding? {
        SpeakerEmbedding(data: vector, identity: identity)
    }
}

extension SpeakerProfileExemplar: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_profile_exemplars"
}

/// What was decided about one detected speaker in one transcript.
///
/// Carries no label — that lives in `speaker_corrections` with provenance and
/// undo. This exists for what that layer cannot express: that a dismissal must
/// not repeat, and that everything disappears with its profile.
public struct SpeakerProfileLink: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case suggested
        case confirmed
        case dismissed
    }

    public var transcriptionId: UUID
    /// Positional ("S1", "system:S1"), which is why rows are fingerprint-scoped:
    /// after re-diarization the same id can mean a different person.
    public var speakerId: String
    public var transcriptFingerprint: String
    public var profileId: UUID
    public var status: Status
    public var distance: Double
    public var runnerUpDistance: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        transcriptionId: UUID,
        speakerId: String,
        transcriptFingerprint: String,
        profileId: UUID,
        status: Status,
        distance: Double,
        runnerUpDistance: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.transcriptionId = transcriptionId
        self.speakerId = speakerId
        self.transcriptFingerprint = transcriptFingerprint
        self.profileId = profileId
        self.status = status
        self.distance = distance
        self.runnerUpDistance = runnerUpDistance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SpeakerProfileLink {
    /// Written when a link records a human decision rather than a score.
    /// Outside the cosine range, so calibration can exclude it instead of
    /// reading a fabricated 0.0 as a perfect match.
    public static let manualDecisionDistance: Double = -1
}

extension SpeakerProfileLink: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_profile_links"
}
