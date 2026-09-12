import AVFoundation
import GRDB
import XCTest
@testable import MacParakeetCore

/// Synthetic two/three-part end-to-end coverage for `MeetingSplitService`,
/// plus focused interruption/retry/cancellation/deletion/ownership
/// regressions. Uses real temp audio files and a real in-memory database,
/// with mocked speech/LLM providers per plan #895 U2.
final class MeetingSplitServiceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue!
    private var transcriptions: TranscriptionRepository!
    private var splitRepo: MeetingSplitRepository!
    private var promptRepo: MockPromptRepository!
    private var promptResultRepo: MockPromptResultRepository!
    private var llm: MockLLMService!
    private var transcribing: RecordingMeetingSplitAudioTranscribing!
    private var recordingsRoot: URL!

    override func setUp() async throws {
        manager = try DatabaseManager()
        dbQueue = manager.dbQueue
        transcriptions = TranscriptionRepository(dbQueue: dbQueue)
        splitRepo = MeetingSplitRepository(dbQueue: dbQueue)
        promptRepo = MockPromptRepository()
        promptResultRepo = MockPromptResultRepository()
        llm = MockLLMService()
        transcribing = RecordingMeetingSplitAudioTranscribing(repo: transcriptions)
        recordingsRoot = try makeTemporaryDirectory()
    }

    override func tearDown() {
        if let recordingsRoot {
            try? FileManager.default.removeItem(at: recordingsRoot)
        }
    }

    private func makeService(
        retentionConfig: @escaping @Sendable () -> MeetingAudioRetention = { .make(mode: .keepForever) },
        destinationRoot: URL? = nil,
        splitRepo overrideSplitRepo: MeetingSplitRepositoryProtocol? = nil
    ) -> MeetingSplitService {
        let root = destinationRoot ?? recordingsRoot!
        let completion = SavedAudioAutoPromptCompletionService(
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            llmService: llm
        )
        return MeetingSplitService(
            transcriptionRepo: transcriptions,
            splitRepo: overrideSplitRepo ?? splitRepo,
            transcriptionService: transcribing,
            completionService: completion,
            meetingRecordingsRootURL: { root },
            retentionConfig: retentionConfig
        )
    }

    // MARK: - Synthetic end-to-end success

    func testCreateAndProcessTwoPartsEndToEndWithEnabledSummary() async throws {
        let source = try makeSourceMeeting(durationMs: 8_000, withRawTracks: true)
        let sourceBeforeSplit = try XCTUnwrap(transcriptions.fetch(id: source.id))
        promptRepo.prompts = [Prompt(name: "Summary", content: "Summarize {{transcript}}", isAutoRun: true)]
        llm.summarizeResult = "Child summary"
        let service = makeService()

        let operation = try await service.createAndProcess(
            idempotencyKey: "op-1",
            sourceId: source.id,
            cutPointsMs: [4_000],
            titles: ["Part 1", "Part 2"]
        )

        XCTAssertEqual(operation.status, .committed)
        XCTAssertEqual(operation.childIds.count, 2)
        XCTAssertTrue(operation.childProgress.allSatisfy { $0.stage == .automationCompleted && $0.outcome == .none })

        for childId in operation.childIds {
            let child = try XCTUnwrap(transcriptions.fetch(id: childId))
            XCTAssertEqual(child.sourceType, .meeting)
            XCTAssertEqual(child.status, .completed)
            XCTAssertNotNil(child.rawTranscript)
            XCTAssertNotNil(child.splitProvenance)
            let results = try promptResultRepo.fetchAll(transcriptionId: childId)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.content, "Child summary")
        }

        // The original recording is never touched.
        let unchangedSource = try XCTUnwrap(transcriptions.fetch(id: source.id))
        XCTAssertEqual(unchangedSource.updatedAt, sourceBeforeSplit.updatedAt)
        XCTAssertNil(unchangedSource.splitProvenance)

        XCTAssertEqual(transcribing.retranscribeMeetingCallCount, 2, "aligned children use the archived meeting route")
        XCTAssertEqual(transcribing.retranscribeCallCount, 0)
    }

    /// The caller must observe every real stage transition for each child —
    /// not just one stale snapshot fired at child entry — so a native
    /// progress UI can show truthful transcribing/automationPending/completed
    /// states instead of appearing stuck.
    func testProgressReportsEveryStageTransitionPerChild() async throws {
        let source = try makeSourceMeeting(durationMs: 8_000, withRawTracks: true)
        promptRepo.prompts = [Prompt(name: "Summary", content: "Summarize {{transcript}}", isAutoRun: true)]
        llm.summarizeResult = "Child summary"
        let service = makeService()

        final class ProgressBox: @unchecked Sendable {
            let lock = NSLock()
            var events: [MeetingSplitProcessingProgress] = []
            func append(_ event: MeetingSplitProcessingProgress) {
                lock.lock()
                defer { lock.unlock() }
                events.append(event)
            }
        }
        let box = ProgressBox()

        let operation = try await service.createAndProcess(
            idempotencyKey: "op-progress",
            sourceId: source.id,
            cutPointsMs: [4_000],
            titles: ["Part 1", "Part 2"],
            onProgress: { box.append($0) }
        )

        XCTAssertEqual(operation.status, .committed)
        XCTAssertTrue(box.events.allSatisfy { $0.operationId == operation.id })
        for childId in operation.childIds {
            let childStages = box.events.filter { $0.childId == childId }.map(\.stage)
            XCTAssertEqual(
                childStages,
                [.pendingTranscription, .transcribing, .transcribed, .automationPending, .automationCompleted],
                "expected every real stage transition to be observed in order for child \(childId)"
            )
        }
    }

    func testCanonicalOnlySourceUsesSingleFileRouteAndGetsActualSTT() async throws {
        let source = try makeSourceMeeting(durationMs: 5_000, withRawTracks: false)
        promptRepo.prompts = []
        let service = makeService()

        let operation = try await service.createAndProcess(
            idempotencyKey: "op-canonical",
            sourceId: source.id,
            cutPointsMs: [2_500],
            titles: ["Part 1", "Part 2"]
        )

        XCTAssertTrue(operation.childProgress.allSatisfy { $0.stage == .automationCompleted })
        XCTAssertEqual(transcribing.retranscribeCallCount, 2, "canonical-only children use the single-file route")
        XCTAssertEqual(transcribing.retranscribeMeetingCallCount, 0)
        for childId in operation.childIds {
            let child = try XCTUnwrap(transcriptions.fetch(id: childId))
            XCTAssertNotNil(child.rawTranscript, "canonical-only children must still receive real STT, not empty success")
        }
    }

    func testDisabledAutomationProducesNoLLMCallOrSavedResult() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: true)
        promptRepo.prompts = [Prompt(name: "Manual only", content: "Summarize", isAutoRun: false)]
        let service = makeService()

        let operation = try await service.createAndProcess(
            idempotencyKey: "op-disabled",
            sourceId: source.id,
            cutPointsMs: [2_000],
            titles: ["Part 1", "Part 2"]
        )

        XCTAssertTrue(operation.childProgress.allSatisfy { $0.stage == .automationCompleted })
        XCTAssertEqual(llm.summarizeCallCount, 0)
        for childId in operation.childIds {
            XCTAssertTrue(try promptResultRepo.fetchAll(transcriptionId: childId).isEmpty)
        }
    }

    // MARK: - Actual TranscriptionService pipeline (not solely a narrow protocol mock)

    /// Exercises the real `TranscriptionService.retranscribe` pipeline (the
    /// same production type the CLI factory constructs), not just the
    /// narrow `MeetingSplitAudioTranscribing` mock every other test in this
    /// file uses, for a canonical-only child. Only the lowest-level STT
    /// client and audio converter are faked.
    func testCanonicalOnlyChildRoutesThroughTheActualTranscriptionServicePipeline() async throws {
        let source = try makeSourceMeeting(durationMs: 3_000, withRawTracks: false)
        let sttClient = MockSTTClient()
        await sttClient.configure(result: STTResult(text: "real pipeline transcript"))
        let audioProcessor = MockAudioProcessor()
        let realTranscriptionService = TranscriptionService(
            audioProcessor: audioProcessor,
            sttTranscriber: sttClient,
            transcriptionRepo: transcriptions,
            shouldDiarizeMeetings: { false }
        )
        let completion = SavedAudioAutoPromptCompletionService(
            promptRepo: promptRepo, promptResultRepo: promptResultRepo, llmService: llm
        )
        let service = MeetingSplitService(
            transcriptionRepo: transcriptions,
            splitRepo: splitRepo,
            transcriptionService: realTranscriptionService,
            completionService: completion,
            meetingRecordingsRootURL: { [recordingsRoot] in recordingsRoot! }
        )

        let operation = try await service.createAndProcess(
            idempotencyKey: "op-real-pipeline", sourceId: source.id, cutPointsMs: [1_500], titles: ["Part 1", "Part 2"]
        )

        XCTAssertTrue(operation.childProgress.allSatisfy { $0.stage != .pendingTranscription })
        for childId in operation.childIds {
            let child = try XCTUnwrap(transcriptions.fetch(id: childId))
            XCTAssertEqual(child.rawTranscript, "real pipeline transcript")
        }
        let convertCallCount = await audioProcessor.convertCallCount
        XCTAssertEqual(convertCallCount, 2, "the actual audio-conversion step must run for each canonical-only child")
    }

    // MARK: - Individual failure continues and is independently retryable

    func testIndividualChildSTTFailureIsRetryableWithoutRerunningSucceededSiblings() async throws {
        let source = try makeSourceMeeting(durationMs: 6_000, withRawTracks: true)
        let service = makeService()
        // The 2nd STT call (the second child, since processing is sequential
        // and in order) fails; the 1st (first child) succeeds normally.
        transcribing.errorOnCallNumber[2] = LLMError.providerError("stt crashed")

        let firstAttempt = try await service.createAndProcess(
            idempotencyKey: "op-manual",
            sourceId: source.id,
            cutPointsMs: [3_000],
            titles: ["Part 1", "Part 2"]
        )
        let firstChildId = firstAttempt.childIds[0]
        let failingChildId = firstAttempt.childIds[1]
        let firstProgress = try XCTUnwrap(firstAttempt.childProgress.first { $0.childId == firstChildId })
        XCTAssertEqual(firstProgress.stage, .automationCompleted)
        let secondProgress = try XCTUnwrap(firstAttempt.childProgress.first { $0.childId == failingChildId })
        XCTAssertEqual(secondProgress.outcome, .failed)
        XCTAssertNotEqual(secondProgress.stage, .automationCompleted)
        XCTAssertEqual(try transcriptions.fetch(id: failingChildId)?.status, .error)

        // Retry after clearing the error: the succeeded sibling must not be
        // retranscribed again.
        transcribing.errorOnCallNumber.removeAll()
        let callsBeforeRetry = transcribing.recordedChildIds.count
        let afterRetry = try await service.resumeProcessing(operationId: firstAttempt.id)

        XCTAssertTrue(afterRetry.childProgress.allSatisfy { $0.stage == .automationCompleted })
        XCTAssertFalse(
            transcribing.recordedChildIds[callsBeforeRetry...].contains(firstChildId),
            "a previously succeeded child must not be retranscribed on retry"
        )
    }

    func testCancellationDuringProcessingStopsAtTheCancelledChildWithoutUndoingEarlierSuccess() async throws {
        let source = try makeSourceMeeting(durationMs: 6_000, withRawTracks: true)
        let service = makeService()
        // Simulates cancellation observed while attempting the second child's
        // speech step (the same place a real cooperative cancellation check
        // would surface it).
        transcribing.cancelOnCallNumber = 2

        var operationId: UUID?
        do {
            let operation = try await service.createAndProcess(
                idempotencyKey: "op-cancel",
                sourceId: source.id,
                cutPointsMs: [3_000],
                titles: ["Part 1", "Part 2"]
            )
            operationId = operation.id
            XCTFail("expected CancellationError to propagate")
        } catch is CancellationError {
            operationId = try XCTUnwrap(splitRepo.operation(idempotencyKey: "op-cancel")).id
        }

        let final = try XCTUnwrap(try splitRepo.operation(id: XCTUnwrap(operationId)))
        let first = try XCTUnwrap(final.childProgress.first { $0.childId == final.childIds[0] })
        XCTAssertEqual(first.stage, .automationCompleted, "the already-finished first child must not be undone")
        let second = try XCTUnwrap(final.childProgress.first { $0.childId == final.childIds[1] })
        XCTAssertEqual(second.outcome, .cancelled)
        XCTAssertNotEqual(second.stage, .automationCompleted)
        XCTAssertEqual(try transcriptions.fetch(id: final.childIds[1])?.status, .error)
    }

    /// A fatal, non-cancellation repository fault that escapes the per-child
    /// handling (here: `markChildFailed` itself failing while persisting the
    /// first child's own ordinary transcription failure) must settle every
    /// other unfinished sibling as `.failed`, never `.cancelled` — a real
    /// fault is not a deliberate stop — and the original fault must still
    /// propagate to the caller, never masked by that settlement.
    func testFatalNonCancellationRepositoryFaultSettlesSiblingsAsFailedNotCancelledWithoutMaskingTheFault() async throws {
        let source = try makeSourceMeeting(durationMs: 6_000, withRawTracks: false)
        transcribing.errorOnCallNumber[1] = LLMError.providerError("boom")
        let faultyRepo = FaultInjectingSplitRepository(wrapping: splitRepo)
        let service = makeService(splitRepo: faultyRepo)

        do {
            _ = try await service.createAndProcess(
                idempotencyKey: "fatal-repo-fault", sourceId: source.id,
                cutPointsMs: [2_000, 4_000], titles: ["One", "Two", "Three"]
            )
            XCTFail("expected the injected repository fault to propagate")
        } catch is FaultInjectingSplitRepository.InjectedFault {
            // Expected: the primary fault is never masked by settlement.
        }

        let operation = try XCTUnwrap(splitRepo.operation(idempotencyKey: "fatal-repo-fault"))
        XCTAssertEqual(operation.childProgress.count, 3)
        XCTAssertTrue(
            operation.childProgress.allSatisfy { $0.outcome == .failed },
            "a fatal non-cancellation fault must settle every unfinished sibling as failed"
        )
        XCTAssertTrue(operation.childProgress.allSatisfy { $0.outcome != .cancelled })
    }

    func testInitialPreviewNeedsNoCutAndCanInspectErroredAudio() async throws {
        var source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        source.status = .error
        try transcriptions.save(source)
        let preview = try await makeService().preview(sourceId: source.id, cutPointsMs: [])
        let saved = try XCTUnwrap(transcriptions.fetch(id: source.id))
        let standalone = try await MeetingSplitService.preview(source: saved, cutPointsMs: [], retention: .keepForever)
        XCTAssertEqual(standalone, preview, "Read-only callers need no processing services")
        let encoded = try JSONEncoder().encode(preview)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSplitPreview.self, from: encoded).sourceIdentity, preview.sourceIdentity)
        XCTAssertEqual(preview.ranges, [.init(startMs: 0, endMs: preview.totalDurationMs)])
        XCTAssertTrue(try splitRepo.operations(sourceId: source.id).isEmpty)
    }

    func testResumeUsesSavedPathsAfterDestinationPreferenceChanges() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        transcribing.errorOnCallNumber[1] = LLMError.providerError("temporary failure")
        let operation = try await makeService().createAndProcess(
            idempotencyKey: "changed-root", sourceId: source.id,
            cutPointsMs: [2_000], titles: ["Planning", "Review"]
        )
        transcribing.errorOnCallNumber.removeAll()
        let newRoot = recordingsRoot.appendingPathComponent("new-location")
        let resumed = try await makeService(destinationRoot: newRoot).resumeProcessing(operationId: operation.id)
        XCTAssertEqual(resumed.childIds, operation.childIds)
        XCTAssertTrue(resumed.childProgress.allSatisfy { $0.stage == .automationCompleted })
        XCTAssertFalse(FileManager.default.fileExists(atPath: newRoot.path))
    }

    func testDestinationInsideOriginalIsRejectedWithoutWriting() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        let sourceFolder = try XCTUnwrap(MeetingArtifactStore.sessionFolderURL(for: source))
        let destination = sourceFolder.appendingPathComponent("parts")
        do {
            _ = try await makeService(destinationRoot: destination).createAndProcess(
                idempotencyKey: "overlapping-root", sourceId: source.id,
                cutPointsMs: [2_000], titles: ["One", "Two"]
            )
            XCTFail("A split cannot store its parts inside the original")
        } catch is MeetingSplitAudioExportError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try splitRepo.operations(sourceId: source.id).isEmpty)
    }

    func testDiscardRefusesBusyMediaWithoutMarkingOperationDiscarded() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        let operation = try splitRepo.begin(
            idempotencyKey: "discard-busy",
            request: .init(sourceId: source.id, expectedSourceIdentity: "test", children: [
                .init(title: "One", startMs: 0, endMs: 2_000),
                .init(title: "Two", startMs: 2_000, endMs: 4_000)
            ])
        )
        let lease = try MeetingMediaMutationLease.acquire(roots: [recordingsRoot])
        defer { lease.release() }
        XCTAssertThrowsError(try makeService().discard(operationId: operation.id))
        XCTAssertEqual(try splitRepo.operation(id: operation.id)?.status, .preparing)
    }

    func testCancellationSettlesUnstartedPartsWithoutLosingAudio() async throws {
        let source = try makeSourceMeeting(durationMs: 6_000, withRawTracks: false)
        transcribing.cancelOnCallNumber = 1
        do {
            _ = try await makeService().createAndProcess(
                idempotencyKey: "cancel-all", sourceId: source.id,
                cutPointsMs: [2_000, 4_000], titles: ["One", "Two", "Three"]
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let operation = try XCTUnwrap(splitRepo.operation(idempotencyKey: "cancel-all"))
        for id in operation.childIds {
            let row = try XCTUnwrap(transcriptions.fetch(id: id))
            XCTAssertEqual(row.status, .error, "Stopped work must not leave a permanent processing spinner")
            XCTAssertNil(row.rawTranscript)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(row.filePath)))
        }
    }

    /// Cancellation observed while export is still writing the final
    /// child's audio (before the pre-publication cancellation check and
    /// `publish` itself even run) must leave the operation `.preparing` with
    /// no child rows committed at all — never a partially published split.
    func testCancellationDuringExportLeavesOperationPreparingWithNothingPublished() async throws {
        let source = try makeSourceMeeting(durationMs: 6_000, withRawTracks: false)
        let cancelling = CancellingExporterHook()
        let exporter = MeetingSplitAudioExporter(
            testHooks: .init(afterEachChunk: { _ in cancelling.maybeCancel() })
        )
        let completion = SavedAudioAutoPromptCompletionService(
            promptRepo: promptRepo, promptResultRepo: promptResultRepo, llmService: llm
        )
        let service = MeetingSplitService(
            transcriptionRepo: transcriptions,
            splitRepo: splitRepo,
            transcriptionService: transcribing,
            completionService: completion,
            exporter: exporter,
            meetingRecordingsRootURL: { [recordingsRoot] in recordingsRoot! }
        )

        let task = Task {
            try await service.createAndProcess(
                idempotencyKey: "op-cancel-export", sourceId: source.id, cutPointsMs: [3_000], titles: ["Part 1", "Part 2"]
            )
        }
        cancelling.armCancellation(for: task)
        do {
            _ = try await task.value
            XCTFail("expected CancellationError from mid-export cancellation")
        } catch is CancellationError {
            // expected
        }

        let operation = try XCTUnwrap(splitRepo.operation(idempotencyKey: "op-cancel-export"))
        XCTAssertEqual(operation.status, .preparing, "a cancelled export must never reach commit")
        for childId in operation.childIds {
            XCTAssertNil(try transcriptions.fetch(id: childId), "no child row may exist before publish commits")
        }
        XCTAssertEqual(transcribing.recordedChildIds.count, 0, "processing must never start before audio is committed")
    }

    // MARK: - Crash-window reconciliation

    func testResumeSkipsRedundantSTTWhenTranscriptWasPersistedBeforeStageReceipt() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: true)
        let service = makeService()
        // Publish the audio only: prevent any processing yet by making the
        // very first STT call cancel immediately.
        transcribing.cancelOnCallNumber = 1
        do {
            _ = try await service.createAndProcess(
                idempotencyKey: "op-race", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"]
            )
            XCTFail("expected CancellationError from the seeded cancel point")
        } catch is CancellationError {
            // expected: audio is now published, no child processed yet.
        }
        let begun = try XCTUnwrap(splitRepo.operation(idempotencyKey: "op-race"))
        let raceChildId = begun.childIds[0]
        transcribing.cancelOnCallNumber = nil
        transcribing.recordedChildIds.removeAll()

        // Simulate the exact crash window: speech persisted the row, but the
        // operation's own stage update never landed (still `.pendingTranscription`).
        var child = try XCTUnwrap(transcriptions.fetch(id: raceChildId))
        child.rawTranscript = "already persisted by a crashed prior attempt"
        child.cleanTranscript = "already persisted by a crashed prior attempt"
        child.status = .completed
        try transcriptions.save(child)

        let resumed = try await service.resumeProcessing(operationId: begun.id)

        XCTAssertFalse(
            transcribing.recordedChildIds.contains(raceChildId),
            "must not re-run STT for a child whose transcript is already durably persisted"
        )
        let progress = try XCTUnwrap(resumed.childProgress.first { $0.childId == raceChildId })
        XCTAssertEqual(progress.stage, .automationCompleted)
    }

    // MARK: - Deletion during processing

    func testChildDeletedDuringProcessingIsSkippedNotRecreated() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: true)
        let service = makeService()
        // Publish audio without processing (same seeded-cancel trick as above).
        transcribing.cancelOnCallNumber = 1
        do {
            _ = try await service.createAndProcess(
                idempotencyKey: "op-delete", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"]
            )
            XCTFail("expected CancellationError from the seeded cancel point")
        } catch is CancellationError {
            // expected
        }
        let begun = try XCTUnwrap(splitRepo.operation(idempotencyKey: "op-delete"))
        transcribing.cancelOnCallNumber = nil

        let deletedChildId = begun.childIds[0]
        _ = try transcriptions.delete(id: deletedChildId)

        let resumed = try await service.resumeProcessing(operationId: begun.id)

        XCTAssertNil(try transcriptions.fetch(id: deletedChildId), "must never be recreated")
        let survivor = try XCTUnwrap(transcriptions.fetch(id: begun.childIds[1]))
        XCTAssertEqual(survivor.status, .completed)
        let survivorProgress = try XCTUnwrap(resumed.childProgress.first { $0.childId == begun.childIds[1] })
        XCTAssertEqual(survivorProgress.stage, .automationCompleted)
    }

    // MARK: - Operation ownership (kernel-backed claim)

    /// Two concurrent `createAndProcess` calls under the SAME idempotency key
    /// must never both proceed to export/publish: the loser observes a clean
    /// busy failure rather than silently double-exporting.
    func testConcurrentCreateAndProcessUnderTheSameKeyNeverBothProceed() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        let firstServiceSTT = BlockingMeetingSplitAudioTranscribing()
        let firstService = MeetingSplitService(
            transcriptionRepo: transcriptions,
            splitRepo: splitRepo,
            transcriptionService: firstServiceSTT,
            completionService: SavedAudioAutoPromptCompletionService(
                promptRepo: promptRepo, promptResultRepo: promptResultRepo, llmService: llm),
            meetingRecordingsRootURL: { [recordingsRoot] in recordingsRoot! }
        )
        let secondService = makeService()

        // Hold the first caller inside its own processing loop (past
        // publish, so the operation lease is provably still held) while the
        // second caller races in under the identical key.
        let firstTask = Task {
            try await firstService.createAndProcess(
                idempotencyKey: "op-concurrent", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"]
            )
        }
        await firstServiceSTT.waitUntilFirstCallStarted()

        do {
            _ = try await secondService.createAndProcess(
                idempotencyKey: "op-concurrent", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"]
            )
            XCTFail("expected the second concurrent caller to observe the operation lease as busy")
        } catch let error as MeetingSplitOperationLease.AcquisitionError {
            guard case .busy = error else {
                return XCTFail("expected .busy, got \(error)")
            }
        }

        await firstServiceSTT.releaseFirstCall()
        let finished = try await firstTask.value
        XCTAssertEqual(finished.status, .committed)
        XCTAssertEqual(try splitRepo.operations(sourceId: source.id).count, 1, "only one operation must ever exist for this key")
    }

    func testOperationOwnershipReflectsAnActiveLeaseHolder() async throws {
        let source = try makeSourceMeeting(durationMs: 3_000, withRawTracks: false)
        let service = makeService()
        let operation = try await service.createAndProcess(
            idempotencyKey: "op-ownership", sourceId: source.id, cutPointsMs: [1_500], titles: ["Part 1", "Part 2"]
        )
        XCTAssertEqual(try service.operationOwnership(operationId: operation.id), .notActive)

        let externalLease = try MeetingSplitOperationLease.acquire(
            idempotencyKey: operation.idempotencyKey, meetingRecordingsRootURL: recordingsRoot)
        defer { externalLease.release() }
        XCTAssertEqual(try service.operationOwnership(operationId: operation.id), .activelyOwned)
    }

    // MARK: - createIfNeeded: idempotency compared before touching the source

    /// A same-key retry after the source (and its already-committed children)
    /// have been deleted must still return the committed operation — the
    /// entire point of a durable receipt — without ever needing the source
    /// to exist.
    func testCommittedRetrySucceedsAfterSourceAndChildrenAreDeleted() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        let service = makeService()
        let first = try await service.createAndProcess(
            idempotencyKey: "op-retry-after-delete", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"]
        )
        XCTAssertEqual(first.status, .committed)

        _ = try transcriptions.delete(id: source.id)
        for childId in first.childIds {
            _ = try transcriptions.delete(id: childId)
        }

        let retried = try await service.createAndProcess(
            idempotencyKey: "op-retry-after-delete", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"]
        )
        XCTAssertEqual(retried.id, first.id)
        XCTAssertEqual(retried.status, .committed)
    }

    /// A same-key retry with a different payload (here: a different cut)
    /// must conflict before ever touching the source — including after the
    /// original source has been deleted.
    func testSameKeyDifferentCutsConflictsWithoutRequiringTheSourceToExist() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        let service = makeService()
        let sourceId = source.id
        _ = try await service.createAndProcess(
            idempotencyKey: "op-mismatch", sourceId: sourceId, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"]
        )
        _ = try transcriptions.delete(id: sourceId)

        do {
            _ = try await service.createAndProcess(
                idempotencyKey: "op-mismatch", sourceId: sourceId, cutPointsMs: [1_000], titles: ["Part 1", "Part 2"]
            )
            XCTFail("expected a request conflict for a mismatched cut under the same key")
        } catch MeetingSplitServiceError.requestConflict {
            // expected
        }
    }

    // MARK: - Explicit expected source identity

    func testCreationFailsWhenSuppliedExpectedIdentityDoesNotMatchTheProbedSource() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        let service = makeService()
        // A structurally valid but wrong identity: same source row, a
        // deliberately different (impossible) inspection, so it can never
        // match whatever `createAndProcess` actually probes.
        let staleIdentity = "a-stale-source-fingerprint"

        do {
            _ = try await service.createAndProcess(
                idempotencyKey: "op-identity", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"],
                expectedSourceIdentity: staleIdentity
            )
            XCTFail("expected creation to reject a stale expected identity")
        } catch MeetingSplitServiceError.sourceNotEligible {
            // expected
        }
        XCTAssertEqual(try splitRepo.operations(sourceId: source.id).count, 0, "a rejected identity must not persist a receipt")
    }

    func testCreationSucceedsWhenSuppliedExpectedIdentityMatchesTheProbedSource() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: false)
        let service = makeService()
        let preview = try await service.preview(sourceId: source.id, cutPointsMs: [2_000])

        let operation = try await service.createAndProcess(
            idempotencyKey: "op-identity-match", sourceId: source.id, cutPointsMs: [2_000], titles: ["Part 1", "Part 2"],
            expectedSourceIdentity: preview.sourceIdentity
        )
        XCTAssertEqual(operation.status, .committed)
    }

    // MARK: - Discard cleans up only positively-verified, exclusively-owned folders

    func testDiscardRemovesOnlyThisOperationsOwnUnpublishedChildFolder() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: true)
        let service = makeService()
        let operation = try splitRepo.begin(
            idempotencyKey: "op-discard",
            request: MeetingSplitRequest(
                sourceId: source.id, expectedSourceIdentity: "test",
                children: [MeetingSplitChildRequest(title: "Part 1", startMs: 0, endMs: 2_000)]
            )
        )
        let childFolderURL = recordingsRoot.appendingPathComponent(operation.childIds[0].uuidString, isDirectory: true)
        // Claimed the same way `finishCreating` claims it: exclusive folder
        // plus this exact operation/child's own marker, so discard can
        // positively verify ownership before removing it.
        _ = try MeetingSplitChildFolderClaimTestSeam.claim(
            operationId: operation.id, childId: operation.childIds[0], folderURL: childFolderURL,
            fileManager: .default)
        try Data("partial".utf8).write(to: childFolderURL.appendingPathComponent("meeting-playback.m4a"))

        let discarded = try service.discard(operationId: operation.id)

        XCTAssertEqual(discarded.status, .discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: childFolderURL.path))
    }

    /// A folder that merely happens to share a child's UUID name, but was not
    /// created by this operation's own claim (no marker, or a mismatched
    /// one), must never be deleted by discard: unexpected existing content
    /// fails safely.
    func testDiscardNeverRemovesAFolderWithoutThisOperationsOwnMarker() async throws {
        let source = try makeSourceMeeting(durationMs: 4_000, withRawTracks: true)
        let service = makeService()
        let operation = try splitRepo.begin(
            idempotencyKey: "op-discard-unowned",
            request: MeetingSplitRequest(
                sourceId: source.id, expectedSourceIdentity: "test",
                children: [MeetingSplitChildRequest(title: "Part 1", startMs: 0, endMs: 2_000)]
            )
        )
        let childFolderURL = recordingsRoot.appendingPathComponent(operation.childIds[0].uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: childFolderURL, withIntermediateDirectories: true)
        try Data("unrelated content".utf8).write(to: childFolderURL.appendingPathComponent("some-file.txt"))

        let discarded = try service.discard(operationId: operation.id)

        XCTAssertEqual(discarded.status, .discarded)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: childFolderURL.path),
            "a folder without this operation's own marker must be left untouched")
    }

    // MARK: - Preview never writes

    func testPreviewPerformsNoWritesAndReturnsRanges() async throws {
        let source = try makeSourceMeeting(durationMs: 9_000, withRawTracks: true)
        let service = makeService()

        let preview = try await service.preview(sourceId: source.id, cutPointsMs: [3_000, 6_000])

        XCTAssertEqual(preview.ranges.count, 3)
        XCTAssertEqual(preview.totalDurationMs, 9_000, accuracy: 1)
        XCTAssertTrue(preview.hasRawMicrophone)
        XCTAssertTrue(preview.hasRawSystem)
        XCTAssertEqual(try splitRepo.operations(sourceId: source.id).count, 0, "preview must not create an operation")
    }

    /// The raw files exist on disk, but there is no recording metadata to
    /// align them: export requires a usable alignment, not merely the file,
    /// so the capability flags must say so rather than promising a track
    /// that will never actually be exported.
    func testPreviewHasRawFlagsAreFalseWhenRawFilesExistButMetadataIsMissing() async throws {
        let source = try makeSourceMeetingWithRawFilesButUnusableMetadata(durationMs: 6_000, metadataIsCorrupt: false)
        let service = makeService()

        let preview = try await service.preview(sourceId: source.id, cutPointsMs: [3_000])

        XCTAssertFalse(preview.hasRawMicrophone)
        XCTAssertFalse(preview.hasRawSystem)
        XCTAssertFalse(preview.hasCleanedMicrophone)
    }

    /// A corrupt (unparseable) metadata sidecar must be treated exactly like
    /// a missing one: canonical-only capability, never a thrown error from
    /// `preview` itself.
    func testPreviewHasRawFlagsAreFalseWhenMetadataFileIsCorrupt() async throws {
        let source = try makeSourceMeetingWithRawFilesButUnusableMetadata(durationMs: 6_000, metadataIsCorrupt: true)
        let service = makeService()

        let preview = try await service.preview(sourceId: source.id, cutPointsMs: [3_000])

        XCTAssertFalse(preview.hasRawMicrophone)
        XCTAssertFalse(preview.hasRawSystem)
        XCTAssertFalse(preview.hasCleanedMicrophone)
    }

    /// Missing/corrupt metadata must never block splitting itself: every
    /// part still gets its own successful independent canonical-only export
    /// and first transcription, even though raw files are physically present
    /// alongside the source's canonical playback.
    func testSplitSucceedsCanonicalOnlyWhenRawFilesExistButMetadataIsMissingOrCorrupt() async throws {
        let source = try makeSourceMeetingWithRawFilesButUnusableMetadata(durationMs: 6_000, metadataIsCorrupt: true)
        let service = makeService()

        let operation = try await service.createAndProcess(
            idempotencyKey: "canonical-fallback", sourceId: source.id,
            cutPointsMs: [3_000], titles: ["One", "Two"]
        )

        XCTAssertEqual(operation.status, .committed)
        XCTAssertTrue(operation.childProgress.allSatisfy { $0.stage == .automationCompleted })
        for childId in operation.childIds {
            let child = try XCTUnwrap(transcriptions.fetch(id: childId))
            XCTAssertNotNil(child.rawTranscript, "each part must still receive its own first transcription")
            let folderURL = try XCTUnwrap(MeetingArtifactStore.sessionFolderURL(for: child))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback).path),
                "canonical playback must always be exported"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone).path),
                "no usable alignment means the raw mic track is never exported for any part"
            )
        }
    }

    // MARK: - Retention

    func testExpiredRetentionRejectsCreation() async throws {
        let source = try makeSourceMeeting(
            durationMs: 4_000, withRawTracks: true, createdAt: Date().addingTimeInterval(-90 * 24 * 3_600)
        )
        let service = makeService(retentionConfig: { MeetingAudioRetention.make(mode: .deleteAfterDays, days: 30) })

        do {
            _ = try await service.createAndProcess(
                idempotencyKey: "op-expired", sourceId: source.id, cutPointsMs: [2_000], titles: ["A", "B"]
            )
            XCTFail("expected sourceExpiredByRetention")
        } catch MeetingSplitServiceError.sourceExpiredByRetention {
            // expected
        }
        XCTAssertEqual(
            try splitRepo.operations(sourceId: source.id).count, 0, "an ineligible source must not persist a receipt"
        )
    }

    // MARK: - Helpers

    private func makeSourceMeeting(
        durationMs: Int,
        withRawTracks: Bool,
        createdAt: Date = Date()
    ) throws -> Transcription {
        let folderURL = recordingsRoot.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try writeToneM4A(
            to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: durationMs
        )
        var alignment = MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil)
        if withRawTracks {
            try writeToneM4A(
                to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone),
                sampleRate: 48_000, durationMs: durationMs
            )
            try writeToneM4A(
                to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem),
                sampleRate: 48_000, durationMs: durationMs
            )
            let track = MeetingSourceAlignment.Track(
                firstHostTime: 1, lastHostTime: 2, startOffsetMs: 0,
                writtenFrameCount: Int64(Double(durationMs) / 1_000 * 48_000), sampleRate: 48_000
            )
            alignment = MeetingSourceAlignment(meetingOriginHostTime: 1, microphone: track, system: track)
        }
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(sourceAlignment: alignment), folderURL: folderURL
        )

        let transcription = Transcription(
            createdAt: createdAt,
            fileName: "Long standup recording",
            meetingArtifactFolderPath: folderURL.path,
            durationMs: durationMs,
            status: .completed,
            sourceType: .meeting,
            updatedAt: createdAt
        )
        try transcriptions.save(transcription)
        return transcription
    }

    /// Raw mic/system/cleaned-mic files all physically exist, but the
    /// recording metadata sidecar that would align them is either entirely
    /// absent or present-but-unparseable — the two ways a real source can
    /// end up with no usable alignment despite having raw files on disk.
    private func makeSourceMeetingWithRawFilesButUnusableMetadata(
        durationMs: Int, metadataIsCorrupt: Bool
    ) throws -> Transcription {
        let folderURL = recordingsRoot.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try writeToneM4A(
            to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000, durationMs: durationMs
        )
        try writeToneM4A(
            to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone),
            sampleRate: 48_000, durationMs: durationMs
        )
        try writeToneM4A(
            to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem),
            sampleRate: 48_000, durationMs: durationMs
        )
        try writeToneM4A(
            to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.cleanedMicrophone),
            sampleRate: 48_000, durationMs: durationMs
        )
        if metadataIsCorrupt {
            try Data("not valid json".utf8).write(
                to: folderURL.appendingPathComponent(MeetingRecordingMetadata.fileName))
        }
        // else: no metadata sidecar at all.

        let transcription = Transcription(
            fileName: "Long standup recording",
            meetingArtifactFolderPath: folderURL.path,
            durationMs: durationMs,
            status: .completed,
            sourceType: .meeting
        )
        try transcriptions.save(transcription)
        return transcription
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSplitServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeToneM4A(to url: URL, sampleRate: Double, durationMs: Int) throws {
        let frameCount = max(1, Int((Double(durationMs) * sampleRate / 1_000).rounded()))
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frameCount {
            samples[index] = Float(0.2 * sin(2 * .pi * 440 * Double(index) / sampleRate))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

/// Records every child transcribed and which route was used, so tests can
/// assert canonical-only vs aligned routing without a real speech engine.
/// Persists into the same repository `MeetingSplitService` reads from, like
/// the real `TranscriptionService` does internally.
private final class RecordingMeetingSplitAudioTranscribing: MeetingSplitAudioTranscribing, @unchecked Sendable {
    private let repo: TranscriptionRepositoryProtocol
    private(set) var retranscribeCallCount = 0
    private(set) var retranscribeMeetingCallCount = 0
    var recordedChildIds: [UUID] = []
    /// 1-based: the Nth speech call across both routes throws this error.
    var errorOnCallNumber: [Int: Error] = [:]
    /// 1-based: the Nth speech call throws `CancellationError`, simulating a
    /// cooperative cancellation check observed mid-STT.
    var cancelOnCallNumber: Int?

    init(repo: TranscriptionRepositoryProtocol) {
        self.repo = repo
    }

    func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        retranscribeCallCount += 1
        try attempt(childId: transcription.id)
        return try persistTranscribed(transcription)
    }

    func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        retranscribeMeetingCallCount += 1
        try attempt(childId: transcription.id)
        return try persistTranscribed(transcription)
    }

    private func attempt(childId: UUID) throws {
        recordedChildIds.append(childId)
        let callNumber = recordedChildIds.count
        if cancelOnCallNumber == callNumber {
            throw CancellationError()
        }
        if let error = errorOnCallNumber[callNumber] {
            throw error
        }
    }

    private func persistTranscribed(_ transcription: Transcription) throws -> Transcription {
        var updated = transcription
        updated.rawTranscript = "synthetic transcript for \(transcription.id.uuidString.prefix(8))"
        updated.cleanTranscript = updated.rawTranscript
        updated.status = .completed
        try repo.save(updated)
        return updated
    }
}

