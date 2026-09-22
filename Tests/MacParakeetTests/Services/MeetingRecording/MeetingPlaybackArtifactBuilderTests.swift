import AVFoundation
import XCTest
@testable import MacParakeetCore

final class MeetingPlaybackArtifactBuilderTests: XCTestCase {
    func testBuildInstallsValidMixedArtifact() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphoneURL = directory.appendingPathComponent("microphone.m4a")
        let systemURL = directory.appendingPathComponent("system.m4a")
        let mixedFixtureURL = directory.appendingPathComponent("valid-mix.m4a")
        let outputURL = directory.appendingPathComponent("meeting-playback.m4a")
        try writeM4A(to: microphoneURL, durationSeconds: 0.1)
        try writeM4A(to: systemURL, durationSeconds: 0.2)
        try writeM4A(to: mixedFixtureURL, durationSeconds: 0.5)
        let microphoneTrack = track(durationSeconds: 0.1)
        let systemTrack = track(durationSeconds: 0.2)
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: microphoneTrack,
            system: systemTrack
        )
        let builder = MeetingPlaybackArtifactBuilder(
            audioConverter: FixtureMixAudioConverter(fixtureURL: mixedFixtureURL)
        )

        let result = try await builder.build(
            candidates: [
                .init(source: .microphone, url: microphoneURL, track: microphoneTrack),
                .init(source: .system, url: systemURL, track: systemTrack),
            ],
            outputURL: outputURL,
            sourceAlignment: alignment
        )

        XCTAssertEqual(result.method, .mixed)
        XCTAssertNil(result.source)
        XCTAssertGreaterThan(result.durationSeconds, 0.3)
        let outputFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThan(outputFile.length, 0)
        let outputTracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        XCTAssertFalse(outputTracks.isEmpty)
    }

    func testBuildRejectsShortMixAndPreservesOffsetInBestSourceFallback() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphoneURL = directory.appendingPathComponent("microphone.m4a")
        let systemURL = directory.appendingPathComponent("system.m4a")
        let shortMixFixtureURL = directory.appendingPathComponent("short-mix.m4a")
        let outputURL = directory.appendingPathComponent("meeting-playback.m4a")
        try writeM4A(to: microphoneURL, durationSeconds: 0.2)
        try writeM4A(to: systemURL, durationSeconds: 0.3)
        try writeM4A(to: shortMixFixtureURL, durationSeconds: 0.1)
        let microphoneTrack = track(durationSeconds: 0.2, startOffsetMs: 250)
        let systemTrack = track(durationSeconds: 0.3)
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: microphoneTrack,
            system: systemTrack
        )
        let builder = MeetingPlaybackArtifactBuilder(
            audioConverter: FixtureMixAudioConverter(fixtureURL: shortMixFixtureURL)
        )

        let result = try await builder.build(
            candidates: [
                .init(source: .microphone, url: microphoneURL, track: microphoneTrack),
                .init(source: .system, url: systemURL, track: systemTrack),
            ],
            outputURL: outputURL,
            sourceAlignment: alignment
        )

        XCTAssertEqual(result.method, .bestSourceFallback)
        XCTAssertEqual(result.source, .microphone)
        XCTAssertGreaterThan(result.durationSeconds, 0.35)
        let outputFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThan(outputFile.length, 0)
        let outputTracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        XCTAssertFalse(outputTracks.isEmpty)
    }

    func testBestSourceFallbackPrefersMicrophoneWhenPlayableEndsTie() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphoneURL = directory.appendingPathComponent("microphone.m4a")
        let systemURL = directory.appendingPathComponent("system.m4a")
        let shortMixFixtureURL = directory.appendingPathComponent("short-mix.m4a")
        let outputURL = directory.appendingPathComponent("meeting-playback.m4a")
        try writeM4A(to: microphoneURL, durationSeconds: 0.2)
        try writeM4A(to: systemURL, durationSeconds: 0.2)
        try writeM4A(to: shortMixFixtureURL, durationSeconds: 0.1)
        let microphoneTrack = track(durationSeconds: 0.2, startOffsetMs: 250)
        let systemTrack = track(durationSeconds: 0.2, startOffsetMs: 250)
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: microphoneTrack,
            system: systemTrack
        )
        let builder = MeetingPlaybackArtifactBuilder(
            audioConverter: FixtureMixAudioConverter(fixtureURL: shortMixFixtureURL)
        )

        let result = try await builder.build(
            candidates: [
                .init(source: .microphone, url: microphoneURL, track: microphoneTrack),
                .init(source: .system, url: systemURL, track: systemTrack),
            ],
            outputURL: outputURL,
            sourceAlignment: alignment
        )

        XCTAssertEqual(result.method, .bestSourceFallback)
        XCTAssertEqual(result.source, .microphone)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-playback-builder-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func track(
        durationSeconds: TimeInterval,
        startOffsetMs: Int = 0,
        sampleRate: Double = 16_000
    ) -> MeetingSourceAlignment.Track {
        MeetingSourceAlignment.Track(
            firstHostTime: 100,
            lastHostTime: 200,
            startOffsetMs: startOffsetMs,
            writtenFrameCount: Int64((durationSeconds * sampleRate).rounded()),
            sampleRate: sampleRate
        )
    }

    private func writeM4A(
        to url: URL,
        durationSeconds: TimeInterval,
        sampleRate: Double = 16_000
    ) throws {
        let frameCount = max(1, Int((durationSeconds * sampleRate).rounded()))
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frameCount {
            samples[index] = 0.1
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        } catch {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatAppleLossless,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
    }
}

private final class FixtureMixAudioConverter: AudioFileConverting, @unchecked Sendable {
    private let fixtureURL: URL

    init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func mixToM4A(
        inputURLs: [URL],
        outputURL: URL,
        sourceAlignment: MeetingSourceAlignment?
    ) async throws {
        try FileManager.default.copyItem(at: fixtureURL, to: outputURL)
    }
}
