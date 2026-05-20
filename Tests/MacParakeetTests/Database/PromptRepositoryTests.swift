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
        // After ADR-020's 2026-05-02 amendment removed "Memo-Steered Notes",
        // "Summary" is the sortOrder=0 default and the first prompt returned.
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
        // The community-prompts artifact is the curated set of `.result`
        // (transcript-summary) prompts. `.transform` built-ins (ADR-022) are
        // shipped UX, not community content, and are intentionally not
        // included.
        let builtIns = Prompt.builtInPrompts().filter { $0.category == .result }

        XCTAssertEqual(artifactPrompts.count, builtIns.count)
        XCTAssertEqual(artifactPrompts.map(\.name), builtIns.map(\.name))
        XCTAssertEqual(artifactPrompts.map(\.content), builtIns.map(\.content))
        XCTAssertEqual(artifactPrompts.map(\.category), builtIns.map { $0.category.rawValue })
        XCTAssertEqual(artifactPrompts.map(\.sortOrder), builtIns.map(\.sortOrder))
    }

    func testBuiltInTransformsSeededWithDefaultShortcuts() throws {
        let transforms = try repo.fetchVisible(category: .transform)
            .sorted(by: { $0.sortOrder < $1.sortOrder })

        XCTAssertEqual(transforms.count, 3, "Phase 2 ships exactly three built-in Transforms: Polish, Distill, Decide.")
        XCTAssertEqual(transforms.map(\.name), ["Polish", "Distill", "Decide"])

        let polish = transforms[0]
        XCTAssertTrue(polish.isBuiltIn)
        XCTAssertEqual(polish.category, .transform)
        XCTAssertEqual(polish.runningLabel, "Polishing…")
        let polishShortcut = try XCTUnwrap(polish.shortcut)
        XCTAssertEqual(polishShortcut.keyLabel, "1")
        XCTAssertEqual(polishShortcut.modifierFlags, [.option])

        let distill = transforms[1]
        XCTAssertEqual(distill.runningLabel, "Distilling…")
        let distillShortcut = try XCTUnwrap(distill.shortcut)
        XCTAssertEqual(distillShortcut.keyLabel, "2")
        XCTAssertEqual(distillShortcut.modifierFlags, [.option])

        let decide = transforms[2]
        XCTAssertEqual(decide.runningLabel, "Deciding…")
        let decideShortcut = try XCTUnwrap(decide.shortcut)
        XCTAssertEqual(decideShortcut.keyLabel, "3")
        XCTAssertEqual(decideShortcut.modifierFlags, [.option])
    }

    func testDefaultRunningLabelFallsBackForAwkwardNames() {
        XCTAssertEqual(Prompt.defaultRunningLabel(forName: "Polish"), "Polishing…")
        XCTAssertEqual(Prompt.defaultRunningLabel(forName: "Make concise"), "Transforming…")
        XCTAssertEqual(Prompt.defaultRunningLabel(forName: "Already polishing"), "Transforming…")
        XCTAssertEqual(Prompt.defaultRunningLabel(forName: " \n "), "Transforming…")
    }

    func testFetchAutoRunPromptsIgnoresTransformPrompts() throws {
        var polish = try XCTUnwrap(
            (try repo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )
        polish.isAutoRun = true
        polish.updatedAt = Date()
        try repo.save(polish)

        let autoRun = try repo.fetchAutoRunPrompts()

        XCTAssertTrue(autoRun.allSatisfy { $0.category == .result })
        XCTAssertFalse(autoRun.contains(where: { $0.id == polish.id }))
    }

    func testToggleAutoRunIgnoresTransformPrompts() throws {
        let polish = try XCTUnwrap(
            (try repo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )

        try repo.toggleAutoRun(id: polish.id)

        let reloaded = try XCTUnwrap(try repo.fetch(id: polish.id))
        XCTAssertFalse(reloaded.isAutoRun)
    }

    func testReconcilerPreservesUserCustomizedBuiltInTransformFields() throws {
        // User customizes Polish. A subsequent app
        // launch (simulated by re-running the reconciler via a fresh
        // DatabaseManager on the same file-backed DB) must NOT overwrite
        // the user's fields back to the shipped defaults.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-transform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let first = try DatabaseManager(path: dbPath)
        let firstRepo = PromptRepository(dbQueue: first.dbQueue)
        var polish = try XCTUnwrap(
            (try firstRepo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )

        let customShortcut = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue,
            keyCode: 0x23, // kVK_ANSI_P
            keyLabel: "P"
        )
        polish.name = "Personal Polish"
        polish.content = "Rewrite this in my house style."
        polish.isAutoRun = true
        let editDate = Date(timeIntervalSince1970: 1_234_567)
        polish.keyboardShortcut = customShortcut.encodedString()
        polish.runningLabel = "Refining…"
        polish.updatedAt = editDate
        try firstRepo.save(polish)

        // Simulate a fresh boot — reconciler runs again. The user's
        // customizations must survive.
        let second = try DatabaseManager(path: dbPath)
        let secondRepo = PromptRepository(dbQueue: second.dbQueue)
        let reloaded = try XCTUnwrap(try secondRepo.fetch(id: polish.id))

        XCTAssertEqual(reloaded.name, "Personal Polish", "Reconciler must not overwrite user-set Transform names.")
        XCTAssertEqual(reloaded.content, "Rewrite this in my house style.", "Reconciler must not overwrite user-set Transform prompt bodies.")
        XCTAssertEqual(reloaded.updatedAt.timeIntervalSince1970, editDate.timeIntervalSince1970, accuracy: 0.001, "Reconciler must not overwrite the user's Transform edit timestamp.")
        XCTAssertFalse(reloaded.isAutoRun, "Built-in Transforms must not keep leaked auto-run state.")
        XCTAssertEqual(reloaded.shortcut?.keyLabel, "P", "Reconciler must not overwrite user-set Transform shortcuts.")
        XCTAssertEqual(reloaded.shortcut?.modifierFlags, [.option, .shift])
        XCTAssertEqual(reloaded.runningLabel, "Refining…", "Reconciler must not overwrite user-set running labels.")
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