/// Blocks its first speech call until explicitly released, so a test can
/// prove a second concurrent caller observes the operation lease as busy
/// while the first is provably still inside its own processing loop.
private final class BlockingMeetingSplitAudioTranscribing: MeetingSplitAudioTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var shouldRelease = false

    func waitUntilFirstCallStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if hasStarted {
                lock.unlock()
                continuation.resume()
            } else {
                startedContinuation = continuation
                lock.unlock()
            }
        }
    }

    func releaseFirstCall() async {
        lock.lock()
        shouldRelease = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if shouldRelease {
                lock.unlock()
                continuation.resume()
            } else {
                releaseContinuation = continuation
                lock.unlock()
            }
        }
    }

    private func markStarted() {
        lock.lock()
        hasStarted = true
        let continuation = startedContinuation
        startedContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        markStarted()
        await waitForRelease()
        var updated = transcription
        updated.rawTranscript = "blocked-then-released"
        updated.cleanTranscript = updated.rawTranscript
        updated.status = .completed
        return updated
    }

    func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        speechEngineOverride: SpeechEngineSelection?,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        try await retranscribe(
            existing: transcription, fileURL: URL(fileURLWithPath: "/dev/null"), source: .meeting,
            speechEngineOverride: speechEngineOverride, onProgress: onProgress)
    }
}

