import Foundation
import GRDB

// MARK: - Request

/// One user-approved cut into the source audio. No child id: fixed child
/// identities are minted by `MeetingSplitRepository.begin`, never supplied by
/// the caller, so a caller cannot smuggle in an id collision.
public struct MeetingSplitChildRequest: Codable, Sendable, Equatable {
    public var title: String
    public var startMs: Int
    public var endMs: Int

    public init(title: String, startMs: Int, endMs: Int) {
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// The frozen request behind one split operation. Two `begin` calls with the
/// same idempotency key must supply requests that are `==` to be treated as
/// the same operation; anything else is a conflict.
public struct MeetingSplitRequest: Codable, Sendable, Equatable {
    public var sourceId: UUID
    /// Caller-observed media/source identity (e.g. a content hash) captured
    /// at preview/prepare time. The repository stores this for later callers
    /// to compare; it does not itself validate media geometry — that is the
    /// future service's job, alongside the cross-process media lease.
    public var expectedSourceIdentity: String
    /// Ordered cuts, in final part order.
    public var children: [MeetingSplitChildRequest]
    /// New operations freeze their output location; optional for earlier development receipts.
    public var destinationRootPath: String?

    public init(
        sourceId: UUID, expectedSourceIdentity: String, children: [MeetingSplitChildRequest],
        destinationRootPath: String? = nil
    ) {
        self.sourceId = sourceId
        self.expectedSourceIdentity = expectedSourceIdentity
        self.children = children
        self.destinationRootPath = destinationRootPath
    }
}

// MARK: - Operation state

public enum MeetingSplitOperationStatus: String, Codable, Sendable {
    /// Fixed child IDs are persisted; audio/artifact preparation may be under
    /// way or interrupted. May be retried (call `begin` again) or discarded.
    case preparing
    /// All child rows were inserted in one transaction. Permanent; cannot be
    /// discarded or resurrected.
    case committed
    /// Preparation was explicitly abandoned before publication. Permanent.
    case discarded
}

/// The furthest stage a child has reached. Distinct from `outcome`: a stage
/// is not undone by a later failure at the *next* stage, so a summary
/// failure never erases a successful transcript.
public enum MeetingSplitChildStage: String, Codable, Sendable {
    /// Audio was published; first transcription has not started.
    case pendingTranscription
    /// First transcription is running.
    case transcribing
    /// First transcription succeeded (an empty/silent result still counts).
    case transcribed
    /// Enabled completion automation (e.g. summaries) is running.
    case automationPending
    /// Enabled completion automation finished. Terminal success.
    case automationCompleted
}

/// Whether the most recent attempt at the current `stage` succeeded. `.none`
/// while healthy or freshly advanced; `.failed`/`.cancelled` mark that
/// `stage` as the retry point without discarding any earlier stage.
public enum MeetingSplitChildOutcome: String, Codable, Sendable {
    case none
    case failed
    case cancelled
}

public struct MeetingSplitChildProgress: Codable, Sendable, Equatable {
    public var childId: UUID
    public var stage: MeetingSplitChildStage
    public var outcome: MeetingSplitChildOutcome
    public var errorMessage: String?
    public var updatedAt: Date

    public init(
        childId: UUID,
        stage: MeetingSplitChildStage = .pendingTranscription,
        outcome: MeetingSplitChildOutcome = .none,
        errorMessage: String? = nil,
        updatedAt: Date
    ) {
        self.childId = childId
        self.stage = stage
        self.outcome = outcome
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

/// The durable operation receipt. No foreign key to `transcriptions`: this
/// row, and every child id/progress entry inside it, must remain readable
/// after the source or any child is deleted.
public struct MeetingSplitOperation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var idempotencyKey: String
    public var sourceId: UUID
    public var request: MeetingSplitRequest
    /// Fixed child identities, in the same order as `request.children`.
    public var childIds: [UUID]
    public var status: MeetingSplitOperationStatus
    /// One entry per `childIds`, same order.
    public var childProgress: [MeetingSplitChildProgress]
    public var createdAt: Date
    public var updatedAt: Date
}

extension MeetingSplitOperation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_split_operations"

    public enum Columns: String, ColumnExpression {
        case id, idempotencyKey, sourceId, request, childIds, status, childProgress, createdAt, updatedAt
    }
}

// MARK: - Source snapshot

/// A small, coherent snapshot of the source row used to detect concurrent
/// changes at publish time. Deliberately not a full transcript snapshot:
/// text/word/correction changes on the source do not matter because they are
/// never copied into a split child.
public struct MeetingSplitSourceSnapshot: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var filePath: String?
    public var meetingArtifactFolderPath: String?
    public var status: Transcription.TranscriptionStatus
    public var title: String

    public init(
        id: UUID,
        createdAt: Date,
        filePath: String?,
        meetingArtifactFolderPath: String?,
        status: Transcription.TranscriptionStatus,
        title: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.filePath = filePath
        self.meetingArtifactFolderPath = meetingArtifactFolderPath
        self.status = status
        self.title = title
    }

    public init(source: Transcription) {
        self.init(
            id: source.id,
            createdAt: source.createdAt,
            filePath: source.filePath,
            meetingArtifactFolderPath: source.meetingArtifactFolderPath,
            status: source.status,
            title: source.effectiveDisplayTitle
        )
    }
}

// MARK: - Publication input

/// What the service has already written to disk for one fixed child id,
/// before calling `publish`. The repository performs no file I/O; it only
/// inserts the row once this is supplied.
public struct MeetingSplitPreparedChild: Sendable, Equatable {
    public var childId: UUID
    public var filePath: String?
    public var meetingArtifactFolderPath: String?
    public var durationMs: Int?
    public var audioTrackOrdinal: Int?

