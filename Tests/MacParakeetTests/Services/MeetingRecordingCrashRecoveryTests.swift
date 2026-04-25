import AVFoundation
import Darwin
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingCrashRecoveryTests: XCTestCase {
    private static let helperFolderEnv = "MACPARAKEET_CRASH_RECOVERY_HELPER_FOLDER"

    func testKillNineMidRecordingProducesPlayableFiles() async throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecordingCrashRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "MacParakeetTests.MeetingRecordingCrashRecoveryTests/testCrashHelperWritesMeetingAudioUntilKilled",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            Self.helperFolderEnv: folderURL.path,
        ]) { _, new in new }

        try process.run()
        try await waitForFileToGrow(folderURL.appendingPathComponent("microphone.m4a"))
        try await Task.sleep(for: .seconds(5))
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()

        let duration = try await audioDuration(folderURL.appendingPathComponent("microphone.m4a"))
        XCTAssertGreaterThanOrEqual(duration, 4.0)
    }

    func testCrashHelperWritesMeetingAudioUntilKilled() throws {
        guard let folderPath = ProcessInfo.processInfo.environment[Self.helperFolderEnv] else {
            return
        }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let writer = try MeetingAudioStorageWriter(folderURL: folderURL)
        for second in 0..<15 {
            let buffer = try makeSineBuffer(frameCount: 48_000, frequency: 220 + Double(second * 10))
            try writer.write(buffer, source: .microphone)
            Thread.sleep(forTimeInterval: 1.0)
        }
        writer.finalize()
    }

    private func waitForFileToGrow(_ url: URL) async throws {
        let startedAt = ContinuousClock.now
        while true {
            if let size = try? fileSize(url), size > 1024 {
                return
            }
            if startedAt.duration(to: .now) > .seconds(8) {
                XCTFail("Timed out waiting for crash helper to write audio")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
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

    private enum TestError: Error {
        case failedToCreateBuffer
        case missingAudioTrack
    }
}
