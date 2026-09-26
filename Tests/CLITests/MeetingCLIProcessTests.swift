import Darwin
import Foundation
import XCTest
@testable import MacParakeetCore

/// Exercises the shipping command entry point and persistence across fresh processes.
/// The audio is a path fixture only: this test never invokes STT or audio playback.
final class MeetingCLIProcessTests: XCTestCase {
    func testMeetingNotesAndExportSurviveSeparateCLIProcesses() throws {
        let executable =
            ProcessInfo.processInfo.environment["MACPARAKEET_CLI_TEST_EXECUTABLE"]
            .map { URL(fileURLWithPath: $0) }
            ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("macparakeet-cli")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "Build macparakeet-cli first or set MACPARAKEET_CLI_TEST_EXECUTABLE to its absolute path."
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-cli-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("meeting-playback.m4a")
        try Data("synthetic path fixture; not playable audio".utf8).write(to: audio)
        let database = root.appendingPathComponent("test.sqlite")
        let transcript = "We approved the local archive design."
        let notes = "Decision: ship the archive.\nOwner: Morgan."
        let meeting = Transcription(
            fileName: "Process roundtrip",
            filePath: audio.path,
            meetingArtifactFolderPath: folder.path,
            rawTranscript: transcript,
            status: .completed,
            sourceType: .meeting
        )
        // Use production migrations and Codable-aware repository writes, never copied SQL.
        do {
            let db = try DatabaseManager(path: database.path)
            try TranscriptionRepository(dbQueue: db.dbQueue).save(meeting)
        }

        func run(_ arguments: [String], expectedStatus: Int32 = 0) throws -> String {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["meetings"] + arguments + ["--database", database.path]
            process.currentDirectoryURL = root
            process.environment = ProcessInfo.processInfo.environment.merging([
                "MACPARAKEET_TELEMETRY": "0",
                "MACPARAKEET_DEBUG_APP_STATE_DIR": root.appendingPathComponent("state").path,
                "MACPARAKEET_DEBUG_SQL": "0",
            ]) { _, isolated in isolated }
            process.standardInput = FileHandle.nullDevice
            // File-backed output cannot fill a pipe while the parent waits for termination.
            let stdoutURL = root.appendingPathComponent("stdout-\(UUID().uuidString)")
            let stderrURL = root.appendingPathComponent("stderr-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer { try? stdout.close(); try? stderr.close() }
            process.standardOutput = stdout
            process.standardError = stderr
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            if exited.wait(timeout: .now() + 30) == .timedOut {
                // Own and reap this child before deleting its database/artifacts.
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                XCTFail("CLI timed out: \(arguments)")
                throw NSError(domain: "MeetingCLIProcessTests.timeout", code: 1)
            }
            let output = try String(contentsOf: stdoutURL, encoding: .utf8)
            let diagnostics = try String(contentsOf: stderrURL, encoding: .utf8)
            XCTAssertEqual(process.terminationReason, .exit, diagnostics)
            XCTAssertEqual(process.terminationStatus, expectedStatus, "\(arguments): \(diagnostics)\n\(output)")
            return output
        }
        func json(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        let id = meeting.id.uuidString
        let shown = try json(run(["show", id, "--json"]))
        XCTAssertEqual(shown["id"] as? String, id)
        XCTAssertEqual(shown["transcript"] as? String, transcript)
        let updated = try json(run(["notes", "set", id, "--text", notes, "--json"]))
        XCTAssertEqual(updated["id"] as? String, id)
        XCTAssertEqual(updated["notes"] as? String, notes)
        let artifact = try XCTUnwrap(updated["artifact"] as? [String: Any])
        XCTAssertEqual(artifact["folderPath"] as? String, folder.path)
        for (key, name) in [
            ("manifestPath", "manifest.json"), ("markdownPath", "meeting.md"),
            ("notesPath", "notes.md"), ("transcriptPath", "transcript.json"),
        ] {
            XCTAssertEqual(artifact[key] as? String, folder.appendingPathComponent(name).path)
        }
        XCTAssertEqual(artifact["playbackAudioPath"] as? String, audio.path)

        // Check materialization before export, so a later read cannot hide a failed notes refresh.
        let markdown = try String(contentsOf: folder.appendingPathComponent("meeting.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains(transcript))
        XCTAssertTrue(markdown.contains(notes))
        let notesFile = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(notesFile.contains(notes))
        let manifest = try json(String(contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8))
        XCTAssertEqual(manifest["schema"] as? String, "com.macparakeet.meeting-session")
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)
        XCTAssertEqual((manifest["meeting"] as? [String: Any])?["id"] as? String, id)
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        for key in ["folderPath", "manifestPath", "markdownPath", "notesPath", "transcriptPath", "playbackAudioPath"] {
            XCTAssertEqual(files[key] as? String, artifact[key] as? String, key)
        }
        let transcriptFile = try json(
            String(contentsOf: folder.appendingPathComponent("transcript.json"), encoding: .utf8))
        XCTAssertEqual(transcriptFile["id"] as? String, id)
        XCTAssertEqual(transcriptFile["transcript"] as? String, transcript)

        let fetchedNotes = try json(run(["notes", "get", id, "--json"]))
        XCTAssertEqual(fetchedNotes["id"] as? String, id)
        XCTAssertEqual(fetchedNotes["notes"] as? String, notes)
        let exported = try run(["export", id, "--format", "md", "--stdout"])
        XCTAssertEqual(exported, markdown)
        do {
            let reopened = try DatabaseManager(path: database.path)
            let persisted = try XCTUnwrap(TranscriptionRepository(dbQueue: reopened.dbQueue).fetch(id: meeting.id))
            XCTAssertEqual(persisted.userNotes, notes)
            XCTAssertEqual(persisted.rawTranscript, transcript)
            XCTAssertEqual(persisted.meetingArtifactFolderPath, folder.path)
            XCTAssertEqual(persisted.filePath, audio.path)
        }
        let missingID = UUID().uuidString
        let missing = try json(run(["show", missingID, "--json"], expectedStatus: 1))
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual(missing["errorType"] as? String, "lookup")
        XCTAssertTrue((missing["error"] as? String)?.contains(missingID) == true)
    }
}
