import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class VocabCommandTests: XCTestCase {

    private var tempDir: URL!
    private var dbPath: String!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-vocab-cli-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir.appendingPathComponent("test.db").path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Compatibility

    func testVocabCommandKeepsFlowAliasForOneMinorRelease() {
        XCTAssertTrue(
            CLI.configuration.subcommands.contains { $0 == VocabCommand.self },
            "vocab must be available from macparakeet-cli"
        )
        XCTAssertTrue(
            VocabCommand.configuration.aliases.contains("flow"),
            "flow must remain as a deprecated alias for the 2.x compatibility window"
        )
        XCTAssertTrue(
            VocabCommand.configuration.discussion.contains("deprecated alias"),
            "the alias needs a visible --help deprecation notice"
        )
        XCTAssertTrue(
            VocabCommand.configuration.subcommands.contains { $0 == VocabLegacyVocabularyCommand.self },
            "flow vocabulary must remain parseable for the 2.x compatibility window"
        )
    }

    func testFlowAliasParsesLegacyWordsPath() throws {
        let cmd = try CLI.parseAsRoot([
            "flow", "words", "list",
            "--database", dbPath,
            "--json",
        ])
        let list = try XCTUnwrap(cmd as? VocabWordsCommand.ListWords)
        XCTAssertEqual(list.database, dbPath)
        XCTAssertTrue(list.json)
    }

    func testFlowAliasParsesFlattenedExportPath() throws {
        let outputPath = tempDir.appendingPathComponent("bundle.json").path
        let cmd = try CLI.parseAsRoot([
            "flow", "export",
            "--database", dbPath,
            "--output", outputPath,
        ])
        let export = try XCTUnwrap(cmd as? VocabExportCommand)
        XCTAssertEqual(export.database, dbPath)
        XCTAssertEqual(export.output, outputPath)
    }

    func testFlowAliasParsesLegacyVocabularyExportPath() throws {
        let outputPath = tempDir.appendingPathComponent("legacy-bundle.json").path
        let cmd = try CLI.parseAsRoot([
            "flow", "vocabulary", "export",
            "--database", dbPath,
            "--output", outputPath,
        ])
        let export = try XCTUnwrap(cmd as? VocabExportCommand)
        XCTAssertEqual(export.database, dbPath)
        XCTAssertEqual(export.output, outputPath)
    }

    func testFlowAliasParsesLegacyVocabularyImportPath() throws {
        let inputPath = tempDir.appendingPathComponent("legacy-bundle.json").path
        let cmd = try CLI.parseAsRoot([
            "flow", "vocabulary", "import",
            "--database", dbPath,
            "--input", inputPath,
            "--dry-run",
            "--json",
        ])
        let importCommand = try XCTUnwrap(cmd as? VocabImportCommand)
        XCTAssertEqual(importCommand.database, dbPath)
        XCTAssertEqual(importCommand.input, inputPath)
        XCTAssertTrue(importCommand.dryRun)
        XCTAssertTrue(importCommand.json)
    }

    func testFlowAliasParsesLegacyVocabularySchemaPath() throws {
        let cmd = try CLI.parseAsRoot(["flow", "vocabulary", "schema", "--json"])
        let schema = try XCTUnwrap(cmd as? VocabSchemaCommand)
        XCTAssertTrue(schema.json)
    }

    func testVocabWordsRecognitionBoostingStatusLineUsesCapabilityRegistry() {
        let suiteName = "macparakeet-vocab-cli-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        SpeechEnginePreference.parakeet.save(to: defaults)
        SpeechEnginePreference.saveParakeetModelVariant(.v3, defaults: defaults)
        XCTAssertTrue(
            VocabWordsCommand.recognitionBoostingStatusLine(defaults: defaults)
                .contains("Recognition boosting on")
        )

        SpeechEnginePreference.saveParakeetModelVariant(.unified, defaults: defaults)
        let unifiedLine = VocabWordsCommand.recognitionBoostingStatusLine(defaults: defaults)
        XCTAssertTrue(unifiedLine.contains("Clean corrections only"))
        XCTAssertTrue(unifiedLine.contains("Parakeet English (Unified)"))

        SpeechEnginePreference.cohere.save(to: defaults)
        let cohereLine = VocabWordsCommand.recognitionBoostingStatusLine(defaults: defaults)
        XCTAssertTrue(cohereLine.contains("Clean corrections only"))
        XCTAssertTrue(cohereLine.contains("Cohere"))
    }

    func testVocabWordsListDisplaysBlankReplacementAsAnchor() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = CustomWordRepository(dbQueue: manager.dbQueue)
        let word = CustomWord(word: "MacParakeet", replacement: "  ")
        try repo.save(word)

        let cmd = try VocabWordsCommand.ListWords.parse([
            "--database", dbPath,
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }

        XCTAssertTrue(output.contains("[+] MacParakeet (anchor)"))
        XCTAssertFalse(output.contains("MacParakeet ->"))
    }

    func testVocabWordsSetTogglesEnabledState() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = CustomWordRepository(dbQueue: manager.dbQueue)
        let word = CustomWord(word: "k8s", replacement: "Kubernetes", isEnabled: true)
        try repo.save(word)

        let cmd = try VocabWordsCommand.SetWord.parse([
            String(word.id.uuidString.prefix(8)),
            "--disabled",
            "--database", dbPath,
            "--json",
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        let updated = try XCTUnwrap(try repo.fetch(id: word.id))
        XCTAssertFalse(updated.isEnabled)
        XCTAssertGreaterThan(updated.updatedAt, word.updatedAt)
    }

    func testVocabWordsSetRequiresOneStateFlag() {
        XCTAssertThrowsError(try VocabWordsCommand.SetWord.parse(["abcd"]))
        XCTAssertThrowsError(try VocabWordsCommand.SetWord.parse(["abcd", "--enabled", "--disabled"]))
    }

    func testVocabSnippetsEditNoopWithJSONEmitsFailureEnvelope() async throws {
        let cmd = try VocabSnippetsCommand.EditSnippet.parse([
            "abcd",
            "--database", dbPath,
            "--json",
        ])

        var thrownError: Error?
        let output = try await capturingStdout {
            do {
                try await cmd.run()
            } catch {
                thrownError = error
            }
        }

        let error = try XCTUnwrap(thrownError)
        XCTAssertTrue(error is CLIJSONEnvelopeExit)
        XCTAssertEqual(CLI.normalizedExitCode(for: error), cliValidationMisuseExitCode)

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, false)
        XCTAssertEqual(decoded["errorType"] as? String, "validation")
        XCTAssertTrue((decoded["error"] as? String)?.contains("--trigger") == true)
    }

    func testVocabSnippetsEditUpdatesExistingSnippet() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = TextSnippetRepository(dbQueue: manager.dbQueue)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snippet = TextSnippet(
            trigger: "my sig",
            expansion: "Original",
            isEnabled: false,
            useCount: 4,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try repo.save(snippet)

        let cmd = try VocabSnippetsCommand.EditSnippet.parse([
            String(snippet.id.uuidString.prefix(8)),
            "--trigger", "my signature",
            "--expansion", "Best regards\\nDaniel",
            "--database", dbPath,
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }

        let updated = try XCTUnwrap(try repo.fetch(id: snippet.id))
        XCTAssertTrue(output.contains("Updated: Say \"my signature\""))
        XCTAssertEqual(updated.id, snippet.id)
        XCTAssertEqual(updated.trigger, "my signature")
        XCTAssertEqual(updated.expansion, "Best regards\nDaniel")
        XCTAssertEqual(updated.isEnabled, false)
        XCTAssertEqual(updated.useCount, 4)
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertGreaterThan(updated.updatedAt, createdAt)
    }

    func testVocabSnippetsEditCanToggleEnabledOnly() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = TextSnippetRepository(dbQueue: manager.dbQueue)
        let snippet = TextSnippet(trigger: "my sig", expansion: "Original", isEnabled: false)
        try repo.save(snippet)

        let cmd = try VocabSnippetsCommand.EditSnippet.parse([
            String(snippet.id.uuidString.prefix(8)),
            "--enabled",
            "--database", dbPath,
            "--json",
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        let updated = try XCTUnwrap(try repo.fetch(id: snippet.id))
        XCTAssertTrue(updated.isEnabled)
        XCTAssertEqual(updated.trigger, "my sig")
        XCTAssertEqual(updated.expansion, "Original")
    }

    func testVocabSnippetsEditRejectsContradictoryEnabledFlags() {
        XCTAssertThrowsError(
            try VocabSnippetsCommand.EditSnippet.parse(["abcd", "--enabled", "--disabled"])
        )
    }

    func testVocabSnippetsEditRejectsShortIDPrefix() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = TextSnippetRepository(dbQueue: manager.dbQueue)
        let snippet = TextSnippet(trigger: "my sig", expansion: "Original")
        try repo.save(snippet)

        let cmd = try VocabSnippetsCommand.EditSnippet.parse([
            String(snippet.id.uuidString.prefix(3)),
            "--expansion", "Updated",
            "--database", dbPath,
        ])

        do {
            try await cmd.run()
            XCTFail("Expected short ID prefix to be rejected")
        } catch is ValidationError {
            // Expected.
        } catch {
            XCTFail("Expected ValidationError, got \(type(of: error))")
        }
    }

    func testVocabWordsDeleteJSONReportsDeletedID() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = CustomWordRepository(dbQueue: manager.dbQueue)
        let word = CustomWord(word: "k8s", replacement: "Kubernetes")
        try repo.save(word)

        let cmd = try VocabWordsCommand.DeleteWord.parse([
            String(word.id.uuidString.prefix(8)),
            "--database", dbPath,
            "--json",
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        XCTAssertEqual(decoded["id"] as? String, word.id.uuidString)
        XCTAssertEqual(decoded["label"] as? String, "k8s")
        XCTAssertNil(try repo.fetch(id: word.id))
    }

    func testVocabSnippetsDeleteRejectsShortPrefix() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = TextSnippetRepository(dbQueue: manager.dbQueue)
        let snippet = TextSnippet(
            id: try XCTUnwrap(UUID(uuidString: "a1111111-1111-1111-1111-111111111111")),
            trigger: "my sig",
            expansion: "Original"
        )
        let other = TextSnippet(
            id: try XCTUnwrap(UUID(uuidString: "b2222222-2222-2222-2222-222222222222")),
            trigger: "my address",
            expansion: "123 Main"
        )
        try repo.save(snippet)
        try repo.save(other)

        let cmd = try VocabSnippetsCommand.DeleteSnippet.parse([
            "a",
            "--database", dbPath,
        ])

        do {
            try await cmd.run()
            XCTFail("Expected short ID prefix to be rejected")
        } catch is ValidationError {
            // Expected.
        } catch {
            XCTFail("Expected ValidationError, got \(type(of: error))")
        }

        XCTAssertNotNil(try repo.fetch(id: snippet.id))
        XCTAssertNotNil(try repo.fetch(id: other.id))
    }

    func testVocabSnippetsDeleteJSONReportsDeletedID() async throws {
        let manager = try DatabaseManager(path: dbPath)
        let repo = TextSnippetRepository(dbQueue: manager.dbQueue)
        let snippet = TextSnippet(trigger: "my sig", expansion: "Original")
        try repo.save(snippet)

        let cmd = try VocabSnippetsCommand.DeleteSnippet.parse([
            String(snippet.id.uuidString.prefix(8)),
            "--database", dbPath,
            "--json",
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        XCTAssertEqual(decoded["id"] as? String, snippet.id.uuidString)
        XCTAssertEqual(decoded["label"] as? String, "my sig")
        XCTAssertNil(try repo.fetch(id: snippet.id))
    }

    // MARK: - Schema

    func testSchemaJSONIsParseable() async throws {
        let cmd = try VocabSchemaCommand.parse(["--json"])
        let output = try await capturingStdout {
            try await cmd.run()
        }
        let data = Data(output.utf8)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["schema"] as? String, VocabularyBundle.schemaIdentifier)
        XCTAssertEqual(decoded["version"] as? Int, VocabularyBundle.currentVersion)
        XCTAssertNotNil(decoded["fields"] as? [Any])
        XCTAssertNotNil(decoded["example"] as? [String: Any])
    }

    func testSchemaHumanIncludesExampleAndFieldNames() async throws {
        let cmd = try VocabSchemaCommand.parse([])
        let output = try await capturingStdout {
            try await cmd.run()
        }
        XCTAssertTrue(output.contains("MacParakeet Vocabulary Bundle"))
        XCTAssertTrue(output.contains("customWords"))
        XCTAssertTrue(output.contains("textSnippets"))
        XCTAssertTrue(output.contains(VocabularyBundle.schemaIdentifier))
    }

    // MARK: - Export

    func testExportToFileWritesValidBundle() async throws {
        try seedDatabase(words: [("kubernetes", "Kubernetes")], snippets: [("addr", "123 Main St")])

        let outPath = tempDir.appendingPathComponent("out.json").path
        let cmd = try VocabExportCommand.parse([
            "--database", dbPath,
            "--output", outPath
        ])
        try await cmd.run()

        let data = try Data(contentsOf: URL(fileURLWithPath: outPath))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["schema"] as? String, VocabularyBundle.schemaIdentifier)
        XCTAssertEqual((decoded["customWords"] as? [Any])?.count, 1)
        XCTAssertEqual((decoded["textSnippets"] as? [Any])?.count, 1)
    }

    // MARK: - Import (dry-run JSON)

    func testImportDryRunJSONReportsConflicts() async throws {
        try seedDatabase(words: [("kubernetes", "Kubernetes")], snippets: [])

        let bundlePath = tempDir.appendingPathComponent("bundle.json").path
        try writeBundle(
            to: bundlePath,
            customWords: [
                .init(word: "Kubernetes", replacement: "Override", isEnabled: true, createdAt: nil),
                .init(word: "fresh", replacement: nil, isEnabled: true, createdAt: nil),
            ],
            textSnippets: []
        )

        let cmd = try VocabImportCommand.parse([
            "--database", dbPath,
            "--input", bundlePath,
            "--dry-run",
            "--json",
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }

        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        XCTAssertEqual(decoded["wordsTotal"] as? Int, 2)
        XCTAssertEqual(decoded["snippetsTotal"] as? Int, 0)
        XCTAssertEqual((decoded["wordConflicts"] as? [String])?.count, 1)
    }

    func testImportApplyJSONReturnsCounts() async throws {
        try seedDatabase(words: [], snippets: [])

        let bundlePath = tempDir.appendingPathComponent("bundle.json").path
        try writeBundle(
            to: bundlePath,
            customWords: [
                .init(word: "kubernetes", replacement: "Kubernetes", isEnabled: true, createdAt: nil)
            ],
            textSnippets: [
                .init(trigger: "addr", expansion: "123 Main", isEnabled: true, action: nil, createdAt: nil)
            ]
        )

        let cmd = try VocabImportCommand.parse([
            "--database", dbPath,
            "--input", bundlePath,
            "--json"
        ])
        let output = try await capturingStdout {
            try await cmd.run()
        }
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["wordsAdded"] as? Int, 1)
        XCTAssertEqual(decoded["snippetsAdded"] as? Int, 1)
        XCTAssertEqual(decoded["wordsSkipped"] as? Int, 0)
    }

    func testImportInvalidSchemaThrows() async throws {
        let bundlePath = tempDir.appendingPathComponent("bad.json").path
        try Data(#"{"schema":"not.us","version":1,"exportedAt":"2026-04-28T12:00:00Z","customWords":[],"textSnippets":[]}"#.utf8)
            .write(to: URL(fileURLWithPath: bundlePath))

        let cmd = try VocabImportCommand.parse([
            "--database", dbPath,
            "--input", bundlePath,
        ])
        do {
            try await cmd.run()
            XCTFail("expected import to throw on invalid schema")
        } catch {
            // Expected — invalid schema rejected.
        }
    }

    // MARK: - Helpers

    private func seedDatabase(
        words: [(String, String?)],
        snippets: [(String, String)]
    ) throws {
        let manager = try DatabaseManager(path: dbPath)
        let wordRepo = CustomWordRepository(dbQueue: manager.dbQueue)
        let snippetRepo = TextSnippetRepository(dbQueue: manager.dbQueue)
        for (word, replacement) in words {
            try wordRepo.save(CustomWord(word: word, replacement: replacement))
        }
        for (trigger, expansion) in snippets {
            try snippetRepo.save(TextSnippet(trigger: trigger, expansion: expansion))
        }
    }

    private func writeBundle(
        to path: String,
        customWords: [VocabularyBundle.ExportedCustomWord],
        textSnippets: [VocabularyBundle.ExportedTextSnippet]
    ) throws {
        let bundle = VocabularyBundle(
            exportedAt: Date(timeIntervalSince1970: 1_745_000_000),
            appVersion: "test",
            customWords: customWords,
            textSnippets: textSnippets
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func capturingStdout(_ body: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        defer { close(saved) }
        guard saved >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0
        else {
            XCTFail("failed to redirect stdout")
            return ""
        }

        var thrown: Error?
        do { try await body() } catch { thrown = error }

        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let captured = String(decoding: data, as: UTF8.self)
        if let thrown { throw thrown }
        return captured
    }
}
