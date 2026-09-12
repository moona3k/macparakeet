import Foundation
import GRDB

public enum SharePublicationRepositoryError: Error, Sendable, Equatable {
    case shareNotFound
    /// A terminal delete is already queued for this share; no further
    /// nonterminal mutation may be enqueued behind it.
    case shareIsTerminating
    /// A `contentUpdate` or `expiryChange` is already queued for this share.
    /// Only one nonterminal mutation may be outstanding at a time, so a
    /// second call before the first confirms is rejected rather than queued
    /// against stale local state.
    case operationAlreadyPending
    case sourceMissing
}

public protocol SharePublicationRepositoryProtocol: Sendable {
    /// Persists the local ledger row and its `create` outbox operation in one
    /// transaction, before any network call — this is the durable intent
    /// that lets a lost create response be reconciled instead of retried
    /// blind or silently dropped.
    func createPublication(_ publication: SharePublication, initialOperation: ShareOutboxOperation) async throws

    func fetch(id: UUID) throws -> SharePublication?
    func fetch(remoteShareId: String) throws -> SharePublication?
    func fetchAll() throws -> [SharePublication]

    /// Every share with at least one queued outbox operation, for restart
    /// resumption sweeps.
    func fetchShareIdsWithPendingOperations() throws -> [UUID]

    /// Detached shares that may still have a Keychain content key pending
    /// removal.
    func fetchDetachedNeedingKeyCleanup() throws -> [SharePublication]

    func fetchPendingOperations(forShareId shareId: UUID) throws -> [ShareOutboxOperation]
    func fetchNextPendingOperation(forShareId shareId: UUID) throws -> ShareOutboxOperation?

    /// Enqueues a nonterminal (`contentUpdate` or `expiryChange`) operation.
    /// Fails with `.shareIsTerminating` if a terminal `delete` is already
    /// queued for this share.
    func enqueueOperation(_ operation: ShareOutboxOperation) async throws

    /// Idempotently enqueues the one terminal `delete` operation for a
    /// share: superseded queued nonterminal work is removed first (a
    /// still-pending `create` is preserved for reconciliation), and calling
    /// this again after a `delete` is already queued is a no-op.
    func enqueueTerminalDelete(shareId: UUID) async throws

    func dequeueOperation(id: UUID) async throws
    /// Atomically marks the request attempted; true only for its first attempt.
    @discardableResult
    func recordAttempt(operationId: UUID) async throws -> Bool
    func rotateOperationIdempotencyKey(id: UUID, newIdempotencyKey: String) async throws

    @discardableResult
    func applyConfirmedReceipt(shareId: UUID, resource: ShareResource) async throws -> SharePublication?

    @discardableResult
    func applyDeletionReceipt(shareId: UUID, receipt: ShareDeletionReceipt) async throws -> SharePublication?

    func confirmOperation(_ operation: ShareOutboxOperation, resource: ShareResource) async throws
    func confirmDelete(_ operation: ShareOutboxOperation, receipt: ShareDeletionReceipt, nextKey: String) async throws
    func reconcileResources(_ resources: [ShareResource], ownerId: String) async throws
    func forgetCompletedPublication(id: UUID) async throws

    /// Removes a share row (and its outbox operations, via cascade) that the
    /// service has definitively never confirmed. Refuses to touch a
    /// confirmed row (`version != nil`) or any row with a queued stop —
    /// reconciliation, not deletion, is the only path for an uncertain
    /// creation. Callers must have authoritative non-acceptance evidence;
    /// a missing version alone is never that evidence.
    @discardableResult
    func deleteUnconfirmedPublication(id: UUID) async throws -> Bool
}

