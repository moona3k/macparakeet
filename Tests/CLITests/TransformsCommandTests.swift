import ArgumentParser
import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class TransformsCommandTests: XCTestCase {

    // MARK: - Command parsing

    func testParsesListAsDefaultSubcommand() throws {
        // `macparakeet-cli transforms` (no subcommand) → ListSubcommand.
        let cmd = try TransformsCommand.parseAsRoot([])
        XCTAssertTrue(cmd is TransformsCommand.ListSubcommand,
                      "Bare `transforms` should default to ListSubcommand.")
    }

    func testParsesListWithJSON() throws {
        let cmd = try TransformsCommand.parseAsRoot(["list", "--json"])
        let list = try XCTUnwrap(cmd as? TransformsCommand.ListSubcommand)
        XCTAssertTrue(list.json)
    }

    func testParsesShowWithIdArgument() throws {
        let cmd = try TransformsCommand.parseAsRoot(["show", "Polish"])
        let show = try XCTUnwrap(cmd as? TransformsCommand.ShowSubcommand)
        XCTAssertEqual(show.idOrName, "Polish")
        XCTAssertFalse(show.json)
    }

    func testParsesRunWithFileInput() throws {
        let cmd = try TransformsCommand.parseAsRoot([
            "run", "Polish",
            "--provider", "anthropic", "--api-key", "test",
            "--input", "/tmp/in.txt",
        ])
        let run = try XCTUnwrap(cmd as? TransformsCommand.RunSubcommand)
        XCTAssertEqual(run.idOrName, "Polish")
        XCTAssertEqual(run.input, "/tmp/in.txt")
        XCTAssertFalse(run.stream)
        XCTAssertFalse(run.json)
    }

    func testRunRejectsJSONWithStream() throws {
        // `parseAsRoot` runs `validate()` itself; both --json and --stream
        // present should surface the mutual-exclusivity error at parse time.
        XCTAssertThrowsError(
            try TransformsCommand.parseAsRoot([
                "run", "Polish",
                "--provider", "anthropic", "--api-key", "test",
                "--input", "-",
                "--json", "--stream",
            ])
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("--json with --stream"))
        }
    }

    func testParsesCreateRequiresPromptOrFromFile() throws {
        XCTAssertThrowsError(
            try TransformsCommand.parseAsRoot([
                "create",
                "--name", "Sharpen",
            ]),
            "Either --prompt or --from-file is required."
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("--prompt or --from-file"))
        }
    }

    func testParsesCreateAcceptsShortcut() throws {
        let cmd = try TransformsCommand.parseAsRoot([
            "create",
            "--name", "Sharpen",
            "--prompt", "Make it crisp.",
            "--shortcut", "opt+5",
        ])
        let create = try XCTUnwrap(cmd as? TransformsCommand.CreateSubcommand)
        XCTAssertNoThrow(try create.validate())
        XCTAssertEqual(create.shortcut, "opt+5")
    }

    func testParsesCreateRejectsMutuallyExclusivePromptAndFromFile() throws {
        XCTAssertThrowsError(
            try TransformsCommand.parseAsRoot([
                "create",
                "--name", "Sharpen",
                "--prompt", "Inline",
                "--from-file", "/tmp/x.txt",
            ])
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("mutually exclusive"))
        }
    }

    func testParsesDeleteSubcommand() throws {
        let cmd = try TransformsCommand.parseAsRoot(["delete", "Sharpen"])
        let del = try XCTUnwrap(cmd as? TransformsCommand.DeleteSubcommand)
        XCTAssertEqual(del.idOrName, "Sharpen")
    }

    func testParsesHistoryListAsDefaultSubcommand() throws {
        let cmd = try TransformsCommand.parseAsRoot(["history", "--limit", "5", "--json"])
        let history = try XCTUnwrap(cmd as? TransformsCommand.HistorySubcommand.ListSubcommand)
        XCTAssertEqual(history.limit, 5)
        XCTAssertTrue(history.json)
    }

    func testParsesHistoryShowDeleteAndClear() throws {
        let show = try TransformsCommand.parseAsRoot(["history", "show", "abc123"])
        XCTAssertEqual(try XCTUnwrap(show as? TransformsCommand.HistorySubcommand.ShowSubcommand).idPrefix, "abc123")

        let delete = try TransformsCommand.parseAsRoot(["history", "delete", "abc123"])
        XCTAssertEqual(try XCTUnwrap(delete as? TransformsCommand.HistorySubcommand.DeleteSubcommand).idPrefix, "abc123")

        let clear = try TransformsCommand.parseAsRoot(["history", "clear", "--json"])
        XCTAssertTrue(try XCTUnwrap(clear as? TransformsCommand.HistorySubcommand.ClearSubcommand).json)
    }

    // MARK: - JSON contract

    func testTransformDTOJSONUsesDocumentedSnakeCaseKeys() throws {
        let shortcut = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,
            keyLabel: "1"
        )
        let prompt = Prompt(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Sharpen",
            content: "Make it crisp.",
            category: .transform,
            isBuiltIn: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            keyboardShortcut: shortcut.encodedString(),
            runningLabel: "Sharpening..."
        )

        let data = try cliJSONEncoder.encode(TransformDTO(prompt: prompt))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["running_label"] as? String, "Sharpening...")
        XCTAssertEqual(object["is_built_in"] as? Bool, true)
        XCTAssertNotNil(object["created_at"])
        XCTAssertNotNil(object["updated_at"])
        XCTAssertNil(object["runningLabel"])
        XCTAssertNil(object["isBuiltIn"])
        XCTAssertNil(object["createdAt"])
        XCTAssertNil(object["updatedAt"])
    }

    func testTransformHistoryDTOJSONUsesDocumentedSnakeCaseKeys() throws {
        let entry = TransformHistoryEntry(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            transformId: UUID(uuidString: "0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11"),
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            sourceAppBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 12,
            totalElapsedMs: 34,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let data = try cliJSONEncoder.encode(TransformHistoryDTO(entry: entry))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(object["transform_name"] as? String, "Polish")
        XCTAssertEqual(object["input_text"] as? String, "rough")
        XCTAssertEqual(object["output_text"] as? String, "polished")
        XCTAssertEqual(object["source_app_bundle_id"] as? String, "com.apple.TextEdit")
        XCTAssertEqual(object["llm_elapsed_ms"] as? Int, 12)
        XCTAssertNotNil(object["created_at"])
        XCTAssertNil(object["transformName"])
        XCTAssertNil(object["inputText"])
        XCTAssertNil(object["outputText"])
    }

    func testAssembledTransformPromptUsesProfileAndWritingSamples() throws {
        let manager = try DatabaseManager()
        let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
        let profileRepo = TransformProfileRepository(dbQueue: manager.dbQueue)
        let writingSampleRepo = WritingSampleRepository(dbQueue: manager.dbQueue)
        let polish = try XCTUnwrap(try promptRepo.fetchVisible(category: .transform).first { $0.name == "Polish" })
        var profile = TransformProfile.defaultProfile(for: polish)
        profile.customInstructions = "Keep it direct."
        profile.useWritingSamples = true
        try profileRepo.save(profile)
        try writingSampleRepo.save(
            WritingSample(
                title: "Launch note",
                text: "This is a realistic writing sample with enough substance to show cadence, directness, and personal phrasing.",
                wordCount: 15
            )
        )

        let assembled = try assembledTransformPrompt(
            transform: polish,
            profileRepo: profileRepo,
            writingSampleRepo: writingSampleRepo
        )

        XCTAssertTrue(assembled.contains("User-selected rules:"))
        XCTAssertTrue(assembled.contains("Additional user instructions:\nKeep it direct."))
        XCTAssertTrue(assembled.contains("Voice reference samples:"))
        XCTAssertTrue(assembled.contains("Sample 1"), assembled)
    }

    // MARK: - End-to-end: create + list + show + delete against a real DB

    func testCreateListShowDeleteRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        let create = try TransformsCommand.CreateSubcommand.parse([
            "--name", "Sharpen",
            "--prompt", "Make it crisp.",
            "--database", dbPath,
        ])
        try create.validate()
        try create.run()

        // After create, the DB should have the three built-ins + Sharpen.
        let db = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let all = try repo.fetchVisible(category: .transform)
        XCTAssertEqual(all.count, 4)
        let sharpen = try XCTUnwrap(all.first(where: { $0.name == "Sharpen" }))
        XCTAssertFalse(sharpen.isBuiltIn)
        XCTAssertNil(sharpen.shortcut)

        // Delete by name.
        let del = try TransformsCommand.DeleteSubcommand.parse([
            "Sharpen",
            "--database", dbPath,
        ])
        try del.run()

        let after = try repo.fetchVisible(category: .transform)
        XCTAssertEqual(after.count, 3)
        XCTAssertFalse(after.contains(where: { $0.name == "Sharpen" }))
    }

    func testHistoryDeleteAndClearRoundTrip() throws {
        // These subcommands intentionally reopen the database from `--database`,
        // so this round-trip needs a file-backed path rather than one in-memory queue.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-history-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        let db = try DatabaseManager(path: dbPath)
        let repo = TransformHistoryRepository(dbQueue: db.dbQueue)
        let first = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )
        let second = TransformHistoryEntry(
            transformName: "Distill",
            inputText: "long",
            outputText: "short",
            capturePath: "clipboard",
            replacementPath: "clipboardPaste",
            llmElapsedMs: 3,
            totalElapsedMs: 4
        )
        try repo.save(first)
        try repo.save(second)

        let del = try TransformsCommand.HistorySubcommand.DeleteSubcommand.parse([
            String(first.id.uuidString.prefix(8)),
            "--database", dbPath,
        ])
        try del.run()
        XCTAssertEqual(try repo.fetchAll().map(\.id), [second.id])

        let clear = try TransformsCommand.HistorySubcommand.ClearSubcommand.parse([
            "--database", dbPath,
        ])
        try clear.run()
        XCTAssertEqual(try repo.count(), 0)
    }

    func testHistoryShowRejectsTooShortPrefix() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-history-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        _ = try DatabaseManager(path: dbPath)

        let show = try TransformsCommand.HistorySubcommand.ShowSubcommand.parse([
            "abc",
            "--database", dbPath,
        ])

        XCTAssertThrowsError(try show.run()) { error in
            guard case CLITransformHistoryError.prefixTooShort(let min, let provided) = error else {
                XCTFail("Expected prefixTooShort, got \(error)")
                return
            }
            XCTAssertEqual(min, 4)
            XCTAssertEqual(provided, "abc")
        }
    }

    func testHistoryShowJSONMapsTooShortPrefixToValidationError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-history-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        _ = try DatabaseManager(path: dbPath)

        let show = try TransformsCommand.HistorySubcommand.ShowSubcommand.parse([
            "abc",
            "--database", dbPath,
            "--json",
        ])

        var thrownError: Error?
        let output = try captureStandardOutput {
            do {
                try show.run()
            } catch {
                thrownError = error
            }
        }

        let exit = try XCTUnwrap(thrownError as? ExitCode)
        XCTAssertEqual(exit.rawValue, 2)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["errorType"] as? String, "validation")
    }

    func testHistoryShowJSONMapsMissingItemToLookupError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-history-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        _ = try DatabaseManager(path: dbPath)

        let show = try TransformsCommand.HistorySubcommand.ShowSubcommand.parse([
            "abcd",
            "--database", dbPath,
            "--json",
        ])

        var thrownError: Error?
        let output = try captureStandardOutput {
            do {
                try show.run()
            } catch {
                thrownError = error
            }
        }

        let exit = try XCTUnwrap(thrownError as? ExitCode)
        XCTAssertEqual(exit, .failure)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["errorType"] as? String, "lookup")
    }

    func testCreateRejectsBareKeyShortcut() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        // First seed the built-ins so the DB exists.
        _ = try DatabaseManager(path: dbPath)

        let create = try TransformsCommand.CreateSubcommand.parse([
            "--name", "Bare",
            "--prompt", "Body",
            "--shortcut", "5",  // no modifier
            "--database", dbPath,
        ])
        try create.validate()
        XCTAssertThrowsError(try create.run()) { error in
            // The error should describe an unparseable or modifier-missing
            // shortcut — either branch is acceptable as the user's signal.
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("modifier") || message.contains("parse"),
                "Expected shortcut-validation error, got: \(message)"
            )
        }
    }

    func testCreateRejectsDuplicateShortcut() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        _ = try DatabaseManager(path: dbPath)

        let create = try TransformsCommand.CreateSubcommand.parse([
            "--name", "Duplicate Hotkey",
            "--prompt", "Body",
            "--shortcut", "opt+1",
            "--database", dbPath,
        ])
        try create.validate()
        XCTAssertThrowsError(try create.run()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("already used"), "Expected duplicate-shortcut error, got: \(message)")
            XCTAssertTrue(message.contains("Polish"), "Expected duplicate owner name, got: \(message)")
        }
    }

    func testCreateRejectsMacOSDeadKeyShortcut() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        _ = try DatabaseManager(path: dbPath)

        let create = try TransformsCommand.CreateSubcommand.parse([
            "--name", "Accent Breaker",
            "--prompt", "Body",
            "--shortcut", "opt+e",
            "--database", dbPath,
        ])
        try create.validate()
        XCTAssertThrowsError(try create.run()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("special character"), "Expected dead-key error, got: \(message)")
        }
    }

    func testCreateRejectsDuplicateName() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        // Polish is a built-in — try to create a custom Transform with the
        // same name.
        let create = try TransformsCommand.CreateSubcommand.parse([
            "--name", "Polish",
            "--prompt", "Body",
            "--database", dbPath,
        ])
        try create.validate()
        XCTAssertThrowsError(try create.run()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("already exists"), "Expected duplicate-name error, got: \(message)")
        }
    }

    func testDeleteRefusesBuiltIn() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transforms-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        _ = try DatabaseManager(path: dbPath)

        let del = try TransformsCommand.DeleteSubcommand.parse([
            "Polish",
            "--database", dbPath,
        ])
        XCTAssertThrowsError(try del.run()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("built-in"), "Expected built-in-protection error, got: \(message)")
        }
    }
}
