import ArgumentParser
import XCTest
import MacParakeetCore
@testable import CLI

final class AskCommandTests: XCTestCase {
    func testAskConversationLifecycleAndExplicitRevisionsThroughCLI() async throws {
        try XCTSkipUnless(
            AppFeatures.isAskWorkspaceAvailable(arguments: [AppFeatures.askWorkspaceDeveloperLaunchArgument]),
            "Ask workspace requires a developer build.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.sqlite").path
        let db = try DatabaseManager(path: path)
        let source = Transcription(
            fileName: "Launch review", rawTranscript: "Launch in June.", status: .completed, sourceType: .meeting)
        try TranscriptionRepository(dbQueue: db.dbQueue).save(source)
        let created = try await run(["new", "--source", source.id.uuidString, "--database", path])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let chat = try decoder.decode(AskConversation.self, from: Data(created.utf8))
        XCTAssertEqual(chat.activeSection?.sourceIDs, [source.id])
        XCTAssertEqual(chat.revision, 0)

        let draftOutput = try await run([
            "draft", chat.id.uuidString, "What changed?", "--revision", "0", "--database", path,
        ])
        let draft = try decoder.decode(AskConversation.self, from: Data(draftOutput.utf8))
        XCTAssertEqual(draft.draft, "What changed?")
        XCTAssertEqual(draft.revision, 1)
        let selected = try await run(["select", chat.id.uuidString, "--revision", "1", "--database", path])
        let cleared = try decoder.decode(AskConversation.self, from: Data(selected.utf8))
        XCTAssertEqual(cleared.sections.count, 2)
        XCTAssertTrue(cleared.activeSection?.sourceIDs.isEmpty == true)
        XCTAssertEqual(cleared.draft, "What changed?")

        _ = try await run(["delete", chat.id.uuidString, "--database", path])
        XCTAssertNil(try AskConversationRepository(dbQueue: db.dbQueue).fetch(id: chat.id))
        XCTAssertNotNil(try TranscriptionRepository(dbQueue: db.dbQueue).fetch(id: source.id))
    }

    func testSendRequiresRevisionAndExplicitProviderAndRejectsBadPickerLimits() throws {
        XCTAssertThrowsError(try CLI.parseAsRoot(["ask", "send", UUID().uuidString, "--question", "When?"]))
        XCTAssertThrowsError(try CLI.parseAsRoot(["ask", "sources", "--limit", "500"]))
        XCTAssertNoThrow(
            try CLI.parseAsRoot([
                "ask", "send", UUID().uuidString, "--question", "When?", "--revision", "0", "--provider", "ollama",
            ]))
    }

    func testEveryAskCommandRejectsBeforeOpeningDatabaseWithoutDeveloperOptIn() async throws {
        try await assertDisabledCommands(extraArguments: [])
    }

    func testReleaseBuildRejectsDeveloperOptInBeforeOpeningDatabase() async throws {
        #if DEBUG
        throw XCTSkip("Release-only containment check.")
        #else
        try await assertDisabledCommands(extraArguments: ["--enable-ask-workspace"])
        #endif
    }

    private func assertDisabledCommands(extraArguments: [String]) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("must-not-exist.sqlite").path
        let id = UUID().uuidString
        let commands = [
            ["list"], ["new"], ["show", id], ["rename", id, "Title", "--revision", "0"],
            ["delete", id], ["sources"], ["select", id, "--revision", "0"],
            ["draft", id, "Question", "--revision", "0"],
            ["send", id, "--question", "When?", "--revision", "0", "--provider", "ollama"],
            ["evidence", id, "--source-revision", "revision", "--segment", "0"],
        ]
        for arguments in commands {
            var command = try XCTUnwrap(
                try CLI.parseAsRoot(["ask"] + arguments + extraArguments + ["--database", path])
                    as? any AsyncParsableCommand)
            var thrownError: Error?
            let output = try await captureStandardOutput {
                do { try await command.run() } catch { thrownError = error }
            }
            let error = try XCTUnwrap(thrownError, "Command should reject: \(arguments)")
            XCTAssertEqual(CLI.normalizedExitCode(for: error), cliValidationMisuseExitCode)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(object["errorType"] as? String, "validation")
            XCTAssertTrue((object["error"] as? String)?.contains("Ask workspace is disabled") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    private func run(_ arguments: [String]) async throws -> String {
        var command = try XCTUnwrap(
            try CLI.parseAsRoot(["ask"] + arguments + ["--enable-ask-workspace"]) as? any AsyncParsableCommand)
        return try await captureStandardOutput { try await command.run() }
    }
}
