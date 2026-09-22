import Foundation
import GRDB

/// A voice held briefly so the user can still enroll it after the fact.
///
/// The pipeline computes one vector per detected speaker, uses it for scoring,
/// and drops it. But naming happens later — often the next day — and by then
/// there is nothing left to remember. These rows close that gap without
/// becoming an archive: they are written only while `rememberSpeakers` is on,
/// never compared against each other, and they expire.
public struct SpeakerEmbeddingCandidate: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var transcriptionId: UUID
    /// Positional ("S1", "system:S1"), hence the fingerprint alongside it.
    public var speakerId: String
    public var transcriptFingerprint: String
    /// 1024 bytes of little-endian Float32, same shape as an exemplar's.
    public var vector: Data
    public var speechSeconds: Double
    public var captureDomain: SpeakerCaptureDomain
    public var embeddingModelId: String
    public var aggregationProfileId: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        speakerId: String,
        transcriptFingerprint: String,
        embedding: SpeakerEmbedding,
        speechSeconds: Double,
        captureDomain: SpeakerCaptureDomain,
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.speakerId = speakerId
        self.transcriptFingerprint = transcriptFingerprint
        self.vector = embedding.data
        self.speechSeconds = speechSeconds
        self.captureDomain = captureDomain
        self.embeddingModelId = embedding.identity.embeddingModelId
        self.aggregationProfileId = embedding.identity.aggregationProfileId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var identity: SpeakerModelIdentity {
        SpeakerModelIdentity(
            embeddingModelId: embeddingModelId,
            aggregationProfileId: aggregationProfileId
        )
    }

    /// `nil` when the blob no longer satisfies the embedding invariants, in
    /// which case this candidate cannot be enrolled.
    public var observation: SpeakerClusterObservation? {
        guard let embedding = SpeakerEmbedding(data: vector, identity: identity) else {
            return nil
        }
        return SpeakerClusterObservation(
            speakerId: speakerId,
            embedding: embedding,
            speechSeconds: speechSeconds,
            captureDomain: captureDomain
        )
    }
}

extension SpeakerEmbeddingCandidate: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_embedding_candidates"
}
