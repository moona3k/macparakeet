import XCTest

@testable import MacParakeet
@testable import MacParakeetCore

final class MeetingFinalizationReconcilerTests: XCTestCase {
    func testReconcileStaleProcessingRowsMarksOnlyProcessingMeetingsFailed() async throws {
        let repo = ReconcilerStatusRepository()
        let staleMeeting = Transcription(
            fileName: "Stale meeting",
            status: .processing,
            sourceType: .meeting
        )
        let completedMeeting = Transcription(
            fileName: "Completed meeting",
            status: .completed,
            sourceType: .meeting
        )
        let processingFile = Transcription(
            fileName: "Processing file",
            status: .processing,
            sourceType: .file
        )
        try repo.save(staleMeeting)
        try repo.save(completedMeeting)
        try repo.save(processingFile)

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo
        )

        XCTAssertEqual(reconciledIDs, [staleMeeting.id])
        let reconciled = try XCTUnwrap(repo.fetch(id: staleMeeting.id))
        XCTAssertEqual(reconciled.status, .error)
        XCTAssertEqual(
            reconciled.errorMessage,
            MeetingFinalizationReconciler.staleProcessingErrorMessage
        )
        XCTAssertEqual(try repo.fetch(id: completedMeeting.id)?.status, .completed)
        XCTAssertEqual(try repo.fetch(id: processingFile.id)?.status, .processing)
    }

    func testReconcileSkipsProcessingRowOwnedByAnotherLiveProcess() async throws {
        let repo = ReconcilerStatusRepository()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFinalizationReconcilerTests-\(UUID().uuidString)")
        let ownershipCoordinator = ReconcilerOwnershipCoordinator(
            liveFolderPaths: [folderURL.standardizedFileURL.path]
        )
        let processingMeeting = Transcription(
            fileName: "Live meeting",
            meetingArtifactFolderPath: folderURL.path,
            status: .processing,
            sourceType: .meeting
        )
        try repo.save(processingMeeting)

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo,
            ownershipCoordinator: ownershipCoordinator
        )

        XCTAssertTrue(reconciledIDs.isEmpty)
        XCTAssertEqual(try repo.fetch(id: processingMeeting.id)?.status, .processing)
    }

    func testReconcileMarksProcessingRowWithDeadLockOwnerFailed() async throws {
        let repo = ReconcilerStatusRepository()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFinalizationReconcilerTests-\(UUID().uuidString)")
        let processingMeeting = Transcription(
            fileName: "Interrupted meeting",
            meetingArtifactFolderPath: folderURL.path,
            status: .processing,
            sourceType: .meeting
        )
        try repo.save(processingMeeting)

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo,
            ownershipCoordinator: ReconcilerOwnershipCoordinator()
        )

        XCTAssertEqual(reconciledIDs, [processingMeeting.id])
        XCTAssertEqual(try repo.fetch(id: processingMeeting.id)?.status, .error)
    }

    func testReconcileOmitsRowWhenAtomicTransitionLosesToCompletion() async throws {
        let repo = ReconcilerStatusRepository()
        let processingMeeting = Transcription(
            fileName: "Finishing meeting",
            status: .processing,
            sourceType: .meeting
        )
        try repo.save(processingMeeting)
        repo.completeBeforeNextTransition(id: processingMeeting.id)

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo
        )

        XCTAssertTrue(reconciledIDs.isEmpty)
        XCTAssertEqual(try repo.fetch(id: processingMeeting.id)?.status, .completed)
        XCTAssertNil(try repo.fetch(id: processingMeeting.id)?.errorMessage)
    }

    func testReconcileSkipsDeadOwnerMeetingAfterAnotherProcessClaimsRetry() async throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFinalizationRetryLease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let processChecker = ReconcilerProcessAliveChecker(alivePIDs: [101])
        let retryStore = MeetingRecordingLockFileStore(
            processChecker: processChecker,
            processID: 101
        )
        let reconcilingStore = MeetingRecordingLockFileStore(
            processChecker: processChecker,
            processID: 202
        )
        try retryStore.write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(),
                pid: 42,
                displayName: "Retry meeting",
                state: .awaitingTranscription
            ),
            folderURL: folderURL
        )
        let retryableMeeting = Transcription(
            fileName: "Retry meeting",
            meetingArtifactFolderPath: folderURL.path,
            status: .error,
            sourceType: .meeting
        )
        try repo.save(retryableMeeting)

        let lease = try retryStore.claimFinalizationOwnership(
            folderURL: folderURL
        )
        defer { try? retryStore.releaseFinalizationOwnership(lease) }
        try repo.updateStatus(
            id: retryableMeeting.id,
            status: .processing,
            errorMessage: nil
        )

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo,
            ownershipCoordinator: reconcilingStore
        )

        XCTAssertTrue(reconciledIDs.isEmpty)
        XCTAssertEqual(try repo.fetch(id: retryableMeeting.id)?.status, .processing)
    }

    @MainActor
    func testReconcileSkipsProcessingRowsOwnedByQueue() async throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let transcriptionService = MockTranscriptionService()
        await transcriptionService.holdMeetingFinalization()
        await transcriptionService.persistFinalizedMeetings(to: repo)
        let lockStore = ReconcilerRecordingLockFileStore()
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            transcriptionRepo: repo,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: repo
            )
        )
        let recording = makeRecordingOutput(displayName: "Live meeting")
        let transcriptionID = UUID()
        try repo.save(
            Transcription(
                id: transcriptionID,
                fileName: recording.displayName,
                filePath: recording.mixedAudioURL.path,
                meetingArtifactFolderPath: recording.folderURL.path,
                status: .processing,
                sourceType: .meeting
            ))
        let item = MeetingTranscriptionQueue.Item(
            recording: recording,
            transcriptionID: transcriptionID,
            operationContext: ObservabilityOperationContext(),
            trigger: .manual,
            liveWordCount: 0,
            liveTranscriptLagged: false
        )

        queue.enqueue(item)
        try await waitUntil {
            queue.queuedTranscriptionIDs == [transcriptionID]
        }

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo,
            excludingTranscriptionIDs: queue.queuedTranscriptionIDs
        )

        XCTAssertTrue(reconciledIDs.isEmpty)
        XCTAssertEqual(try repo.fetch(id: transcriptionID)?.status, .processing)

        await transcriptionService.releaseMeetingFinalization()
        await queue.waitUntilIdle()
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
            mixedAudioURL: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            microphoneAudioURL: folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone),
            systemAudioURL: folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem),
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
        while await !predicate() {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ReconcilerStatusRepository: MeetingFinalizationStatusRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Transcription] = []
    private var completionBeforeTransitionIDs: Set<UUID> = []

    func save(_ transcription: Transcription) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = rows.firstIndex(where: { $0.id == transcription.id }) {
            rows[index] = transcription
        } else {
            rows.append(transcription)
        }
    }

    func fetch(id: UUID) throws -> Transcription? {
        lock.lock()
        defer { lock.unlock() }
        return rows.first { $0.id == id }
    }

    func fetchMeetings(
        withStatus status: Transcription.TranscriptionStatus
    ) throws -> [Transcription] {
        lock.lock()
        defer { lock.unlock() }
        return
            rows
            .filter { $0.sourceType == .meeting && $0.status == status }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func completeBeforeNextTransition(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        completionBeforeTransitionIDs.insert(id)
    }

    @discardableResult
    func transitionStatus(
        id: UUID,
        from expectedStatus: Transcription.TranscriptionStatus,
        to status: Transcription.TranscriptionStatus,
        errorMessage: String?
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if completionBeforeTransitionIDs.remove(id) != nil {
            rows[index].status = .completed
            rows[index].errorMessage = nil
        }
        guard rows[index].status == expectedStatus else {
            return false
        }
        rows[index].status = status
        rows[index].errorMessage = errorMessage
        return true
    }
}

private struct ReconcilerOwnershipCoordinator:
    MeetingFinalizationReconciliationCoordinating
{
    var liveFolderPaths: Set<String> = []

    func reconcileIfUnowned(
        folderURL: URL,
        transition: @Sendable () throws -> Bool
    ) throws -> Bool {
        guard !liveFolderPaths.contains(folderURL.standardizedFileURL.path) else {
            return false
        }
        return try transition()
    }
}

private struct ReconcilerProcessAliveChecker: ProcessAliveChecking {
    let alivePIDs: Set<Int32>

    func isAlive(pid: Int32) -> Bool {
        alivePIDs.contains(pid)
    }
}

private final class ReconcilerRecordingLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {}
    func read(folderURL: URL) throws -> MeetingRecordingLockFile? { nil }
    func delete(folderURL: URL) throws {}
    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] { [] }
}
