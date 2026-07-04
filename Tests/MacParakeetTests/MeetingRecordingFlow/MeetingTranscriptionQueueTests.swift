import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class MeetingTranscriptionQueueTests: XCTestCase {
    func testQueueFinalizesMeetingsFIFO() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let first = makeItem(name: "A")
        let second = makeItem(name: "B")

        queue.enqueue(first)
        queue.enqueue(second)
        await queue.waitUntilIdle()

        let transcriptionSnapshot = await transcriptionService.snapshot()
        XCTAssertEqual(transcriptionSnapshot, [first.transcriptionID, second.transcriptionID])
        XCTAssertEqual(lockStore.deletes, [
            first.recording.folderURL,
            second.recording.folderURL,
        ])
    }

    func testQueueContinuesAfterFailedFinalize() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let first = makeItem(name: "A")
        let second = makeItem(name: "B")
        await transcriptionService.fail(transcriptionID: first.transcriptionID)

        var completions: [String] = []
        queue.onCompletion = { completion in
            switch completion {
            case .success(let item, _):
                completions.append("success:\(item.recording.displayName)")
            case .failure(let item, _):
                completions.append("failure:\(item.recording.displayName)")
            }
        }

        queue.enqueue(first)
        queue.enqueue(second)
        await queue.waitUntilIdle()

        let transcriptionSnapshot = await transcriptionService.snapshot()
        XCTAssertEqual(completions, ["failure:A", "success:B"])
        XCTAssertEqual(transcriptionSnapshot, [first.transcriptionID, second.transcriptionID])
        XCTAssertEqual(lockStore.deletes, [second.recording.folderURL])
    }

    func testSnapshotCountsActiveAndPendingItems() async throws {
        let transcriptionRepo = MockTranscriptionRepository()
        let lockStore = QueueRecordingLockFileStore()
        let transcriptionService = QueueTranscriptionServiceSpy(transcriptionRepo: transcriptionRepo)
        await transcriptionService.setHoldFinalization(true)
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            meetingRecordingSettlement: MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
        let first = makeItem(name: "A")
        let second = makeItem(name: "B")

        queue.enqueue(first)
        queue.enqueue(second)
        try await waitUntil {
            queue.snapshot.activeItem?.transcriptionID == first.transcriptionID
                && queue.snapshot.pendingCount == 1
        }

        XCTAssertEqual(queue.snapshot.totalCount, 2)

        await transcriptionService.releaseFinalization()
        await queue.waitUntilIdle()
        XCTAssertEqual(queue.snapshot.totalCount, 0)
    }

    private func makeItem(name: String) -> MeetingTranscriptionQueue.Item {
        let output = makeRecordingOutput(displayName: name)
        return MeetingTranscriptionQueue.Item(
            recording: output,
            transcriptionID: UUID(),
            operationContext: ObservabilityOperationContext(),
            trigger: .manual,
            liveWordCount: 0,
            liveTranscriptLagged: false
        )
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
            mixedAudioURL: folder.appendingPathComponent("meeting.m4a"),
            microphoneAudioURL: folder.appendingPathComponent("microphone.m4a"),
            systemAudioURL: folder.appendingPathComponent("system.m4a"),
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
    private(set) var finalizedIDs: [UUID] = []
    private var failingIDs: Set<UUID> = []
    var holdFinalization = false
    private var finalizationWaiters: [CheckedContinuation<Void, Never>] = []

    init(transcriptionRepo: MockTranscriptionRepository) {
        self.transcriptionRepo = transcriptionRepo
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
        Transcription(
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            status: .processing,
            sourceType: .meeting
        )
    }

    func finalizeMeetingTranscription(
        recording: MeetingRecordingOutput,
        updating transcriptionID: UUID,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        finalizedIDs.append(transcriptionID)
        while holdFinalization {
            await withCheckedContinuation { continuation in
                finalizationWaiters.append(continuation)
            }
        }
        if failingIDs.contains(transcriptionID) {
            throw QueueTestError.failed
        }
        let transcription = Transcription(
            id: transcriptionID,
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            meetingArtifactFolderPath: recording.folderURL.path,
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

private enum QueueTestError: Error {
    case failed
}
