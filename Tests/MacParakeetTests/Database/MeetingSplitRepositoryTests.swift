import XCTest
import GRDB
@testable import MacParakeetCore

final class MeetingSplitRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue!
    private var repo: MeetingSplitRepository!
    private var transcriptions: TranscriptionRepository!

    private let epoch = Date(timeIntervalSince1970: 1_757_000_000)

    override func setUp() async throws {
        manager = try DatabaseManager()
        dbQueue = manager.dbQueue
        repo = MeetingSplitRepository(dbQueue: dbQueue)
        transcriptions = TranscriptionRepository(dbQueue: dbQueue)
    }

    // MARK: Schema

    func testMigrationCreatesTheOperationsTable() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("meeting_split_operations"))
            XCTAssertEqual(
                Set(try db.columns(in: "meeting_split_operations").map(\.name)),
                [
                    "id", "idempotencyKey", "sourceId", "request", "childIds",
                    "status", "childProgress", "createdAt", "updatedAt",
                ]
            )
        }
    }

    func testMigrationAddsOptionalSplitProvenanceColumnToTranscriptions() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.columns(in: "transcriptions").map(\.name).contains("splitProvenance"))
        }
    }

    /// A non-split row round-trips with `splitProvenance == nil`: existing
    /// consumers are unaffected by the new column.
    func testNonSplitTranscriptionRoundTripsWithNilProvenance() throws {
        let recording = try savedSource()
        let fetched = try XCTUnwrap(transcriptions.fetch(id: recording.id))
        XCTAssertNil(fetched.splitProvenance)
    }

    // MARK: begin idempotence and conflict

    func testBeginWithNewKeyPersistsFixedChildIdsBeforeFiles() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)

        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)

        XCTAssertEqual(operation.status, .preparing)
        XCTAssertEqual(operation.childIds.count, 2)
        XCTAssertEqual(Set(operation.childIds).count, 2, "child ids must be distinct")
        XCTAssertEqual(operation.childProgress.map(\.childId), operation.childIds)
        XCTAssertTrue(operation.childProgress.allSatisfy { $0.stage == .pendingTranscription && $0.outcome == .none })
    }

    func testRepeatedBeginWithSameKeyAndRequestReturnsSameOperation() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)

        let first = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let second = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch.addingTimeInterval(5))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.childIds, second.childIds)
    }

    func testRepeatedBeginWithSameKeyButDifferentRequestConflicts() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        _ = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)

        var mutated = request
        mutated.children[0].title = "Different title"

        XCTAssertThrowsError(try repo.begin(idempotencyKey: "op-1", request: mutated, now: epoch)) { error in
            guard case MeetingSplitRepositoryError.idempotencyKeyConflict = error else {
                return XCTFail("expected idempotencyKeyConflict, got \(error)")
            }
        }
    }

    func testBeginDoesNotRequireSourceToExist() throws {
        // The repository must not require source existence to persist or
        // return a receipt; the caller may not yet have validated the source.
        let request = twoPartRequest(sourceId: UUID())
        XCTAssertNoThrow(try repo.begin(idempotencyKey: "op-missing-source", request: request, now: epoch))
    }

    // MARK: publish — source validation

    func testPublishRejectsWhenSourceSnapshotChanged() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let staleSnapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))

        // Source changes after prepare started (e.g. renamed/moved) but before publish.
        try transcriptions.updateFilePath(id: source.id, filePath: "/tmp/moved.m4a")

        XCTAssertThrowsError(
            try repo.publish(
                operationId: operation.id,
                preparedChildren: preparedChildren(for: operation),
                expectedSource: staleSnapshot,
                now: epoch
            )
        ) { error in
            guard case MeetingSplitRepositoryError.sourceMissingOrChanged = error else {
                return XCTFail("expected sourceMissingOrChanged, got \(error)")
            }
        }
        XCTAssertEqual(try repo.operation(id: operation.id)?.status, .preparing)
        XCTAssertEqual(try transcriptions.count(), 1, "no children should have been inserted")
    }

    func testPublishRejectsWhenSourceDeleted() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))

        _ = try transcriptions.delete(id: source.id)

        XCTAssertThrowsError(
            try repo.publish(
                operationId: operation.id,
                preparedChildren: preparedChildren(for: operation),
                expectedSource: snapshot,
                now: epoch
            )
        ) { error in
            guard case MeetingSplitRepositoryError.sourceMissingOrChanged = error else {
                return XCTFail("expected sourceMissingOrChanged, got \(error)")
            }
        }
    }

    // MARK: publish — success

    func testPublishInsertsAllNewChildRowsWithProvenanceAndSourceAge() throws {
        let source = try savedSource(createdAt: epoch.addingTimeInterval(-3600))
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))

        let published = try repo.publish(
            operationId: operation.id,
            preparedChildren: preparedChildren(for: operation),
            expectedSource: snapshot,
            now: epoch
        )

        XCTAssertEqual(published.status, .committed)
        let children = try operation.childIds.map { id in try XCTUnwrap(transcriptions.fetch(id: id)) }
        XCTAssertEqual(Set(children.map(\.id)), Set(operation.childIds), "children must be fresh ids, independent of the source id")
        for (index, child) in children.enumerated() {
            XCTAssertEqual(child.createdAt, source.createdAt, "initial child createdAt equals source age")
            XCTAssertEqual(child.sourceType, .meeting)
            XCTAssertNil(child.rawTranscript)
            XCTAssertNil(child.cleanTranscript)
            XCTAssertNil(child.wordTimestamps)
            XCTAssertNil(child.userNotes)
            XCTAssertNil(child.chatMessages)
            XCTAssertEqual(child.status, .processing)
            let provenance = try XCTUnwrap(child.splitProvenance)
            XCTAssertEqual(provenance.operationId, operation.id)
            XCTAssertEqual(provenance.sourceId, source.id)
            XCTAssertEqual(provenance.sourceTitle, snapshot.title)
            let requestChild = request.children[index]
            XCTAssertEqual(provenance.approvedStartMs, requestChild.startMs)
            XCTAssertEqual(provenance.approvedEndMs, requestChild.endMs)
            XCTAssertEqual(provenance.ordinal, index)
        }
    }

    func testPublishDoesNotSaveOrUpdateTheSourceRow() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))

        _ = try repo.publish(
            operationId: operation.id,
            preparedChildren: preparedChildren(for: operation),
            expectedSource: snapshot,
            now: epoch
        )

        let unchanged = try XCTUnwrap(transcriptions.fetch(id: source.id))
        XCTAssertEqual(unchanged.updatedAt, source.updatedAt)
        XCTAssertEqual(unchanged.fileName, source.fileName)
    }

    /// Last-child insertion failure must roll back the whole transaction.
    func testFailureInsertingTheFinalChildPublishesNoChildren() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))

        // Pre-occupy the LAST child's id with an unrelated existing row, so
        // that insert collides only after the earlier child insert(s) ran.
        let collidingId = operation.childIds[1]
        let squatter = Transcription(id: collidingId, fileName: "squatter.wav", sourceType: .file)
        try transcriptions.save(squatter)

        XCTAssertThrowsError(
            try repo.publish(
                operationId: operation.id,
                preparedChildren: preparedChildren(for: operation),
                expectedSource: snapshot,
                now: epoch
            )
        )

        // Rolled back entirely: the first child was never left behind, the
        // squatter row is untouched, and the operation is still preparing.
        XCTAssertNil(try transcriptions.fetch(id: operation.childIds[0]))
        let stillSquatting = try XCTUnwrap(transcriptions.fetch(id: collidingId))
        XCTAssertEqual(stillSquatting.fileName, "squatter.wav")
        XCTAssertEqual(try repo.operation(id: operation.id)?.status, .preparing)
    }

    func testChildIdentitySetMismatchIsRejected() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))

        let wrongChildren = [MeetingSplitPreparedChild(childId: UUID())]

        XCTAssertThrowsError(
            try repo.publish(
                operationId: operation.id, preparedChildren: wrongChildren, expectedSource: snapshot, now: epoch
            )
        ) { error in
            guard case MeetingSplitRepositoryError.childIdentitySetMismatch = error else {
                return XCTFail("expected childIdentitySetMismatch, got \(error)")
            }
        }
    }

    // MARK: discovery by source (after receipt loss)

    func testOperationsForSourceReturnsMostRecentFirst() throws {
        let source = try savedSource()
        let first = try repo.begin(idempotencyKey: "op-1", request: twoPartRequest(sourceId: source.id), now: epoch)
        let second = try repo.begin(
            idempotencyKey: "op-2", request: twoPartRequest(sourceId: source.id), now: epoch.addingTimeInterval(10))

        let operations = try repo.operations(sourceId: source.id)
        XCTAssertEqual(operations.map(\.id), [second.id, first.id])
    }

    func testOperationsForSourceIsUsableAfterSourceIsDeleted() throws {
        let source = try savedSource()
        let operation = try repo.begin(idempotencyKey: "op-1", request: twoPartRequest(sourceId: source.id), now: epoch)

        _ = try transcriptions.delete(id: source.id)

        XCTAssertEqual(try repo.operations(sourceId: source.id).map(\.id), [operation.id])
    }

    // MARK: publish — duplicate child id in the prepared set

    /// A caller-supplied duplicate child id must be rejected as
    /// `childIdentitySetMismatch`, never trap the process building the
    /// dictionary keyed by child id.
    func testDuplicateChildIdInPreparedChildrenIsRejectedNotTrapped() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))

        let duplicated = [
            MeetingSplitPreparedChild(childId: operation.childIds[0]),
            MeetingSplitPreparedChild(childId: operation.childIds[0]),
        ]

        XCTAssertThrowsError(
            try repo.publish(operationId: operation.id, preparedChildren: duplicated, expectedSource: snapshot, now: epoch)
        ) { error in
            guard case MeetingSplitRepositoryError.childIdentitySetMismatch = error else {
                return XCTFail("expected childIdentitySetMismatch, got \(error)")
            }
        }
    }

    // MARK: durable retry across deletion

    func testCommittedOperationLookupReturnsSameIdsAfterSourceAndChildrenDeleted() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))
        let committed = try repo.publish(
            operationId: operation.id,
            preparedChildren: preparedChildren(for: operation),
            expectedSource: snapshot,
            now: epoch
        )

        _ = try transcriptions.delete(id: source.id)
        for childId in committed.childIds {
            _ = try transcriptions.delete(id: childId)
        }

        let retried = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch.addingTimeInterval(60))
        XCTAssertEqual(retried.id, committed.id)
        XCTAssertEqual(retried.childIds, committed.childIds)
        XCTAssertEqual(retried.status, .committed, "committed operations are never resurrected into preparing")

        let byId = try XCTUnwrap(repo.operation(id: committed.id))
        XCTAssertEqual(byId.status, .committed)
    }

    // MARK: discard vs committed refusal

    func testDiscardingAPreparingOperationSucceeds() throws {
        let source = try savedSource()
        let operation = try repo.begin(idempotencyKey: "op-1", request: twoPartRequest(sourceId: source.id), now: epoch)

        let discarded = try repo.discard(operationId: operation.id, now: epoch.addingTimeInterval(1))
        XCTAssertEqual(discarded.status, .discarded)
    }

    func testDiscardingACommittedOperationIsRefused() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))
        _ = try repo.publish(
            operationId: operation.id, preparedChildren: preparedChildren(for: operation), expectedSource: snapshot, now: epoch
        )

        XCTAssertThrowsError(try repo.discard(operationId: operation.id, now: epoch)) { error in
            guard case MeetingSplitRepositoryError.operationNotPreparing(let current) = error else {
                return XCTFail("expected operationNotPreparing, got \(error)")
            }
            XCTAssertEqual(current, .committed)
        }
    }

    // MARK: per-child progress

    func testProgressUpdatesRequireACommittedOperation() throws {
        let source = try savedSource()
        let operation = try repo.begin(idempotencyKey: "op-1", request: twoPartRequest(sourceId: source.id), now: epoch)

        XCTAssertThrowsError(
            try repo.markChildTranscriptionStarted(operationId: operation.id, childId: operation.childIds[0], now: epoch)
        ) { error in
            guard case MeetingSplitRepositoryError.operationNotCommitted(let current) = error else {
                return XCTFail("expected operationNotCommitted, got \(error)")
            }
            XCTAssertEqual(current, .preparing)
        }
    }

    func testProgressUpdateForUnknownChildIsRejected() throws {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))
        _ = try repo.publish(
            operationId: operation.id, preparedChildren: preparedChildren(for: operation), expectedSource: snapshot, now: epoch
        )

        XCTAssertThrowsError(
            try repo.markChildTranscriptionStarted(operationId: operation.id, childId: UUID(), now: epoch)
        ) { error in
            guard case MeetingSplitRepositoryError.unknownChild = error else {
                return XCTFail("expected unknownChild, got \(error)")
            }
        }
    }

    /// A summary/automation failure must not erase a successful transcript:
    /// the stage stays at `automationPending` (past `transcribed`), only the
    /// outcome flips to `failed`, so a retry resumes automation without
    /// rerunning speech.
    func testAutomationFailureAfterSuccessfulTranscriptionPreservesTranscribedStageForRetry() throws {
        let (operation, childId) = try publishedOperationAndFirstChild()

        _ = try repo.markChildTranscriptionStarted(operationId: operation.id, childId: childId, now: epoch)
        _ = try repo.markChildTranscriptionSucceeded(operationId: operation.id, childId: childId, now: epoch.addingTimeInterval(1))
        _ = try repo.markChildAutomationStarted(operationId: operation.id, childId: childId, now: epoch.addingTimeInterval(2))
        let afterFailure = try repo.markChildFailed(
            operationId: operation.id, childId: childId, errorMessage: "summary provider failed",
            now: epoch.addingTimeInterval(3)
        )

        let progress = try XCTUnwrap(afterFailure.childProgress.first { $0.childId == childId })
        XCTAssertEqual(progress.stage, .automationPending, "still past transcribed; speech is not repeated on retry")
        XCTAssertEqual(progress.outcome, .failed)
        XCTAssertEqual(progress.errorMessage, "summary provider failed")

        // Retry: automation can be re-attempted and complete without ever
        // moving the stage backward through transcribing/transcribed again.
        let recovered = try repo.markChildAutomationSucceeded(
            operationId: operation.id, childId: childId, now: epoch.addingTimeInterval(4)
        )
        let finalProgress = try XCTUnwrap(recovered.childProgress.first { $0.childId == childId })
        XCTAssertEqual(finalProgress.stage, .automationCompleted)
        XCTAssertEqual(finalProgress.outcome, .none)
    }

    func testTranscriptionFailureLeavesStageAtTranscribingForRetryWithoutTouchingOtherChildren() throws {
        let (operation, childId) = try publishedOperationAndFirstChild()
        let otherChildId = operation.childIds[1]

        _ = try repo.markChildTranscriptionStarted(operationId: operation.id, childId: childId, now: epoch)
        let failed = try repo.markChildFailed(
            operationId: operation.id, childId: childId, errorMessage: "stt crashed", now: epoch.addingTimeInterval(1)
        )

        let progress = try XCTUnwrap(failed.childProgress.first { $0.childId == childId })
        XCTAssertEqual(progress.stage, .transcribing)
        XCTAssertEqual(progress.outcome, .failed)

        let other = try XCTUnwrap(failed.childProgress.first { $0.childId == otherChildId })
        XCTAssertEqual(other.stage, .pendingTranscription)
        XCTAssertEqual(other.outcome, .none, "continuing to later parts after one failure must not mark siblings failed")
    }

    func testCancellationMarksOutcomeWithoutClearingReachedStage() throws {
        let (operation, childId) = try publishedOperationAndFirstChild()
        _ = try repo.markChildTranscriptionStarted(operationId: operation.id, childId: childId, now: epoch)
        _ = try repo.markChildTranscriptionSucceeded(operationId: operation.id, childId: childId, now: epoch.addingTimeInterval(1))

        let cancelled = try repo.markChildCancelled(operationId: operation.id, childId: childId, now: epoch.addingTimeInterval(2))
        let progress = try XCTUnwrap(cancelled.childProgress.first { $0.childId == childId })
        XCTAssertEqual(progress.stage, .transcribed, "cancellation after a successful transcript must not discard it")
        XCTAssertEqual(progress.outcome, .cancelled)
    }

    /// Deleting the underlying child row must not change how progress is
    /// described: no reinsertion, no refusal, just the last known receipt.
    func testProgressRemainsDescribableAfterTheChildRowIsDeleted() throws {
        let (operation, childId) = try publishedOperationAndFirstChild()
        _ = try repo.markChildTranscriptionStarted(operationId: operation.id, childId: childId, now: epoch)
        _ = try repo.markChildTranscriptionSucceeded(operationId: operation.id, childId: childId, now: epoch.addingTimeInterval(1))

        _ = try transcriptions.delete(id: childId)

        let afterDeletion = try repo.markChildFailed(
            operationId: operation.id, childId: childId, errorMessage: "automation hook never ran", now: epoch.addingTimeInterval(2)
        )
        let progress = try XCTUnwrap(afterDeletion.childProgress.first { $0.childId == childId })
        XCTAssertEqual(progress.stage, .transcribed)
        XCTAssertEqual(progress.outcome, .failed)
        XCTAssertNil(try transcriptions.fetch(id: childId), "must not be reinserted by a progress update")
    }

    // MARK: helpers

    private func savedSource(createdAt: Date? = nil) throws -> Transcription {
        let source = Transcription(
            createdAt: createdAt ?? epoch,
            fileName: "long-standup-recording.m4a",
            filePath: "/tmp/long-standup-recording.m4a",
            durationMs: 3_600_000,
            status: .completed,
            sourceType: .meeting,
            updatedAt: createdAt ?? epoch
        )
        try transcriptions.save(source)
        return source
    }

    private func twoPartRequest(sourceId: UUID) -> MeetingSplitRequest {
        MeetingSplitRequest(
            sourceId: sourceId,
            expectedSourceIdentity: "sha256:abc123",
            children: [
                MeetingSplitChildRequest(title: "Standup: Part 1", startMs: 0, endMs: 1_800_000),
                MeetingSplitChildRequest(title: "Standup: Part 2", startMs: 1_800_000, endMs: 3_600_000),
            ]
        )
    }

    private func preparedChildren(for operation: MeetingSplitOperation) -> [MeetingSplitPreparedChild] {
        operation.childIds.enumerated().map { index, childId in
            MeetingSplitPreparedChild(
                childId: childId,
                filePath: "/tmp/split/\(childId.uuidString)/meeting-playback.m4a",
                meetingArtifactFolderPath: "/tmp/split/\(childId.uuidString)",
                durationMs: operation.request.children[index].endMs - operation.request.children[index].startMs
            )
        }
    }

    private func publishedOperationAndFirstChild() throws -> (MeetingSplitOperation, UUID) {
        let source = try savedSource()
        let request = twoPartRequest(sourceId: source.id)
        let operation = try repo.begin(idempotencyKey: "op-1", request: request, now: epoch)
        let snapshot = try XCTUnwrap(repo.sourceSnapshot(sourceId: source.id))
        let committed = try repo.publish(
            operationId: operation.id, preparedChildren: preparedChildren(for: operation), expectedSource: snapshot, now: epoch
        )
        return (committed, committed.childIds[0])
    }
}
