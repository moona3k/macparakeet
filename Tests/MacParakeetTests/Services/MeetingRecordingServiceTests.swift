import AVFAudio
import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingServiceTests: XCTestCase {
    func testStopRecordingPreservesCrossStreamHostTimeOffsetsInPreparedTranscript() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = SequencedMeetingSTTClient(results: [
            STTResult(text: "mic", words: [
                TimestampedWord(word: "mic", startMs: 0, endMs: 120, confidence: 0.9),
            ]),
            STTResult(text: "sys", words: [
                TimestampedWord(word: "sys", startMs: 0, endMs: 120, confidence: 0.9),
            ]),
            STTResult(text: "", words: []),
            STTResult(text: "", words: []),
        ])
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))

        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.150))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let prepared = try XCTUnwrap(output.preparedTranscript)
        XCTAssertEqual(prepared.words.map(\.word), ["mic", "sys"])
        XCTAssertEqual(prepared.words.map(\.speakerId), ["microphone", "system"])
        XCTAssertLessThanOrEqual(abs(prepared.words[0].startMs - 0), 10)
        XCTAssertLessThanOrEqual(abs(prepared.words[1].startMs - 150), 20)
        XCTAssertEqual(prepared.diarizationSegments, [
            DiarizationSegmentRecord(speakerId: "microphone", startMs: prepared.words[0].startMs, endMs: prepared.words[0].endMs),
            DiarizationSegmentRecord(speakerId: "system", startMs: prepared.words[1].startMs, endMs: prepared.words[1].endMs),
        ])
    }

    func testStopRecordingCancelsPendingLiveChunksInsteadOfWaitingForThem() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = SleepingMeetingSTTClient(liveChunkDelay: .seconds(1))
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        try await waitForLiveChunkTranscriptionStart(sttClient)

        let startedAt = ContinuousClock.now
        let output = try await service.stopRecording()
        let elapsed = startedAt.duration(to: .now)
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertNil(output.preparedTranscript)
    }

    func testStopRecordingPreservesPreparedTranscriptWhenPendingChunksTimeOut() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = PrefixScriptedMeetingSTTClient(
            microphoneSteps: [
                .result(
                    STTResult(text: "mic", words: [
                        TimestampedWord(word: "mic", startMs: 0, endMs: 120, confidence: 0.9),
                    ])
                ),
            ],
            systemSteps: [
                .result(
                    STTResult(text: "sys", words: [
                        TimestampedWord(word: "sys", startMs: 0, endMs: 120, confidence: 0.9),
                    ]),
                    delay: .seconds(1)
                ),
            ]
        )
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))

        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.150))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let prepared = try XCTUnwrap(output.preparedTranscript)
        XCTAssertEqual(prepared.words.map(\.word), ["mic"])
        XCTAssertEqual(prepared.words.map(\.speakerId), ["microphone"])
    }

    func testBackpressureDropMarksNextTranscriptUpdateAsLagging() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = PrefixScriptedMeetingSTTClient(
            microphoneSteps: [
                .result(
                    STTResult(text: "first", words: [
                        TimestampedWord(word: "first", startMs: 0, endMs: 120, confidence: 0.9),
                    ]),
                    delay: .milliseconds(200)
                ),
                .dropBackpressure,
            ]
        )
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        let updates = await service.transcriptUpdates
        let nextUpdate = Task {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        }

        try await service.startRecording()

        let firstBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let secondBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 64_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            firstBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.microphoneBuffer(
            secondBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 104.0))
        ))

        let maybeUpdate = await nextUpdate.value
        let update = try XCTUnwrap(maybeUpdate)
        XCTAssertTrue(update.isTranscriptionLagging)
        XCTAssertEqual(update.words.map(\.word), ["first"])

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }
        XCTAssertNotNil(output.preparedTranscript)
    }

    func testStaleChunkFailureFromPreviousSessionDoesNotPoisonNextSession() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = PathScriptedMeetingSTTClient(responses: [
            "microphone-100000-105000": .failure(message: "late failure", delay: .milliseconds(300)),
            "microphone-200000-205000": .result(STTResult(text: "fresh", words: [
                TimestampedWord(word: "fresh", startMs: 0, endMs: 160, confidence: 0.9),
            ])),
        ])
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let firstBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            firstBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let firstOutput = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: firstOutput.folderURL) }
        XCTAssertNil(firstOutput.preparedTranscript)

        try await service.startRecording()

        let secondBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        await captureService.yield(.microphoneBuffer(
            secondBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 200.0))
        ))
        try await Task.sleep(for: .milliseconds(350))

        let secondOutput = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: secondOutput.folderURL) }

        let prepared = try XCTUnwrap(secondOutput.preparedTranscript)
        XCTAssertEqual(prepared.words.map(\.word), ["fresh"])
        XCTAssertEqual(prepared.words.map(\.speakerId), ["microphone"])
    }

    private func waitForLiveChunkTranscriptionStart(
        _ client: SleepingMeetingSTTClient,
        timeout: Duration = .seconds(1)
    ) async throws {
        let startedAt = ContinuousClock.now
        while await client.liveChunkCallCount == 0 {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for live chunk transcription to start")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeMonoFloatBuffer(frameCount: Int, sampleValue: Float) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.floatChannelData else { return nil }
        for index in 0..<frameCount {
            channelData[0][index] = sampleValue
        }
        return buffer
    }
}