/// Deterministic mid-export cancellation seam: invokes the armed cancel
/// closure the first time the exporter's write loop reports a chunk, so the
/// test never races a timer against the writer.
private final class CancellingExporterHook: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (@Sendable () -> Void)?
    private var hasCancelled = false

    func armCancellation<T, E>(for task: Task<T, E>) {
        lock.lock()
        cancel = { task.cancel() }
        lock.unlock()
    }

    func maybeCancel() {
        let cancelToRun: (@Sendable () -> Void)? = lock.withLock {
            guard !hasCancelled, let cancel else { return nil }
            hasCancelled = true
            return cancel
        }
        cancelToRun?()
    }
}

/// Test-only access to the package-internal folder claim helper, so a test
/// can set up a folder exactly the way `MeetingSplitService` itself does
/// (exclusive creation plus this operation/child's own marker) without
/// duplicating that logic.
private enum MeetingSplitChildFolderClaimTestSeam {
    static func claim(operationId: UUID, childId: UUID, folderURL: URL, fileManager: FileManager) throws -> URL {
        try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: fileManager)
    }
}

/// Wraps a real `MeetingSplitRepositoryProtocol`, injecting one fatal,
/// non-cancellation fault the Nth time `markChildFailed` is called (default:
/// the very first call), then delegating every call afterward — including
/// every later call to `markChildFailed` itself — straight to the wrapped
/// repository. This reproduces the narrow seam where a real repository fault
/// can escape `processAll`'s per-child handling: a `markChild*` call made
/// from *inside* one of its own `catch` blocks throwing, which is not itself
/// wrapped in a further `do`/`catch`.
private final class FaultInjectingSplitRepository: MeetingSplitRepositoryProtocol, @unchecked Sendable {
    struct InjectedFault: Error, Equatable {}

