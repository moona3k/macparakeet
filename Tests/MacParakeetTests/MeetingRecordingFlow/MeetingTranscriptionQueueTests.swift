import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class MeetingTranscriptionQueueTests: XCTestCase {
    func testQueueFinalizesMeetingsFIFO() async throws {
        let transcriptionService = QueueTranscriptionServiceSpy()
        let recordingService = QueueRecordingServiceSpy()
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            meetingRecordingService: recordingService
        )
        let first = makeItem(name: "A")
        let second = makeItem(name: "B")

        queue.enqueue(first)
        queue.enqueue(second)
        await queue.waitUntilIdle()

        let transcriptionSnapshot = await transcriptionService.snapshot()
        let recordingSnapshot = await recordingService.snapshot()
        XCTAssertEqual(transcriptionSnapshot, [first.transcriptionID, second.transcriptionID])
        XCTAssertEqual(recordingSnapshot.completedSessionIDs, [
            first.recording.sessionID,
            second.recording.sessionID,
        ])
    }

    func testQueueContinuesAfterFailedFinalize() async throws {
        let transcriptionService = QueueTranscriptionServiceSpy()
        let recordingService = QueueRecordingServiceSpy()
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            meetingRecordingService: recordingService
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
        let recordingSnapshot = await recordingService.snapshot()
        XCTAssertEqual(completions, ["failure:A", "success:B"])
        XCTAssertEqual(transcriptionSnapshot, [first.transcriptionID, second.transcriptionID])
        XCTAssertEqual(recordingSnapshot.finishedAttemptSessionIDs, [first.recording.sessionID])
        XCTAssertEqual(recordingSnapshot.completedSessionIDs, [second.recording.sessionID])
    }

    func testSnapshotCountsActiveAndPendingItems() async throws {
        let transcriptionService = QueueTranscriptionServiceSpy()
        await transcriptionService.setHoldFinalization(true)
        let recordingService = QueueRecordingServiceSpy()
        let queue = MeetingTranscriptionQueue(
            transcriptionService: transcriptionService,
            meetingRecordingService: recordingService
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
    private(set) var finalizedIDs: [UUID] = []
    private var failingIDs: Set<UUID> = []
    var holdFinalization = false
    private var finalizationWaiters: [CheckedContinuation<Void, Never>] = []

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
        return Transcription(
            id: transcriptionID,
            fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path,
            rawTranscript: "done",
            status: .completed,
            sourceType: .meeting
        )
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

private actor QueueRecordingServiceSpy: MeetingRecordingServiceProtocol {
    private(set) var completedSessionIDs: [UUID] = []
    private(set) var finishedAttemptSessionIDs: [UUID] = []

    func snapshot() -> (
        completedSessionIDs: [UUID],
        finishedAttemptSessionIDs: [UUID]
    ) {
        (
            completedSessionIDs: completedSessionIDs,
            finishedAttemptSessionIDs: finishedAttemptSessionIDs
        )
    }

    func startRecording(title: String?, sourceMode: MeetingAudioSourceMode?) async throws {}

    func stopRecording() async throws -> MeetingRecordingOutput {
        throw MeetingAudioError.notRunning
    }

    func completeTranscription(for recording: MeetingRecordingOutput) async {
        completedSessionIDs.append(recording.sessionID)
    }

    func finishTranscriptionAttempt(for recording: MeetingRecordingOutput) async {
        finishedAttemptSessionIDs.append(recording.sessionID)
    }

    func discardStoppedRecording(_ recording: MeetingRecordingOutput) async {}
    func cancelRecording() async {}
    func pauseRecording() async {}
    func resumeRecording() async {}
    func setMicrophoneMuted(_ muted: Bool) async -> MeetingMicrophoneMuteState {
        MeetingMicrophoneMuteState(isMuted: muted, canMute: true)
    }
    func updateNotes(_ notes: String) async {}

    var isRecording: Bool { false }
    var isPaused: Bool { false }
    var micLevel: Float { 0 }
    var systemLevel: Float { 0 }
    var elapsedSeconds: Int { 0 }
    var captureMode: CaptureMode { .stopped }
    var isMicrophoneMuted: Bool { false }
    var canMuteMicrophone: Bool { false }
    var microphoneMuteState: MeetingMicrophoneMuteState {
        MeetingMicrophoneMuteState(isMuted: false, canMute: false)
    }
    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private enum QueueTestError: Error {
    case failed
}
