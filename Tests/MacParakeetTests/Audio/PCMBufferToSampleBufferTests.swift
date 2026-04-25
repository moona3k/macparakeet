import AVFoundation
import XCTest
@testable import MacParakeetCore

final class PCMBufferToSampleBufferTests: XCTestCase {
    func testPresentationTimestampUsesPerCallSampleOffset() throws {
        let converter = PCMBufferToSampleBuffer()
        let buffer = try makeConstantBuffer(frameCount: 256, value: 0.25)

        let first = try converter.makeSampleBuffer(from: buffer, presentationTimeSamples: 1_024)
        let second = try converter.makeSampleBuffer(from: buffer, presentationTimeSamples: 4_096)

        XCTAssertEqual(CMSampleBufferGetNumSamples(first), 256)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first), CMTime(value: 1_024, timescale: 48_000))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(second), CMTime(value: 4_096, timescale: 48_000))
        XCTAssertEqual(CMSampleBufferGetDuration(first), CMTime(value: 256, timescale: 48_000))
    }

    func testSampleBufferDeepCopiesPCMData() throws {
        let converter = PCMBufferToSampleBuffer()
        let buffer = try makeConstantBuffer(frameCount: 4, value: 0.5)
        let samples = buffer.floatChannelData![0]
        samples[0] = 0.125
        samples[1] = 0.25
        samples[2] = 0.375
        samples[3] = 0.5

        let sampleBuffer = try converter.makeSampleBuffer(from: buffer, presentationTimeSamples: 0)

        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 99
        }

        XCTAssertEqual(try floatSamples(from: sampleBuffer), [0.125, 0.25, 0.375, 0.5])
    }

    func testWriterReaderRoundTripWithLinearPCMFixture() async throws {
        let fileURL = temporaryFileURL(extension: "caf")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let sampleRate = 48_000.0
        let frameCount = 1_024
        let buffer = try makeSineBuffer(frameCount: frameCount, sampleRate: sampleRate, frequency: 440)
        let sampleBuffer = try PCMBufferToSampleBuffer().makeSampleBuffer(
            from: buffer,
            presentationTimeSamples: 0
        )

        try write(sampleBuffer: sampleBuffer, to: fileURL, sampleRate: sampleRate)
        let decodedSamples = try await readFloatSamples(from: fileURL)

        XCTAssertGreaterThanOrEqual(decodedSamples.count, frameCount)
        XCTAssertEqual(decodedSamples[0], 0, accuracy: 0.000_01)
        XCTAssertEqual(decodedSamples[12], buffer.floatChannelData![0][12], accuracy: 0.000_1)
        XCTAssertEqual(decodedSamples[128], buffer.floatChannelData![0][128], accuracy: 0.000_1)
    }

    private func makeConstantBuffer(frameCount: Int, value: Float) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw TestError.failedToCreateBuffer
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            samples[index] = value
        }
        return buffer
    }

    private func makeSineBuffer(
        frameCount: Int,
        sampleRate: Double,
        frequency: Double
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw TestError.failedToCreateBuffer
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            samples[index] = Float(sin(phase) * 0.25)
        }
        return buffer
    }

    private func write(
        sampleBuffer: CMSampleBuffer,
        to fileURL: URL,
        sampleRate: Double
    ) throws {
        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .caf)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)

        guard writer.canAdd(input) else {
            throw TestError.writerRejectedInput
        }

        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        XCTAssertTrue(input.append(sampleBuffer))
        input.markAsFinished()

        let expectation = expectation(description: "finish writing")
        writer.finishWriting {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        if writer.status != .completed {
            throw writer.error ?? TestError.writerFailed
        }
    }

    private func readFloatSamples(from fileURL: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TestError.missingAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )

        guard reader.canAdd(output) else {
            throw TestError.readerRejectedOutput
        }

        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            samples.append(contentsOf: try floatSamples(from: sampleBuffer))
        }

        if reader.status == .failed {
            throw reader.error ?? TestError.readerFailed
        }

        return samples
    }

    private func floatSamples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw TestError.missingSampleData
        }

        let byteCount = CMBlockBufferGetDataLength(dataBuffer)
        guard byteCount % MemoryLayout<Float>.stride == 0 else {
            throw TestError.unexpectedSampleDataSize
        }

        var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.stride)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: bytes.baseAddress!
            )
        }

        guard status == noErr else {
            throw TestError.failedToReadSampleData(status)
        }

        return samples
    }

    private func temporaryFileURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }

    private enum TestError: Error {
        case failedToCreateBuffer
        case failedToReadSampleData(OSStatus)
        case missingAudioTrack
        case missingSampleData
        case readerFailed
        case readerRejectedOutput
        case unexpectedSampleDataSize
        case writerFailed
        case writerRejectedInput
    }
}
