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
        let ownershipChecker = ReconcilerOwnershipChecker(
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
            ownershipChecker: ownershipChecker
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
            ownershipChecker: ReconcilerOwnershipChecker()
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
        return rows
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

private struct ReconcilerOwnershipChecker: MeetingFinalizationOwnershipChecking {
    var liveFolderPaths: Set<String> = []

    func hasLiveOwner(folderURL: URL) throws -> Bool {
        liveFolderPaths.contains(folderURL.standardizedFileURL.path)
    }
}

private final class ReconcilerRecordingLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {}
    func read(folderURL: URL) throws -> MeetingRecordingLockFile? { nil }
    func delete(folderURL: URL) throws {}
    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] { [] }
}
