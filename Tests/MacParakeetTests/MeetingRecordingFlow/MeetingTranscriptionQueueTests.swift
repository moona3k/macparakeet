import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class MeetingTranscriptionQueueTests: XCTestCase {
    func testCaptureAdmissionDoesNotAwaitPlaybackAndPreservesFIFO() async throws {
        let repo = MockTranscriptionRepository()
        let locks = QueueRecordingLockFileStore()
        let service = QueueTranscriptionServiceSpy(transcriptionRepo: repo)
        let ready = makeRecordingOutput(displayName: "A")
        let capture = try makeCapture(from: ready)
        defer { try? FileManager.default.removeItem(at: capture.folderURL) }
        let stub = capture.makeProcessingTranscription()
        try repo.save(stub)
        let entered = expectation(description: "Playback started")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let queue = MeetingTranscriptionQueue(
            transcriptionService: service, transcriptionRepo: repo,
            meetingRecordingSettlement: MeetingRecordingSettlement(lockFileStore: locks, transcriptionRepo: repo),
            preparePlayback: { _ in
                entered.fulfill()
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                return ready
            }
        )
        let first = MeetingTranscriptionQueue.Item(
            input: .capture(capture), transcriptionID: stub.id, recordingGeneration: 1,
            operationContext: ObservabilityOperationContext(), trigger: .manual,
            liveWordCount: 0, liveTranscriptLagged: false
        )
        let admitted = try await queue.enqueueClaimingFinalizationOwnership(first)
        XCTAssertTrue(admitted)
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(queue.snapshot.activeItem?.sessionID, capture.sessionID)
        XCTAssertNil(try repo.fetch(id: stub.id)?.durationMs)
        XCTAssertNotNil(try MeetingRecordingLockFileStore().read(folderURL: capture.folderURL)?.finalizationLeaseId)
        let started = await service.snapshot()
        XCTAssertTrue(started.isEmpty)
        let second = makeItem(name: "B")
        try persistProcessingRows([second], in: repo)
        await queue.enqueue(second)
        XCTAssertEqual(queue.snapshot.pendingCount, 1)
        continuation.yield(())
        continuation.finish()
        await queue.waitUntilIdle()
        let finalized = await service.snapshot()
        XCTAssertEqual(finalized, [stub.id, second.transcriptionID])
        XCTAssertEqual(repo.transcriptions.filter { $0.filePath == ready.mixedAudioURL.path }.map(\.id), [stub.id])
    }

    func testPlaybackFailureAndCancellationPreserveSourcesAndDoNotBlockNextItem() async throws {
        for cancelled in [false, true] {
            let repo = MockTranscriptionRepository()
            let locks = QueueRecordingLockFileStore()
            let service = QueueTranscriptionServiceSpy(transcriptionRepo: repo)
            let capture = try makeCapture(from: makeRecordingOutput(displayName: "A"))
            defer { try? FileManager.default.removeItem(at: capture.folderURL) }
            let stub = capture.makeProcessingTranscription()
            try repo.save(stub)
            let queue = MeetingTranscriptionQueue(
                transcriptionService: service, transcriptionRepo: repo,
                meetingRecordingSettlement: MeetingRecordingSettlement(lockFileStore: locks, transcriptionRepo: repo),
                preparePlayback: { _ in
                    if cancelled { throw CancellationError() }
                    throw QueueTestError.failed
                }
            )
            let first = MeetingTranscriptionQueue.Item(
                input: .capture(capture), transcriptionID: stub.id, recordingGeneration: 1,
                operationContext: ObservabilityOperationContext(), trigger: .manual,
                liveWordCount: 0, liveTranscriptLagged: false
            )
            _ = try await queue.enqueueClaimingFinalizationOwnership(first)
            let second = makeItem(name: "B")
            try persistProcessingRows([second], in: repo)
            await queue.enqueue(second)
            await queue.waitUntilIdle()
            XCTAssertEqual(try repo.fetch(id: stub.id)?.status, cancelled ? .cancelled : .error)
            XCTAssertEqual(try repo.fetch(id: second.transcriptionID)?.status, .completed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: capture.microphoneAudioURL.path))
            XCTAssertNil(try MeetingRecordingLockFileStore().read(folderURL: capture.folderURL)?.finalizationLeaseId)
            XCTAssertEqual(locks.deletes, [second.folderURL])
            let finalized = await service.snapshot()
            XCTAssertEqual(finalized, [second.transcriptionID])
        }
    }

    private func makeCapture(from output: MeetingRecordingOutput) throws -> MeetingRecordingCapture {
        try FileManager.default.createDirectory(at: output.folderURL, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: output.microphoneAudioURL)
        let lock = MeetingRecordingLockFile(
            sessionId: output.sessionID, startedAt: Date(), displayName: output.displayName,
            state: .awaitingTranscription, folderURL: output.folderURL
        )
        let metadata = MeetingRecordingMetadata(sourceAlignment: output.sourceAlignment)
        try MeetingRecordingLockFileStore().write(lock, folderURL: output.folderURL)
        try MeetingRecordingMetadataStore.save(metadata, folderURL: output.folderURL)
        return try MeetingRecordingCapture.load(from: output.folderURL)
    }

    func testQueueFinalizesMeetingsFIFO() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let first = makeItem(name: "A")
        let second = makeItem(name: "B")
        try persistProcessingRows([first, second], in: transcriptionRepo)

        await queue.enqueue(first)
        await queue.enqueue(second)
        await queue.waitUntilIdle()

        let transcriptionSnapshot = await transcriptionService.snapshot()
        XCTAssertEqual(transcriptionSnapshot, [first.transcriptionID, second.transcriptionID])
        XCTAssertEqual(
            lockStore.deletes,
            [
                first.recording!.folderURL,
                second.recording!.folderURL,
            ])
    }

    func testCompletionWaitsForDurableSaveBeforeRefreshingConsumers() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let finalizationStarted = expectation(description: "Finalization reached the delayed save")
        let transcriptionService = QueueTranscriptionServiceSpy(
            transcriptionRepo: transcriptionRepo,
            onFinalizationStarted: { finalizationStarted.fulfill() }
        )
        await transcriptionService.setHoldFinalization(true)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let item = makeItem(name: "Delayed save")
        try persistProcessingRows([item], in: transcriptionRepo)
        var refreshedStatuses: [Transcription.TranscriptionStatus] = []
        queue.onCompletion = { completion in
            guard case .success(_, let transcription) = completion else {
                XCTFail("Expected successful completion")
                return
            }
            do {
                let persisted = try XCTUnwrap(transcriptionRepo.fetch(id: transcription.id))
                refreshedStatuses.append(persisted.status)
                XCTAssertEqual(lockStore.deletes, [item.recording!.folderURL])
            } catch {
                XCTFail("Completion must expose a durably saved row: \(error)")
            }
        }

        await queue.enqueue(item)
        await fulfillment(of: [finalizationStarted], timeout: 1)
        XCTAssertTrue(refreshedStatuses.isEmpty)
        XCTAssertEqual(try transcriptionRepo.fetch(id: item.transcriptionID)?.status, .processing)
        XCTAssertTrue(lockStore.deletes.isEmpty)

        await transcriptionService.releaseFinalization()
        await queue.waitUntilIdle()

        XCTAssertEqual(refreshedStatuses, [.completed])
    }

    func testQueueContinuesAfterFailedFinalize() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let ownershipClaimer = QueueFinalizationOwnershipClaimer()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            ),
            finalizationOwnershipClaimer: ownershipClaimer
        )
        let originalFirst = makeItem(name: "A")
        let lease = makeFinalizationOwnershipLease(for: originalFirst)
        let first = originalFirst.withFinalizationOwnershipLease(lease)
        let second = makeItem(name: "B")
        try persistProcessingRows([first, second], in: transcriptionRepo)
        try createAudioFile(for: first)
        await transcriptionService.fail(transcriptionID: first.transcriptionID)

        var completions: [String] = []
        queue.onCompletion = { completion in
            switch completion {
            case .success(let item, _):
                completions.append("success:\(item.recording!.displayName)")
            case .failure(let item, _):
                completions.append("failure:\(item.recording!.displayName)")
            }
        }

        await queue.enqueue(first)
        await queue.enqueue(second)
        await queue.waitUntilIdle()

        let transcriptionSnapshot = await transcriptionService.snapshot()
        XCTAssertEqual(completions, ["failure:A", "success:B"])
        XCTAssertEqual(transcriptionSnapshot, [first.transcriptionID, second.transcriptionID])
        XCTAssertEqual(lockStore.deletes, [second.recording!.folderURL])
        let failed = try XCTUnwrap(transcriptionRepo.fetch(id: first.transcriptionID))
        XCTAssertEqual(failed.status, .error)
        XCTAssertNotNil(failed.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.recording!.mixedAudioURL.path))
        XCTAssertEqual(ownershipClaimer.releasedLeaseIDs, [lease.id])
        XCTAssertEqual(ownershipClaimer.releaseMainThreadValues, [false])
    }

    func testSettlementRefusalAfterFinalizeStillReportsSuccessAndRetainsLock() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let ownershipClaimer = QueueFinalizationOwnershipClaimer()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            ),
            finalizationOwnershipClaimer: ownershipClaimer
        )
        let originalItem = makeItem(name: "A")
        let lease = makeFinalizationOwnershipLease(for: originalItem)
        let item = originalItem.withFinalizationOwnershipLease(lease)
        try persistProcessingRows([item], in: transcriptionRepo)
        await transcriptionService.mismatchSettlementPaths(transcriptionID: item.transcriptionID)

        var completions: [String] = []
        queue.onCompletion = { completion in
            switch completion {
            case .success(let item, _):
                completions.append("success:\(item.recording!.displayName)")
            case .failure(let item, _):
                completions.append("failure:\(item.recording!.displayName)")
            }
        }

        await queue.enqueue(item)
        await queue.waitUntilIdle()

        XCTAssertEqual(completions, ["success:A"])
        XCTAssertTrue(lockStore.deletes.isEmpty)
        XCTAssertEqual(ownershipClaimer.releasedLeaseIDs, [lease.id])
    }

    func testSnapshotCountsActiveAndPendingItems() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        await transcriptionService.setHoldFinalization(true)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let first = makeItem(name: "A")
        let second = makeItem(name: "B")
        try persistProcessingRows([first, second], in: transcriptionRepo)

        await queue.enqueue(first)
        await queue.enqueue(second)
        try await waitUntil {
            queue.snapshot.activeItem?.transcriptionID == first.transcriptionID
                && queue.snapshot.pendingCount == 1
        }

        XCTAssertEqual(queue.snapshot.totalCount, 2)

        await transcriptionService.releaseFinalization()
        await queue.waitUntilIdle()
        XCTAssertEqual(queue.snapshot.totalCount, 0)
    }

    func testQueueCreatesProcessingRowWhenEnqueuedItemHasNoRow() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        await transcriptionService.setHoldFinalization(true)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let item = makeItem(name: "Missing Row")

        await queue.enqueue(item)
        try await waitUntil {
            queue.snapshot.activeItem?.transcriptionID != nil
                && queue.snapshot.activeItem?.transcriptionID != item.transcriptionID
        }

        let preparedID = try XCTUnwrap(queue.snapshot.activeItem?.transcriptionID)
        let prepared = try XCTUnwrap(transcriptionRepo.fetch(id: preparedID))
        XCTAssertEqual(prepared.status, .processing)
        XCTAssertEqual(prepared.sourceType, .meeting)
        XCTAssertEqual(transcriptionRepo.transcriptions.count, 1)

        await transcriptionService.releaseFinalization()
        await queue.waitUntilIdle()

        let finalizedIDs = await transcriptionService.snapshot()
        XCTAssertEqual(finalizedIDs, [preparedID])
        XCTAssertEqual(transcriptionRepo.transcriptions.map(\.id), [preparedID])
        XCTAssertEqual(transcriptionRepo.transcriptions.first?.status, .completed)
    }

    func testQueueRetryReusesFailedRowAndDoesNotDuplicate() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let item = makeItem(name: "Retry")
        let failed = Transcription(
            id: item.transcriptionID,
            fileName: item.recording!.displayName,
            filePath: item.recording!.mixedAudioURL.path,
            meetingArtifactFolderPath: item.recording!.folderURL.path,
            status: .error,
            errorMessage: "Previous failure",
            sourceType: .meeting
        )
        try transcriptionRepo.save(failed)
        try createAudioFile(for: item)

        await queue.enqueue(item)
        await queue.waitUntilIdle()

        let fetched = try XCTUnwrap(transcriptionRepo.fetch(id: item.transcriptionID))
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertNil(fetched.errorMessage)
        XCTAssertEqual(transcriptionRepo.transcriptions.map(\.id), [item.transcriptionID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.recording!.mixedAudioURL.path))
    }

    func testCancelledFinalizationCanBeRetriedFromSameRow() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let item = makeItem(name: "Cancelled Retry")
        try persistProcessingRows([item], in: transcriptionRepo)
        try createAudioFile(for: item)
        await transcriptionService.cancel(transcriptionID: item.transcriptionID)

        await queue.enqueue(item)
        await queue.waitUntilIdle()

        let cancelled = try XCTUnwrap(transcriptionRepo.fetch(id: item.transcriptionID))
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertNil(cancelled.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.recording!.mixedAudioURL.path))

        await transcriptionService.clearFailures(transcriptionID: item.transcriptionID)
        await queue.enqueue(item)
        await queue.waitUntilIdle()

        let retried = try XCTUnwrap(transcriptionRepo.fetch(id: item.transcriptionID))
        XCTAssertEqual(retried.status, .completed)
        XCTAssertNil(retried.errorMessage)
        XCTAssertEqual(transcriptionRepo.transcriptions.map(\.id), [item.transcriptionID])
        let finalizedIDs = await transcriptionService.snapshot()
        XCTAssertEqual(finalizedIDs, [item.transcriptionID, item.transcriptionID])
    }

    func testQueueDropsDuplicateRetryWhileItemIsActive() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        await transcriptionService.setHoldFinalization(true)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let item = makeItem(name: "Duplicate Retry")
        try persistRow(status: .error, item: item, in: transcriptionRepo)
        try createAudioFile(for: item)

        await queue.enqueue(item)
        await queue.enqueue(item)
        try await waitUntil {
            queue.snapshot.activeItem?.transcriptionID == item.transcriptionID
        }
        XCTAssertEqual(queue.snapshot.pendingCount, 0)

        await transcriptionService.releaseFinalization()
        await queue.waitUntilIdle()

        let transcriptionSnapshot = await transcriptionService.snapshot()
        XCTAssertEqual(transcriptionSnapshot, [item.transcriptionID])
        let fetched = try XCTUnwrap(transcriptionRepo.fetch(id: item.transcriptionID))
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertEqual(transcriptionRepo.transcriptions.map(\.id), [item.transcriptionID])
    }

    func testQueueDoesNotRegressCompletedRowBackToProcessing() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let ownershipClaimer = QueueFinalizationOwnershipClaimer()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            ),
            finalizationOwnershipClaimer: ownershipClaimer
        )
        let originalItem = makeItem(name: "Already Done")
        let lease = makeFinalizationOwnershipLease(for: originalItem)
        let item = originalItem.withFinalizationOwnershipLease(lease)
        try persistRow(status: .completed, item: item, in: transcriptionRepo)

        var completions: [MeetingTranscriptionQueue.Completion] = []
        queue.onCompletion = { completion in
            completions.append(completion)
        }

        await queue.enqueue(item)
        await queue.waitUntilIdle()

        XCTAssertTrue(completions.isEmpty)
        let transcriptionSnapshot = await transcriptionService.snapshot()
        XCTAssertEqual(transcriptionSnapshot, [])
        let fetched = try XCTUnwrap(transcriptionRepo.fetch(id: item.transcriptionID))
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertNil(fetched.errorMessage)
        XCTAssertEqual(ownershipClaimer.releasedLeaseIDs, [lease.id])
    }

    private func makeItem(name: String) -> MeetingTranscriptionQueue.Item {
        let output = makeRecordingOutput(displayName: name)
        return MeetingTranscriptionQueue.Item(
            recording: output,
            transcriptionID: UUID(),
            recordingGeneration: 0,
            operationContext: ObservabilityOperationContext(),
            trigger: .manual,
            liveWordCount: 0,
            liveTranscriptLagged: false
        )
    }

    private func makeFinalizationOwnershipLease(
        for item: MeetingTranscriptionQueue.Item
    ) -> MeetingFinalizationOwnershipLease {
        MeetingFinalizationOwnershipLease(
            id: UUID(),
            folderURL: item.recording!.folderURL,
            previousLock: MeetingRecordingLockFile(
                sessionId: item.recording!.sessionID,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pid: 42,
                displayName: item.recording!.displayName,
                state: .awaitingTranscription,
                folderURL: item.recording!.folderURL
            )
        )
    }

    private func persistProcessingRows(
        _ items: [MeetingTranscriptionQueue.Item],
        in repo: MockTranscriptionRepository
    ) throws {
        for item in items {
            try persistRow(status: .processing, item: item, in: repo)
        }
    }

    private func persistRow(
        status: Transcription.TranscriptionStatus,
        item: MeetingTranscriptionQueue.Item,
        in repo: MockTranscriptionRepository
    ) throws {
        try repo.save(
            Transcription(
                id: item.transcriptionID,
                fileName: item.recording!.displayName,
                filePath: item.recording!.mixedAudioURL.path,
                meetingArtifactFolderPath: item.recording!.folderURL.path,
                status: status,
                sourceType: .meeting
            ))
    }

    private func createAudioFile(for item: MeetingTranscriptionQueue.Item) throws {
        try FileManager.default.createDirectory(
            at: item.recording!.folderURL,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: item.recording!.mixedAudioURL.path,
                contents: Data("audio".utf8)
            ))
    }

    private func makeRecordingOutput(displayName: String) -> MeetingRecordingOutput {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let track = MeetingSourceAlignment.Track(
            firstHostTime: 1,
            lastHostTime: 2,
            startOffsetMs: 0,
            writtenFrameCount: 48_000,
            sampleRate: 48_000
        )
        return MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: displayName,
            folderURL: folder,
            mixedAudioURL: folder.appendingPathComponent("meeting-playback.m4a"),
            microphoneAudioURL: folder.appendingPathComponent("microphone-raw.m4a"),
            systemAudioURL: folder.appendingPathComponent("system-raw.m4a"),
            durationSeconds: 42,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 1,
                microphone: track,
                system: track
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
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

private actor QueueTranscriptionServiceSpy: TranscriptionServiceProtocol {
    private let transcriptionRepo: MockTranscriptionRepository
    private let onFinalizationStarted: @Sendable () -> Void
    private(set) var finalizedIDs: [UUID] = []
    private var failingIDs: Set<UUID> = []
    private var cancellationIDs: Set<UUID> = []
    private var settlementMismatchIDs: Set<UUID> = []
    var holdFinalization = false
    private var finalizationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        transcriptionRepo: MockTranscriptionRepository,
        onFinalizationStarted: @escaping @Sendable () -> Void = {}
    ) {
        self.transcriptionRepo = transcriptionRepo
        self.onFinalizationStarted = onFinalizationStarted
    }

    func snapshot() -> [UUID] {
        finalizedIDs
    }

    func setHoldFinalization(_ hold: Bool) {
        holdFinalization = hold
    }

    func fail(transcriptionID: UUID) {
        failingIDs.insert(transcriptionID)
    }

    func cancel(transcriptionID: UUID) {
        cancellationIDs.insert(transcriptionID)
    }

    func clearFailures(transcriptionID: UUID) {
        failingIDs.remove(transcriptionID)
        cancellationIDs.remove(transcriptionID)
    }

    func mismatchSettlementPaths(transcriptionID: UUID) {
        settlementMismatchIDs.insert(transcriptionID)
    }

    func releaseFinalization() {
        holdFinalization = false
        let waiters = finalizationWaiters
        finalizationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        Transcription(fileName: fileURL.lastPathComponent, status: .completed)
    }

    func transcribeTransient(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        try await transcribe(fileURL: fileURL, source: source, onProgress: onProgress)
    }

    func transcribeMeeting(
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        Transcription(
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            status: .completed,
            sourceType: .meeting
        )
    }

    func prepareMeetingTranscription(recording: MeetingRecordingOutput) async throws -> Transcription {
        let transcription = Transcription(
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            meetingArtifactFolderPath: recording.folderURL.path,
            status: .processing,
            sourceType: .meeting
        )
        try transcriptionRepo.save(transcription)
        return transcription
    }

    func finalizeMeetingTranscription(
        recording: MeetingRecordingOutput,
        updating transcriptionID: UUID,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        finalizedIDs.append(transcriptionID)
        onFinalizationStarted()
        while holdFinalization {
            await withCheckedContinuation { continuation in
                finalizationWaiters.append(continuation)
            }
        }
        if cancellationIDs.contains(transcriptionID) {
            throw CancellationError()
        }
        if failingIDs.contains(transcriptionID) {
            throw QueueTestError.failed
        }
        let mismatched = settlementMismatchIDs.contains(transcriptionID)
        let folderPath =
            mismatched
            ? "/nonexistent/other-folder"
            : recording.folderURL.path
        let transcription = Transcription(
            id: transcriptionID,
            fileName: recording.displayName,
            filePath: mismatched ? folderPath + "/meeting-playback.m4a" : recording.mixedAudioURL.path,
            meetingArtifactFolderPath: folderPath,
            rawTranscript: "done",
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(transcription)
        return transcription
    }

    func retranscribe(
        existing transcription: Transcription,
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        transcription
    }

    func retranscribeMeeting(
        existing transcription: Transcription,
        recording: MeetingRecordingOutput,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        transcription
    }

    func transcribeURL(
        urlString: String,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        Transcription(fileName: "URL", status: .completed)
    }

    func transcribeURLTransient(
        urlString: String,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        try await transcribeURL(urlString: urlString, onProgress: onProgress)
    }
}

private final class QueueRecordingLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var deletes: [URL] = []

    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {}

    func read(folderURL: URL) throws -> MeetingRecordingLockFile? { nil }

    func delete(folderURL: URL) throws {
        lock.withLock {
            deletes.append(folderURL)
        }
    }

    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] { [] }
}

private final class QueueFinalizationOwnershipClaimer:
    MeetingFinalizationOwnershipClaiming,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var releasedIDs: [UUID] = []
    private var releaseWasOnMainThread: [Bool] = []

    var releasedLeaseIDs: [UUID] {
        lock.withLock { releasedIDs }
    }

    var releaseMainThreadValues: [Bool] {
        lock.withLock { releaseWasOnMainThread }
    }

    func claimFinalizationOwnership(
        folderURL: URL
    ) throws -> MeetingFinalizationOwnershipLease {
        throw QueueTestError.failed
    }

    func releaseFinalizationOwnership(
        _ lease: MeetingFinalizationOwnershipLease
    ) throws {
        lock.withLock {
            releasedIDs.append(lease.id)
            releaseWasOnMainThread.append(Thread.isMainThread)
        }
    }
}

private enum QueueTestError: Error {
    case failed
}
