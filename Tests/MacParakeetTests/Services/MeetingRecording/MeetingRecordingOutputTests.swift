import AVFoundation
import Foundation
import XCTest
@testable import MacParakeetCore

/// Coverage for the #605 cleaned-mic surface on `MeetingRecordingOutput`: the
/// `microphoneTranscriptionURL` preference policy, the validated STT routing
/// gate (U4), and the `loadArchived` disk probe that re-surfaces a derived
/// cleaned mic on re-open.
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

    func testMicrophoneTranscriptionURLIsCheapAndDoesNotDecodeCorruptCleanedMic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), cleanedURL)
    }

    func testValidatedMicrophoneTranscriptionURLFallsBackToRawWhenCleanedIsCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.validatedMicrophoneTranscriptionURL(), rawURL)
    }

    func testReadinessTimeoutDoesNotPublishLateCleanedArtifact() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let systemURL = dir.appendingPathComponent("system.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        let candidateURL = dir.appendingPathComponent(".microphone-cleaned-test.tmp.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data([0x00]).write(to: systemURL)
        let renderTask = Task<MeetingCleanedMicrophoneRenderCompletion, Never> {
            try? await Task.sleep(for: .milliseconds(150))
            try? Data("candidate payload".utf8).write(to: candidateURL)
            return .rendered(candidateURL)
        }
        let readiness = MeetingCleanedMicrophoneReadiness.scheduled(
            outputURL: cleanedURL,
            task: renderTask,
            candidateOutputURL: candidateURL
        )
        let output = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Timeout",
            folderURL: dir,
            mixedAudioURL: dir.appendingPathComponent("meeting.m4a"),
            microphoneAudioURL: rawURL,
            systemAudioURL: systemURL,
            cleanedMicrophoneAudioURL: cleanedURL,
            cleanedMicrophoneReadiness: readiness,
            durationSeconds: 1,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: .init(
                    firstHostTime: 100,
                    lastHostTime: 200,
                    startOffsetMs: 0,
                    writtenFrameCount: 16_000,
                    sampleRate: 16_000
                ),
                system: .init(
                    firstHostTime: 100,
                    lastHostTime: 200,
                    startOffsetMs: 0,
                    writtenFrameCount: 16_000,
                    sampleRate: 16_000
                )
            )
        )

        let decision = try await output.resolvedMicrophoneTranscriptionSource(
            policy: .init(floorSeconds: 0.05, durationMultiplier: 0, capSeconds: 0.05)
        )
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(decision.reason, .rawTimeout)
        XCTAssertEqual(decision.url, rawURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testResolvedSourcePersistsEchoSuppressionMetadataForCleanedRender() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let systemURL = dir.appendingPathComponent("system.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data([0x00]).write(to: systemURL)
        let renderSummary = MeetingCleanedMicrophoneRenderSummary(
            modelVersion: "localvqe-v1.4-aec-200K-f32.gguf",
            renderDurationMs: 123,
            realtimeFactor: 8.5,
            delayEstimateMs: 42,
            probeWindowsEvaluated: 3,
            probeBestCorrelation: 0.41
        )
        let renderTask = Task<MeetingCleanedMicrophoneRenderCompletion, Never> {
            try? await MeetingCleanedMicRenderer.encodeMonoFloat(
                [Float](repeating: 0.05, count: 1_600),
                sampleRate: 16_000,
                to: cleanedURL,
                fileManager: .default
            )
            return .rendered(cleanedURL, summary: renderSummary)
        }
        let output = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Cleaned",
            folderURL: dir,
            mixedAudioURL: dir.appendingPathComponent("meeting.m4a"),
            microphoneAudioURL: rawURL,
            systemAudioURL: systemURL,
            cleanedMicrophoneAudioURL: cleanedURL,
            cleanedMicrophoneReadiness: .scheduled(outputURL: cleanedURL, task: renderTask),
            durationSeconds: 1,
            sourceAlignment: dualSourceAlignment()
        )

        let decision = try await output.resolvedMicrophoneTranscriptionSource(
            policy: .init(floorSeconds: 1, durationMultiplier: 0, capSeconds: 1)
        )

        XCTAssertEqual(decision.reason, .cleanedUsed)
        let metadata = try MeetingRecordingMetadataStore.load(from: dir)
        let echo = try XCTUnwrap(metadata.echoSuppression)
        XCTAssertEqual(echo.reasonCode, .cleanedUsed)
        XCTAssertEqual(echo.modelVersion, "localvqe-v1.4-aec-200K-f32.gguf")
        XCTAssertEqual(echo.renderDurationMs, 123)
        XCTAssertEqual(echo.delayEstimateMs, 42)
        XCTAssertEqual(try XCTUnwrap(echo.probeBestCorrelation), 0.41, accuracy: 0.0001)
    }

    func testResolvedSourcePersistsEchoSuppressionMetadataForNoEchoSkip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let rawURL = dir.appendingPathComponent("microphone.m4a")
        let systemURL = dir.appendingPathComponent("system.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data([0x00]).write(to: systemURL)
        let renderSummary = MeetingCleanedMicrophoneRenderSummary(
            modelVersion: nil,
            renderDurationMs: nil,
            realtimeFactor: nil,
            delayEstimateMs: nil,
            probeWindowsEvaluated: 5,
            probeBestCorrelation: 0.03
        )
        let renderTask = Task<MeetingCleanedMicrophoneRenderCompletion, Never> {
            .fallback(.skippedNoEchoPath, summary: renderSummary)
        }
        let output = MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "No Echo",
            folderURL: dir,
            mixedAudioURL: dir.appendingPathComponent("meeting.m4a"),
            microphoneAudioURL: rawURL,
            systemAudioURL: systemURL,
            cleanedMicrophoneAudioURL: cleanedURL,
            cleanedMicrophoneReadiness: .scheduled(outputURL: cleanedURL, task: renderTask),
            durationSeconds: 1,
            sourceAlignment: dualSourceAlignment()
        )

        let decision = try await output.resolvedMicrophoneTranscriptionSource(
            policy: .init(floorSeconds: 1, durationMultiplier: 0, capSeconds: 1)
        )

        XCTAssertEqual(decision.reason, .skippedNoEchoPath)
        XCTAssertEqual(decision.url, rawURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanedURL.path))
        let metadata = try MeetingRecordingMetadataStore.load(from: dir)
        let echo = try XCTUnwrap(metadata.echoSuppression)
        XCTAssertEqual(echo.reasonCode, .skippedNoEchoPath)
        XCTAssertNil(echo.modelVersion)
        XCTAssertNil(echo.renderDurationMs)
        XCTAssertNil(echo.delayEstimateMs)
        XCTAssertEqual(try XCTUnwrap(echo.probeBestCorrelation), 0.03, accuracy: 0.0001)
        let json =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: MeetingRecordingMetadataStore.metadataURL(for: dir))
            ) as? [String: Any]
        let echoJSON = try XCTUnwrap(json?["echoSuppression"] as? [String: Any])
        XCTAssertFalse(echoJSON.keys.contains("modelVersion"))
        XCTAssertFalse(echoJSON.keys.contains("renderDurationMs"))
        XCTAssertFalse(echoJSON.keys.contains("delayEstimateMs"))
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

    func testLoadArchivedSurfacesNonEmptyCleanedMicForDeferredValidation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let mixedURL = dir.appendingPathComponent("meeting.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived", mixedAudioURL: mixedURL, durationSeconds: 12)
        XCTAssertEqual(output.cleanedMicrophoneAudioURL, cleanedURL)
        XCTAssertEqual(output.validatedMicrophoneTranscriptionURL(), output.microphoneAudioURL)
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

    func testLoadArchivedHasNoCleanedMicWhenEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let mixedURL = dir.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("microphone-cleaned.m4a").path,
            contents: Data())

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived", mixedAudioURL: mixedURL, durationSeconds: 12)
        XCTAssertNil(output.cleanedMicrophoneAudioURL)
    }

    func testMetadataLoadReportsFailedContentsProbeAsUnreadableNotMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)

        XCTAssertThrowsError(try MeetingRecordingMetadataStore.load(
            from: dir,
            fileManager: ContentsProbeFailingFileManager())) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("Unable to read archived meeting metadata"),
                    "Unexpected error: \(error)")
        }
    }

    func testUpdateEchoSuppressionPreservesLegacyMissingSpeechEngine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeLegacyMetadataWithoutSpeechEngine(in: dir)

        try MeetingRecordingMetadataStore.updateEchoSuppression(
            MeetingEchoSuppressionMetadata(reasonCode: .skippedNoEchoPath),
            folderURL: dir
        )

        let data = try Data(contentsOf: MeetingRecordingMetadataStore.metadataURL(for: dir))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["speechEngine"])
        let metadata = try MeetingRecordingMetadataStore.load(from: dir)
        XCTAssertFalse(metadata.speechEngineWasCaptured)
        XCTAssertEqual(metadata.echoSuppression?.reasonCode, .skippedNoEchoPath)
    }

    func testUpdateEchoSuppressionSavesThroughInjectedFileManager() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let virtualFileManager = RecordingMetadataFileManager(
            data: try legacyMetadataDataWithoutSpeechEngine()
        )

        try MeetingRecordingMetadataStore.updateEchoSuppression(
            MeetingEchoSuppressionMetadata(reasonCode: .cleanedUsed, modelVersion: "test-model.gguf"),
            folderURL: dir,
            fileManager: virtualFileManager
        )

        XCTAssertEqual(
            virtualFileManager.createdPaths,
            [MeetingRecordingMetadataStore.metadataURL(for: dir).path]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MeetingRecordingMetadataStore.metadataURL(for: dir).path))
        let data = try XCTUnwrap(virtualFileManager.data)
        let metadata = try JSONDecoder().decode(MeetingRecordingMetadata.self, from: data)
        XCTAssertFalse(metadata.speechEngineWasCaptured)
        XCTAssertEqual(metadata.echoSuppression?.reasonCode, .cleanedUsed)
        XCTAssertEqual(metadata.echoSuppression?.modelVersion, "test-model.gguf")
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

    private func legacyMetadataDataWithoutSpeechEngine() throws -> Data {
        let scratch = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try writeLegacyMetadataWithoutSpeechEngine(in: scratch)
        return try Data(contentsOf: MeetingRecordingMetadataStore.metadataURL(for: scratch))
    }

    private func writeLegacyMetadataWithoutSpeechEngine(in dir: URL) throws {
        try saveAlignmentMetadata(in: dir)
        let url = MeetingRecordingMetadataStore.metadataURL(for: dir)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any])
        json.removeValue(forKey: "speechEngine")
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func dualSourceAlignment() -> MeetingSourceAlignment {
        MeetingSourceAlignment(
            meetingOriginHostTime: 100,
            microphone: .init(
                firstHostTime: 100,
                lastHostTime: 200,
                startOffsetMs: 0,
                writtenFrameCount: 16_000,
                sampleRate: 16_000
            ),
            system: .init(
                firstHostTime: 100,
                lastHostTime: 200,
                startOffsetMs: 0,
                writtenFrameCount: 16_000,
                sampleRate: 16_000
            )
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
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
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

private final class ContentsProbeFailingFileManager: FileManager {
    override func fileExists(atPath path: String) -> Bool {
        true
    }

    override func contents(atPath path: String) -> Data? {
        nil
    }
}

private final class RecordingMetadataFileManager: FileManager {
    private(set) var data: Data?
    private(set) var createdPaths: [String] = []

    init(data: Data) {
        self.data = data
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        data != nil
    }

    override func contents(atPath path: String) -> Data? {
        data
    }

    override func removeItem(at URL: URL) throws {
        data = nil
    }

    override func createFile(
        atPath path: String,
        contents data: Data?,
        attributes attr: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        createdPaths.append(path)
        self.data = data
        return true
    }
}
