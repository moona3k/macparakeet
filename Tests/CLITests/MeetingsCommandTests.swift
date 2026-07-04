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

    func testMeetingJSONSurfacesExposeTranscriptSegments() async throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let segmentID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let meeting = Transcription(
            fileName: "Segment Review",
            rawTranscript: "Ship the durable segment contract.",
            wordTimestamps: [
                WordTimestamp(word: "Ship", startMs: 0, endMs: 200, confidence: 0.98, speakerId: "microphone"),
                WordTimestamp(word: "it.", startMs: 220, endMs: 360, confidence: 0.98, speakerId: "microphone"),
            ],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    id: segmentID,
                    startMs: 0,
                    endMs: 360,
                    speakerId: "microphone",
                    speakerLabel: "Me",
                    text: "Ship it.",
                    wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 2)
                ),
            ],
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(meeting)

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
        let showSegments = try XCTUnwrap(showPayload["transcriptSegments"] as? [[String: Any]])
        assertSegmentPayload(showSegments.first, id: segmentID)

        let transcriptCommand = try MeetingsCommand.TranscriptSubcommand.parse([
            meeting.id.uuidString,
            "--format", "json",
            "--database", dbURL.path,
        ])
        let transcriptOutput = try await captureStandardOutput {
            try await transcriptCommand.run()
        }
        let transcriptPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(transcriptOutput.utf8)) as? [String: Any]
        )
        let transcriptSegments = try XCTUnwrap(transcriptPayload["transcriptSegments"] as? [[String: Any]])
        assertSegmentPayload(transcriptSegments.first, id: segmentID)
    }

    func testShowJSONIncludesMeetingStartContext() async throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let startContext = MeetingStartContext(
            triggerKind: .calendarAutoStart,
            frontmostApplication: .init(
                bundleIdentifier: "COM.Google.Chrome",
                localizedName: "Google Chrome"
            ),
            sourceMode: .microphoneAndSystem
        )
        let meeting = Transcription(
            fileName: "Customer Sync",
            rawTranscript: "We discussed onboarding.",
            status: .completed,
            sourceType: .meeting,
            meetingStartContext: startContext
        )
        try transcriptionRepo.save(meeting)

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
        let context = try XCTUnwrap(showPayload["startContext"] as? [String: Any])
        XCTAssertEqual(context["triggerKind"] as? String, "calendar_auto_start")
        XCTAssertEqual(context["sourceMode"] as? String, "microphone_and_system")
        let app = try XCTUnwrap(context["frontmostApplication"] as? [String: Any])
        XCTAssertEqual(app["bundleIdentifier"] as? String, "com.google.chrome")
        XCTAssertEqual(app["localizedName"] as? String, "Google Chrome")
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
        XCTAssertEqual(snapshot["schema"] as? String, MeetingArtifactStore.schema)
        XCTAssertEqual(snapshot["schemaVersion"] as? Int, MeetingArtifactStore.schemaVersion)
        XCTAssertEqual(snapshot["folderPath"] as? String, folderURL.path)
        XCTAssertEqual(snapshot["manifestPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName).path)
        XCTAssertEqual(snapshot["transcriptPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.transcriptFileName).path)
        XCTAssertEqual(snapshot["notesPath"] as? String, MeetingNotesFile.fileURL(for: folderURL).path)
        XCTAssertEqual(snapshot["promptResultsPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.promptResultsFileName).path)
        XCTAssertEqual(snapshot["promptResultsDirectoryPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.promptResultsDirectoryName).path)
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
        XCTAssertEqual(data["schema"] as? String, MeetingArtifactStore.schema)
        XCTAssertEqual(data["schemaVersion"] as? Int, MeetingArtifactStore.schemaVersion)
        XCTAssertEqual(data["folderPath"] as? String, folderURL.path)
        XCTAssertEqual(data["manifestPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName).path)
        XCTAssertEqual(data["transcriptPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.transcriptFileName).path)
        XCTAssertEqual(data["promptResultsPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.promptResultsFileName).path)
        XCTAssertEqual(data["promptResultsDirectoryPath"] as? String, folderURL.appendingPathComponent(MeetingArtifactStore.promptResultsDirectoryName).path)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
        XCTAssertEqual(meta["schemaVersion"] as? Int, 1)
    }

    func testMeetingJSONSurfacesArtifactFolderAfterAudioIsGone() async throws {
        let dbURL = temporaryDatabaseURL()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-meeting-no-audio-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: folderURL)
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let expectedFolderPath = folderURL.standardizedFileURL.path

        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let meeting = Transcription(
            fileName: "Retained Out Review",
            meetingArtifactFolderPath: folderURL.path,
            rawTranscript: "Audio is gone but artifacts remain.",
            status: .completed,
            sourceType: .meeting,
            userNotes: "Keep artifact folder visible."
        )
        try transcriptionRepo.save(meeting)

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
        XCTAssertEqual(listItem["artifactFolderPath"] as? String, expectedFolderPath)
        XCTAssertEqual(listItem["hasArtifactManifest"] as? Bool, false)

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
        XCTAssertNil(showPayload["filePath"] as? String)
        XCTAssertEqual(showPayload["artifactFolderPath"] as? String, expectedFolderPath)
        XCTAssertEqual(
            showPayload["artifactManifestPath"] as? String,
            folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName).standardizedFileURL.path
        )

        let artifactCommand = try MeetingsCommand.ArtifactSubcommand.parse([
            meeting.id.uuidString,
            "--json",
            "--database", dbURL.path,
        ])
        let artifactOutput = try await captureStandardOutput {
            try await artifactCommand.run()
        }
        let artifactPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(artifactOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(artifactPayload["folderPath"] as? String, expectedFolderPath)
        XCTAssertEqual(artifactPayload["notesPath"] as? String, MeetingNotesFile.fileURL(for: folderURL).standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(MeetingArtifactStore.manifestFileName).path
        ))
    }

    func testShowJSONIncludesCalendarEventSnapshot() async throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let scheduledStart = Date(timeIntervalSince1970: 1_720_000_000)
        let scheduledEnd = Date(timeIntervalSince1970: 1_720_003_600)
        let calendarSnapshot = MeetingCalendarSnapshot(
            confidence: .confirmed,
            eventIdentifier: "evt-cli",
            externalId: "external-cli",
            title: "CLI Contract Review",
            scheduledStartAt: scheduledStart,
            scheduledEndAt: scheduledEnd,
            attendees: [
                MeetingCalendarPerson(name: "Alice Example", email: "alice@example.com"),
            ],
            organizer: MeetingCalendarPerson(name: "Omar Organizer", email: "omar@example.com"),
            meetingURL: "https://meet.google.com/abc-defg-hij",
            meetingService: "Google Meet",
            capturedAt: Date(timeIntervalSince1970: 1_720_000_010)
        )
        let db = try DatabaseManager(path: dbURL.path)
        let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
        let meeting = Transcription(
            fileName: "CLI Contract Review",
            rawTranscript: "Calendar context is local-only.",
            status: .completed,
            sourceType: .meeting,
            calendarEventSnapshot: calendarSnapshot
        )
        try transcriptionRepo.save(meeting)

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
        let snapshot = try XCTUnwrap(showPayload["calendarEventSnapshot"] as? [String: Any])

        XCTAssertEqual(snapshot["confidence"] as? String, "confirmed")
        XCTAssertEqual(snapshot["eventIdentifier"] as? String, "evt-cli")
        XCTAssertEqual(snapshot["externalId"] as? String, "external-cli")
        XCTAssertEqual(snapshot["title"] as? String, "CLI Contract Review")
        let dateFormatter = ISO8601DateFormatter()
        XCTAssertEqual(snapshot["scheduledStartAt"] as? String, dateFormatter.string(from: scheduledStart))
        XCTAssertEqual(snapshot["scheduledEndAt"] as? String, dateFormatter.string(from: scheduledEnd))
        XCTAssertEqual(snapshot["meetingURL"] as? String, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(snapshot["meetingService"] as? String, "Google Meet")
        let attendees = try XCTUnwrap(snapshot["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.first?["name"] as? String, "Alice Example")
        XCTAssertEqual(attendees.first?["email"] as? String, "alice@example.com")
        let organizer = try XCTUnwrap(snapshot["organizer"] as? [String: Any])
        XCTAssertEqual(organizer["name"] as? String, "Omar Organizer")
        XCTAssertEqual(organizer["email"] as? String, "omar@example.com")
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

    private func assertSegmentPayload(
        _ payload: [String: Any]?,
        id: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let payload else {
            return XCTFail("Expected segment payload", file: file, line: line)
        }
        XCTAssertEqual(payload["id"] as? String, id.uuidString, file: file, line: line)
        XCTAssertEqual(payload["startMs"] as? Int, 0, file: file, line: line)
        XCTAssertEqual(payload["endMs"] as? Int, 360, file: file, line: line)
        XCTAssertEqual(payload["speakerId"] as? String, "microphone", file: file, line: line)
        XCTAssertEqual(payload["speakerLabel"] as? String, "Me", file: file, line: line)
        XCTAssertEqual(payload["text"] as? String, "Ship it.", file: file, line: line)
        guard let wordRange = payload["wordRange"] as? [String: Any] else {
            return XCTFail("Expected wordRange", file: file, line: line)
        }
        XCTAssertEqual(wordRange["startIndex"] as? Int, 0, file: file, line: line)
        XCTAssertEqual(wordRange["endIndexExclusive"] as? Int, 2, file: file, line: line)
    }
}
