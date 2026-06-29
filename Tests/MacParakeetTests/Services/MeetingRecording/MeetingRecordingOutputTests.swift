import AVFoundation
import Foundation
import XCTest
@testable import MacParakeetCore

/// Coverage for the #605 cleaned-mic surface on `MeetingRecordingOutput`: the
/// `microphoneTranscriptionURL` preference policy (U4) and the `loadArchived`
/// disk probe that re-surfaces a derived cleaned mic on re-open.
final class MeetingRecordingOutputTests: XCTestCase {
    func testMicrophoneTranscriptionURLPrefersExistingCleanedMic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try writeM4A(to: cleanedURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), cleanedURL)
    }

    func testMicrophoneTranscriptionURLFallsBackToRawWhenCleanedMissingOnDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        try Data([0x00]).write(to: rawURL)
        // URL is set but the file was never written / was deleted by retention.
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), rawURL)
    }

    func testMicrophoneTranscriptionURLFallsBackToRawWhenCleanedIsCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), rawURL)
    }

    func testMicrophoneTranscriptionURLFallsBackToRawWhenCleanedIsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        FileManager.default.createFile(atPath: cleanedURL.path, contents: Data())

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), rawURL)
    }

    func testMicrophoneTranscriptionURLFallsBackToRawWhenNoCleanedURL() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        try Data([0x00]).write(to: rawURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: nil)
        XCTAssertEqual(output.microphoneTranscriptionURL(), rawURL)
    }

    func testLoadArchivedSurfacesCleanedMicWhenPresent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let mixedURL = dir.appendingPathComponent("meeting.m4a")
        try writeM4A(to: dir.appendingPathComponent("microphone-cleaned.m4a"))

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived", mixedAudioURL: mixedURL, durationSeconds: 12)
        XCTAssertEqual(
            output.cleanedMicrophoneAudioURL,
            dir.appendingPathComponent("microphone-cleaned.m4a"))
    }

    func testLoadArchivedIgnoresCorruptCleanedMic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let mixedURL = dir.appendingPathComponent("meeting.m4a")
        try Data("partial m4a fragment".utf8).write(to: dir.appendingPathComponent("microphone-cleaned.m4a"))

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived", mixedAudioURL: mixedURL, durationSeconds: 12)
        XCTAssertNil(output.cleanedMicrophoneAudioURL)
    }

    func testLoadArchivedHasNoCleanedMicWhenAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let mixedURL = dir.appendingPathComponent("meeting.m4a")

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived", mixedAudioURL: mixedURL, durationSeconds: 12)
        XCTAssertNil(output.cleanedMicrophoneAudioURL)
    }

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Metadata with nil source tracks so `loadArchived` does not require the
    /// raw `microphone.m4a`/`system.m4a` files — keeping these tests focused on
    /// the cleaned-mic probe.
    private func saveAlignmentMetadata(in dir: URL) throws {
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: MeetingSourceAlignment(
                    meetingOriginHostTime: nil, microphone: nil, system: nil),
                speechEngine: SpeechEngineSelection(engine: .parakeet)
            ),
            folderURL: dir
        )
    }

    private func writeM4A(to url: URL, sampleRate: Double = 16_000) throws {
        let frameCount = Int(sampleRate / 10)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
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
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            samples[index] = 0.1
        }
        try file.write(from: buffer)
    }

    private func makeOutput(
        folderURL: URL,
        microphoneAudioURL: URL,
        cleanedMicrophoneAudioURL: URL?
    ) -> MeetingRecordingOutput {
        MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Test",
            folderURL: folderURL,
            mixedAudioURL: folderURL.appendingPathComponent("meeting.m4a"),
            microphoneAudioURL: microphoneAudioURL,
            systemAudioURL: folderURL.appendingPathComponent("system.m4a"),
            cleanedMicrophoneAudioURL: cleanedMicrophoneAudioURL,
            durationSeconds: 1,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil, microphone: nil, system: nil)
        )
    }
}
