import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class QuickPromptsCommandTests: XCTestCase {

    // MARK: - findQuickPrompt

    func testFindByExactUUID() throws {
        let db = try DatabaseManager()
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)
        let p = QuickPrompt(label: "ELI5", prompt: "Explain like I'm five.")
        try repo.save(p)

        let found = try findQuickPrompt(idOrLabel: p.id.uuidString, repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindByPrefix() throws {
        let db = try DatabaseManager()
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)
        let p = QuickPrompt(label: "Recap", prompt: "Recap.")
        try repo.save(p)

        let prefix = String(p.id.uuidString.prefix(8))
        let found = try findQuickPrompt(idOrLabel: prefix, repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindByLabelCaseInsensitive() throws {
        let db = try DatabaseManager()
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)
        let p = QuickPrompt(label: "My Custom Pill", prompt: "x")
        try repo.save(p)

        let found = try findQuickPrompt(idOrLabel: "my custom pill", repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindThrowsNotFound() throws {
        let db = try DatabaseManager()
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findQuickPrompt(idOrLabel: "nonexistent-pill-xyz", repo: repo)) { error in
            guard let e = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = e {} else {
                XCTFail("Expected .notFound, got \(e)")
            }
        }
    }

    func testFindThrowsAmbiguousForSharedPrefix() throws {
        let db = try DatabaseManager()
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)
        let id1 = UUID(uuidString: "BEEFCAFE-1111-4111-8111-111111111111")!
        let id2 = UUID(uuidString: "BEEFCAFE-2222-4222-8222-222222222222")!
        try repo.save(QuickPrompt(id: id1, label: "X", prompt: "x"))
        try repo.save(QuickPrompt(id: id2, label: "Y", prompt: "y"))

        XCTAssertThrowsError(try findQuickPrompt(idOrLabel: "BEEFCAFE", repo: repo)) { error in
            guard let e = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .ambiguous = e {} else {
                XCTFail("Expected .ambiguous, got \(e)")
            }
        }
    }

    func testFindThrowsEmptyIDForWhitespace() throws {
        let db = try DatabaseManager()
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findQuickPrompt(idOrLabel: "   ", repo: repo)) { error in
            guard let e = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .emptyID = e {} else {
                XCTFail("Expected .emptyID, got \(e)")
            }
        }
    }

    // MARK: - List

    func testListPinnedFilterOnlyReturnsPinnedRows() throws {
        let dbURL = temporaryDatabaseURL()
        let command = try QuickPromptsCommand.ListSubcommand.parse([
            "--pinned", "true",
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput { try command.run() }
        let prompts = try decodedJSONArray(output)
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.allSatisfy { ($0["isPinned"] as? Bool) == true })
        XCTAssertEqual(prompts.count, 5, "default seed pins 5 built-ins")
    }

    func testListUnpinnedFilterOnlyReturnsUnpinnedRows() throws {
        let dbURL = temporaryDatabaseURL()
        let command = try QuickPromptsCommand.ListSubcommand.parse([
            "--pinned", "false",
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput { try command.run() }
        let prompts = try decodedJSONArray(output)
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.allSatisfy { ($0["isPinned"] as? Bool) == false })
    }

    // MARK: - Add validation

    func testAddRequiresLabel() {
        XCTAssertThrowsError(try QuickPromptsCommand.AddSubcommand.parse([]))
    }

    func testAddRejectsPromptAndFromFileTogether() {
        XCTAssertThrowsError(
            try QuickPromptsCommand.AddSubcommand.parse([
                "--label", "X", "--prompt", "body", "--from-file", "/tmp/x.txt"
            ])
        )
    }

    func testAddAcceptsGroupOnAnyPrompt() {
        // v2: --group is now valid for every prompt, not just starters.
        XCTAssertNoThrow(
            try QuickPromptsCommand.AddSubcommand.parse([
                "--label", "X", "--prompt", "y", "--group", "REFINE"
            ])
        )
    }

    func testAddRejectsEmptyLabel() {
        XCTAssertThrowsError(
            try QuickPromptsCommand.AddSubcommand.parse([
                "--label", "   ", "--prompt", "y"
            ])
        )
    }

    func testAddJSONReturnsSuccessEnvelope() throws {
        let dbURL = temporaryDatabaseURL()
        let command = try QuickPromptsCommand.AddSubcommand.parse([
            "--label", "ELI5",
            "--prompt", "Explain simply.",
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput {
            try command.run()
        }
        let envelope = try decodedJSONObject(output)

        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let prompt = try XCTUnwrap(envelope["prompt"] as? [String: Any])
        XCTAssertEqual(prompt["label"] as? String, "ELI5")
        XCTAssertEqual(prompt["isPinned"] as? Bool, false, "new prompts default unpinned")
        XCTAssertNil(prompt["kind"], "v2 model has no kind field")
    }

    func testAddPinnedSucceedsUnbounded() throws {
        let dbURL = temporaryDatabaseURL()
        // Pinning is unbounded — adding past the default seed count is allowed.
        let command = try QuickPromptsCommand.AddSubcommand.parse([
            "--label", "Extra pinned",
            "--prompt", "body",
            "--pinned",
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput { try command.run() }
        let envelope = try decodedJSONObject(output)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let saved = try XCTUnwrap(envelope["prompt"] as? [String: Any])
        XCTAssertEqual(saved["isPinned"] as? Bool, true)
    }

    // MARK: - Set validation

    func testSetRejectsVisibleAndHidden() {
        XCTAssertThrowsError(
            try QuickPromptsCommand.SetSubcommand.parse(["x", "--visible", "--hidden"])
        )
    }

    func testSetRequiresAtLeastOneField() {
        XCTAssertThrowsError(try QuickPromptsCommand.SetSubcommand.parse(["x"]))
    }

    func testSetAcceptsLabelOnly() {
        XCTAssertNoThrow(try QuickPromptsCommand.SetSubcommand.parse(["x", "--label", "New"]))
    }

    func testSetRejectsEmptyLabel() {
        XCTAssertThrowsError(try QuickPromptsCommand.SetSubcommand.parse(["x", "--label", "   "]))
    }

    func testSetRejectsEmptyPrompt() {
        XCTAssertThrowsError(try QuickPromptsCommand.SetSubcommand.parse(["x", "--prompt", "   "]))
    }

    func testSetGroupOnPinnedPromptIsAllowed() throws {
        // v2: --group is no longer rejected on previously-followup prompts.
        let dbURL = temporaryDatabaseURL()
        let command = try QuickPromptsCommand.SetSubcommand.parse([
            "Tell me more",
            "--group", "REFINE",
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput { try command.run() }
        let envelope = try decodedJSONObject(output)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let saved = try XCTUnwrap(envelope["prompt"] as? [String: Any])
        XCTAssertEqual(saved["groupLabel"] as? String, "REFINE")
    }

    func testSetJSONReturnsSuccessEnvelope() throws {
        let dbURL = temporaryDatabaseURL()
        let db = try DatabaseManager(path: dbURL.path)
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)
        let prompt = QuickPrompt(label: "Original", prompt: "body")
        try repo.save(prompt)

        let command = try QuickPromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--label", "Updated",
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput {
            try command.run()
        }
        let envelope = try decodedJSONObject(output)

        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let saved = try XCTUnwrap(envelope["prompt"] as? [String: Any])
        XCTAssertEqual(saved["id"] as? String, prompt.id.uuidString)
        XCTAssertEqual(saved["label"] as? String, "Updated")
    }

    // MARK: - Pin / Unpin

    func testUnpinSucceedsOnDefaultBuiltIn() throws {
        let dbURL = temporaryDatabaseURL()
        let command = try QuickPromptsCommand.UnpinSubcommand.parse([
            "Tell me more",
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput { try command.run() }
        let envelope = try decodedJSONObject(output)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let saved = try XCTUnwrap(envelope["prompt"] as? [String: Any])
        XCTAssertEqual(saved["isPinned"] as? Bool, false)
    }

    func testPinSucceedsBeyondDefaultPinnedCount() throws {
        let dbURL = temporaryDatabaseURL()
        let db = try DatabaseManager(path: dbURL.path)
        let repo = QuickPromptRepository(dbQueue: db.dbQueue)
        let candidate = QuickPrompt(label: "Newly pinned", prompt: "body")
        try repo.save(candidate)

        let command = try QuickPromptsCommand.PinSubcommand.parse([
            candidate.id.uuidString,
            "--database", dbURL.path,
            "--json",
        ])

        let output = try captureStandardOutput { try command.run() }
        let envelope = try decodedJSONObject(output)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let saved = try XCTUnwrap(envelope["prompt"] as? [String: Any])
        XCTAssertEqual(saved["isPinned"] as? Bool, true)
    }

    // MARK: - Restore-defaults

    func testRestoreDefaultsHasNoKindFlag() {
        // v2 dropped --kind; only --id remains. Parsing --kind should fail.
        XCTAssertThrowsError(
            try QuickPromptsCommand.RestoreDefaultsSubcommand.parse([
                "--kind", "starter"
            ])
        )
    }

    // MARK: - Error type mapping

    func testErrorTypeMapsImportSchemaError() {
        let err = QuickPromptCLIError.importSchemaError("bad shape")
        XCTAssertEqual(CLIErrorType.key(for: err), "import_schema")
    }

    func testErrorTypeMapsDeleteBuiltInToValidation() {
        let err = QuickPromptCLIError.cannotDeleteBuiltIn("Tell me more")
        XCTAssertEqual(CLIErrorType.key(for: err), "validation")
    }

    func testErrorTypeMapsImportCancelledToValidation() {
        XCTAssertEqual(CLIErrorType.key(for: QuickPromptCLIError.importCancelled), "validation")
    }

    func testErrorTypeMapsReadFailedToInputMissing() {
        let err = QuickPromptCLIError.readFailed("/no/such/path", underlying: NSError(domain: "test", code: 1))
        XCTAssertEqual(CLIErrorType.key(for: err), "input_missing")
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-quick-prompts-\(UUID().uuidString).db")
    }

    private func decodedJSONObject(_ output: String) throws -> [String: Any] {
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func decodedJSONArray(_ output: String) throws -> [[String: Any]] {
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]])
    }
}
