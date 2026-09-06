import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class PromptsCommandTests: XCTestCase {

    func testStoredPromptRunResultUsesEffectiveSettingsReceipt() {
        let transcript = Transcription(
            fileName: "Meeting",
            rawTranscript: "Transcript",
            status: .completed,
            userNotes: "Keep this detail"
        )
        let requested = PromptInferenceSettings(
            temperature: 0.4,
            topK: 40,
            thinkingMode: .enabled
        )
        let effective = PromptInferenceSettings(temperature: 0.4)
        let prompt = Prompt(
            name: "Configured",
            content: "Summarize.",
            inferenceSettings: requested
        )

        let result = makeStoredPromptRunResult(
            transcript: transcript,
            prompt: prompt,
            extraInstructions: "Brief.",
            output: "Result",
            userNotesSnapshot: nil,
            effectiveSettings: effective
        )

        XCTAssertEqual(result.transcriptionId, transcript.id)
        XCTAssertEqual(result.promptName, prompt.name)
        XCTAssertNil(result.userNotesSnapshot)
        XCTAssertFalse(result.includeMeetingNotesSnapshot)
        XCTAssertEqual(result.inferenceSettingsSnapshot, effective)
        XCTAssertNotEqual(result.inferenceSettingsSnapshot, requested)
    }

    func testStoredPromptRunResultUsesExactEffectiveNotesReceiptAndPreference() {
        let transcript = Transcription(
            fileName: "Meeting",
            rawTranscript: "Transcript",
            status: .completed,
            userNotes: "Canonical notes are not copied implicitly"
        )
        let prompt = Prompt(
            name: "Configured",
            content: "Summarize.",
            includeMeetingNotes: true
        )
        let effectiveNotes = "Exact capped notes receipt"

        let result = makeStoredPromptRunResult(
            transcript: transcript,
            prompt: prompt,
            extraInstructions: nil,
            output: "Result",
            userNotesSnapshot: effectiveNotes,
            effectiveSettings: nil
        )

        XCTAssertEqual(result.userNotesSnapshot, effectiveNotes)
        XCTAssertTrue(result.includeMeetingNotesSnapshot)
    }

    // MARK: - findPrompt

    func testFindPromptByExactUUID() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let p = Prompt(name: "Custom A", content: "Hello")
        try repo.save(p)

        let found = try findPrompt(idOrName: p.id.uuidString, repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindPromptByPrefix() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let p = Prompt(name: "Custom B", content: "Hello")
        try repo.save(p)

        let prefix = String(p.id.uuidString.prefix(8))
        let found = try findPrompt(idOrName: prefix, repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindPromptRejectsShortUUIDPrefixUnlessItIsName() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let uuid = UUID(uuidString: "DDBBCCAA-1111-1111-1111-111111111111")!
        let p = Prompt(id: uuid, name: "Custom", content: "Hello")
        try repo.save(p)

        XCTAssertThrowsError(try findPrompt(idOrName: "ddb", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .shortUUIDPrefix(let minimumLength) = lookupError {
                XCTAssertEqual(minimumLength, 4)
            } else {
                XCTFail("Expected .shortUUIDPrefix, got \(lookupError)")
            }
        }

        let nameOnly = Prompt(name: "dd", content: "Name")
        try repo.save(nameOnly)
        let foundByName = try findPrompt(idOrName: "dd", repo: repo)
        XCTAssertEqual(foundByName.id, nameOnly.id)
    }

    func testFindPromptByNameCaseInsensitive() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let p = Prompt(name: "My Special Prompt", content: "Hello")
        try repo.save(p)

        let found = try findPrompt(idOrName: "my special prompt", repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindPromptIgnoresTransformRows() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let polish = try XCTUnwrap(
            (try repo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )

        XCTAssertThrowsError(try findPrompt(idOrName: "Polish", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {
            } else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
        XCTAssertThrowsError(try findPrompt(idOrName: polish.id.uuidString, repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {
            } else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
    }

    func testFindPromptThrowsNotFoundForBogusInput() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findPrompt(idOrName: "nonexistent-prompt-name", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {
            } else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
    }

    func testFindPromptThrowsEmptyIDForWhitespace() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findPrompt(idOrName: "   ", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .emptyID = lookupError {
            } else {
                XCTFail("Expected .emptyID, got \(lookupError)")
            }
        }
    }

    func testFindPromptThrowsAmbiguousForSharedPrefix() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        let uuid1 = UUID(uuidString: "CCDDEEFF-1111-1111-1111-111111111111")!
        let uuid2 = UUID(uuidString: "CCDDEEFF-2222-2222-2222-222222222222")!
        try repo.save(Prompt(id: uuid1, name: "X", content: "x"))
        try repo.save(Prompt(id: uuid2, name: "Y", content: "y"))

        XCTAssertThrowsError(try findPrompt(idOrName: "CCDDEEFF", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .ambiguous = lookupError {
            } else {
                XCTFail("Expected .ambiguous, got \(lookupError)")
            }
        }
    }

    func testFindPromptPrefersIDPrefixOverName() throws {
        // If a name happens to look like a UUID prefix that also matches a real
        // prompt's UUID, the ID match wins. This mirrors the precedence in
        // findTranscription/findDictation.
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        let realID = UUID(uuidString: "DEADBEEF-1111-1111-1111-111111111111")!
        try repo.save(Prompt(id: realID, name: "Real", content: "real"))
        try repo.save(Prompt(name: "deadbeef", content: "name-only"))

        let found = try findPrompt(idOrName: "deadbeef", repo: repo)
        XCTAssertEqual(found.id, realID, "ID prefix match should beat case-insensitive name match")
    }

    // MARK: - cliJSONEncoder smoke

    func testListJSONExcludesTransformPrompts() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path

        _ = try DatabaseManager(path: dbPath)

        let command = try PromptsCommand.ListSubcommand.parse([
            "--json",
            "--database", dbPath,
        ])
        let output = try captureStandardOutput { try command.run() }
        let prompts = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        )

        XCTAssertEqual(prompts.count, 6)
        XCTAssertTrue(prompts.allSatisfy { $0["category"] as? String == Prompt.Category.result.rawValue })
        XCTAssertFalse(prompts.contains(where: { $0["name"] as? String == "Polish" }))
    }

    // MARK: - Set validation
    // .parse() runs validate() automatically, so a failed parse with our error
    // text proves validate() rejected it.

    func testSetRejectsContradictoryHiddenAndAutoRun() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--hidden", "--auto-run"])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("auto-run requires visible"),
                          "Expected message about auto-run requiring visible, got: \(error)")
        }
    }

    func testSetRejectsMutuallyExclusiveVisibleHidden() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--visible", "--hidden"])
        )
    }

    func testSetRequiresAtLeastOneFlag() {
        XCTAssertThrowsError(try PromptsCommand.SetSubcommand.parse(["anything"]))
    }

    func testSetAcceptsHiddenWithNoAutoRun() {
        XCTAssertNoThrow(
            try PromptsCommand.SetSubcommand.parse(["anything", "--hidden", "--no-auto-run"])
        )
    }

    func testSetAcceptsSourceScopedAutoRun() throws {
        let command = try PromptsCommand.SetSubcommand.parse([
            "anything",
            "--auto-run",
            "--source", "meeting",
        ])

        XCTAssertEqual(command.source, .meeting)
    }

    func testSetRejectsSourceWithoutAutoRunFlag() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--source", "meeting"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("--source requires"))
        }
    }

    func testSetRejectsSourceWithVisibilityFlags() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--visible", "--source", "meeting"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("--source can only"))
        }
    }

    func testSetRejectsContradictoryMeetingNotesFlags() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse([
                "anything", "--include-meeting-notes", "--no-include-meeting-notes",
            ])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("mutually exclusive"))
        }
    }

    func testSetMeetingNotesFlagPersistsAndAppearsInJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-notes-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let prompt = try XCTUnwrap(try PromptRepository(dbQueue: db.dbQueue).fetchAll().first)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--include-meeting-notes",
            "--json",
            "--database", dbPath,
        ])
        let output = try captureStandardOutput { try command.run() }
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["includeMeetingNotes"] as? Bool, true)
    }

    func testMeetingNotesLookupPrefersResultsWithoutLosingExactUUIDIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("test.db").path
        let manager = try DatabaseManager(path: databasePath)
        let repository = PromptRepository(dbQueue: manager.dbQueue)
        let result = Prompt(
            id: UUID(uuidString: "CCDDEEFF-1111-1111-1111-111111111111")!,
            name: "Result prefix target", content: "Result"
        )
        let transform = Prompt(
            id: UUID(uuidString: "CCDDEEFF-2222-2222-2222-222222222222")!,
            name: "Transform prefix target", content: "Transform", category: .transform
        )
        try repository.save(result)
        try repository.save(transform)
        for flag in ["--include-meeting-notes", "--no-include-meeting-notes"] {
            let command = try PromptsCommand.SetSubcommand.parse([
                "CCDDEEFF", flag, "--database", databasePath,
            ])
            try command.run()
            XCTAssertEqual(try repository.fetch(id: result.id)?.includeMeetingNotes, flag == "--include-meeting-notes")
            XCTAssertEqual(try repository.fetch(id: transform.id)?.includeMeetingNotes, false)
        }

        // A result name that resembles only a transform's prefix still
        // resolves as a name within the result-specific notes operation.
        let namedResult = Prompt(name: "CCDDEEFF-2222", content: "Named result")
        try repository.save(namedResult)
        let namedCommand = try PromptsCommand.SetSubcommand.parse([
            namedResult.name, "--include-meeting-notes", "--database", databasePath,
        ])
        try namedCommand.run()
        XCTAssertEqual(try repository.fetch(id: namedResult.id)?.includeMeetingNotes, true)

        // Exact UUID precedence must still reject a transform, rather than
        // modifying a result with a display name equal to that UUID.
        let uuidNamedResult = Prompt(name: transform.id.uuidString, content: "UUID display name")
        try repository.save(uuidNamedResult)
        let exactCommand = try PromptsCommand.SetSubcommand.parse([
            transform.id.uuidString, "--include-meeting-notes", "--database", databasePath,
        ])
        XCTAssertThrowsError(try exactCommand.run()) { error in
            XCTAssertTrue(String(describing: error).contains("only available for result prompts"))
        }
        XCTAssertEqual(try repository.fetch(id: uuidNamedResult.id)?.includeMeetingNotes, false)

        // Ambiguity among results must not fall through to wider lookup.
        try repository.save(Prompt(
            id: UUID(uuidString: "CCDDEEFF-3333-3333-3333-333333333333")!,
            name: "Second result", content: "Result"
        ))
        let ambiguous = try PromptsCommand.SetSubcommand.parse([
            "CCDDEEFF", "--include-meeting-notes", "--database", databasePath,
        ])
        XCTAssertThrowsError(try ambiguous.run()) { error in
            guard case CLILookupError.ambiguous = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSetMeetingNotesFlagRejectsTransformPrompt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-notes-transform-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let transform = try XCTUnwrap(
            try PromptRepository(dbQueue: db.dbQueue).fetchVisible(category: .transform).first
        )
        let command = try PromptsCommand.SetSubcommand.parse([
            transform.id.uuidString,
            "--include-meeting-notes",
            "--database", dbPath,
        ])

        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertEqual(
                CLI.normalizedExitCode(for: error),
                cliValidationMisuseExitCode,
                "Unexpected error: \(type(of: error)): \(error)"
            )
        }
        XCTAssertFalse(try XCTUnwrap(PromptRepository(dbQueue: db.dbQueue).fetch(id: transform.id)).includeMeetingNotes)
    }

    // MARK: - Set flag semantics (applyFlags)

    func testSetAutoRunClearsPerSourceScope() {
        // A prompt narrowed to meetings-only in the GUI must not stay scoped when
        // the CLI enables global auto-run — otherwise it claims global-on while
        // silently firing on meetings only.
        let inferenceSettings = PromptInferenceSettings(temperature: 0.3, maxTokens: 450)
        var prompt = Prompt(
            name: "Summary",
            content: "x",
            category: .result,
            inferenceSettings: inferenceSettings
        )
        prompt.isAutoRun = true
        prompt.appliesToSources = [.meeting]

        PromptsCommand.SetSubcommand.applyFlags(
            to: &prompt, visible: false, hidden: false, autoRun: true, noAutoRun: false
        )

        XCTAssertTrue(prompt.isAutoRun)
        XCTAssertTrue(prompt.isVisible)
        XCTAssertNil(prompt.appliesToSources, "global --auto-run resets scope to all sources")
        XCTAssertEqual(prompt.inferenceSettings, inferenceSettings)
    }

    func testSetNoAutoRunClearsPerSourceScope() {
        var prompt = Prompt(name: "Summary", content: "x", category: .result)
        prompt.isAutoRun = true
        prompt.appliesToSources = [.meeting]

        PromptsCommand.SetSubcommand.applyFlags(
            to: &prompt, visible: false, hidden: false, autoRun: false, noAutoRun: true
        )

        XCTAssertFalse(prompt.isAutoRun)
        XCTAssertNil(prompt.appliesToSources, "disabling auto-run returns to a clean nil scope")
    }

    func testSetHiddenClearsAutoRunAndScope() {
        var prompt = Prompt(name: "Summary", content: "x", category: .result)
        prompt.isAutoRun = true
        prompt.appliesToSources = [.meeting]

        PromptsCommand.SetSubcommand.applyFlags(
            to: &prompt, visible: false, hidden: true, autoRun: false, noAutoRun: false
        )

        XCTAssertFalse(prompt.isVisible)
        XCTAssertFalse(prompt.isAutoRun)
        XCTAssertNil(prompt.appliesToSources)
    }

    func testSetSourceScopedAutoRunUsesRepositoryScoping() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let inferenceSettings = PromptInferenceSettings(topP: 0.8, maxTokens: 700)
        let prompt = Prompt(
            name: "Meeting Follow-up",
            content: "x",
            category: .result,
            inferenceSettings: inferenceSettings
        )
        try repo.save(prompt)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--auto-run",
            "--source", "meeting",
            "--database", dbPath,
        ])
        _ = try captureStandardOutput {
            try command.run()
        }

        let updated = try XCTUnwrap(repo.fetch(id: prompt.id))
        XCTAssertTrue(updated.isAutoRun)
        XCTAssertTrue(updated.isVisible)
        XCTAssertEqual(updated.appliesToSources, [.meeting])
        XCTAssertEqual(updated.inferenceSettings, inferenceSettings)
        XCTAssertTrue(updated.autoRuns(for: .meeting))
        XCTAssertFalse(updated.autoRuns(for: .file))
    }

    func testSetSourceScopedAutoRunJSONEmitsUpdatedPrompt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let prompt = Prompt(name: "Meeting Follow-up", content: "x", category: .result)
        try repo.save(prompt)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--auto-run",
            "--source", "meeting",
            "--database", dbPath,
            "--json",
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["id"] as? String, prompt.id.uuidString.uppercased())
        XCTAssertEqual(decoded["name"] as? String, "Meeting Follow-up")
        XCTAssertEqual(decoded["isAutoRun"] as? Bool, true)
        XCTAssertEqual(decoded["isVisible"] as? Bool, true)
        XCTAssertEqual(decoded["appliesToSources"] as? [String], ["meeting"])
    }

    func testSetJSONLookupFailureEmitsEnvelope() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-json-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        _ = try DatabaseManager(path: dbPath)

        let command = try PromptsCommand.SetSubcommand.parse([
            "missing",
            "--auto-run",
            "--database", dbPath,
            "--json",
        ])
        var thrownError: Error?
        let output = try captureStandardOutput {
            do {
                try command.run()
            } catch {
                thrownError = error
            }
        }

        let error = try XCTUnwrap(thrownError)
        XCTAssertTrue(error is CLIJSONEnvelopeExit)
        XCTAssertEqual(CLI.normalizedExitCode(for: error), .failure)

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, false)
        XCTAssertEqual(decoded["errorType"] as? String, "lookup")
        XCTAssertTrue((decoded["error"] as? String)?.contains("No prompt matching") == true)
    }

    func testRestoreDefaultsKeepsTransformVisibilityCompatibility() throws {
        XCTAssertEqual(
            PromptsCommand.RestoreDefaultsSubcommand.configuration.abstract,
            "Re-show built-in result prompts and hidden built-in Transforms."
        )

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-restore-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let manager = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: manager.dbQueue)
        let transform = try XCTUnwrap(
            (try repo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )
        try repo.toggleVisibility(id: transform.id)
        XCTAssertFalse(try XCTUnwrap(try repo.fetch(id: transform.id)).isVisible)

        let command = try PromptsCommand.RestoreDefaultsSubcommand.parse([
            "--database", dbPath,
        ])
        let output = try captureStandardOutput {
            try command.run()
        }

        XCTAssertTrue(output.contains("Built-in result prompts and hidden built-in Transforms re-shown."))
        XCTAssertTrue(try XCTUnwrap(try repo.fetch(id: transform.id)).isVisible)
    }

    func testSetSourceScopedNoAutoRunNarrowsGlobalAutoRun() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-source-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbPath = tmp.appendingPathComponent("test.db").path
        let db = try DatabaseManager(path: dbPath)
        let repo = PromptRepository(dbQueue: db.dbQueue)
        var prompt = Prompt(name: "All Sources", content: "x", category: .result, isAutoRun: true)
        prompt.appliesToSources = nil
        try repo.save(prompt)

        let command = try PromptsCommand.SetSubcommand.parse([
            prompt.id.uuidString,
            "--no-auto-run",
            "--source", "meeting",
            "--database", dbPath,
        ])
        _ = try captureStandardOutput {
            try command.run()
        }

        let updated = try XCTUnwrap(repo.fetch(id: prompt.id))
        XCTAssertTrue(updated.isAutoRun)
        XCTAssertEqual(updated.appliesToSources, [.file, .youtube, .podcast])
        XCTAssertFalse(updated.autoRuns(for: .meeting))
        XCTAssertTrue(updated.autoRuns(for: .file))
    }

    // MARK: - Add validation

    func testAddRejectsContentAndFromFileTogether() {
        XCTAssertThrowsError(
            try PromptsCommand.AddSubcommand.parse([
                "--name", "X", "--content", "body", "--from-file", "/tmp/file.txt",
            ])
        )
    }

    func testAddAllowsNeitherSet() {
        // Neither set means "read body from stdin" — parsing must succeed; the
        // empty-body guard runs in run(), not validate().
        XCTAssertNoThrow(try PromptsCommand.AddSubcommand.parse(["--name", "X"]))
    }

    func testAddRejectsEmptyName() {
        XCTAssertThrowsError(
            try PromptsCommand.AddSubcommand.parse(["--name", "   ", "--content", "body"])
        )
    }

    // MARK: - JSON encoder

    func testCLIJSONEncoderEmitsParseableJSON() throws {
        // DatabaseManager() seeds 6 built-in prompts during migration, so we
        // can't assume insertion order — search by name instead of position.
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        try repo.save(Prompt(name: "JSON Test", content: "Body"))

        let prompts = try repo.fetchAll()
        let data = try cliJSONEncoder.encode(prompts)

        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertNotNil(parsed)
        let names = parsed?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("JSON Test"), "Expected 'JSON Test' in encoded names; got: \(names)")
    }
}
