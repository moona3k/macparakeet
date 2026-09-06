import Foundation
import GRDB

/// Database-backed read model for the automatic transcript plus its active
/// speaker-correction branch. Renderers consume `effectiveTranscription`
/// without learning how correction history is stored.
public struct SpeakerAttributionProjection: Sendable {
    public let automaticTranscription: Transcription
    public let attribution: EffectiveSpeakerAttribution
    public let correctionsApplied: Bool
    public let canUndo: Bool
    public let canRedo: Bool

    public init(
        automaticTranscription: Transcription,
        attribution: EffectiveSpeakerAttribution,
        correctionsApplied: Bool,
        canUndo: Bool = false,
        canRedo: Bool = false
    ) {
        self.automaticTranscription = automaticTranscription
        self.attribution = attribution
        self.correctionsApplied = correctionsApplied
        self.canUndo = canUndo
        self.canRedo = canRedo
    }

    public var correctionRevision: Int { attribution.correctionRevision }

    /// A transient, effective view. The automatic `Transcription` row remains
    /// immutable; callers must never save this materialized copy as canonical
    /// diarization output.
    public var effectiveTranscription: Transcription {
        let automaticWords = automaticTranscription.wordTimestamps ?? []
        let automaticSpeakers = automaticTranscription.speakers ?? []
        let automaticDiarization = automaticTranscription.diarizationSegments ?? []
        guard
            attribution.words != automaticWords
                || attribution.speakers != automaticSpeakers
                || attribution.diarizationSegments != automaticDiarization
        else {
            return automaticTranscription
        }

        var result = automaticTranscription
        result.speakers = attribution.speakers
        result.speakerCount = attribution.speakers.count
        result.wordTimestamps = attribution.words
        result.diarizationSegments = attribution.diarizationSegments
        result.transcriptSegments = materializedDurableSegments()
        return result
    }

    private func materializedDurableSegments() -> [TranscriptSegmentRecord]? {
        guard automaticTranscription.transcriptSegments != nil else { return nil }
        let labelsByID = Dictionary(
            attribution.speakers.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )

        return attribution.durableSegments.map { effective in
            var segment = effective.base
            guard effective.speakerRuns.count == 1,
                let run = effective.speakerRuns.first
            else {
                segment.speakerId = nil
                segment.speakerLabel = "Multiple speakers"
                return segment
            }

            switch run.assignment {
            case .speaker(let id):
                segment.speakerId = id
                segment.speakerLabel = labelsByID[id] ?? id
            case .unassigned:
                segment.speakerId = nil
                segment.speakerLabel = "Unassigned"
            }
            return segment
        }
    }
}

public protocol SpeakerAttributionReading: Sendable {
    func resolve(transcriptionId: UUID) throws -> SpeakerAttributionProjection?
    func resolve(transcription: Transcription) throws -> SpeakerAttributionProjection
}

/// Resolves correction state once at a database boundary. The `Database`
/// overload lets transactional services reuse the same read path without a
/// nested `DatabaseQueue.read`.
public final class SpeakerAttributionReadService: SpeakerAttributionReading,
    @unchecked Sendable
{
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func resolve(transcriptionId: UUID) throws -> SpeakerAttributionProjection? {
        try dbQueue.read { db in
            guard let transcription = try Transcription.fetchOne(db, key: transcriptionId) else {
                return nil
            }
            return try Self.resolve(transcription: transcription, in: db)
        }
    }

    public func resolve(transcription: Transcription) throws -> SpeakerAttributionProjection {
        try dbQueue.read { db in
            try Self.resolve(transcription: transcription, in: db)
        }
    }

    static func resolve(
        transcription: Transcription,
        in db: Database
    ) throws -> SpeakerAttributionProjection {
        let state = try SpeakerCorrectionRepository.fetchState(
            transcriptionId: transcription.id,
            in: db
        )
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        guard let state, state.transcriptFingerprint == fingerprint.rawValue else {
            return SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: SpeakerAttributionResolver.resolve(transcription: transcription),
                correctionsApplied: false
            )
        }
        let history = try SpeakerCorrectionRepository.fetchHistory(
            transcriptionId: transcription.id,
            fingerprint: state.transcriptFingerprint,
            in: db
        )
        let attribution = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: history,
            state: state
        )
        let canRedo =
            try SpeakerCorrectionRepository.redoChild(
                transcriptionId: transcription.id,
                fingerprint: state.transcriptFingerprint,
                parentId: state.headId,
                in: db
            ) != nil
        return SpeakerAttributionProjection(
            automaticTranscription: transcription,
            attribution: attribution,
            correctionsApplied: state.headId != nil,
            canUndo: state.headId != nil,
            canRedo: canRedo
        )
    }
}
