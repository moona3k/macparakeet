import XCTest
import GRDB
@testable import MacParakeetCore

final class PromptRepositoryTests: XCTestCase {
    var repo: PromptRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = PromptRepository(dbQueue: manager.dbQueue)
    }

    func testBuiltInPromptsSeededAfterMigration() throws {
        let prompts = try repo.fetchAll()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(prompts.allSatisfy(\.isVisible))
        XCTAssertEqual(prompts.first?.name, "Concise Summary")
    }

    func testSaveAndFetchCustomPrompt() throws {
        let prompt = Prompt(name: "Standup", content: "Summarize as standup.", sortOrder: 99)
        try repo.save(prompt)

        let fetched = try repo.fetch(id: prompt.id)
        XCTAssertEqual(fetched?.name, "Standup")
        XCTAssertEqual(fetched?.content, "Summarize as standup.")
    }

    func testFetchVisibleFiltersHiddenPrompts() throws {
        let prompt = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Detailed Summary" }))
        try repo.toggleVisibility(id: prompt.id)

        let visible = try repo.fetchVisible(category: .summary)
        XCTAssertFalse(visible.contains(where: { $0.id == prompt.id }))
    }

    func testRestoreDefaultsRevealsBuiltIns() throws {
        let prompt = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Detailed Summary" }))
        try repo.toggleVisibility(id: prompt.id)
        XCTAssertFalse(try repo.fetchVisible(category: .summary).contains(where: { $0.id == prompt.id }))

        try repo.restoreDefaults()

        XCTAssertTrue(try repo.fetchVisible(category: .summary).contains(where: { $0.id == prompt.id }))
    }

    func testNameUniquenessConstraintIsCaseInsensitive() throws {
        let duplicate = Prompt(name: "concise summary", content: "Duplicate")

        XCTAssertThrowsError(try repo.save(duplicate))
    }
}