    public init(
        childId: UUID,
        filePath: String? = nil,
        meetingArtifactFolderPath: String? = nil,
        durationMs: Int? = nil,
        audioTrackOrdinal: Int? = nil
    ) {
        self.childId = childId
        self.filePath = filePath
        self.meetingArtifactFolderPath = meetingArtifactFolderPath
        self.durationMs = durationMs
        self.audioTrackOrdinal = audioTrackOrdinal
    }
}

// MARK: - Errors

public enum MeetingSplitRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case idempotencyKeyConflict(existingOperationId: UUID)
    case operationNotFound
    case operationNotPreparing(current: MeetingSplitOperationStatus)
    case operationNotCommitted(current: MeetingSplitOperationStatus)
    case sourceMissingOrChanged
    case childIdentitySetMismatch
    case unknownChild(UUID)

    public var errorDescription: String? {
        switch self {
        case .idempotencyKeyConflict(let existingOperationId):
            return "A different split request already exists under this idempotency key (operation \(existingOperationId))."
        case .operationNotFound:
            return "No split operation matches the given id."
        case .operationNotPreparing(let current):
            return "This operation is \(current.rawValue), not preparing."
        case .operationNotCommitted(let current):
            return "This operation is \(current.rawValue); child processing progress requires committed audio."
        case .sourceMissingOrChanged:
            return "The source recording is missing or has changed since this split was prepared."
        case .childIdentitySetMismatch:
            return "The prepared children do not match this operation's fixed child identities."
        case .unknownChild(let childId):
            return "Child \(childId) is not part of this split operation."
        }
    }
}

// MARK: - Repository

public protocol MeetingSplitRepositoryProtocol: Sendable {
    /// Returns the existing operation for `idempotencyKey` when its stored
    /// request matches `request`, otherwise persists fresh fixed child ids
    /// and a new `.preparing` operation. Throws `.idempotencyKeyConflict` when
    /// an existing operation under the same key has a different request.
    /// Never requires the source row to exist.
    func begin(idempotencyKey: String, request: MeetingSplitRequest, now: Date) throws -> MeetingSplitOperation

