import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class PromptsCommandTests: XCTestCase {

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

    func testFindPromptByNameCaseInsensitive() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)
        let p = Prompt(name: "My Special Prompt", content: "Hello")
        try repo.save(p)

        let found = try findPrompt(idOrName: "my special prompt", repo: repo)
        XCTAssertEqual(found.id, p.id)
    }

    func testFindPromptThrowsNotFoundForBogusInput() throws {
        let db = try DatabaseManager()
        let repo = PromptRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findPrompt(idOrName: "nonexistent-prompt-name", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {} else {
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
            if case .emptyID = lookupError {} else {
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
            if case .ambiguous = lookupError {} else {
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

    // MARK: - Set validation
    // .parse() runs validate() automatically, so a failed parse with our error
    // text proves validate() rejected it.

    func testSetRejectsContradictoryHiddenAndAutoRun() {
        XCTAssertThrowsError(
            try PromptsCommand.SetSubcommand.parse(["anything", "--hidden", "--auto-run"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("auto-run requires visible"),
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

    // MARK: - Add validation

    func testAddRejectsContentAndFromFileTogether() {
        XCTAssertThrowsError(
            try PromptsCommand.AddSubcommand.parse([
                "--name", "X", "--content", "body", "--from-file", "/tmp/file.txt"
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