private actor MockMeetingAudioCaptureService: MeetingAudioCapturing {
    private var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var stream: AsyncStream<MeetingAudioCaptureEvent>?

    var events: AsyncStream<MeetingAudioCaptureEvent> {
        if let stream {
            return stream
        }

        let stream = AsyncStream<MeetingAudioCaptureEvent>(bufferingPolicy: .unbounded) {
            self.continuation = $0
        }
        self.stream = stream
        return stream
    }

    func start() async throws {
        _ = events
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
        stream = nil
    }

    func yield(_ event: MeetingAudioCaptureEvent) {
        continuation?.yield(event)
    }
}

private final class MockMeetingAudioFileConverter: AudioFileConverting, @unchecked Sendable {
    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func mixToM4A(inputURLs: [URL], outputURL: URL) async throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: Data("mixed".utf8))
    }
}

private actor SequencedMeetingSTTClient: STTClientProtocol {
    private var remainingResults: [STTResult]

    init(results: [STTResult]) {
        self.remainingResults = results
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        guard !remainingResults.isEmpty else {
            XCTFail("Unexpected extra meeting STT request")
            return STTResult(text: "", words: [])
        }
        return remainingResults.removeFirst()
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private actor SleepingMeetingSTTClient: STTClientProtocol {
    private let liveChunkDelay: Duration
    private(set) var liveChunkCallCount = 0

    init(liveChunkDelay: Duration) {
        self.liveChunkDelay = liveChunkDelay
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        if job == .meetingLiveChunk {
            liveChunkCallCount += 1
            try await Task.sleep(for: liveChunkDelay)
        }
        return STTResult(text: "", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private actor PrefixScriptedMeetingSTTClient: STTClientProtocol {
    enum Step: Sendable {
        case result(STTResult, delay: Duration = .zero)
        case dropBackpressure
    }

    private var microphoneSteps: [Step]
    private var systemSteps: [Step]

    init(
        microphoneSteps: [Step] = [],
        systemSteps: [Step] = []
    ) {
        self.microphoneSteps = microphoneSteps
        self.systemSteps = systemSteps
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let fileName = URL(fileURLWithPath: audioPath).lastPathComponent
        let step: Step
        if fileName.hasPrefix("microphone-"), !microphoneSteps.isEmpty {
            step = microphoneSteps.removeFirst()
        } else if fileName.hasPrefix("system-"), !systemSteps.isEmpty {
            step = systemSteps.removeFirst()
        } else {
            step = .result(STTResult(text: "", words: []))
        }

        switch step {
        case .result(let result, let delay):
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            return result
        case .dropBackpressure:
            throw STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
        }
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private actor PathScriptedMeetingSTTClient: STTClientProtocol {
    enum Response {
        case result(STTResult, delay: Duration = .zero)
        case failure(message: String, delay: Duration = .zero)
    }

    private let responses: [String: Response]

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        guard let response = responses.first(where: { audioPath.contains($0.key) })?.value else {
            return STTResult(text: "", words: [])
        }

        switch response {
        case .result(let result, let delay):
            await waitIgnoringCancellation(for: delay)
            return result
        case .failure(let message, let delay):
            await waitIgnoringCancellation(for: delay)
            throw STTError.transcriptionFailed(message)
        }
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}

    private func waitIgnoringCancellation(for delay: Duration) async {
        guard delay > .zero else { return }
        let startedAt = ContinuousClock.now
        while startedAt.duration(to: .now) < delay {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
