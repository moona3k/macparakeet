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
        let transcription = makeMeeting(notes: "Decision: ship\nOwner: Dana")
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

        let manifest = try jsonObject(at: URL(fileURLWithPath: snapshot.manifestPath))
        XCTAssertEqual(manifest["schema"] as? String, MeetingArtifactStore.schema)
        XCTAssertEqual(manifest["schemaVersion"] as? Int, MeetingArtifactStore.schemaVersion)
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        XCTAssertEqual(files["folderPath"] as? String, folderURL.path)
        XCTAssertEqual(files["mixedAudioPath"] as? String, transcription.filePath)
        XCTAssertEqual(files["microphoneAudioPath"] as? String, folderURL.appendingPathComponent("microphone.m4a").path)
        XCTAssertEqual(files["systemAudioPath"] as? String, folderURL.appendingPathComponent("system.m4a").path)
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

    private func makeMeeting(notes: String?) -> Transcription {
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
            status: .completed,
            sourceType: .meeting,
            userNotes: notes,
            engine: "parakeet",
            engineVariant: "v3"
        )
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
