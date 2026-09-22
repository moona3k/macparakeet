import CryptoKit
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
        guard correctionsApplied else { return automaticTranscription }
        let automaticWords = automaticTranscription.wordTimestamps ?? []
        let automaticSpeakers = automaticTranscription.speakers ?? []
        let automaticDiarization = automaticTranscription.diarizationSegments ?? []
        guard
            attribution.hasTextCorrections
                || attribution.words != automaticWords
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
        if attribution.hasTextCorrections {
            result.cleanTranscript = attribution.editableSegments
                .map(\.text)
                .joined(separator: " ")
            result.transcriptSegments = materializedTextCorrectedSegments()
        } else {
            result.transcriptSegments = materializedDurableSegments()
        }
        return result
    }

    private func materializedTextCorrectedSegments() -> [TranscriptSegmentRecord] {
        let labelsByID = Dictionary(
            attribution.speakers.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        return attribution.editableSegments.map { segment in
            let speakerID: String?
            let speakerLabel: String
            switch segment.assignment {
            case .speaker(let id):
                speakerID = id
                speakerLabel = labelsByID[id] ?? id
            case .unassigned:
                speakerID = nil
                speakerLabel = "Unassigned"
            }
            let keepsDurableIdentity =
                segment.anchorTranscriptSegmentIDs.count == 1
                && automaticTranscription.transcriptSegments?.first(where: {
                    $0.id == segment.anchorTranscriptSegmentIDs[0]
                })?.wordRange == segment.wordRange
            return TranscriptSegmentRecord(
                id: keepsDurableIdentity
                    ? segment.anchorTranscriptSegmentIDs[0]
                    : effectiveSegmentID(for: segment.id),
                startMs: segment.startMs,
                endMs: segment.endMs,
                speakerId: speakerID,
                speakerLabel: speakerLabel,
                text: segment.text,
                wordRange: segment.wordRange,
                isTextEdited: segment.isTextEdited ? true : nil,
                anchorTranscriptSegmentIDs: keepsDurableIdentity
                    ? nil
                    : segment.anchorTranscriptSegmentIDs
            )
        }
    }

    private func effectiveSegmentID(for id: SpeakerEditableSegmentID) -> UUID {
        let input = "\(id.transcriptionId.uuidString.lowercased()):\(id.transcriptFingerprint.rawValue):\(id.wordRange.startIndex):\(id.wordRange.endIndexExclusive)"
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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

    /// Returns effective content without building the full timed-display
    /// projection when no correction branch is active.
    public func effectiveTranscription(for transcription: Transcription) throws -> Transcription {
        try dbQueue.read { db in
            try Self.effectiveTranscription(transcription: transcription, in: db)
        }
    }

    static func effectiveTranscription(
        transcription: Transcription,
        in db: Database
    ) throws -> Transcription {
        guard let state = try SpeakerCorrectionRepository.fetchState(
            transcriptionId: transcription.id,
            in: db
        ), state.headId != nil else {
            return transcription
        }
        return try resolve(transcription: transcription, in: db).effectiveTranscription
    }

    static func resolve(
        transcription: Transcription,
        in db: Database
    ) throws -> SpeakerAttributionProjection {
        let state = try SpeakerCorrectionRepository.fetchState(
            transcriptionId: transcription.id,
            in: db
        )
        guard let state,
              state.transcriptFingerprint == SpeakerAttributionResolver.fingerprint(for: transcription).rawValue
        else {
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
