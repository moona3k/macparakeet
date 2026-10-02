import AVFoundation
import FluidAudio
import XCTest

@testable import MacParakeetCore

final class DitheredAudioSampleSourceTests: XCTestCase {
    private typealias Dithered = DitheredAudioSampleSource<ArrayAudioSampleSource>

    private func read(_ source: Dithered, offset: Int, count: Int) throws -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        try samples.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: offset, count: count)
        }
        return samples
    }

    func testDigitalSilenceHasNoExactZeroLeft() throws {
        let source = Dithered(base: ArrayAudioSampleSource(samples: [Float](repeating: 0, count: 48_000)))

        let samples = try read(source, offset: 0, count: 48_000)

        XCTAssertFalse(samples.contains(0))
        XCTAssertTrue(samples.allSatisfy { abs($0) <= Dithered.amplitude })
    }

    func testNoiseIsNeverExactlyZero() {
        // The first index where the previous mapping produced exactly 0.
        XCTAssertNotEqual(Dithered.noise(at: 26_849_042), 0)
        XCTAssertFalse((0..<1_000_000).contains { Dithered.noise(at: $0) == 0 })
    }

    func testStagedFileOfDigitalSilenceIsDitheredAtSixteenKilohertz() throws {
        let url = try writeSilentWav(sampleCount: 48_000, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let (source, _) = try DitheredAudioSampleSource.staging(url, sampleRate: 16_000)
        defer { source.cleanup() }
        var samples = [Float](repeating: 0, count: source.sampleCount)
        try samples.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: 0, count: $0.count)
        }

        XCTAssertEqual(source.sampleCount, 16_000, accuracy: 16)
        XCTAssertFalse(samples.contains(0))
        XCTAssertTrue(samples.allSatisfy { abs($0) <= Dithered.amplitude })
    }

    func testNoiseIsInaudibleAndCentered() throws {
        let source = Dithered(base: ArrayAudioSampleSource(samples: [Float](repeating: 0, count: 160_000)))

        let samples = try read(source, offset: 0, count: 160_000)
        let mean = samples.reduce(0, +) / Float(samples.count)
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()

        XCTAssertLessThan(abs(mean), Dithered.amplitude / 50)
        XCTAssertEqual(rms, Dithered.amplitude / Float(3).squareRoot(), accuracy: Dithered.amplitude / 50)
    }

    func testOverlappingReadsGetTheSameNoise() throws {
        let source = Dithered(base: ArrayAudioSampleSource(samples: [Float](repeating: 0, count: 1_000)))

        let whole = try read(source, offset: 0, count: 1_000)
        let tail = try read(source, offset: 600, count: 400)

        XCTAssertEqual(Array(whole[600...]), tail)
    }

    func testSpeechIsOnlyShiftedByTheNoise() throws {
        let speech = (0..<1_000).map { sin(Float($0) * 0.05) * 0.5 }
        let source = Dithered(base: ArrayAudioSampleSource(samples: speech))

        let samples = try read(source, offset: 0, count: 1_000)

        for (dithered, original) in zip(samples, speech) {
            XCTAssertEqual(dithered, original, accuracy: Dithered.amplitude)
        }
        XCTAssertEqual(source.sampleCount, speech.count)
    }

    private func writeSilentWav(sampleCount: Int, sampleRate: Double) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))!
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        try file.write(from: buffer)
        return url
    }
}