    private let wrapped: MeetingSplitRepositoryProtocol
    private let failMarkChildFailedOnCallNumber: Int
    private var markChildFailedCallCount = 0

    init(wrapping wrapped: MeetingSplitRepositoryProtocol, failMarkChildFailedOnCallNumber: Int = 1) {
        self.wrapped = wrapped
        self.failMarkChildFailedOnCallNumber = failMarkChildFailedOnCallNumber
    }

    func begin(idempotencyKey: String, request: MeetingSplitRequest, now: Date) throws -> MeetingSplitOperation {
        try wrapped.begin(idempotencyKey: idempotencyKey, request: request, now: now)
    }

    func operation(id: UUID) throws -> MeetingSplitOperation? { try wrapped.operation(id: id) }

    func operation(idempotencyKey: String) throws -> MeetingSplitOperation? {
        try wrapped.operation(idempotencyKey: idempotencyKey)
    }

    func operations(sourceId: UUID) throws -> [MeetingSplitOperation] { try wrapped.operations(sourceId: sourceId) }

    func sourceSnapshot(sourceId: UUID) throws -> MeetingSplitSourceSnapshot? {
        try wrapped.sourceSnapshot(sourceId: sourceId)
    }

    func discard(operationId: UUID, now: Date) throws -> MeetingSplitOperation {
        try wrapped.discard(operationId: operationId, now: now)
    }

