import AVFoundation
import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingArtifactStoreTests: XCTestCase {
    private var folderURL: URL!

    override func setUpWithError() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingArtifactStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folderURL.appendingPathComponent("meeting.m4a"))
        try Data("mic".utf8).write(to: folderURL.appendingPathComponent("microphone.m4a"))
        try Data("system".utf8).write(to: folderURL.appendingPathComponent("system.m4a"))
        try Data("{}".utf8).write(to: MeetingRecordingMetadataStore.metadataURL(for: folderURL))
    }

    override func tearDownWithError() throws {
        if let folderURL {
            try? FileManager.default.removeItem(at: folderURL)
        }
        folderURL = nil
    }

    func testMaterializeWritesFirstClassMeetingArtifactFiles() async throws {
        let startContext = MeetingStartContext(
            triggerKind: .manual,
            frontmostApplication: .init(
                bundleIdentifier: "com.apple.MobileSMS",
                localizedName: "Messages"
            ),
            sourceMode: .microphoneOnly
        )
        let transcription = makeMeeting(
            notes: "Decision: ship\nOwner: Dana",
            startContext: startContext
        )
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Executive Summary",
            promptContent: "Summarize the meeting.",
            extraInstructions: "External agent",
            content: "Ship the artifact contract.",
            userNotesSnapshot: transcription.userNotes
        )

        let snapshot = try await MeetingArtifactStore().materialize(
            transcription: transcription,
            promptResults: [result]
        )

        XCTAssertEqual(snapshot.meetingID, transcription.id)
        XCTAssertEqual(snapshot.schema, MeetingArtifactStore.schema)
        XCTAssertEqual(snapshot.schemaVersion, MeetingArtifactStore.schemaVersion)
        XCTAssertEqual(snapshot.folderPath, folderURL.path)
        XCTAssertEqual(snapshot.manifestPath, folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName).path)
        XCTAssertEqual(snapshot.transcriptPath, folderURL.appendingPathComponent(MeetingArtifactStore.transcriptFileName).path)
        XCTAssertEqual(snapshot.notesPath, MeetingNotesFile.fileURL(for: folderURL).path)
        XCTAssertEqual(snapshot.promptResultsPath, folderURL.appendingPathComponent(MeetingArtifactStore.promptResultsFileName).path)
        XCTAssertEqual(snapshot.promptResultsDirectoryPath, folderURL.appendingPathComponent(MeetingArtifactStore.promptResultsDirectoryName).path)
        XCTAssertEqual(snapshot.promptResultCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.manifestPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.transcriptPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.promptResultsPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.promptResultsDirectoryPath))
        let folderEntries = Set(try FileManager.default.contentsOfDirectory(atPath: folderURL.path))
        XCTAssertTrue(folderEntries.isSuperset(of: [
            "meeting.m4a",
            "microphone.m4a",
            "system.m4a",
            MeetingRecordingMetadataStore.metadataURL(for: folderURL).lastPathComponent,
            MeetingArtifactStore.manifestFileName,
            MeetingArtifactStore.transcriptFileName,
            MeetingNotesFile.fileURL(for: folderURL).lastPathComponent,
            MeetingArtifactStore.promptResultsFileName,
            MeetingArtifactStore.promptResultsDirectoryName,
        ]))

        let notes = try String(contentsOf: MeetingNotesFile.fileURL(for: folderURL), encoding: .utf8)
        XCTAssertEqual(notes, "# Design Review\n\nDecision: ship\nOwner: Dana\n")

        let transcript = try jsonObject(at: URL(fileURLWithPath: snapshot.transcriptPath))
        XCTAssertEqual(transcript["id"] as? String, transcription.id.uuidString)
        XCTAssertEqual(transcript["title"] as? String, "Design Review")
        XCTAssertEqual(transcript["transcript"] as? String, "Clean transcript.")
        XCTAssertEqual(transcript["sourceType"] as? String, "meeting")
        XCTAssertEqual(transcript["userNotes"] as? String, "Decision: ship\nOwner: Dana")
        let transcriptSegments = try XCTUnwrap(transcript["transcriptSegments"] as? [[String: Any]])
        XCTAssertEqual(transcriptSegments.count, 1)
        XCTAssertEqual(
            transcriptSegments.first?["id"] as? String,
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!.uuidString
        )
        XCTAssertEqual(transcriptSegments.first?["speakerLabel"] as? String, "Speaker 1")
        XCTAssertEqual(transcriptSegments.first?["text"] as? String, "Clean")
        let wordRange = try XCTUnwrap(transcriptSegments.first?["wordRange"] as? [String: Any])
        XCTAssertEqual(wordRange["startIndex"] as? Int, 0)
        XCTAssertEqual(wordRange["endIndexExclusive"] as? Int, 1)
        assertStartContext(transcript["startContext"], equals: startContext)

        let manifest = try jsonObject(at: URL(fileURLWithPath: snapshot.manifestPath))
        XCTAssertEqual(manifest["schema"] as? String, MeetingArtifactStore.schema)
        XCTAssertEqual(manifest["schemaVersion"] as? Int, MeetingArtifactStore.schemaVersion)
        let manifestMeeting = try XCTUnwrap(manifest["meeting"] as? [String: Any])
        assertStartContext(manifestMeeting["startContext"], equals: startContext)
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        XCTAssertEqual(files["folderPath"] as? String, folderURL.path)
        XCTAssertEqual(files["mixedAudioPath"] as? String, transcription.filePath)
        XCTAssertEqual(files["microphoneAudioPath"] as? String, folderURL.appendingPathComponent("microphone.m4a").path)
        XCTAssertEqual(files["systemAudioPath"] as? String, folderURL.appendingPathComponent("system.m4a").path)
        XCTAssertNil(files["cleanedMicrophoneAudioPath"] as? String)
        XCTAssertEqual(files["metadataPath"] as? String, MeetingRecordingMetadataStore.metadataURL(for: folderURL).path)
        XCTAssertEqual(files["manifestPath"] as? String, snapshot.manifestPath)
        XCTAssertEqual(files["transcriptPath"] as? String, snapshot.transcriptPath)
        XCTAssertEqual(files["notesPath"] as? String, MeetingNotesFile.fileURL(for: folderURL).path)
        XCTAssertEqual(files["promptResultsPath"] as? String, snapshot.promptResultsPath)
        XCTAssertEqual(files["promptResultsDirectoryPath"] as? String, snapshot.promptResultsDirectoryPath)

        let promptResults = try jsonArray(at: URL(fileURLWithPath: snapshot.promptResultsPath))
        let promptResult = try XCTUnwrap(promptResults.first)
        XCTAssertEqual(promptResults.count, 1)
        XCTAssertEqual(promptResult["index"] as? Int, 1)
        XCTAssertEqual(promptResult["name"] as? String, "Executive Summary")

        let resultFiles = try XCTUnwrap(manifest["promptResults"] as? [[String: Any]])
        XCTAssertEqual(resultFiles.count, 1)
        let resultMarkdownPath = try XCTUnwrap(resultFiles.first?["path"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: resultMarkdownPath).lastPathComponent, "01-Executive Summary.md")
        let resultMarkdown = try String(contentsOfFile: resultMarkdownPath, encoding: .utf8)
        XCTAssertTrue(resultMarkdown.contains("# Executive Summary"))
        XCTAssertTrue(resultMarkdown.contains("Ship the artifact contract."))
    }

    func testMaterializeIncludesCleanedMicrophoneAudioPathWhenArtifactExists() async throws {
        let cleanedURL = folderURL.appendingPathComponent("microphone-cleaned.m4a")
        try writeM4A(to: cleanedURL)
        let transcription = makeMeeting(notes: nil)

        let snapshot = try await MeetingArtifactStore().materialize(
            transcription: transcription,
            promptResults: []
        )

        let manifest = try jsonObject(at: URL(fileURLWithPath: snapshot.manifestPath))
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        XCTAssertEqual(files["cleanedMicrophoneAudioPath"] as? String, cleanedURL.path)
    }

    func testMaterializeOmitsInvalidCleanedMicrophoneAudioPath() async throws {
        let cleanedURL = folderURL.appendingPathComponent("microphone-cleaned.m4a")
        try Data("partial m4a fragment".utf8).write(to: cleanedURL)
        let transcription = makeMeeting(notes: nil)

        let snapshot = try await MeetingArtifactStore().materialize(
            transcription: transcription,
            promptResults: []
        )

        let manifest = try jsonObject(at: URL(fileURLWithPath: snapshot.manifestPath))
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        XCTAssertNil(files["cleanedMicrophoneAudioPath"] as? String)
    }

    func testMaterializeRemovesStaleNotesAndPromptResultFiles() async throws {
        let initial = makeMeeting(notes: "Old note")
        _ = try await MeetingArtifactStore().materialize(
            transcription: initial,
            promptResults: [
                PromptResult(
                    transcriptionId: initial.id,
                    promptName: "Old Result",
                    promptContent: "Prompt",
                    content: "Content"
                ),
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: MeetingNotesFile.fileURL(for: folderURL).path))
        let staleMarkdownURL = folderURL
            .appendingPathComponent(MeetingArtifactStore.promptResultsDirectoryName)
            .appendingPathComponent("01-Old Result.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleMarkdownURL.path))

        var updated = initial
        updated.userNotes = nil
        let snapshot = try await MeetingArtifactStore().materialize(
            transcription: updated,
            promptResults: []
        )

        XCTAssertNil(snapshot.notesPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MeetingNotesFile.fileURL(for: folderURL).path))
        let promptResults = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: snapshot.promptResultsPath))
        ) as? [[String: Any]]
        XCTAssertEqual(promptResults?.count, 0)

        let resultFiles = try FileManager.default.contentsOfDirectory(
            atPath: snapshot.promptResultsDirectoryPath
        )
        XCTAssertTrue(resultFiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleMarkdownURL.path))
    }

    func testMaterializeUsesDurableArtifactFolderWhenAudioPathIsCleared() async throws {
        var transcription = makeMeeting(notes: "Audio retained out")
        transcription.filePath = nil
        transcription.meetingArtifactFolderPath = folderURL.path

        let snapshot = try await MeetingArtifactStore().materialize(
            transcription: transcription,
            promptResults: []
        )

        XCTAssertEqual(snapshot.folderPath, folderURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.manifestPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.transcriptPath))

        let manifest = try jsonObject(at: URL(fileURLWithPath: snapshot.manifestPath))
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        XCTAssertEqual(files["folderPath"] as? String, folderURL.path)
        XCTAssertNil(files["mixedAudioPath"] as? String)
    }

    func testMaterializeRejectsNonMeetingRows() async throws {
        let transcription = Transcription(
            fileName: "File",
            filePath: folderURL.appendingPathComponent("meeting.m4a").path,
            sourceType: .file
        )

        do {
            _ = try await MeetingArtifactStore().materialize(
                transcription: transcription,
                promptResults: []
            )
            XCTFail("Expected non-meeting materialization to fail.")
        } catch MeetingArtifactError.notMeeting {
            // Expected.
        }
    }

    private func makeMeeting(
        notes: String?,
        startContext: MeetingStartContext? = nil
    ) -> Transcription {
        Transcription(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            fileName: "Design Review",
            filePath: folderURL.appendingPathComponent("meeting.m4a").path,
            durationMs: 12_000,
            rawTranscript: "Raw transcript.",
            cleanTranscript: "Clean transcript.",
            wordTimestamps: [
                WordTimestamp(word: "Clean", startMs: 0, endMs: 400, confidence: 0.98, speakerId: "S1"),
            ],
            language: "en",
            speakerCount: 1,
            speakers: [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
            ],
            diarizationSegments: [
                DiarizationSegmentRecord(speakerId: "S1", startMs: 0, endMs: 1000),
            ],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                    startMs: 0,
                    endMs: 400,
                    speakerId: "S1",
                    speakerLabel: "Speaker 1",
                    text: "Clean",
                    wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)
                ),
            ],
            status: .completed,
            sourceType: .meeting,
            userNotes: notes,
            meetingStartContext: startContext,
            engine: "parakeet",
            engineVariant: "v3"
        )
    }

    private func assertStartContext(
        _ value: Any?,
        equals expected: MeetingStartContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let context = value as? [String: Any] else {
            return XCTFail("Expected startContext object.", file: file, line: line)
        }
        XCTAssertEqual(context["triggerKind"] as? String, expected.triggerKind.rawValue, file: file, line: line)
        XCTAssertEqual(context["sourceMode"] as? String, expected.sourceMode.rawValue, file: file, line: line)
        guard let app = context["frontmostApplication"] as? [String: Any] else {
            return XCTFail("Expected frontmostApplication object.", file: file, line: line)
        }
        XCTAssertEqual(
            app["bundleIdentifier"] as? String,
            expected.frontmostApplication?.bundleIdentifier,
            file: file,
            line: line
        )
        XCTAssertEqual(
            app["localizedName"] as? String,
            expected.frontmostApplication?.localizedName,
            file: file,
            line: line
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

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func jsonArray(at url: URL) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        )
    }
}
