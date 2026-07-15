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
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try writeM4A(to: cleanedURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), cleanedURL)
    }

    func testMicrophoneTranscriptionURLFallsBackToRawWhenCleanedMissingOnDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        try Data([0x00]).write(to: rawURL)
        // URL is set but the file was never written / was deleted by retention.
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), rawURL)
    }

    func testMicrophoneTranscriptionURLIsCheapAndDoesNotDecodeCorruptCleanedMic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), cleanedURL)
    }

    func testValidatedMicrophoneTranscriptionURLFallsBackToRawWhenCleanedIsCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.validatedMicrophoneTranscriptionURL(), rawURL)
    }

    func testReadinessTimeoutDoesNotPublishLateCleanedArtifact() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let systemURL = dir.appendingPathComponent("system-raw.m4a")
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
            mixedAudioURL: dir.appendingPathComponent("meeting-playback.m4a"),
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
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let systemURL = dir.appendingPathComponent("system-raw.m4a")
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
            mixedAudioURL: dir.appendingPathComponent("meeting-playback.m4a"),
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

    func testResolvedSourcePreservesArchivedCleanedRenderMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try writeM4A(to: cleanedURL)
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: dualSourceAlignment(),
                echoSuppression: MeetingEchoSuppressionMetadata(
                    reasonCode: .cleanedUsed,
                    modelVersion: "localvqe-v1.4-aec-200K-f32.gguf",
                    renderDurationMs: 234,
                    delayEstimateMs: 18,
                    probeBestCorrelation: 0.52
                )
            ),
            folderURL: dir
        )
        let output = makeOutput(
            folderURL: dir,
            microphoneAudioURL: rawURL,
            cleanedMicrophoneAudioURL: cleanedURL
        )

        let decision = try await output.resolvedMicrophoneTranscriptionSource()

        XCTAssertEqual(decision.reason, .cleanedUsed)
        let echo = try XCTUnwrap(MeetingRecordingMetadataStore.load(from: dir).echoSuppression)
        XCTAssertEqual(echo.reasonCode, .cleanedUsed)
        XCTAssertEqual(echo.modelVersion, "localvqe-v1.4-aec-200K-f32.gguf")
        XCTAssertEqual(echo.renderDurationMs, 234)
        XCTAssertEqual(echo.delayEstimateMs, 18)
        XCTAssertEqual(try XCTUnwrap(echo.probeBestCorrelation), 0.52, accuracy: 0.0001)
    }

    func testResolvedSourcePreservesArchivedCleanedMetricsWhenArtifactTurnsInvalid() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: dualSourceAlignment(),
                echoSuppression: MeetingEchoSuppressionMetadata(
                    reasonCode: .cleanedUsed,
                    modelVersion: "localvqe-v1.4-aec-200K-f32.gguf",
                    renderDurationMs: 234,
                    delayEstimateMs: 18,
                    probeBestCorrelation: 0.52
                )
            ),
            folderURL: dir
        )
        let output = makeOutput(
            folderURL: dir,
            microphoneAudioURL: rawURL,
            cleanedMicrophoneAudioURL: cleanedURL
        )

        let decision = try await output.resolvedMicrophoneTranscriptionSource()

        XCTAssertEqual(decision.reason, .rawInvalidArtifact)
        let echo = try XCTUnwrap(MeetingRecordingMetadataStore.load(from: dir).echoSuppression)
        XCTAssertEqual(echo.reasonCode, .rawInvalidArtifact)
        XCTAssertEqual(echo.modelVersion, "localvqe-v1.4-aec-200K-f32.gguf")
        XCTAssertEqual(echo.renderDurationMs, 234)
        XCTAssertEqual(echo.delayEstimateMs, 18)
        XCTAssertEqual(try XCTUnwrap(echo.probeBestCorrelation), 0.52, accuracy: 0.0001)
    }

    func testResolvedSourcePersistsEchoSuppressionMetadataForNoEchoSkip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let systemURL = dir.appendingPathComponent("system-raw.m4a")
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
            mixedAudioURL: dir.appendingPathComponent("meeting-playback.m4a"),
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
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        let cleanedURL = dir.appendingPathComponent("microphone-cleaned.m4a")
        try Data([0x00]).write(to: rawURL)
        FileManager.default.createFile(atPath: cleanedURL.path, contents: Data())

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: cleanedURL)
        XCTAssertEqual(output.microphoneTranscriptionURL(), rawURL)
    }

    func testMicrophoneTranscriptionURLFallsBackToRawWhenNoCleanedURL() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = dir.appendingPathComponent("microphone-raw.m4a")
        try Data([0x00]).write(to: rawURL)

        let output = makeOutput(folderURL: dir, microphoneAudioURL: rawURL, cleanedMicrophoneAudioURL: nil)
        XCTAssertEqual(output.microphoneTranscriptionURL(), rawURL)
    }

    func testLoadArchivedSurfacesCleanedMicWhenPresent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let mixedURL = dir.appendingPathComponent("meeting-playback.m4a")
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
        let mixedURL = dir.appendingPathComponent("meeting-playback.m4a")
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
        let mixedURL = dir.appendingPathComponent("meeting-playback.m4a")

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived", mixedAudioURL: mixedURL, durationSeconds: 12)
        XCTAssertNil(output.cleanedMicrophoneAudioURL)
    }

    func testLoadArchivedHasNoCleanedMicWhenEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)
        let mixedURL = dir.appendingPathComponent("meeting-playback.m4a")
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("microphone-cleaned.m4a").path,
            contents: Data())

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived", mixedAudioURL: mixedURL, durationSeconds: 12)
        XCTAssertNil(output.cleanedMicrophoneAudioURL)
    }

    func testLoadArchivedReadsLegacyMeetingAudioFileNames() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(sourceAlignment: dualSourceAlignment()),
            folderURL: dir
        )
        try writeM4A(to: dir.appendingPathComponent("microphone.m4a"))
        try writeM4A(to: dir.appendingPathComponent("system.m4a"))
        try writeM4A(to: dir.appendingPathComponent("meeting.m4a"))

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived",
            mixedAudioURL: dir.appendingPathComponent("meeting-playback.m4a"),
            durationSeconds: 12
        )

        XCTAssertEqual(output.mixedAudioURL.lastPathComponent, "meeting.m4a")
        XCTAssertEqual(output.microphoneAudioURL.lastPathComponent, "microphone.m4a")
        XCTAssertEqual(output.systemAudioURL.lastPathComponent, "system.m4a")
    }

    func testLoadArchivedPreservesCalendarSnapshotFromMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendarSnapshot = MeetingCalendarSnapshot(
            confidence: .confirmed,
            eventIdentifier: "evt-sidecar",
            externalId: "external-sidecar",
            title: "Sidecar Review",
            scheduledStartAt: Date(timeIntervalSince1970: 1_720_000_000),
            scheduledEndAt: Date(timeIntervalSince1970: 1_720_003_600),
            attendees: [
                MeetingCalendarPerson(name: "Alice Example", email: "alice@example.com"),
            ],
            organizer: MeetingCalendarPerson(name: "Omar Organizer", email: "omar@example.com"),
            meetingURL: "https://zoom.us/j/123456789",
            meetingService: "Zoom",
            capturedAt: Date(timeIntervalSince1970: 1_720_000_010)
        )
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: MeetingSourceAlignment(
                    meetingOriginHostTime: nil,
                    microphone: nil,
                    system: nil
                ),
                speechEngine: SpeechEngineSelection(engine: .parakeet),
                calendarEventSnapshot: calendarSnapshot
            ),
            folderURL: dir
        )

        let output = try MeetingRecordingOutput.loadArchived(
            displayName: "Archived",
            mixedAudioURL: dir.appendingPathComponent("meeting-playback.m4a"),
            durationSeconds: 12
        )

        XCTAssertEqual(output.calendarEventSnapshot, calendarSnapshot)
    }

    func testMetadataLoadIgnoresMalformedCalendarSnapshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {
            "sourceAlignment": {
                "meetingOriginHostTime": null,
                "microphone": null,
                "system": null
            },
            "speechEngine": {
                "engine": "parakeet"
            },
            "calendarEventSnapshot": 42
        }
        """
        try Data(json.utf8).write(to: MeetingRecordingMetadataStore.metadataURL(for: dir))

        let metadata = try MeetingRecordingMetadataStore.load(from: dir)
        XCTAssertNil(metadata.calendarEventSnapshot)
        XCTAssertEqual(metadata.speechEngine.engine, .parakeet)
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

    func testMeetingRecordingMetadataRoundTripsStartContext() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let startContext = MeetingStartContext(
            triggerKind: .calendarAutoStart,
            frontmostApplication: .init(
                bundleIdentifier: "us.zoom.xos",
                localizedName: "zoom.us"
            ),
            sourceMode: .microphoneAndSystem
        )
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: MeetingSourceAlignment(
                    meetingOriginHostTime: nil,
                    microphone: nil,
                    system: nil
                ),
                startContext: startContext
            ),
            folderURL: dir
        )

        let metadata = try MeetingRecordingMetadataStore.load(from: dir)
        XCTAssertEqual(metadata.startContext, startContext)

        let archived = try MeetingRecordingOutput.loadArchived(
            displayName: "Recovered Meeting",
            mixedAudioURL: dir.appendingPathComponent("meeting-playback.m4a"),
            durationSeconds: 12
        )
        XCTAssertEqual(archived.startContext, startContext)
    }

    func testMeetingRecordingMetadataRoundTripsOptionalPreviewSpeechEngine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preview = SpeechEngineSelection(engine: .parakeet)
        let final = SpeechEngineSelection(engine: .cohere, language: "fr")

        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: dualSourceAlignment(),
                speechEngine: final,
                previewSpeechEngine: preview
            ),
            folderURL: dir
        )

        let metadata = try MeetingRecordingMetadataStore.load(from: dir)
        XCTAssertEqual(metadata.speechEngine, final)
        XCTAssertEqual(metadata.previewSpeechEngine, preview)
    }

    func testLegacyMeetingRecordingMetadataWithoutPreviewSpeechEngineStillLoads() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = MeetingRecordingMetadata(
            sourceAlignment: dualSourceAlignment(),
            speechEngine: SpeechEngineSelection(engine: .whisper, language: "ja")
        )
        let encoded = try JSONEncoder().encode(metadata)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "previewSpeechEngine")
        try JSONSerialization.data(withJSONObject: object).write(
            to: MeetingRecordingMetadataStore.metadataURL(for: dir)
        )

        let decoded = try MeetingRecordingMetadataStore.load(from: dir)
        XCTAssertNil(decoded.previewSpeechEngine)
        XCTAssertEqual(decoded.speechEngine, SpeechEngineSelection(engine: .whisper, language: "ja"))
    }

    func testMeetingRecordingMetadataWithMalformedStartContextStillLoads() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try saveAlignmentMetadata(in: dir)

        let url = MeetingRecordingMetadataStore.metadataURL(for: dir)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any])
        json["startContext"] = [
            "triggerKind": "future_trigger",
            "sourceMode": "microphone_only",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)

        let metadata = try MeetingRecordingMetadataStore.load(from: dir)
        XCTAssertNil(metadata.startContext, "malformed startContext must not block metadata load")
        XCTAssertEqual(metadata.speechEngine.engine, .parakeet)

        let archived = try MeetingRecordingOutput.loadArchived(
            displayName: "Recovered Meeting",
            mixedAudioURL: dir.appendingPathComponent("meeting-playback.m4a"),
            durationSeconds: 12
        )
        XCTAssertNil(archived.startContext)
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

    func testUpdateEchoSuppressionPreservesInjectedFileManagerDataWhenCreateFails() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalData = try legacyMetadataDataWithoutSpeechEngine()
        let virtualFileManager = RecordingMetadataFileManager(
            data: originalData,
            shouldCreateFileSucceed: false
        )

        XCTAssertThrowsError(try MeetingRecordingMetadataStore.updateEchoSuppression(
            MeetingEchoSuppressionMetadata(reasonCode: .cleanedUsed),
            folderURL: dir,
            fileManager: virtualFileManager
        ))

        XCTAssertEqual(virtualFileManager.data, originalData)
        XCTAssertTrue(virtualFileManager.removedPaths.isEmpty)
    }

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Metadata with nil source tracks so `loadArchived` does not require the
    /// raw `microphone-raw.m4a`/`system-raw.m4a` files — keeping these tests focused on
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
            mixedAudioURL: folderURL.appendingPathComponent("meeting-playback.m4a"),
            microphoneAudioURL: microphoneAudioURL,
            systemAudioURL: folderURL.appendingPathComponent("system-raw.m4a"),
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
    private(set) var removedPaths: [String] = []
    private let shouldCreateFileSucceed: Bool

    init(data: Data, shouldCreateFileSucceed: Bool = true) {
        self.data = data
        self.shouldCreateFileSucceed = shouldCreateFileSucceed
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        data != nil
    }

    override func contents(atPath path: String) -> Data? {
        data
    }

    override func removeItem(at URL: URL) throws {
        removedPaths.append(URL.path)
        data = nil
    }

    override func createFile(
        atPath path: String,
        contents data: Data?,
        attributes attr: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        createdPaths.append(path)
        guard shouldCreateFileSucceed else { return false }
        self.data = data
        return true
    }
}
