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

        await finalize(writer)

        let duration = try await audioDuration(writer.microphoneAudioURL)
        XCTAssertEqual(duration, 5.0, accuracy: 0.35)
    }

    func testWritesToBothMicAndSystemFiles() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        try writeSeconds(2, source: .microphone, writer: writer)
        try writeSeconds(2, source: .system, writer: writer)

        await finalize(writer)

        XCTAssertGreaterThan(try fileSize(writer.microphoneAudioURL), 0)
        XCTAssertGreaterThan(try fileSize(writer.systemAudioURL), 0)
        let microphoneDuration = try await audioDuration(writer.microphoneAudioURL)
        let systemDuration = try await audioDuration(writer.systemAudioURL)
        XCTAssertEqual(microphoneDuration, 2.0, accuracy: 0.35)
        XCTAssertEqual(systemDuration, 2.0, accuracy: 0.35)
    }

    func testFragmentedFileContainsMovieFragments() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        try writeSeconds(10, source: .microphone, writer: writer)

        await finalize(writer)

        let fragments = try fragmentBoundaryOffsets(in: writer.microphoneAudioURL)
        XCTAssertGreaterThanOrEqual(fragments.count, 1)
    }

    func testTimelineGapWritesSilenceWithoutInflatingCapturedFrameMetrics() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        let first = try makeSineBuffer(frameCount: 48_000, frequency: 220)
        let recovered = try makeSineBuffer(frameCount: 48_000, frequency: 440)

        try writer.write(
            first,
            source: .microphone,
            timelineTimeSeconds: 100
        )
        try writer.write(
            recovered,
            source: .microphone,
            timelineTimeSeconds: 103
        )

        let metrics = writer.metrics(for: .microphone)
        XCTAssertEqual(metrics.writtenFrameCount, 96_000)
        XCTAssertEqual(metrics.timelineFrameCount, 192_000)

        await finalize(writer)

        let duration = try await audioDuration(writer.microphoneAudioURL)
        XCTAssertEqual(duration, 4.0, accuracy: 0.35)
    }

    func testFirstValidTimelineTimestampAccountsForEarlierUntimedAudio() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        let buffer = try makeSineBuffer(frameCount: 48_000, frequency: 220)

        try writer.write(buffer, source: .system)
        try writer.write(buffer, source: .system, timelineTimeSeconds: 101)
        try writer.write(buffer, source: .system, timelineTimeSeconds: 103)

        let metrics = writer.metrics(for: .system)
        XCTAssertEqual(metrics.writtenFrameCount, 144_000)
        XCTAssertEqual(metrics.timelineFrameCount, 192_000)
        XCTAssertEqual(try XCTUnwrap(metrics.timelineOriginSeconds), 100, accuracy: 0.001)

        await finalize(writer)
        let duration = try await audioDuration(writer.systemAudioURL)
        XCTAssertEqual(duration, 4.0, accuracy: 0.35)
    }

    func testBoundedRouteRecoveryGapCanBeMaterializedWithoutBackpressureLoss() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        let buffer = try makeSineBuffer(frameCount: 4_800, frequency: 220)

        try writer.write(buffer, source: .microphone, timelineTimeSeconds: 100)
        try writer.write(buffer, source: .microphone, timelineTimeSeconds: 132)

        let metrics = writer.metrics(for: .microphone)
        XCTAssertEqual(metrics.writtenFrameCount, 9_600)
        XCTAssertEqual(metrics.timelineFrameCount, 1_540_800)

        await finalize(writer)
        let duration = try await audioDuration(writer.microphoneAudioURL)
        XCTAssertEqual(duration, 32.1, accuracy: 0.35)
    }

    func testSuccessfulFinalizationReportsNoFailedWrittenSources() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        try writeSeconds(1, source: .microphone, writer: writer)
        try writeSeconds(1, source: .system, writer: writer)

        let report = await finalize(writer)

        XCTAssertTrue(report.failedSources.isEmpty)
    }

    func testFinalizationFailurePolicyIgnoresUnwrittenSources() {
        XCTAssertFalse(
            MeetingAudioStorageWriter.shouldReportFinalizationFailure(
                status: .failed,
                hasError: true,
                writtenFrameCount: 0
            )
        )
        XCTAssertTrue(
            MeetingAudioStorageWriter.shouldReportFinalizationFailure(
                status: .failed,
                hasError: true,
                writtenFrameCount: 48_000
            )
        )
        XCTAssertFalse(
            MeetingAudioStorageWriter.shouldReportFinalizationFailure(
                status: .completed,
                hasError: false,
                writtenFrameCount: 48_000
            )
        )
        XCTAssertTrue(
            MeetingAudioStorageWriter.shouldReportFinalizationFailure(
                status: .completed,
                hasError: true,
                writtenFrameCount: 48_000
            )
        )
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

    @discardableResult
    private func finalize(
        _ writer: MeetingAudioStorageWriter
    ) async -> MeetingAudioStorageWriter.FinalizationReport {
        await withCheckedContinuation { continuation in
            writer.finalize { report in
                continuation.resume(returning: report)
            }
        }
    }

    private func makeSineBuffer(frameCount: Int, frequency: Double) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else {
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
            let range = data.range(of: marker, options: [], in: searchStart..<data.endIndex)
        {
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
