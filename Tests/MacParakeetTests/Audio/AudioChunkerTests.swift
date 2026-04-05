import AVFAudio
import XCTest
@testable import MacParakeetCore

final class AudioChunkerTests: XCTestCase {
    func testEmitsFiveSecondChunkAndRetainsOneSecondOverlap() async {
        let chunker = AudioChunker()
        let samples = [Float](repeating: 0.25, count: 80_000)

        let firstChunk = await chunker.addSamples(samples)
        let bufferSampleCount = await chunker.bufferSampleCount
        let currentPositionMs = await chunker.currentPositionMs

        XCTAssertNotNil(firstChunk)
        XCTAssertEqual(firstChunk?.samples.count, 80_000)
        XCTAssertEqual(firstChunk?.startMs, 0)
        XCTAssertEqual(firstChunk?.endMs, 5_000)
        XCTAssertEqual(bufferSampleCount, 16_000)
        XCTAssertEqual(currentPositionMs, 4_000)
    }

    func testFlushReturnsRemainingAudioAboveMinimumThreshold() async {
        let chunker = AudioChunker()
        _ = await chunker.addSamples([Float](repeating: 0.1, count: 80_000))

        let flushed = await chunker.flush()

        XCTAssertNotNil(flushed)
        XCTAssertEqual(flushed?.samples.count, 16_000)
        XCTAssertEqual(flushed?.startMs, 4_000)
        XCTAssertEqual(flushed?.endMs, 5_000)
    }

    func testFlushDropsTinyTail() async {
        let chunker = AudioChunker()

        let flushed = await chunker.addSamples([Float](repeating: 0.1, count: 4_000))

        let finalFlush = await chunker.flush()

        XCTAssertNil(flushed)
        XCTAssertNil(finalFlush)
    }

    func testResampleDownsamplesTo16kHz() {
        let input = Array(0..<48_000).map(Float.init)

        let output = AudioChunker.resample(samples: input, fromRate: 48_000, toRate: 16_000)

        XCTAssertEqual(output.count, 16_000)
    }

    func testExtractAndResampleAcceptsInt16PCMBuffer() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
            return XCTFail("Failed to create Int16 PCM buffer")
        }

        buffer.frameLength = 4
        guard let channelData = buffer.int16ChannelData else {
            return XCTFail("Missing Int16 channel data")
        }

        channelData[0][0] = 0
        channelData[0][1] = 16_384
        channelData[0][2] = -16_384
        channelData[0][3] = Int16.max

        let samples = AudioChunker.extractAndResample(from: buffer)

        XCTAssertEqual(samples?.count, 4)
        XCTAssertEqual(samples?[0] ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(samples?[1] ?? .nan, 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples?[2] ?? .nan, -0.5, accuracy: 0.0001)
        XCTAssertEqual(samples?[3] ?? .nan, 1.0, accuracy: 0.0001)
    }

    func testExtractSamplesDownmixesFloatStereoBuffers() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
            return XCTFail("Failed to create Float32 stereo buffer")
        }

        buffer.frameLength = 4
        guard let channelData = buffer.floatChannelData else {
            return XCTFail("Missing Float32 channel data")
        }

        channelData[0][0] = 1.0
        channelData[0][1] = 0.0
        channelData[0][2] = -1.0
        channelData[0][3] = 0.5

        channelData[1][0] = 0.0
        channelData[1][1] = 1.0
        channelData[1][2] = 1.0
        channelData[1][3] = -0.5

        let samples = AudioChunker.extractSamples(from: buffer)

        XCTAssertEqual(samples?.count, 4)
        XCTAssertEqual(samples?[0] ?? .nan, 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples?[1] ?? .nan, 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples?[2] ?? .nan, 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples?[3] ?? .nan, 0.0, accuracy: 0.0001)
    }

    func testExtractSamplesDownmixesInt16StereoBuffers() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
            return XCTFail("Failed to create Int16 stereo buffer")
        }

        buffer.frameLength = 4
        guard let channelData = buffer.int16ChannelData else {
            return XCTFail("Missing Int16 channel data")
        }

        channelData[0][0] = Int16.max
        channelData[0][1] = 0
        channelData[0][2] = Int16.min + 1
        channelData[0][3] = 8_192

        channelData[1][0] = 0
        channelData[1][1] = Int16.max
        channelData[1][2] = Int16.max
        channelData[1][3] = -8_192

        let samples = AudioChunker.extractSamples(from: buffer)

        XCTAssertEqual(samples?.count, 4)
        XCTAssertEqual(samples?[0] ?? .nan, 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples?[1] ?? .nan, 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples?[2] ?? .nan, 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples?[3] ?? .nan, 0.0, accuracy: 0.0001)
    }
}
