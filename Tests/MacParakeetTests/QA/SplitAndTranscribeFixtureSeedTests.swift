import AVFoundation
import XCTest

@testable import MacParakeetCore

/// Opt-in, DEBUG-only fixture seeder for host QA of native "Split and
/// transcribe" (issue #895). Not run by default and never touches a real
/// install: it only writes anything when `MACPARAKEET_DEBUG_APP_STATE_DIR`
/// points at a path under the system temporary directory that does not yet
/// exist, so a fresh, disposable app-state root is always required.
///
/// Usage:
///   FIXTURE_DIR="$(mktemp -d)/macparakeet-895-fixture"
///   MACPARAKEET_DEBUG_APP_STATE_DIR="$FIXTURE_DIR" swift test --filter SplitAndTranscribeFixtureSeedTests
///   MACPARAKEET_DEBUG_APP_STATE_DIR="$FIXTURE_DIR" scripts/dev/run_app.sh
///
/// The seeded meeting has real (silent-tone) audio in the exact on-disk
/// layout `MeetingSplitService` expects, a saved transcript, and
/// `status == .completed`, so it is immediately eligible for the native
/// Split and transcribe sheet without any live recording or STT model.
final class SplitAndTranscribeFixtureSeedTests: XCTestCase {
    func testSeedSplitAndTranscribeFixture() throws {
        guard
            let rawDir = ProcessInfo.processInfo.environment[AppPaths.debugAppStateDirEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawDir.isEmpty
        else {
            throw XCTSkip(
                "Set \(AppPaths.debugAppStateDirEnvironmentKey) to a fresh temp directory to seed a Split and transcribe QA fixture."
            )
        }

        let stateDir = URL(fileURLWithPath: rawDir, isDirectory: true).standardizedFileURL
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL
        guard stateDir.path.hasPrefix(temporaryRoot.path + "/") else {
            XCTFail(
                "\(AppPaths.debugAppStateDirEnvironmentKey) must be under \(temporaryRoot.path); refusing to seed \(stateDir.path)."
            )
            return
        }
        guard !FileManager.default.fileExists(atPath: stateDir.path) else {
            XCTFail(
                "\(stateDir.path) already exists; refusing to seed over an existing target. Use a fresh directory."
            )
            return
        }

        try AppPaths.ensureDirectories()
        let manager = try DatabaseManager(path: AppPaths.databasePath)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)

        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let durationMs = 90_000
        try Self.writeToneM4A(
            to: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            sampleRate: 48_000,
            durationMs: durationMs
        )
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: MeetingSourceAlignment(meetingOriginHostTime: nil, microphone: nil, system: nil)
            ),
            folderURL: folderURL
        )

        let transcription = Transcription(
            fileName: "Weekly sync — Split QA fixture",
            filePath: folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback).path,
            meetingArtifactFolderPath: folderURL.path,
            durationMs: durationMs,
            rawTranscript: """
                Alex: Let's get started — first up is the roadmap review.
                Jordan: Sounds good. I'll cover onboarding, then hand off to you for the release plan.
                Alex: Perfect, let's dive in.
                """,
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(transcription)

        print("Seeded Split and transcribe QA fixture at \(stateDir.path) — meeting id \(transcription.id).")
    }

    private static func writeToneM4A(to url: URL, sampleRate: Double, durationMs: Int) throws {
        let frameCount = max(1, Int((Double(durationMs) * sampleRate / 1_000).rounded()))
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frameCount {
            samples[index] = Float(0.05 * sin(2 * .pi * 220 * Double(index) / sampleRate))
        }
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
    }
}
