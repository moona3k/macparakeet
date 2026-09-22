import Foundation
import MacParakeetCore

/// Whether a `.processing` split child's own operation lease can be safely
/// treated as abandoned. Distinct from `MeetingFinalizationReconciliationCoordinating`,
/// which probes a live-capture `recording.lock` file a split child never
/// writes: reusing that folder-only signal here would misclassify a child
/// still being actively processed by another CLI/native caller as
/// interrupted, when only that caller's own `MeetingSplitOperationLease`
/// actually reflects live ownership.
protocol MeetingSplitOperationReconciliationCoordinating: Sendable {
    /// Runs `transition` only if this exact operation's own advisory lease is
    /// not currently held elsewhere. Implementations must acquire (not merely
    /// probe-then-release) the real lease and hold it across `transition`,
    /// so a live caller racing to acquire the same lease fails outright
    /// instead of both sides observing "free" and proceeding — never a
    /// probe/release-then-unconditional-CAS sequence, which leaves a window
    /// for exactly that race.
    func reconcileIfUnowned(
        operationId: UUID,
        transition: @Sendable () throws -> Bool
    ) throws -> Bool
}

/// Production coordinator: reuses the real `MeetingSplitOperationLease`
/// kernel file lock, keyed by the operation's own frozen idempotency key and
/// destination root — never a broad media-root probe, matching every other
/// `MeetingSplitService` entry point.
struct MeetingSplitOperationLeaseReconciliationCoordinator: MeetingSplitOperationReconciliationCoordinating {
    let splitRepo: any MeetingSplitRepositoryProtocol

    func reconcileIfUnowned(
        operationId: UUID,
        transition: @Sendable () throws -> Bool
    ) throws -> Bool {
        // An operation the repository no longer knows about (e.g. pruned)
        // has nothing left to protect: fall back to the same unconditional
        // transition a non-split row with no resolvable folder already gets.
        guard let operation = try splitRepo.operation(id: operationId),
            let rootPath = operation.request.destinationRootPath
        else {
            return try transition()
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        do {
            let lease = try MeetingSplitOperationLease.acquire(
                idempotencyKey: operation.idempotencyKey, meetingRecordingsRootURL: rootURL)
            defer { lease.release() }
            return try transition()
        } catch MeetingSplitOperationLease.AcquisitionError.busy {
            // A live process still holds this operation's own lease: it is
            // actively processing this child, not abandoned.
            return false
        }
    }
}

/// Default when no split repository is available to a caller: preserves the
/// reconciler's prior unconditional-transition behavior for split children,
/// same as a non-split row with no resolvable folder.
struct UnconditionalMeetingSplitOperationReconciliationCoordinator: MeetingSplitOperationReconciliationCoordinating {
    func reconcileIfUnowned(
        operationId: UUID,
        transition: @Sendable () throws -> Bool
    ) throws -> Bool {
        try transition()
    }
}
