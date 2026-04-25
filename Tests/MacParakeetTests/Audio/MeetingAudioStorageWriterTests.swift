import AVFoundation
import XCTest
@testable import MacParakeetCore

final class MeetingAudioStorageWriterTests: XCTestCase {
    private var tempFolder: URL!

    override func setUpWithError() throws {
        tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioStorageWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFolder)
    }

    func testFinalizedFileLoadsAsAVAssetWithExpectedDuration() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        try writeSeconds(5, source: .microphone, writer: writer)

        writer.finalize()

        let duration = try await audioDuration(writer.microphoneAudioURL)
        XCTAssertEqual(duration, 5.0, accuracy: 0.35)
    }

    func testWritesToBothMicAndSystemFiles() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        try writeSeconds(2, source: .microphone, writer: writer)
        try writeSeconds(2, source: .system, writer: writer)

        writer.finalize()

        XCTAssertGreaterThan(try fileSize(writer.microphoneAudioURL), 0)
        XCTAssertGreaterThan(try fileSize(writer.systemAudioURL), 0)
        let microphoneDuration = try await audioDuration(writer.microphoneAudioURL)
        let systemDuration = try await audioDuration(writer.systemAudioURL)
        XCTAssertEqual(microphoneDuration, 2.0, accuracy: 0.35)
        XCTAssertEqual(systemDuration, 2.0, accuracy: 0.35)
    }

    func testFragmentedFileContainsMovieFragments() throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        try writeSeconds(10, source: .microphone, writer: writer)

        writer.finalize()

        let fragments = try fragmentBoundaryOffsets(in: writer.microphoneAudioURL)
        XCTAssertGreaterThanOrEqual(fragments.count, 1)
    }

    func testWriterDoesNotReferenceAVAudioFile() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/MacParakeetCore/Audio/MeetingAudioStorageWriter.swift")
        let source = try String(contentsOf: sourceURL)
        XCTAssertFalse(source.contains("AVAudioFile"))
    }

    private func writeSeconds(
        _ seconds: Int,
        source: AudioSource,
        writer: MeetingAudioStorageWriter
    ) throws {
        for chunkIndex in 0..<seconds {
            let buffer = try makeSineBuffer(
                frameCount: 48_000,
                frequency: 220 + Double(chunkIndex * 10)
            )
            try writer.write(buffer, source: source)
        }
    }

    private func makeSineBuffer(frameCount: Int, frequency: Double) throws -> AVAudioPCMBuffer {
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
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000.0
            samples[index] = Float(sin(phase) * 0.2)
        }
        return buffer
    }

    private func audioDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TestError.missingAudioTrack }
        let duration = try await asset.load(.duration)
        return duration.seconds
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func fragmentBoundaryOffsets(in url: URL) throws -> [Int] {
        let data = try Data(contentsOf: url)
        let marker = Data("moof".utf8)
        var offsets: [Int] = []
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let range = data.range(of: marker, options: [], in: searchStart..<data.endIndex) {
            offsets.append(range.lowerBound - 4)
            searchStart = range.upperBound
        }
        return offsets.filter { $0 > 0 }
    }

    private enum TestError: Error {
        case failedToCreateBuffer
        case missingAudioTrack
    }
}
