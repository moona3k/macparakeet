import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class MeetingsCommandTests: XCTestCase {
    func testMeetingsCommandIsRegisteredAtTopLevel() {
        XCTAssertTrue(
            CLI.configuration.subcommands.contains { $0 == MeetingsCommand.self },
            "meetings must be available from macparakeet-cli"
        )
    }

    func testExecutableSubcommandsParse() throws {
        XCTAssertNoThrow(try MeetingsCommand.ListSubcommand.parse(["--json"]))
        XCTAssertNoThrow(try MeetingsCommand.ShowSubcommand.parse(["abcd", "--json"]))
        XCTAssertNoThrow(try MeetingsCommand.TranscriptSubcommand.parse(["abcd", "--format", "srt"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.GetSubcommand.parse(["abcd", "--envelope"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--text", "Decision: ship", "--envelope"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--text", "Decision: ship"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.ClearSubcommand.parse(["abcd", "--envelope"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.ClearSubcommand.parse(["abcd", "--json"]))
        XCTAssertNoThrow(try MeetingsCommand.ResultsSubcommand.ListSubcommand.parse(["abcd", "--json"]))
        XCTAssertNoThrow(try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse(["abcd", "--name", "Agent Notes", "--content", "Decision: ship", "--json"]))
        XCTAssertNoThrow(try MeetingsCommand.ArtifactSubcommand.parse(["abcd", "--json"]))
        XCTAssertNoThrow(try MeetingsCommand.ArtifactSubcommand.parse(["abcd", "--envelope"]))
        XCTAssertNoThrow(try MeetingsCommand.ExportSubcommand.parse(["abcd", "--format", "md", "--stdout"]))
    }

    func testListRejectsNegativeLimit() {
        XCTAssertThrowsError(try MeetingsCommand.ListSubcommand.parse(["--limit", "-1"]))
    }

    func testJSONAndEnvelopeFlagsAreMutuallyExclusive() {
        assertRejectsJSONEnvelope {
            try MeetingsCommand.ListSubcommand.parse(["--json", "--envelope"])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.ShowSubcommand.parse(["abcd", "--json", "--envelope"])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.NotesSubcommand.GetSubcommand.parse(["abcd", "--json", "--envelope"])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--text", "note", "--json", "--envelope"])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--text", "note", "--json", "--envelope"])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.NotesSubcommand.ClearSubcommand.parse(["abcd", "--json", "--envelope"])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.ResultsSubcommand.ListSubcommand.parse(["abcd", "--json", "--envelope"])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse([
                "abcd", "--name", "Agent Notes", "--content", "Decision: ship", "--json", "--envelope",
            ])
        }
        assertRejectsJSONEnvelope {
            try MeetingsCommand.ArtifactSubcommand.parse(["abcd", "--json", "--envelope"])
        }
    }

    func testNotesSetRequiresOneInputSource() {
        XCTAssertThrowsError(try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd"]))
        XCTAssertThrowsError(
            try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--text", "note", "--stdin"])
        )
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--text", "note"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.SetSubcommand.parse(["abcd", "--stdin"]))
    }

    func testNotesAppendRequiresOneInputSource() {
        XCTAssertThrowsError(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd"]))
        XCTAssertThrowsError(
            try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--text", "note", "--stdin"])
        )
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--text", "note"]))
        XCTAssertNoThrow(try MeetingsCommand.NotesSubcommand.AppendSubcommand.parse(["abcd", "--stdin"]))
    }

    func testResultsAddRequiresNameAndOneInputSource() {
        XCTAssertThrowsError(try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse(["abcd", "--name", "Result"]))
        XCTAssertThrowsError(
            try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse([
                "abcd", "--name", "Result", "--content", "body", "--stdin"
            ])
        )
        XCTAssertThrowsError(
            try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse([
                "abcd", "--name", "   ", "--content", "body"
            ])
        )
        XCTAssertNoThrow(
            try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse([
                "abcd", "--name", "Result", "--content", "body"
            ])
        )
        XCTAssertNoThrow(
            try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse([
                "abcd", "--name", "Result", "--stdin"
            ])
        )
    }

    func testResultsAddStoresPromptResultForMeeting() async throws {
        let dbURL = temporaryDatabaseURL()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-result-artifact-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: folderURL)
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folderURL.appendingPathComponent("meeting.m4a"))
        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let resultRepo = PromptResultRepository(dbQueue: db.dbQueue)
        let meeting = Transcription(
            fileName: "Design Review",
            filePath: folderURL.appendingPathComponent("meeting.m4a").path,
            rawTranscript: "We agreed to ship the parser.",
            status: .completed,
            sourceType: .meeting,
            userNotes: "Manual note"
        )
        try transcriptionRepo.save(meeting)

        let command = try MeetingsCommand.ResultsSubcommand.AddSubcommand.parse([
            meeting.id.uuidString,
            "--name", "Agent Notes",
            "--content", "Decision: ship the parser.",
            "--prompt-content", "Extract decisions.",
            "--extra", "Generated by external agent.",
            "--json",
            "--database", dbURL.path,
        ])
        let output = try await captureStandardOutput {
            try await command.run()
        }
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["meetingTitle"] as? String, "Design Review")
        XCTAssertEqual(payload["name"] as? String, "Agent Notes")
        XCTAssertEqual(payload["content"] as? String, "Decision: ship the parser.")
        XCTAssertEqual(payload["userNotesSnapshot"] as? String, "Manual note")
        let artifact = try XCTUnwrap(payload["artifact"] as? [String: Any])
        XCTAssertEqual(artifact["folderPath"] as? String, folderURL.path)

        let saved = try resultRepo.fetchAll(transcriptionId: meeting.id)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].promptName, "Agent Notes")
        XCTAssertEqual(saved[0].promptContent, "Extract decisions.")
        XCTAssertEqual(saved[0].extraInstructions, "Generated by external agent.")
        XCTAssertEqual(saved[0].content, "Decision: ship the parser.")
        XCTAssertEqual(saved[0].userNotesSnapshot, "Manual note")
    }

    func testMeetingSurfacesExposePromptResultAvailability() async throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let resultRepo = PromptResultRepository(dbQueue: db.dbQueue)
        let meeting = Transcription(
            fileName: "Agent Review",
            rawTranscript: "We agreed to keep the CLI contract explicit.",
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(meeting)
        try resultRepo.save(PromptResult(
            transcriptionId: meeting.id,
            promptName: "Executive Summary",
            promptContent: "Summarize the meeting.",
            content: "Keep the CLI contract explicit."
        ))

        let listCommand = try MeetingsCommand.ListSubcommand.parse([
            "--json",
            "--database", dbURL.path,
        ])
        let listOutput = try await captureStandardOutput {
            try await listCommand.run()
        }
        let listPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listOutput.utf8)) as? [[String: Any]]
        )
        let listItem = try XCTUnwrap(listPayload.first)
        XCTAssertEqual(listItem["hasPromptResults"] as? Bool, true)
        XCTAssertEqual(listItem["promptResultCount"] as? Int, 1)

        let showCommand = try MeetingsCommand.ShowSubcommand.parse([
            meeting.id.uuidString,
            "--json",
            "--database", dbURL.path,
        ])
        let showOutput = try await captureStandardOutput {
            try await showCommand.run()
        }
        let showPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(showOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(showPayload["hasPromptResults"] as? Bool, true)
        XCTAssertEqual(showPayload["promptResultCount"] as? Int, 1)

        let exportCommand = try MeetingsCommand.ExportSubcommand.parse([
            meeting.id.uuidString,
            "--format", "json",
            "--stdout",
            "--database", dbURL.path,
        ])
        let exportOutput = try await captureStandardOutput {
            try await exportCommand.run()
        }
        let exportPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(exportOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(exportPayload["hasPromptResults"] as? Bool, true)
        XCTAssertEqual(exportPayload["promptResultCount"] as? Int, 1)

        let markdownExportCommand = try MeetingsCommand.ExportSubcommand.parse([
            meeting.id.uuidString,
            "--format", "md",
            "--stdout",
            "--database", dbURL.path,
        ])
        let markdownExportOutput = try await captureStandardOutput {
            try await markdownExportCommand.run()
        }
        XCTAssertTrue(markdownExportOutput.contains("- Prompt results: 1"))
    }

    func testArtifactSubcommandMaterializesMeetingFolder() async throws {
        let dbURL = temporaryDatabaseURL()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-meeting-artifact-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: folderURL)
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folderURL.appendingPathComponent("meeting.m4a"))

        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let resultRepo = PromptResultRepository(dbQueue: db.dbQueue)
        let meeting = Transcription(
            fileName: "Artifact Review",
            filePath: folderURL.appendingPathComponent("meeting.m4a").path,
            rawTranscript: "We agreed to make meeting folders first-class.",
            cleanTranscript: "Meeting folders are first-class.",
            status: .completed,
            sourceType: .meeting,
            userNotes: "Use the folder as the contract."
        )
        try transcriptionRepo.save(meeting)
        try resultRepo.save(PromptResult(
            transcriptionId: meeting.id,
            promptName: "Agent Summary",
            promptContent: "Summarize.",
            content: "Meeting folders become the artifact contract."
        ))

        let command = try MeetingsCommand.ArtifactSubcommand.parse([
            meeting.id.uuidString,
            "--json",
            "--database", dbURL.path,
        ])
        let output = try await captureStandardOutput {
            try await command.run()
        }
        let snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )

        XCTAssertEqual(snapshot["meetingID"] as? String, meeting.id.uuidString)
        XCTAssertEqual(snapshot["folderPath"] as? String, folderURL.path)
        XCTAssertEqual(snapshot["promptResultCount"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(MeetingArtifactStore.transcriptFileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MeetingNotesFile.fileURL(for: folderURL).path
        ))
    }

    func testArtifactSubcommandSupportsSuccessEnvelope() async throws {
        let dbURL = temporaryDatabaseURL()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-meeting-envelope-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: folderURL)
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folderURL.appendingPathComponent("meeting.m4a"))

        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let meeting = Transcription(
            fileName: "Envelope Review",
            filePath: folderURL.appendingPathComponent("meeting.m4a").path,
            rawTranscript: "Envelope mode stays opt in.",
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(meeting)

        let command = try MeetingsCommand.ArtifactSubcommand.parse([
            meeting.id.uuidString,
            "--envelope",
            "--database", dbURL.path,
        ])
        let output = try await captureStandardOutput {
            try await command.run()
        }
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )

        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(envelope["command"] as? String, "meetings artifact")
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["meetingID"] as? String, meeting.id.uuidString)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
        XCTAssertEqual(meta["schemaVersion"] as? Int, 1)
    }

    func testFormatRawValues() {
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "text"), .text)
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "json"), .json)
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "srt"), .srt)
        XCTAssertEqual(MeetingTranscriptFormat(rawValue: "vtt"), .vtt)
        XCTAssertEqual(MeetingExportFormat(rawValue: "md"), .md)
        XCTAssertEqual(MeetingExportFormat(rawValue: "json"), .json)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-meetings-\(UUID().uuidString).db")
    }

    private func assertRejectsJSONEnvelope(
        _ parse: () throws -> any ParsableCommand,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(), file: file, line: line) { error in
            XCTAssertTrue(
                String(describing: error).contains("--json") && String(describing: error).contains("--envelope"),
                "Expected error to mention --json and --envelope, got: \(error)",
                file: file,
                line: line
            )
        }
    }
}
