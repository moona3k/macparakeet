import GRDB
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingSplitViewModelTests: XCTestCase {
    private var service: MockMeetingSplitServicing!
    private var viewModel: MeetingSplitViewModel!
    private let sourceId = UUID()

    override func setUp() async throws {
        service = MockMeetingSplitServicing()
        service.previewsBySourceId[sourceId] = MeetingSplitPreview(
            sourceId: sourceId,
            sourceTitle: "Weekly sync",
            totalDurationMs: 10_000,
            ranges: [MeetingSplitSourceRange(startMs: 0, endMs: 10_000)],
            hasRawMicrophone: true,
            hasRawSystem: true,
            hasCleanedMicrophone: false,
            sourceIdentity: "identity-1"
        )
        viewModel = MeetingSplitViewModel(service: service)
    }

    // MARK: - Present / defaults

    func testPresentDefaultsToTwoPartsAtMidpointWithStableTitles() async {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")

        XCTAssertEqual(viewModel.loadState, .ready)
        let editing = try? XCTUnwrap(viewModel.editing)
        XCTAssertEqual(editing?.cutPointsMs, [5_000])
        XCTAssertEqual(editing?.partTitles.count, 2)
        XCTAssertNil(viewModel.validationError)
        XCTAssertTrue(viewModel.canSubmit)
    }

    func testPresentSurfacesPreviewFailure() async {
        service.previewError = MeetingSplitServiceError.sourceNotFound
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")

        guard case .failed = viewModel.loadState else {
            return XCTFail("expected .failed, got \(viewModel.loadState)")
        }
        XCTAssertNil(viewModel.editing)
    }

    func testDifferentSourcePreviewFailureDoesNotDisplayPreviousOperation() async throws {
        let previous = try service.makeCommittedOperationWithPendingChild(sourceId: sourceId)
        service.operationsBySourceId[sourceId] = [previous]
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        XCTAssertEqual(viewModel.operation?.id, previous.id)

        service.previewError = MeetingSplitServiceError.sourceNotFound
        await viewModel.present(sourceId: UUID(), sourceTitle: "Missing recording")

        guard case .failed = viewModel.loadState else { return XCTFail("Expected preview failure") }
        XCTAssertNil(viewModel.operation, "An unrelated old receipt must not replace the failed source")
        XCTAssertFalse(viewModel.isExternallyOwned, "A missing source is not an ownership conflict")
        XCTAssertEqual(viewModel.activeSourceTitle, "Missing recording")
    }

    // MARK: - Geometry editing

    func testTimeEntrySupportsHoursAndKeepsIncompleteInputInvalid() async {
        XCTAssertEqual(MeetingSplitTimecode.parse("1:02:03.125"), 3_723_125)
        XCTAssertEqual(MeetingSplitTimecode.parse("90:00"), 5_400_000)
        XCTAssertEqual(MeetingSplitTimecode.format(3_723_125), "1:02:03.125")
        for invalid in ["", "1:", "1:60", "-1:20", "1:60:00", "999999999999999999999:00", "1:02.1234"] {
            XCTAssertNil(MeetingSplitTimecode.parse(invalid), invalid)
        }
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        viewModel.updateCutText(at: 0, to: "0:")
        XCTAssertEqual(viewModel.boundaryText, ["0:"])
        XCTAssertFalse(viewModel.canSubmit)
        viewModel.updateCutText(at: 0, to: "0:03.250")
        XCTAssertEqual(viewModel.editing?.cutPointsMs, [3_250])
        XCTAssertTrue(viewModel.canSubmit)
    }

    func testAddSplitDividesLongestRangePreservingExistingCutsAndTitles() async {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        viewModel.updateTitle(at: 0, to: "Intro")
        viewModel.updateTitle(at: 1, to: "Deep dive")

        viewModel.addSplit()

        let editing = try? XCTUnwrap(viewModel.editing)
        // Original single cut at 5_000 divided the [0, 10_000) range into two
        // equal 5_000ms parts; the new split bisects whichever is longest
        // (a tie here resolves to the first, [0, 5_000)), inserting 2_500.
        XCTAssertEqual(editing?.cutPointsMs, [2_500, 5_000])
        XCTAssertEqual(editing?.partTitles, ["Intro", "Weekly sync — Part 2", "Deep dive"])
        XCTAssertNil(viewModel.validationError)
    }

    func testRemoveCutMergesAdjacentPartsKeepingEarlierTitle() async {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        viewModel.updateTitle(at: 0, to: "Intro")
        viewModel.updateTitle(at: 1, to: "Deep dive")
        viewModel.addSplit()
        XCTAssertEqual(viewModel.editing?.cutPointsMs.count, 2)

        viewModel.removeCut(at: 0)

        let editing = try? XCTUnwrap(viewModel.editing)
        XCTAssertEqual(editing?.cutPointsMs, [5_000])
        XCTAssertEqual(editing?.partTitles, ["Intro", "Deep dive"])
    }

    func testUpdateCutOutOfOrderProducesValidationErrorAndBlocksSubmit() async {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        viewModel.addSplit()
        XCTAssertEqual(viewModel.editing?.cutPointsMs.count, 2)

        // Push the first cut past the second: no longer strictly ascending.
        viewModel.updateCut(at: 0, toMs: 9_000)

        XCTAssertNotNil(viewModel.validationError)
        XCTAssertFalse(viewModel.canSubmit)
        XCTAssertFalse(viewModel.submit())
    }

    func testBlankTitleProducesValidationErrorAndBlocksSubmit() async {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        viewModel.updateTitle(at: 0, to: "   ")

        XCTAssertNotNil(viewModel.validationError)
        XCTAssertFalse(viewModel.canSubmit)
    }

    // MARK: - Submit / process

    func testSubmitCallsServiceWithStableIdempotencyKeyAndReportsProgress() async throws {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")

        let childId = UUID()
        service.createAndProcessHandler = { key, sid, cuts, titles, identity, onProgress in
            XCTAssertFalse(key.isEmpty)
            XCTAssertEqual(sid, self.sourceId)
            XCTAssertEqual(cuts, [5_000])
            let result = try self.service.makeCommittedOperation(sourceId: sid, cutPointsMs: cuts, titles: titles)
            onProgress?(MeetingSplitProcessingProgress(operationId: result.id, childId: childId, childIndex: 0, childCount: 2, stage: .transcribing))
            return result
        }

        XCTAssertTrue(viewModel.submit())
        try await waitUntil { self.viewModel.progress != nil || self.viewModel.completedOperation != nil }

        try await waitUntil { self.viewModel.completedOperation != nil }
        XCTAssertEqual(viewModel.completedOperation?.status, .committed)
        XCTAssertNil(viewModel.processingErrorMessage)
    }

    func testDoubleSubmitWhileProcessingIsRefusedWithoutASecondServiceCall() async throws {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        let gate = Gate()
        service.createAndProcessHandler = { _, sid, cuts, titles, _, _ in
            await gate.wait()
            return try self.service.makeCommittedOperation(sourceId: sid, cutPointsMs: cuts, titles: titles)
        }

        XCTAssertTrue(viewModel.submit())
        XCTAssertFalse(viewModel.canSubmit, "The UI must disable creation while a batch is running")
        XCTAssertFalse(viewModel.submit(), "a second submit while processing must be refused")
        await gate.open()

        try await waitUntil { self.viewModel.completedOperation != nil }
        XCTAssertEqual(service.createAndProcessCallCount, 1)
    }

    func testStopCancelsProcessingWithoutMarkingItFailed() async throws {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        service.createAndProcessHandler = { _, _, _, _, _, _ in
            try await Task.sleep(for: .seconds(5))
            XCTFail("must not run to completion after cancellation")
            throw CancellationError()
        }

        XCTAssertTrue(viewModel.submit())
        XCTAssertTrue(viewModel.isProcessingActive)
        viewModel.stop()

        try await waitUntil { !self.viewModel.isProcessingActive }
        XCTAssertNil(viewModel.completedOperation)
        XCTAssertNil(viewModel.processingErrorMessage)
    }

    func testDifferentSourceCannotReplaceAnActiveBatch() async throws {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        let gate = Gate()
        service.createAndProcessHandler = { _, sid, cuts, titles, _, _ in
            await gate.wait()
            return try self.service.makeCommittedOperation(sourceId: sid, cutPointsMs: cuts, titles: titles)
        }
        XCTAssertTrue(viewModel.submit())

        let otherSourceId = UUID()
        service.previewsBySourceId[otherSourceId] = MeetingSplitPreview(
            sourceId: otherSourceId, sourceTitle: "Other meeting", totalDurationMs: 4_000,
            ranges: [MeetingSplitSourceRange(startMs: 0, endMs: 4_000)],
            hasRawMicrophone: false, hasRawSystem: false, hasCleanedMicrophone: false, sourceIdentity: "identity-2"
        )
        await viewModel.present(sourceId: otherSourceId, sourceTitle: "Other meeting")
        XCTAssertFalse(viewModel.submit(), "must not replace the still-running batch for a different source")
        XCTAssertEqual(viewModel.activeSourceId, sourceId, "the original batch must still be the active one")

        await gate.open()
        try await waitUntil { self.viewModel.completedOperation != nil }
    }

    // MARK: - Restart discovery / resume

    func testPresentDiscoversIncompleteOperationAsResumable() async throws {
        let committed = try service.makeCommittedOperationWithPendingChild(sourceId: sourceId)
        service.operationsBySourceId[sourceId] = [committed]

        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")

        XCTAssertEqual(viewModel.resumableOperation?.id, committed.id)
    }

    func testCancelledOperationRemainsDiscoverableAfterRestart() async throws {
        var operation = try service.makeCommittedOperationWithPendingChild(sourceId: sourceId)
        for index in operation.childProgress.indices {
            operation.childProgress[index].outcome = .cancelled
        }
        service.operationsBySourceId[sourceId] = [operation]
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        XCTAssertEqual(viewModel.resumableOperation?.id, operation.id)
    }

    func testSavedPartsRemainRecoverableWhenOriginalIsMissing() async throws {
        let operation = try service.makeCommittedOperationWithPendingChild(sourceId: sourceId)
        service.operationsBySourceId[sourceId] = [operation]
        service.previewError = MeetingSplitServiceError.sourceNotFound
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        XCTAssertEqual(viewModel.loadState, .ready)
        XCTAssertEqual(viewModel.resumableOperation?.id, operation.id)
    }

    func testReopeningRunningSheetPreservesPartTitles() async throws {
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        viewModel.updateTitle(at: 0, to: "Planning")
        let gate = Gate()
        let result = try service.makeCommittedOperationWithPendingChild(sourceId: sourceId)
        service.createAndProcessHandler = { _, _, _, _, _, _ in
            await gate.wait()
            return result
        }
        XCTAssertTrue(viewModel.submit())
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        XCTAssertEqual(viewModel.editing?.partTitles.first, "Planning")
        await gate.open()
        try await waitUntil { !self.viewModel.isProcessingActive }
    }

    func testResumeCallsResumeProcessingAndReportsCompletion() async throws {
        let committed = try service.makeCommittedOperationWithPendingChild(sourceId: sourceId)
        service.operationsBySourceId[sourceId] = [committed]
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        XCTAssertNotNil(viewModel.resumableOperation)

        service.resumeProcessingHandler = { operationId, onProgress in
            XCTAssertEqual(operationId, committed.id)
            return try self.service.markAllChildrenCompleted(committed)
        }

        XCTAssertTrue(viewModel.resume(operationId: committed.id, sourceTitle: "Weekly sync"))
        XCTAssertEqual(viewModel.activeSourceId, sourceId, "Resuming must show progress for the original source")
        XCTAssertEqual(viewModel.operation?.id, committed.id, "A receipt ID is not a child ID")
        try await waitUntil { self.viewModel.completedOperation != nil }
        XCTAssertEqual(viewModel.completedOperation?.id, committed.id)
    }

    func testRetryKeepsPublishedRecordingsVisibleBeforeNextProgressEvent() async throws {
        let committed = try service.makeCommittedOperationWithPendingChild(sourceId: sourceId)
        service.operationsBySourceId[sourceId] = [committed]
        await viewModel.present(sourceId: sourceId, sourceTitle: "Weekly sync")
        service.resumeProcessingHandler = { _, _ in committed }
        XCTAssertTrue(viewModel.resume(operationId: committed.id, sourceTitle: "Weekly sync"))
        try await waitUntil { !self.viewModel.isProcessingActive }
        XCTAssertEqual(viewModel.completedOperation?.id, committed.id)

        let gate = Gate()
        service.resumeProcessingHandler = { _, _ in
            await gate.wait()
            return committed
        }
        XCTAssertTrue(viewModel.resume(operationId: committed.id, sourceTitle: "Weekly sync"))
        XCTAssertEqual(viewModel.operation?.id, committed.id, "Retry must not hide already-published recordings")
        await gate.open()
        try await waitUntil { !self.viewModel.isProcessingActive }
    }

    // MARK: - helpers

    private func waitUntil(
        timeout: Duration = .seconds(2),
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let startedAt = ContinuousClock.now
        while !predicate() {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

// MARK: - Mock servicing

private final class MockMeetingSplitServicing: MeetingSplitServicing, @unchecked Sendable {
    var previewsBySourceId: [UUID: MeetingSplitPreview] = [:]
    var previewError: Error?
    var operationsBySourceId: [UUID: [MeetingSplitOperation]] = [:]
    var createAndProcessHandler: (
        (String, UUID, [Int], [String], String?, (@Sendable (MeetingSplitProcessingProgress) -> Void)?)
            async throws -> MeetingSplitOperation
    )?
    var resumeProcessingHandler: (
        (UUID, (@Sendable (MeetingSplitProcessingProgress) -> Void)?) async throws -> MeetingSplitOperation
    )?
    private(set) var createAndProcessCallCount = 0

    // Fixture builder: a real in-memory repository, used only to produce
    // valid `MeetingSplitOperation` values — the servicing layer itself
    // stays a plain mock the ViewModel test drives directly.
    private let fixtureManager = try! DatabaseManager()
    lazy var fixtureRepo = MeetingSplitRepository(dbQueue: fixtureManager.dbQueue)
    lazy var fixtureTranscriptionRepo = TranscriptionRepository(dbQueue: fixtureManager.dbQueue)

    func preview(sourceId: UUID, cutPointsMs: [Int]) async throws -> MeetingSplitPreview {
        if let previewError { throw previewError }
        guard let preview = previewsBySourceId[sourceId] else { throw MeetingSplitServiceError.sourceNotFound }
        return preview
    }

    func createAndProcess(
        idempotencyKey: String, sourceId: UUID, cutPointsMs: [Int], titles: [String],
        expectedSourceIdentity: String?, onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)?
    ) async throws -> MeetingSplitOperation {
        createAndProcessCallCount += 1
        guard let handler = createAndProcessHandler else {
            return try makeCommittedOperation(sourceId: sourceId, cutPointsMs: cutPointsMs, titles: titles)
        }
        return try await handler(idempotencyKey, sourceId, cutPointsMs, titles, expectedSourceIdentity, onProgress)
    }

    func resumeProcessing(
        operationId: UUID, onProgress: (@Sendable (MeetingSplitProcessingProgress) -> Void)?
    ) async throws -> MeetingSplitOperation {
        guard let handler = resumeProcessingHandler else { throw MeetingSplitRepositoryError.operationNotFound }
        return try await handler(operationId, onProgress)
    }

    func operation(id: UUID) throws -> MeetingSplitOperation? {
        operationsBySourceId.values.flatMap { $0 }.first { $0.id == id }
    }

    func operations(sourceId: UUID) throws -> [MeetingSplitOperation] {
        operationsBySourceId[sourceId] ?? []
    }

    func discard(operationId: UUID) throws -> MeetingSplitOperation {
        throw MeetingSplitRepositoryError.operationNotFound
    }

    func operationOwnership(operationId: UUID) throws -> MeetingSplitOperationOwnership {
        .notActive
    }

    // MARK: fixture builders

    func makeCommittedOperation(sourceId: UUID, cutPointsMs: [Int], titles: [String]) throws -> MeetingSplitOperation {
        let request = MeetingSplitRequest(
            sourceId: sourceId,
            expectedSourceIdentity: "fixture-identity",
            children: zip(titles, try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: cutPointsMs)).map {
                MeetingSplitChildRequest(title: $0.0, startMs: $0.1.startMs, endMs: $0.1.endMs)
            },
            destinationRootPath: FileManager.default.temporaryDirectory.path
        )
        let key = "fixture-\(UUID().uuidString)"
        let begun = try fixtureRepo.begin(idempotencyKey: key, request: request)
        // A fixed whole-second `createdAt`: GRDB's Date storage round-trips
        // exactly for whole seconds, avoiding sub-millisecond drift between
        // this in-memory snapshot and the value `publish` re-fetches.
        let source = try fixtureTranscriptionRepo.fetch(id: sourceId)
            ?? Transcription(
                id: sourceId, createdAt: Date(timeIntervalSince1970: 1_757_000_000),
                fileName: "Weekly sync", status: .completed, sourceType: .meeting
            )
        try fixtureTranscriptionRepo.save(source)
        let prepared = begun.childIds.map { MeetingSplitPreparedChild(childId: $0) }
        // Left at the default `.pendingTranscription`/`.none` progress: good
        // enough for `createAndProcess` fixtures (no failed outcome to trip
        // the ViewModel's failure surface) and for "still incomplete, thus
        // resumable" fixtures alike. Tests that need a fully finished
        // operation call `markAllChildrenCompleted` explicitly.
        return try fixtureRepo.publish(
            operationId: begun.id, preparedChildren: prepared,
            expectedSource: MeetingSplitSourceSnapshot(source: source)
        )
    }

    func makeCommittedOperationWithPendingChild(sourceId: UUID) throws -> MeetingSplitOperation {
        try makeCommittedOperation(sourceId: sourceId, cutPointsMs: [5_000], titles: ["Part 1", "Part 2"])
    }

    func markAllChildrenCompleted(_ operation: MeetingSplitOperation) throws -> MeetingSplitOperation {
        var current = operation
        for childId in operation.childIds {
            current = try fixtureRepo.markChildTranscriptionStarted(operationId: operation.id, childId: childId, now: Date())
            current = try fixtureRepo.markChildTranscriptionSucceeded(operationId: operation.id, childId: childId, now: Date())
            current = try fixtureRepo.markChildAutomationStarted(operationId: operation.id, childId: childId, now: Date())
            current = try fixtureRepo.markChildAutomationSucceeded(operationId: operation.id, childId: childId, now: Date())
        }
        return current
    }
}