    func operation(id: UUID) throws -> MeetingSplitOperation?
    func operation(idempotencyKey: String) throws -> MeetingSplitOperation?
    /// Every operation recorded against `sourceId`, most recent first. Lets a
    /// caller that lost an in-memory receipt (for example a process that died
    /// before returning the operation id to the user) discover prior
    /// preparing/committed work for a source without inspecting the database
    /// directly.
    func operations(sourceId: UUID) throws -> [MeetingSplitOperation]

    /// A snapshot of the current source row, for later comparison in
    /// `publish`. `nil` when the source no longer exists.
    func sourceSnapshot(sourceId: UUID) throws -> MeetingSplitSourceSnapshot?

    /// Abandons a `.preparing` operation. Throws `.operationNotPreparing` for
    /// any other status: committed operations cannot be undone.
    @discardableResult
    func discard(operationId: UUID, now: Date) throws -> MeetingSplitOperation

    /// One short transaction: revalidates the operation is still preparing
    /// and the source snapshot is unchanged, inserts every child row fresh,
    /// then marks the operation committed. Any failure (mismatch or insert
    /// collision) rolls back everything; the source row is never written.
    func publish(
        operationId: UUID,
        preparedChildren: [MeetingSplitPreparedChild],
        expectedSource: MeetingSplitSourceSnapshot,
        now: Date
    ) throws -> MeetingSplitOperation

