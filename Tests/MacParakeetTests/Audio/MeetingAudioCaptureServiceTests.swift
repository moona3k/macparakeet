import AVFAudio
import XCTest
@testable import MacParakeetCore

final class MeetingAudioCaptureServiceTests: XCTestCase {
    func testStartHandlerCopiesInterleavedMicrophoneBuffersIntoUsablePCM() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemTap = MockMeetingSystemAudioTap()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioTapFactory: { systemTap }
        )

        let capturedBuffer = CapturedPCMBuffer()
        try await service.start { event in
            guard case let .microphoneBuffer(buffer, _) = event else { return }
            Task {
                await capturedBuffer.store(buffer)
            }
        }
        defer { Task { await service.stop() } }

        let interleaved = try XCTUnwrap(makeInterleavedFloatStereoBuffer(samples: [
            1.0, 0.0,
            0.0, 1.0,
            -1.0, 1.0,
            0.5, -0.5,
        ]))
        microphone.emit(buffer: interleaved, time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1.0)))

        var copiedBuffer: AVAudioPCMBuffer?
        for _ in 0..<20 {
            copiedBuffer = await capturedBuffer.value()
            if copiedBuffer != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let buffer = try XCTUnwrap(copiedBuffer)
        let samples = try XCTUnwrap(AudioChunker.extractSamples(from: buffer))

        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[3], 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(buffer.rmsLevel, 0)
    }

    func testEventsStreamRetainsFiveSecondsOfBurstSystemAudioBuffers() async throws {
        let microphone = MockMeetingMicrophoneCapture()
        let systemTap = MockMeetingSystemAudioTap()
        let service = MeetingAudioCaptureService(
            microphoneCapture: microphone,
            systemAudioTapFactory: { systemTap }
        )

        let events = await service.events
        try await service.start()

        // 500 callbacks * 480 frames @ 48kHz = 5 seconds of source audio.
        // After 48kHz -> 16kHz resampling, that is exactly 80,000 samples,
        // enough for the first live-transcription chunk if no events are dropped.
        let burstBuffer = try XCTUnwrap(makeInterleavedFloatStereoBuffer(
            sampleRate: 48_000,
            samples: [Float](repeating: 0.25, count: 960)
        ))

        for _ in 0..<500 {
            systemTap.emit(buffer: burstBuffer, time: AVAudioTime(hostTime: 1))
        }

        try await Task.sleep(for: .milliseconds(150))
        await service.stop()

        var systemBufferCount = 0
        for await event in events {
            if case .systemBuffer = event {
                systemBufferCount += 1
            }
        }

        XCTAssertEqual(systemBufferCount, 500)
    }

    private func makeInterleavedFloatStereoBuffer(
        sampleRate: Double = 16_000,
        samples: [Float]
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count / 2)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count / 2)
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData else { return nil }
        let destination = data.assumingMemoryBound(to: Float.self)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            destination.update(from: baseAddress, count: samples.count)
        }
        return buffer
    }
}

private final class MockMeetingMicrophoneCapture: MeetingMicrophoneCapturing, @unchecked Sendable {
    private var handler: AudioBufferHandler?

    func start(handler: @escaping AudioBufferHandler) throws {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func emit(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        handler?(buffer, time)
    }
}

private final class MockMeetingSystemAudioTap: MeetingSystemAudioTapping, @unchecked Sendable {
    private var handler: AudioBufferHandler?

    func start(handler: @escaping AudioBufferHandler) throws {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func emit(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        handler?(buffer, time)
    }
}

private actor CapturedPCMBuffer {
    private var buffer: AVAudioPCMBuffer?

    func store(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func value() -> AVAudioPCMBuffer? {
        buffer
    }
}