public final class SharePublicationRepository: SharePublicationRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func createPublication(_ publication: SharePublication, initialOperation: ShareOutboxOperation) async throws {
        try await dbQueue.write { db in
            if let sourceId = publication.transcriptionId,
                try Transcription.fetchOne(db, key: sourceId) == nil {
                throw SharePublicationRepositoryError.sourceMissing
            }
            try publication.insert(db)
            var operation = initialOperation
            operation.sequence = try Self.nextSequence(in: db)
            try operation.insert(db)
        }
    }

    public func fetch(id: UUID) throws -> SharePublication? {
        try dbQueue.read { db in
            try SharePublication.fetchOne(db, key: id)
        }
    }

    public func fetch(remoteShareId: String) throws -> SharePublication? {
        try dbQueue.read { db in
            try SharePublication
                .filter(SharePublication.Columns.remoteShareId == remoteShareId)
                .fetchOne(db)
        }
    }

    public func fetchAll() throws -> [SharePublication] {
        try dbQueue.read { db in
            try SharePublication
                .order(SharePublication.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchShareIdsWithPendingOperations() throws -> [UUID] {
        try dbQueue.read { db in
            let operations = try ShareOutboxOperation.fetchAll(db)
            return Array(Set(operations.map(\.sharePublicationId)))
        }
    }

    public func fetchDetachedNeedingKeyCleanup() throws -> [SharePublication] {
        try dbQueue.read { db in
            try SharePublication
                .filter(SharePublication.Columns.isDetached == true)
                .fetchAll(db)
        }
    }

    public func fetchPendingOperations(forShareId shareId: UUID) throws -> [ShareOutboxOperation] {
        try dbQueue.read { db in
            try ShareOutboxOperation
                .filter(ShareOutboxOperation.Columns.sharePublicationId == shareId)
                .order(ShareOutboxOperation.Columns.sequence.asc)
                .fetchAll(db)
        }
    }

    public func fetchNextPendingOperation(forShareId shareId: UUID) throws -> ShareOutboxOperation? {
        try dbQueue.read { db in
            try ShareOutboxOperation
                .filter(ShareOutboxOperation.Columns.sharePublicationId == shareId)
                .order(ShareOutboxOperation.Columns.sequence.asc)
                .fetchOne(db)
        }
    }

    public func enqueueOperation(_ operation: ShareOutboxOperation) async throws {
        try await dbQueue.write { db in
            guard try SharePublication.fetchOne(db, key: operation.sharePublicationId) != nil else {
                throw SharePublicationRepositoryError.shareNotFound
            }
            let existingKinds =
                try ShareOutboxOperation
                .filter(ShareOutboxOperation.Columns.sharePublicationId == operation.sharePublicationId)
                .fetchAll(db)
                .map(\.kind)
            guard !existingKinds.contains(.delete) else {
                throw SharePublicationRepositoryError.shareIsTerminating
            }
            guard !existingKinds.contains(.contentUpdate), !existingKinds.contains(.expiryChange) else {
                throw SharePublicationRepositoryError.operationAlreadyPending
            }
            var operation = operation
            operation.sequence = try Self.nextSequence(in: db)
            try operation.insert(db)
        }
    }

    public func enqueueTerminalDelete(shareId: UUID) async throws {
        try await dbQueue.write { db in
            try Self.performEnqueueTerminalDelete(shareId: shareId, in: db)
        }
    }

    public func dequeueOperation(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try ShareOutboxOperation.deleteOne(db, key: id)
        }
    }

    @discardableResult
    public func recordAttempt(operationId: UUID) async throws -> Bool {
        try await dbQueue.write { db in
            guard var operation = try ShareOutboxOperation.fetchOne(db, key: operationId) else {
                throw SharePublicationRepositoryError.shareNotFound
            }
            let firstAttempt = operation.lastAttemptAt == nil
            operation.lastAttemptAt = Date()
            try operation.update(db)
            return firstAttempt
        }
    }

    public func rotateOperationIdempotencyKey(id: UUID, newIdempotencyKey: String) async throws {
        try await dbQueue.write { db in
            guard var operation = try ShareOutboxOperation.fetchOne(db, key: id) else { return }
            operation.idempotencyKey = newIdempotencyKey
            operation.lastAttemptAt = Date()
            try operation.update(db)
        }
    }

    @discardableResult
    public func applyConfirmedReceipt(shareId: UUID, resource: ShareResource) async throws -> SharePublication? {
        try await dbQueue.write { db in
            guard var share = try SharePublication.fetchOne(db, key: shareId) else { return nil }
            share.locatorCommitment = resource.locatorCommitment
            share.contentRevision = resource.contentRevision
            share.version = resource.version
            share.accessState = resource.accessState
            share.deletionState = resource.deletionState
            share.contentWritable = resource.contentWritable
            share.expiresAt = resource.expiresAt
            share.maxExpiresAt = resource.maxExpiresAt
            share.terminalAt = resource.terminalAt
            share.updatedAt = Date()
            try share.update(db)
            return share
        }
    }

    @discardableResult
    public func applyDeletionReceipt(shareId: UUID, receipt: ShareDeletionReceipt) async throws -> SharePublication? {
        try await dbQueue.write { db in
            guard var share = try SharePublication.fetchOne(db, key: shareId) else { return nil }
            share.locatorCommitment = receipt.locatorCommitment
            share.accessState = receipt.accessState
            share.deletionState = receipt.deletionState
            if share.terminalAt == nil {
                share.terminalAt = Date()
            }
            share.updatedAt = Date()
            try share.update(db)
            return share
        }
    }

    @discardableResult
    public func deleteUnconfirmedPublication(id: UUID) async throws -> Bool {
        try await dbQueue.write { db in
            guard let share = try SharePublication.fetchOne(db, key: id), share.version == nil else {
                return false
            }
            let pending = try ShareOutboxOperation.filter(ShareOutboxOperation.Columns.sharePublicationId == id).fetchAll(db)
            guard pending.count == 1, pending.first?.kind == .create else { return false }
            return try SharePublication.deleteOne(db, key: share.id)
        }
    }

    public func confirmOperation(_ operation: ShareOutboxOperation, resource: ShareResource) async throws {
        try await dbQueue.write { db in
            guard var share = try SharePublication.fetchOne(db, key: operation.sharePublicationId) else { return }
            // A terminal intent may have removed an in-flight mutation. Its
            // response cannot clear that intent or repopulate detached fields.
            Self.apply(resource, to: &share)
            if !share.isDetached && (operation.kind == .create || operation.kind == .contentUpdate) {
                share.projectionManifest = operation.projectionManifest
                share.contentDigest = operation.contentDigest
            }
            if try Self.hasTerminalOperation(share.id, in: db), resource.deletionState != .complete {
                share.deletionState = .pending
            }
            try share.update(db)
            _ = try ShareOutboxOperation.deleteOne(db, key: operation.id)
        }
    }

    public func confirmDelete(_ operation: ShareOutboxOperation, receipt: ShareDeletionReceipt, nextKey: String) async throws {
        try await dbQueue.write { db in
            guard var share = try SharePublication.fetchOne(db, key: operation.sharePublicationId) else { return }
            share.locatorCommitment = receipt.locatorCommitment
            share.accessState = receipt.accessState
            share.deletionState = receipt.deletionState
            share.terminalAt = share.terminalAt ?? Date()
            share.contentWritable = false
            share.updatedAt = Date()
            try share.update(db)
            if receipt.deletionState == .complete {
                _ = try ShareOutboxOperation.deleteOne(db, key: operation.id)
            } else if var pending = try ShareOutboxOperation.fetchOne(db, key: operation.id) {
                pending.idempotencyKey = nextKey
                try pending.update(db)
            }
        }
    }

    public func reconcileResources(_ resources: [ShareResource], ownerId: String) async throws {
        try await dbQueue.write { db in
            for resource in resources {
                let existing = try SharePublication.filter(SharePublication.Columns.remoteShareId == resource.id).fetchOne(db)
                // Remote retention tombstones are not new management work.
                // In particular, refresh must not undo "Remove from this Mac".
                // Known rows still reconcile their deletion-complete receipt.
                if existing == nil && resource.deletionState == .complete { continue }
                var share = existing ?? SharePublication(remoteShareId: resource.id, locator: nil,
                        locatorCommitment: resource.locatorCommitment, ownerId: ownerId,
                        createdCredentialGeneration: 0, createdAt: resource.createdAt,
                        expiresAt: resource.expiresAt, maxExpiresAt: resource.maxExpiresAt)
                Self.apply(resource, to: &share)
                // A recovered row has no content key/source association.
                if share.locator == nil { share.contentWritable = false }
                if try Self.hasTerminalOperation(share.id, in: db), resource.deletionState != .complete {
                    share.deletionState = .pending
                }
                try share.save(db)
            }
        }
    }

    private static func apply(_ resource: ShareResource, to share: inout SharePublication) {
        share.locatorCommitment = resource.locatorCommitment
        share.contentRevision = resource.contentRevision
        share.version = resource.version
        share.accessState = resource.accessState
        share.deletionState = resource.deletionState
        share.contentWritable = resource.contentWritable
        share.expiresAt = resource.expiresAt
        share.maxExpiresAt = resource.maxExpiresAt
        share.terminalAt = resource.terminalAt
        share.updatedAt = resource.updatedAt
    }

    private static func hasTerminalOperation(_ shareId: UUID, in db: Database) throws -> Bool {
        try ShareOutboxOperation.filter(ShareOutboxOperation.Columns.sharePublicationId == shareId)
            .filter(ShareOutboxOperation.Columns.kind == ShareOutboxOperation.Kind.delete.rawValue).fetchCount(db) > 0
    }

    // MARK: - Transaction-scoped helpers

    public func forgetCompletedPublication(id: UUID) async throws {
        try await dbQueue.write { db in
            guard let share = try SharePublication.fetchOne(db, key: id), share.deletionState == .complete,
                try ShareOutboxOperation.filter(ShareOutboxOperation.Columns.sharePublicationId == id).fetchCount(db) == 0 else {
                throw SharePublicationRepositoryError.shareIsTerminating
            }
            _ = try SharePublication.deleteOne(db, key: id)
        }
    }

    /// Called inside U5's existing source-deletion write transaction. Clears
    /// every content-derived local field on each share
    /// associated with `transcriptionId` and queues exactly one terminal
    /// `delete` operation per share. Performs no network I/O.
    public static func detachAndEnqueueTerminalOperations(
        transcriptionId: UUID,
        in db: Database
    ) throws -> [SharePublication] {
        let attached =
            try SharePublication
            .filter(SharePublication.Columns.transcriptionId == transcriptionId)
            .fetchAll(db)

        var detached: [SharePublication] = []
        for share in attached {
            var updated = share
            updated.transcriptionId = nil
            updated.projectionManifest = nil
            updated.contentDigest = nil
            updated.isDetached = true
            updated.updatedAt = Date()
            try updated.update(db)
            for var operation in try ShareOutboxOperation.filter(ShareOutboxOperation.Columns.sharePublicationId == updated.id).fetchAll(db) {
                operation.projectionManifest = nil
                operation.contentDigest = nil
                try operation.update(db)
            }
            try performEnqueueTerminalDelete(shareId: updated.id, in: db)
            if let refreshed = try SharePublication.fetchOne(db, key: updated.id) {
                detached.append(refreshed)
            }
        }
        return detached
    }

    private static func performEnqueueTerminalDelete(shareId: UUID, in db: Database) throws {
        guard var share = try SharePublication.fetchOne(db, key: shareId) else { return }
        guard share.deletionState != .complete else { return }

        try ShareOutboxOperation
            .filter(ShareOutboxOperation.Columns.sharePublicationId == shareId)
            .filter(
                [ShareOutboxOperation.Kind.contentUpdate.rawValue, ShareOutboxOperation.Kind.expiryChange.rawValue]
                    .contains(ShareOutboxOperation.Columns.kind)
            )
            .deleteAll(db)

        let alreadyQueued =
            try ShareOutboxOperation
            .filter(ShareOutboxOperation.Columns.sharePublicationId == shareId)
            .filter(ShareOutboxOperation.Columns.kind == ShareOutboxOperation.Kind.delete.rawValue)
            .fetchCount(db) > 0

        if !alreadyQueued {
            let payload = ShareDeleteRequestBody(locatorCommitment: share.locatorCommitment)
            let operation = ShareOutboxOperation(
                sharePublicationId: shareId,
                sequence: try Self.nextSequence(in: db),
                kind: .delete,
                idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
                requestBody: try ShareServiceJSON.makeEncoder().encode(payload)
            )
            try operation.insert(db)
        }

        if share.deletionState != .pending {
            share.deletionState = .pending
            share.updatedAt = Date()
            try share.update(db)
        }
    }

    /// A single global counter (not scoped per share) is sufficient: filtering
    /// by share and sorting by `sequence` still yields correct per-share
    /// order, and a global monotonic value is simpler to reason about than a
    /// per-share one recomputed on every insert.
    private static func nextSequence(in db: Database) throws -> Int {
        let current = try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM share_outbox_operations") ?? 0
        return current + 1
    }
}
