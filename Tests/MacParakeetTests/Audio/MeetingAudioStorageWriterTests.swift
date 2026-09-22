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
        try writer.write(buffer, source: .microphone, timelineTimeSeconds: 132.1)
        try writer.write(buffer, source: .microphone, timelineTimeSeconds: 132.2)
        try writer.write(buffer, source: .microphone, timelineTimeSeconds: 132.3)

        let metrics = writer.metrics(for: .microphone)
        XCTAssertEqual(metrics.writtenFrameCount, 24_000)
        XCTAssertEqual(metrics.timelineFrameCount, 1_555_200)

        await finalize(writer)
        let duration = try await audioDuration(writer.microphoneAudioURL)
        XCTAssertEqual(duration, 32.4, accuracy: 0.35)
    }

    func testRetainedMonoIncludesRightChannelAudio() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        let buffer = try makeStereoSineBuffer(leftGain: 0, rightGain: 1, interleaved: false)
        try writer.write(buffer, source: .system)

        let report = await finalize(writer)

        XCTAssertTrue(report.failedSources.isEmpty)
        XCTAssertEqual(writer.metrics(for: .system).peakSampleMagnitude, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(writer.metrics(for: .system).writtenFrameCount, 48_000)
        XCTAssertEqual(writer.metrics(for: .system).timelineFrameCount, 48_000)
        XCTAssertGreaterThan(try decodedPeak(at: writer.systemAudioURL), 0)
    }

    func testRetainedMonoPreservesOppositeInterleavedChannels() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        let buffer = try makeStereoSineBuffer(leftGain: 1, rightGain: -1, interleaved: true)
        try writer.write(buffer, source: .system)

        let report = await finalize(writer)

        XCTAssertTrue(report.failedSources.isEmpty)
        XCTAssertEqual(writer.metrics(for: .system).peakSampleMagnitude, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(writer.metrics(for: .system).writtenFrameCount, 48_000)
        XCTAssertEqual(writer.metrics(for: .system).timelineFrameCount, 48_000)
        XCTAssertGreaterThan(try decodedPeak(at: writer.systemAudioURL), 0.1)
    }

    func testSuccessfulFinalizationReportsNoFailedWrittenSources() async throws {
        let writer = try MeetingAudioStorageWriter(folderURL: tempFolder)
        try writeSeconds(1, source: .microphone, writer: writer)
        try writeSeconds(1, source: .system, writer: writer)

        let report = await finalize(writer)

        XCTAssertTrue(report.failedSources.isEmpty)
        XCTAssertFalse(
            MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder)
        )
    }

    func testFinalizationCoordinatorCompletesExactlyOnceAfterBothSourcesSucceed() {
        let coordinator = MeetingAudioStorageWriter.FinalizationCoordinator(
            folderURL: tempFolder,
            writtenFrameCounts: [.microphone: 48_000, .system: 48_000]
        )

        XCTAssertNil(coordinator.sourceDidFinish(.microphone, failed: false))
        XCTAssertTrue(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
        XCTAssertEqual(
            coordinator.sourceDidFinish(.system, failed: false),
            .init(failedSources: [], timedOutSources: [])
        )
        XCTAssertFalse(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
        XCTAssertNil(coordinator.deadlineExpired())
        XCTAssertNil(coordinator.sourceDidFinish(.system, failed: false))
        MeetingAudioWriterFinalizationRegistry.begin(folderURL: tempFolder)
        defer { MeetingAudioWriterFinalizationRegistry.end(folderURL: tempFolder) }
        XCTAssertNil(coordinator.sourceDidFinish(.microphone, failed: false))
        XCTAssertTrue(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
    }

    func testFinalizationCoordinatorReportsOrdinaryWrittenSourceFailure() {
        let coordinator = MeetingAudioStorageWriter.FinalizationCoordinator(
            folderURL: tempFolder,
            writtenFrameCounts: [.microphone: 48_000, .system: 48_000]
        )

        XCTAssertNil(coordinator.sourceDidFinish(.microphone, failed: true))
        XCTAssertEqual(
            coordinator.sourceDidFinish(.system, failed: false),
            .init(failedSources: [.microphone], timedOutSources: [])
        )
        XCTAssertFalse(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
    }

    func testFinalizationCoordinatorReportsMissingWrittenSourceAtDeadlineWithoutWaiting() {
        let coordinator = MeetingAudioStorageWriter.FinalizationCoordinator(
            folderURL: tempFolder,
            writtenFrameCounts: [.microphone: 48_000, .system: 48_000]
        )

        XCTAssertNil(coordinator.sourceDidFinish(.system, failed: false))
        XCTAssertEqual(
            coordinator.deadlineExpired(),
            .init(failedSources: [.microphone], timedOutSources: [.microphone])
        )
        XCTAssertTrue(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
        XCTAssertNil(coordinator.sourceDidFinish(.microphone, failed: false))
        XCTAssertFalse(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
    }

    func testFinalizationCoordinatorReportsBothWrittenSourcesWhenBothCallbacksTimeOut() {
        let coordinator = MeetingAudioStorageWriter.FinalizationCoordinator(
            folderURL: tempFolder,
            writtenFrameCounts: [.microphone: 48_000, .system: 48_000]
        )

        XCTAssertEqual(
            coordinator.deadlineExpired(),
            .init(
                failedSources: [.microphone, .system],
                timedOutSources: [.microphone, .system]
            )
        )
        XCTAssertTrue(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
        XCTAssertNil(coordinator.sourceDidFinish(.system, failed: false))
        XCTAssertTrue(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
        XCTAssertNil(coordinator.deadlineExpired())
        XCTAssertNil(coordinator.sourceDidFinish(.microphone, failed: false))
        XCTAssertFalse(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
    }

    func testFinalizationCoordinatorPreservesUnwrittenTimeoutOwnershipAndIgnoresLateCallback() {
        let coordinator = MeetingAudioStorageWriter.FinalizationCoordinator(
            folderURL: tempFolder,
            writtenFrameCounts: [.microphone: 48_000, .system: 0]
        )

        XCTAssertNil(coordinator.sourceDidFinish(.microphone, failed: false))
        XCTAssertEqual(
            coordinator.deadlineExpired(),
            .init(failedSources: [], timedOutSources: [.system])
        )
        XCTAssertTrue(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
        XCTAssertNil(coordinator.sourceDidFinish(.system, failed: true))
        XCTAssertNil(coordinator.deadlineExpired())
        XCTAssertFalse(MeetingAudioWriterFinalizationRegistry.contains(folderURL: tempFolder))
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

    private func makeStereoSineBuffer(
        leftGain: Float,
        rightGain: Float,
        interleaved: Bool
    ) throws -> AVAudioPCMBuffer {
        let mono = try makeSineBuffer(frameCount: 48_000, frequency: 220)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: interleaved
            )
        )
        let stereo = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: mono.frameLength))
        stereo.frameLength = mono.frameLength
        let source = try XCTUnwrap(mono.floatChannelData)[0]
        let channels = try XCTUnwrap(stereo.floatChannelData)
        for frame in 0..<Int(mono.frameLength) {
            if interleaved {
                channels[0][frame * 2] = source[frame] * leftGain
                channels[0][frame * 2 + 1] = source[frame] * rightGain
            } else {
                channels[0][frame] = source[frame] * leftGain
                channels[1][frame] = source[frame] * rightGain
            }
        }
        return stereo
    }

    private func decodedPeak(at url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
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
