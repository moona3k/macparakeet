import XCTest
import GRDB
@testable import MacParakeetCore

final class PromptRepositoryTests: XCTestCase {
    private struct PromptArtifact: Decodable {
        let name: String
        let content: String
        let category: String
        let sortOrder: Int
    }

    var manager: DatabaseManager!
    var repo: PromptRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = PromptRepository(dbQueue: manager.dbQueue)
    }

    func testBuiltInPromptsSeededAfterMigration() throws {
        let prompts = try repo.fetchAll()
        XCTAssertEqual(prompts.count, Prompt.builtInPrompts().count)
        XCTAssertTrue(prompts.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(prompts.allSatisfy(\.isVisible))
        XCTAssertEqual(prompts.first?.name, "Summary")
    }

    func testCommunityPromptArtifactMatchesBuiltInPrompts() throws {
        let artifactURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacParakeetCore/Resources/community-prompts.json")
        let data = try Data(contentsOf: artifactURL)
        let artifactPrompts = try JSONDecoder().decode([PromptArtifact].self, from: data)
        let builtIns = Prompt.builtInPrompts()

        XCTAssertEqual(artifactPrompts.count, builtIns.count)
        XCTAssertEqual(artifactPrompts.map(\.name), builtIns.map(\.name))
        XCTAssertEqual(artifactPrompts.map(\.content), builtIns.map(\.content))
        XCTAssertEqual(artifactPrompts.map(\.category), builtIns.map { $0.category.rawValue })
        XCTAssertEqual(artifactPrompts.map(\.sortOrder), builtIns.map(\.sortOrder))
    }

    func testSaveAndFetchCustomPrompt() throws {
        let prompt = Prompt(name: "Standup", content: "Summarize as standup.", sortOrder: 99)
        try repo.save(prompt)

        let fetched = try repo.fetch(id: prompt.id)
        XCTAssertEqual(fetched?.name, "Standup")
        XCTAssertEqual(fetched?.content, "Summarize as standup.")
    }

    func testFetchVisibleFiltersHiddenPrompts() throws {
        let prompt = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Chapter Breakdown" }))
        try repo.toggleVisibility(id: prompt.id)

        let visible = try repo.fetchVisible(category: .result)
        XCTAssertFalse(visible.contains(where: { $0.id == prompt.id }))
    }

    func testRestoreDefaultsRevealsBuiltIns() throws {
        let prompt = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Chapter Breakdown" }))
        try repo.toggleVisibility(id: prompt.id)
        XCTAssertFalse(try repo.fetchVisible(category: .result).contains(where: { $0.id == prompt.id }))

        try repo.restoreDefaults()

        XCTAssertTrue(try repo.fetchVisible(category: .result).contains(where: { $0.id == prompt.id }))
    }

    func testNameUniquenessConstraintIsCaseInsensitive() throws {
        let duplicate = Prompt(name: "summary", content: "Duplicate")

        XCTAssertThrowsError(try repo.save(duplicate))
    }

    func testBuiltInPromptsReconciledOnReopen() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-reconcile-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let expectedChapter = try XCTUnwrap(
            Prompt.builtInPrompts().first(where: { $0.name == "Chapter Breakdown" })
        )
        let expectedBlog = try XCTUnwrap(
            Prompt.builtInPrompts().first(where: { $0.name == "Blog Post" })
        )

        do {
            let manager = try DatabaseManager(path: dbURL.path)
            try manager.dbQueue.write { db in
                // Simulate a stale built-in with wrong ID and old content
                try db.execute(
                    sql: """
                        UPDATE prompts
                        SET id = ?, content = ?, isVisible = 0
                        WHERE name = ?
                        """,
                    arguments: [
                        UUID().uuidString,
                        "Stale content",
                        "Chapter Breakdown",
                    ]
                )
                // Simulate a deleted built-in
                try db.execute(
                    sql: "DELETE FROM prompts WHERE name = ?",
                    arguments: ["Blog Post"]
                )
            }
        }

        let reopenedManager = try DatabaseManager(path: dbURL.path)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let prompts = try reopenedRepo.fetchAll()

        let chapter = try XCTUnwrap(prompts.first(where: { $0.name == "Chapter Breakdown" }))
        XCTAssertEqual(chapter.id, expectedChapter.id)
        XCTAssertEqual(chapter.content, expectedChapter.content)
        XCTAssertFalse(chapter.isVisible)
        XCTAssertEqual(prompts.count, Prompt.builtInPrompts().count)
        XCTAssertEqual(
            prompts.first(where: { $0.name == "Blog Post" })?.id,
            expectedBlog.id
        )
    }

    func testReconcileDoesNotOverwriteCustomPromptSharingBuiltInName() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-custom-conflict-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let customID = UUID()
        let customContent = "My custom blog format."

        do {
            let manager = try DatabaseManager(path: dbURL.path)
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM prompts WHERE name = ?",
                    arguments: ["Blog Post"]
                )
                try db.execute(
                    sql: """
                        INSERT INTO prompts (
                            id, name, content, category, isBuiltIn, isVisible, isAutoRun, sortOrder, createdAt, updatedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        customID.uuidString,
                        "Blog Post",
                        customContent,
                        Prompt.Category.result.rawValue,
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

        let blogPost = try XCTUnwrap(prompts.first(where: { $0.name == "Blog Post" }))
        XCTAssertEqual(blogPost.id, customID)
        XCTAssertEqual(blogPost.content, customContent)
        XCTAssertFalse(blogPost.isBuiltIn)
        XCTAssertEqual(prompts.filter { $0.name == "Blog Post" }.count, 1)
    }
}
