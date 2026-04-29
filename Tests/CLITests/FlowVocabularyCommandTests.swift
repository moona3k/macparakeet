import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class FlowVocabularyCommandTests: XCTestCase {

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

    // MARK: - Schema

    func testSchemaJSONIsParseable() async throws {
        let cmd = try FlowVocabularyCommand.VocabularySchema.parse(["--json"])
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
        let cmd = try FlowVocabularyCommand.VocabularySchema.parse([])
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
        let cmd = try FlowVocabularyCommand.ExportVocabulary.parse([
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

        let cmd = try FlowVocabularyCommand.ImportVocabulary.parse([
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

        let cmd = try FlowVocabularyCommand.ImportVocabulary.parse([
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

        let cmd = try FlowVocabularyCommand.ImportVocabulary.parse([
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

    /// Async stdout capture that rethrows the body's error so callers can
    /// inspect the captured output via try/catch.
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
        // CLI stdout is expected to be UTF-8; non-failable decoding keeps
        // test output available if it is not.
        let captured = String(decoding: data, as: UTF8.self)
        if let thrown { throw thrown }
        return captured
    }
}
