import Foundation
import GRDB

public protocol SpeakerCorrectionServicing: Sendable {
    func apply(
        transcriptionId: UUID,
        command: SpeakerCorrectionCommand,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult

    func undo(
        transcriptionId: UUID,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult

    func redo(
        transcriptionId: UUID,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult
}

public struct SpeakerCorrectionResult: Sendable, Equatable {
    public let attribution: EffectiveSpeakerAttribution
    public let revision: Int
    public let canUndo: Bool
    public let canRedo: Bool

    public init(
        attribution: EffectiveSpeakerAttribution,
        revision: Int,
        canUndo: Bool,
        canRedo: Bool
    ) {
        self.attribution = attribution
        self.revision = revision
        self.canUndo = canUndo
        self.canRedo = canRedo
    }
}

public enum SpeakerCorrectionServiceError: Error, Equatable, Sendable {
    case transcriptionNotFound
    case transcriptionIncomplete
    case timingsRequired
    case durableSegmentsRequired
    case conflict
    case invalidCommand(UnresolvedSpeakerCorrectionReason)
    case malformedHistory
    case nothingToUndo
    case nothingToRedo
}

/// Commits one speaker-management action together with every database-derived
/// read model. File artifacts are intentionally refreshed only after this
/// transaction returns successfully.
public final class SpeakerCorrectionService: SpeakerCorrectionServicing, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Date

    public init(
        dbQueue: DatabaseQueue,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dbQueue = dbQueue
        self.now = now
    }

    public func apply(
        transcriptionId: UUID,
        command: SpeakerCorrectionCommand,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult {
        let now = now()
        return try await dbQueue.write { db in
            let context = try Self.loadContext(
                transcriptionId: transcriptionId,
                expectedFingerprint: expectedFingerprint,
                expectedRevision: expectedRevision,
                versionMismatch: .resetForApply,
                now: now,
                in: db
            )
            let correction = SpeakerCorrection(
                transcriptionId: transcriptionId,
                parentId: context.state.headId,
                sequence: try SpeakerCorrectionRepository.nextSequence(
                    transcriptionId: transcriptionId,
                    in: db
                ),
                transcriptFingerprint: context.fingerprint,
                payload: command,
                createdAt: now
            )

            let candidateHistory = context.history + [correction]
            let candidateState = SpeakerCorrectionState(
                transcriptionId: transcriptionId,
                transcriptFingerprint: context.fingerprint.rawValue,
                headId: correction.id,
                revision: context.state.revision + 1,
                updatedAt: now
            )
            let effective = SpeakerAttributionResolver.resolve(
                transcription: context.transcription,
                corrections: candidateHistory,
                state: candidateState
            )
            if let rejection = effective.unresolvedCorrections.first(where: {
                $0.correctionID == correction.id
            }) {
                throw SpeakerCorrectionServiceError.invalidCommand(rejection.reason)
            }

            try SpeakerCorrectionRepository.abandonRedoBranch(
                transcriptionId: transcriptionId,
                fingerprint: context.fingerprint.rawValue,
                in: db
            )
            try SpeakerCorrectionRepository.insert(correction, in: db)
            let state = try SpeakerCorrectionRepository.updateState(
                transcriptionId: transcriptionId,
                fingerprint: context.fingerprint.rawValue,
                headId: correction.id,
                expectedRevision: context.state.revision,
                updatedAt: now,
                in: db
            )
            let derived = KnowledgeSegmenter.deriveSegments(
                for: context.transcription,
                effectiveAttribution: effective
            )
            try KnowledgeLayerMutationService.replaceSegmentsAndInvalidateCard(
                derived,
                transcriptionId: transcriptionId,
                in: db
            )
            return try Self.result(
                transcription: context.transcription,
                history: candidateHistory,
                state: state,
                in: db
            )
        }
    }

    public func undo(
        transcriptionId: UUID,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult {
        let now = now()
        return try await dbQueue.write { db in
            let context = try Self.loadContext(
                transcriptionId: transcriptionId,
                expectedFingerprint: expectedFingerprint,
                expectedRevision: expectedRevision,
                versionMismatch: .fail(.nothingToUndo),
                now: now,
                in: db
            )
            guard let headID = context.state.headId,
                let head = context.history.first(where: { $0.id == headID })
            else {
                throw SpeakerCorrectionServiceError.nothingToUndo
            }
            try SpeakerCorrectionRepository.updateBranchState(
                id: head.id,
                transcriptionId: transcriptionId,
                from: .current,
                to: .redo,
                in: db
            )
            let state = try SpeakerCorrectionRepository.updateState(
                transcriptionId: transcriptionId,
                fingerprint: context.fingerprint.rawValue,
                headId: head.parentId,
                expectedRevision: context.state.revision,
                updatedAt: now,
                in: db
            )
            return try Self.publish(
                transcription: context.transcription,
                state: state,
                in: db
            )
        }
    }

    public func redo(
        transcriptionId: UUID,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult {
        let now = now()
        return try await dbQueue.write { db in
            let context = try Self.loadContext(
                transcriptionId: transcriptionId,
                expectedFingerprint: expectedFingerprint,
                expectedRevision: expectedRevision,
                versionMismatch: .fail(.nothingToRedo),
                now: now,
                in: db
            )
            guard
                let child = try SpeakerCorrectionRepository.redoChild(
                    transcriptionId: transcriptionId,
                    fingerprint: context.fingerprint.rawValue,
                    parentId: context.state.headId,
                    in: db
                )
            else {
                throw SpeakerCorrectionServiceError.nothingToRedo
            }
            try SpeakerCorrectionRepository.updateBranchState(
                id: child.id,
                transcriptionId: transcriptionId,
                from: .redo,
                to: .current,
                in: db
            )
            let state = try SpeakerCorrectionRepository.updateState(
                transcriptionId: transcriptionId,
                fingerprint: context.fingerprint.rawValue,
                headId: child.id,
                expectedRevision: context.state.revision,
                updatedAt: now,
                in: db
            )
            return try Self.publish(
                transcription: context.transcription,
                state: state,
                in: db
            )
        }
    }

    private struct Context {
        let transcription: Transcription
        let fingerprint: TranscriptFingerprint
        let history: [SpeakerCorrection]
        let state: SpeakerCorrectionState
    }

    private enum VersionMismatchBehavior {
        case resetForApply
        case fail(SpeakerCorrectionServiceError)
    }

    private static func loadContext(
        transcriptionId: UUID,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int,
        versionMismatch: VersionMismatchBehavior,
        now: Date,
        in db: Database
    ) throws -> Context {
        guard let transcription = try Transcription.fetchOne(db, key: transcriptionId) else {
            throw SpeakerCorrectionServiceError.transcriptionNotFound
        }
        guard transcription.status == .completed else {
            throw SpeakerCorrectionServiceError.transcriptionIncomplete
        }
        guard !(transcription.wordTimestamps ?? []).isEmpty else {
            throw SpeakerCorrectionServiceError.timingsRequired
        }
        guard !(transcription.transcriptSegments ?? []).isEmpty else {
            throw SpeakerCorrectionServiceError.durableSegmentsRequired
        }
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        guard fingerprint == expectedFingerprint else {
            throw SpeakerCorrectionServiceError.conflict
        }

        let state: SpeakerCorrectionState
        if let stored = try SpeakerCorrectionRepository.fetchState(
            transcriptionId: transcriptionId,
            in: db
        ) {
            if stored.transcriptFingerprint != fingerprint.rawValue {
                switch versionMismatch {
                case .resetForApply:
                    guard expectedRevision == 0 else {
                        throw SpeakerCorrectionServiceError.conflict
                    }
                    state = try SpeakerCorrectionRepository.replaceStateForNewFingerprint(
                        transcriptionId: transcriptionId,
                        oldFingerprint: stored.transcriptFingerprint,
                        oldRevision: stored.revision,
                        newFingerprint: fingerprint.rawValue,
                        updatedAt: now,
                        in: db
                    )
                case .fail(let error):
                    throw error
                }
            } else {
                guard stored.revision == expectedRevision else {
                    throw SpeakerCorrectionServiceError.conflict
                }
                state = stored
            }
        } else {
            guard expectedRevision == 0 else {
                throw SpeakerCorrectionServiceError.conflict
            }
            state = SpeakerCorrectionState(
                transcriptionId: transcriptionId,
                transcriptFingerprint: fingerprint.rawValue,
                headId: nil,
                revision: 0,
                updatedAt: now
            )
            try SpeakerCorrectionRepository.insertState(state, in: db)
        }
        let history = try SpeakerCorrectionRepository.fetchHistory(
            transcriptionId: transcriptionId,
            fingerprint: fingerprint.rawValue,
            in: db
        )
        let current = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: history,
            state: state
        )
        guard current.unresolvedCorrections.isEmpty else {
            throw SpeakerCorrectionServiceError.malformedHistory
        }
        return Context(
            transcription: transcription,
            fingerprint: fingerprint,
            history: history,
            state: state
        )
    }

    private static func publish(
        transcription: Transcription,
        state: SpeakerCorrectionState,
        in db: Database
    ) throws -> SpeakerCorrectionResult {
        let history = try SpeakerCorrectionRepository.fetchHistory(
            transcriptionId: transcription.id,
            fingerprint: state.transcriptFingerprint,
            in: db
        )
        let effective = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: history,
            state: state
        )
        guard effective.unresolvedCorrections.isEmpty else {
            throw SpeakerCorrectionServiceError.malformedHistory
        }
        let derived = KnowledgeSegmenter.deriveSegments(
            for: transcription,
            effectiveAttribution: effective
        )
        try KnowledgeLayerMutationService.replaceSegmentsAndInvalidateCard(
            derived,
            transcriptionId: transcription.id,
            in: db
        )
        return try result(
            transcription: transcription,
            history: history,
            state: state,
            in: db
        )
    }

    private static func result(
        transcription: Transcription,
        history: [SpeakerCorrection],
        state: SpeakerCorrectionState,
        in db: Database
    ) throws -> SpeakerCorrectionResult {
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
        return SpeakerCorrectionResult(
            attribution: attribution,
            revision: state.revision,
            canUndo: state.headId != nil,
            canRedo: canRedo
        )
    }
}