    func markChildTranscriptionStarted(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation
    func markChildTranscriptionSucceeded(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation
    func markChildAutomationStarted(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation
    func markChildAutomationSucceeded(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation
    func markChildFailed(operationId: UUID, childId: UUID, errorMessage: String, now: Date) throws -> MeetingSplitOperation
    func markChildCancelled(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation
}

extension MeetingSplitRepositoryProtocol {
    public func begin(idempotencyKey: String, request: MeetingSplitRequest) throws -> MeetingSplitOperation {
        try begin(idempotencyKey: idempotencyKey, request: request, now: Date())
    }

    public func discard(operationId: UUID) throws -> MeetingSplitOperation {
        try discard(operationId: operationId, now: Date())
    }

    public func publish(
        operationId: UUID,
        preparedChildren: [MeetingSplitPreparedChild],
        expectedSource: MeetingSplitSourceSnapshot
    ) throws -> MeetingSplitOperation {
        try publish(operationId: operationId, preparedChildren: preparedChildren, expectedSource: expectedSource, now: Date())
    }
}

public final class MeetingSplitRepository: MeetingSplitRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func begin(idempotencyKey: String, request: MeetingSplitRequest, now: Date = Date()) throws -> MeetingSplitOperation {
        try dbQueue.write { db in
            if let existing = try MeetingSplitOperation
                .filter(MeetingSplitOperation.Columns.idempotencyKey == idempotencyKey)
                .fetchOne(db)
            {
                guard existing.request == request else {
                    throw MeetingSplitRepositoryError.idempotencyKeyConflict(existingOperationId: existing.id)
                }
                return existing
            }

            let childIds = request.children.map { _ in UUID() }
            let operation = MeetingSplitOperation(
                id: UUID(),
                idempotencyKey: idempotencyKey,
                sourceId: request.sourceId,
                request: request,
                childIds: childIds,
                status: .preparing,
                childProgress: childIds.map { MeetingSplitChildProgress(childId: $0, updatedAt: now) },
                createdAt: now,
                updatedAt: now
            )
            try operation.insert(db)
            return operation
        }
    }

    public func operation(id: UUID) throws -> MeetingSplitOperation? {
        try dbQueue.read { db in
            try MeetingSplitOperation.fetchOne(db, key: id)
        }
    }

    public func operation(idempotencyKey: String) throws -> MeetingSplitOperation? {
        try dbQueue.read { db in
            try MeetingSplitOperation
                .filter(MeetingSplitOperation.Columns.idempotencyKey == idempotencyKey)
                .fetchOne(db)
        }
    }

    public func operations(sourceId: UUID) throws -> [MeetingSplitOperation] {
        try dbQueue.read { db in
            try MeetingSplitOperation
                .filter(MeetingSplitOperation.Columns.sourceId == sourceId)
                .order(MeetingSplitOperation.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func sourceSnapshot(sourceId: UUID) throws -> MeetingSplitSourceSnapshot? {
        try dbQueue.read { db in
            guard let source = try Transcription.fetchOne(db, key: sourceId) else { return nil }
            return MeetingSplitSourceSnapshot(source: source)
        }
    }

    @discardableResult
    public func discard(operationId: UUID, now: Date = Date()) throws -> MeetingSplitOperation {
        try dbQueue.write { db in
            guard var operation = try MeetingSplitOperation.fetchOne(db, key: operationId) else {
                throw MeetingSplitRepositoryError.operationNotFound
            }
            guard operation.status == .preparing else {
                throw MeetingSplitRepositoryError.operationNotPreparing(current: operation.status)
            }
            operation.status = .discarded
            operation.updatedAt = now
            try operation.update(db)
            return operation
        }
    }

    public func publish(
        operationId: UUID,
        preparedChildren: [MeetingSplitPreparedChild],
        expectedSource: MeetingSplitSourceSnapshot,
        now: Date = Date()
    ) throws -> MeetingSplitOperation {
        try dbQueue.write { db in
            guard var operation = try MeetingSplitOperation.fetchOne(db, key: operationId) else {
                throw MeetingSplitRepositoryError.operationNotFound
            }
            guard operation.status == .preparing else {
                throw MeetingSplitRepositoryError.operationNotPreparing(current: operation.status)
            }

            guard let currentSource = try Transcription.fetchOne(db, key: expectedSource.id),
                  currentSource.id == operation.sourceId,
                  MeetingSplitSourceSnapshot(source: currentSource) == expectedSource
            else {
                throw MeetingSplitRepositoryError.sourceMissingOrChanged
            }

            // Built with a last-wins merge strategy (never
            // `uniqueKeysWithValues:`, which traps on a duplicate key) so a
            // caller-supplied duplicate child id is rejected as a thrown
            // `childIdentitySetMismatch` below instead of crashing the process.
            let preparedByChildId = Dictionary(
                preparedChildren.map { ($0.childId, $0) },
                uniquingKeysWith: { _, last in last }
            )
            guard preparedByChildId.count == preparedChildren.count,
                  Set(preparedByChildId.keys) == Set(operation.childIds)
            else {
                throw MeetingSplitRepositoryError.childIdentitySetMismatch
            }

            for (index, childId) in operation.childIds.enumerated() {
                let requestChild = operation.request.children[index]
                guard let prepared = preparedByChildId[childId] else {
                    throw MeetingSplitRepositoryError.childIdentitySetMismatch
                }

                // A plain insert (never save/upsert) so an id collision with
                // any existing row throws instead of silently overwriting it;
                // the throw rolls back every row inserted earlier in this loop.
                let child = Transcription(
                    id: childId,
                    createdAt: expectedSource.createdAt,
                    fileName: requestChild.title,
                    filePath: prepared.filePath,
                    audioTrackOrdinal: prepared.audioTrackOrdinal,
                    meetingArtifactFolderPath: prepared.meetingArtifactFolderPath,
                    durationMs: prepared.durationMs,
                    sourceType: .meeting,
                    splitProvenance: MeetingSplitProvenance(
                        operationId: operation.id,
                        sourceId: operation.sourceId,
                        sourceTitle: expectedSource.title,
                        approvedStartMs: requestChild.startMs,
                        approvedEndMs: requestChild.endMs,
                        ordinal: index,
                        splitCreatedAt: now
                    ),
                    updatedAt: now
                )
                try child.insert(db)
            }

            operation.status = .committed
            operation.updatedAt = now
            try operation.update(db)
            return operation
        }
    }

    public func markChildTranscriptionStarted(operationId: UUID, childId: UUID, now: Date = Date()) throws -> MeetingSplitOperation {
        try updateChildProgress(operationId: operationId, childId: childId, now: now) { progress in
            progress.stage = .transcribing
            progress.outcome = .none
            progress.errorMessage = nil
        }
    }

    public func markChildTranscriptionSucceeded(operationId: UUID, childId: UUID, now: Date = Date()) throws -> MeetingSplitOperation {
        try updateChildProgress(operationId: operationId, childId: childId, now: now) { progress in
            progress.stage = .transcribed
            progress.outcome = .none
            progress.errorMessage = nil
        }
    }

    public func markChildAutomationStarted(operationId: UUID, childId: UUID, now: Date = Date()) throws -> MeetingSplitOperation {
        try updateChildProgress(operationId: operationId, childId: childId, now: now) { progress in
            progress.stage = .automationPending
            progress.outcome = .none
            progress.errorMessage = nil
        }
    }

    public func markChildAutomationSucceeded(operationId: UUID, childId: UUID, now: Date = Date()) throws -> MeetingSplitOperation {
        try updateChildProgress(operationId: operationId, childId: childId, now: now) { progress in
            progress.stage = .automationCompleted
            progress.outcome = .none
            progress.errorMessage = nil
        }
    }

    /// Marks the *current* stage failed without moving it forward or back,
    /// so a transcription failure leaves automation untouched and an
    /// automation failure leaves the transcript in place for retry.
    public func markChildFailed(operationId: UUID, childId: UUID, errorMessage: String, now: Date = Date()) throws -> MeetingSplitOperation {
        try updateChildProgress(operationId: operationId, childId: childId, now: now) { progress in
            progress.outcome = .failed
            progress.errorMessage = errorMessage
        }
    }

    public func markChildCancelled(operationId: UUID, childId: UUID, now: Date = Date()) throws -> MeetingSplitOperation {
        try updateChildProgress(operationId: operationId, childId: childId, now: now) { progress in
            progress.outcome = .cancelled
            progress.errorMessage = nil
        }
    }

    /// Keep the receipt and the Library's first-processing status coherent.
    /// A deleted child still has a receipt, but is never reinserted.
    private func updateChildProgress(
        operationId: UUID,
        childId: UUID,
        now: Date,
        mutate: (inout MeetingSplitChildProgress) -> Void
    ) throws -> MeetingSplitOperation {
        try dbQueue.write { db in
            guard var operation = try MeetingSplitOperation.fetchOne(db, key: operationId) else {
                throw MeetingSplitRepositoryError.operationNotFound
            }
            guard operation.status == .committed else {
                throw MeetingSplitRepositoryError.operationNotCommitted(current: operation.status)
            }
            guard let index = operation.childProgress.firstIndex(where: { $0.childId == childId }) else {
                throw MeetingSplitRepositoryError.unknownChild(childId)
            }
            mutate(&operation.childProgress[index])
            if var child = try Transcription.fetchOne(db, key: childId) {
                let progress = operation.childProgress[index]
                if child.rawTranscript == nil {
                    if progress.outcome != .none {
                        child.status = .error
                        child.errorMessage = progress.errorMessage ?? "Processing stopped. Your audio is saved."
                        child.updatedAt = max(child.updatedAt, now)
                        try child.update(db)
                    } else if progress.stage == .transcribing {
                        child.status = .processing
                        child.errorMessage = nil
                        child.updatedAt = max(child.updatedAt, now)
                        try child.update(db)
                    }
                } else if progress.outcome != .none,
                          progress.stage == .pendingTranscription || progress.stage == .transcribing {
                    // Speech may have committed just before cancellation or
                    // a journal write failed. Keep that successful stage.
                    operation.childProgress[index].stage = .transcribed
                }
            }
            operation.childProgress[index].updatedAt = now
            operation.updatedAt = now
            try operation.update(db)
            return operation
        }
    }
}
