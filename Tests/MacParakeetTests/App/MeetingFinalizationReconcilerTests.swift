import XCTest

@testable import MacParakeet
@testable import MacParakeetCore

final class MeetingFinalizationReconcilerTests: XCTestCase {
    func testReconcileStaleProcessingRowsMarksOnlyProcessingMeetingsFailed() async throws {
        let repo = MockTranscriptionRepository()
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

        XCTAssertEqual(repo.fetchMeetingsWithStatusCalls, [.processing])
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
        let repo = MockTranscriptionRepository()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFinalizationReconcilerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let lockStore = MeetingRecordingLockFileStore(
            processChecker: ReconcilerProcessAliveChecker(alivePIDs: [42])
        )
        try lockStore.write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(),
                pid: 42,
                displayName: "Meeting owned by another app process",
                state: .awaitingTranscription
            ),
            folderURL: folderURL
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
            lockFileStore: lockStore
        )

        XCTAssertTrue(reconciledIDs.isEmpty)
        XCTAssertEqual(try repo.fetch(id: processingMeeting.id)?.status, .processing)
    }

    func testReconcileMarksProcessingRowWithDeadLockOwnerFailed() async throws {
        let repo = MockTranscriptionRepository()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFinalizationReconcilerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let lockStore = MeetingRecordingLockFileStore(
            processChecker: ReconcilerProcessAliveChecker(alivePIDs: [])
        )
        try lockStore.write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(),
                pid: 42,
                displayName: "Interrupted meeting",
                state: .awaitingTranscription
            ),
            folderURL: folderURL
        )
        let processingMeeting = Transcription(
            fileName: "Interrupted meeting",
            meetingArtifactFolderPath: folderURL.path,
            status: .processing,
            sourceType: .meeting
        )
        try repo.save(processingMeeting)

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo,
            lockFileStore: lockStore
        )

        XCTAssertEqual(reconciledIDs, [processingMeeting.id])
        XCTAssertEqual(try repo.fetch(id: processingMeeting.id)?.status, .error)
    }

    @MainActor
    func testReconcileSkipsProcessingRowsOwnedByQueue() async throws {
        let repo = MockTranscriptionRepository()
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

private final class ReconcilerRecordingLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {}
    func read(folderURL: URL) throws -> MeetingRecordingLockFile? { nil }
    func delete(folderURL: URL) throws {}
    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] { [] }
}

private struct ReconcilerProcessAliveChecker: ProcessAliveChecking {
    let alivePIDs: Set<Int32>

    func isAlive(pid: Int32) -> Bool {
        alivePIDs.contains(pid)
    }
}
