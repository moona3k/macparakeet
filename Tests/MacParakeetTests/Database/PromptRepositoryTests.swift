import XCTest
import GRDB
@testable import MacParakeetCore

final class PromptRepositoryTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: PromptRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = PromptRepository(dbQueue: manager.dbQueue)
    }

    func testBuiltInPromptsSeededAfterMigration() throws {
        let prompts = try repo.fetchAll()
        XCTAssertEqual(prompts.count, 7)
        XCTAssertTrue(prompts.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(prompts.allSatisfy(\.isVisible))
        XCTAssertEqual(prompts.first?.name, "General Summary")
    }

    func testSaveAndFetchCustomPrompt() throws {
        let prompt = Prompt(name: "Standup", content: "Summarize as standup.", sortOrder: 99)
        try repo.save(prompt)

        let fetched = try repo.fetch(id: prompt.id)
        XCTAssertEqual(fetched?.name, "Standup")
        XCTAssertEqual(fetched?.content, "Summarize as standup.")
    }

    func testFetchVisibleFiltersHiddenPrompts() throws {
        let prompt = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Meeting Notes" }))
        try repo.toggleVisibility(id: prompt.id)

        let visible = try repo.fetchVisible(category: .summary)
        XCTAssertFalse(visible.contains(where: { $0.id == prompt.id }))
    }

    func testRestoreDefaultsRevealsBuiltIns() throws {
        let prompt = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Meeting Notes" }))
        try repo.toggleVisibility(id: prompt.id)
        XCTAssertFalse(try repo.fetchVisible(category: .summary).contains(where: { $0.id == prompt.id }))

        try repo.restoreDefaults()

        XCTAssertTrue(try repo.fetchVisible(category: .summary).contains(where: { $0.id == prompt.id }))
    }

    func testNameUniquenessConstraintIsCaseInsensitive() throws {
        let duplicate = Prompt(name: "general summary", content: "Duplicate")

        XCTAssertThrowsError(try repo.save(duplicate))
    }

    func testBuiltInPromptsReconciledOnReopen() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-reconcile-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let expectedMeetingNotes = try XCTUnwrap(
            Prompt.builtInPrompts().first(where: { $0.name == "Meeting Notes" })
        )
        let expectedExecutiveBrief = try XCTUnwrap(
            Prompt.builtInPrompts().first(where: { $0.name == "Executive Brief" })
        )

        do {
            let manager = try DatabaseManager(path: dbURL.path)
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE prompts
                        SET id = ?, content = ?, isVisible = 0
                        WHERE name = ?
                        """,
                    arguments: [
                        UUID().uuidString,
                        "Stale content",
                        "Meeting Notes",
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM prompts WHERE name = ?",
                    arguments: ["Executive Brief"]
                )
            }
        }

        let reopenedManager = try DatabaseManager(path: dbURL.path)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let prompts = try reopenedRepo.fetchAll()

        let meetingNotes = try XCTUnwrap(prompts.first(where: { $0.name == "Meeting Notes" }))
        XCTAssertEqual(meetingNotes.id, expectedMeetingNotes.id)
        XCTAssertEqual(meetingNotes.content, expectedMeetingNotes.content)
        XCTAssertFalse(meetingNotes.isVisible)
        XCTAssertEqual(prompts.count, Prompt.builtInPrompts().count)
        XCTAssertEqual(
            prompts.first(where: { $0.name == "Executive Brief" })?.id,
            expectedExecutiveBrief.id
        )
    }

    func testReconcileDoesNotOverwriteCustomPromptSharingBuiltInName() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-custom-conflict-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let customID = UUID()
        let customContent = "My custom executive summary format."

        do {
            let manager = try DatabaseManager(path: dbURL.path)
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM prompts WHERE name = ?",
                    arguments: ["Executive Brief"]
                )
                try db.execute(
                    sql: """
                        INSERT INTO prompts (
                            id, name, content, category, isBuiltIn, isVisible, isAutoRun, sortOrder, createdAt, updatedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        customID.uuidString,
                        "Executive Brief",
                        customContent,
                        Prompt.Category.summary.rawValue,
                        false,
                        true,
                        false,
                        99,
                        Date(),
                        Date(),
                    ]
                )
            }
        }

        let reopenedManager = try DatabaseManager(path: dbURL.path)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let prompts = try reopenedRepo.fetchAll()

        let executiveBrief = try XCTUnwrap(prompts.first(where: { $0.name == "Executive Brief" }))
        XCTAssertEqual(executiveBrief.id, customID)
        XCTAssertEqual(executiveBrief.content, customContent)
        XCTAssertFalse(executiveBrief.isBuiltIn)
        XCTAssertEqual(prompts.filter { $0.name == "Executive Brief" }.count, 1)
    }
}