    func publish(
        operationId: UUID, preparedChildren: [MeetingSplitPreparedChild],
        expectedSource: MeetingSplitSourceSnapshot, now: Date
    ) throws -> MeetingSplitOperation {
        try wrapped.publish(
            operationId: operationId, preparedChildren: preparedChildren, expectedSource: expectedSource, now: now)
    }

    func markChildTranscriptionStarted(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation {
        try wrapped.markChildTranscriptionStarted(operationId: operationId, childId: childId, now: now)
    }

    func markChildTranscriptionSucceeded(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation {
        try wrapped.markChildTranscriptionSucceeded(operationId: operationId, childId: childId, now: now)
    }

    func markChildAutomationStarted(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation {
        try wrapped.markChildAutomationStarted(operationId: operationId, childId: childId, now: now)
    }

    func markChildAutomationSucceeded(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation {
        try wrapped.markChildAutomationSucceeded(operationId: operationId, childId: childId, now: now)
    }

    func markChildFailed(
        operationId: UUID, childId: UUID, errorMessage: String, now: Date
    ) throws -> MeetingSplitOperation {
        markChildFailedCallCount += 1
        if markChildFailedCallCount == failMarkChildFailedOnCallNumber {
            throw InjectedFault()
        }
        return try wrapped.markChildFailed(operationId: operationId, childId: childId, errorMessage: errorMessage, now: now)
    }

    func markChildCancelled(operationId: UUID, childId: UUID, now: Date) throws -> MeetingSplitOperation {
        try wrapped.markChildCancelled(operationId: operationId, childId: childId, now: now)
    }
}
