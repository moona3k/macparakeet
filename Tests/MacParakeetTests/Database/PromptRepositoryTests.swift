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
        XCTAssertEqual(decideShortcut.modifierFlags, [.control, .option])
        XCTAssertEqual(decideShortcut.displayString, "⌃⌥3")
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

    // MARK: - Source-scoped auto-run (ADR-020 2026-05 amendment)

    func testAppliesToSourcesScopesAutoRunQueryBySource() throws {
        // Summary ships auto-run + unscoped (nil = all sources). Round-trips
        // through GRDB's JSON encoding of the Set column.
        let summary = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Summary" }))
        XCTAssertTrue(summary.isAutoRun)
        XCTAssertNil(summary.appliesToSources)

        var actionItems = try XCTUnwrap(
            (try repo.fetchAll()).first(where: { $0.name == "Action Items & Decisions" })
        )
        actionItems.isAutoRun = true
        actionItems.appliesToSources = [.meeting]
        try repo.save(actionItems)

        XCTAssertEqual(
            try XCTUnwrap(repo.fetch(id: actionItems.id)).appliesToSources,
            [.meeting],
            "Set<SourceType> must survive a GRDB save/fetch round-trip."
        )

        let meetingAuto = try repo.fetchAutoRunPrompts(for: .meeting).map(\.name)
        let youtubeAuto = try repo.fetchAutoRunPrompts(for: .youtube).map(\.name)

        XCTAssertTrue(meetingAuto.contains("Summary"))                 // unscoped → all
        XCTAssertTrue(meetingAuto.contains("Action Items & Decisions")) // meeting-scoped
        XCTAssertTrue(youtubeAuto.contains("Summary"))
        XCTAssertFalse(youtubeAuto.contains("Action Items & Decisions")) // not on YouTube
        // The source-agnostic query still returns every auto-run prompt.
        XCTAssertTrue(try repo.fetchAutoRunPrompts().map(\.name).contains("Action Items & Decisions"))
    }

    func testSetAutoRunFromOffScopesToSingleSource() throws {
        let chapter = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Chapter Breakdown" }))
        XCTAssertFalse(chapter.isAutoRun)

        try repo.setAutoRun(id: chapter.id, source: .meeting, enabled: true)

        let reloaded = try XCTUnwrap(try repo.fetch(id: chapter.id))
        XCTAssertTrue(reloaded.isAutoRun)
        XCTAssertTrue(reloaded.isVisible)
        XCTAssertEqual(reloaded.appliesToSources, [.meeting], "Enabling from off must scope to just that source — no leak onto other types.")
        XCTAssertFalse(try repo.fetchAutoRunPrompts(for: .file).contains(where: { $0.id == chapter.id }))
    }

    func testSetAutoRunDisableFromAllNarrowsToOtherSources() throws {
        // Summary is auto-run + unscoped (all). Turning it off for meetings
        // should keep it running for file/YouTube.
        let summary = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Summary" }))

        try repo.setAutoRun(id: summary.id, source: .meeting, enabled: false)

        let reloaded = try XCTUnwrap(try repo.fetch(id: summary.id))
        XCTAssertTrue(reloaded.isAutoRun)
        XCTAssertEqual(reloaded.appliesToSources, [.file, .youtube])
        XCTAssertFalse(reloaded.autoRuns(for: .meeting))
        XCTAssertTrue(reloaded.autoRuns(for: .youtube))
    }

    func testSetAutoRunDisablingLastSourceTurnsAutoRunOff() throws {
        var chapter = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Chapter Breakdown" }))
        chapter.isAutoRun = true
        chapter.appliesToSources = [.meeting]
        try repo.save(chapter)

        try repo.setAutoRun(id: chapter.id, source: .meeting, enabled: false)

        let reloaded = try XCTUnwrap(try repo.fetch(id: chapter.id))
        XCTAssertFalse(reloaded.isAutoRun, "Removing the only scoped source must turn auto-run fully off.")
        XCTAssertNil(reloaded.appliesToSources)
    }

    func testSetAutoRunReEnablingEverySourceNormalizesScopeToNil() throws {
        // Summary ships unscoped (nil = all). Turn it off for meetings, then
        // back on: the scope must collapse back to nil rather than an explicit
        // full set, so a future SourceType case is auto-included.
        let summary = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Summary" }))

        try repo.setAutoRun(id: summary.id, source: .meeting, enabled: false)
        XCTAssertEqual(try XCTUnwrap(repo.fetch(id: summary.id)).appliesToSources, [.file, .youtube])

        try repo.setAutoRun(id: summary.id, source: .meeting, enabled: true)
        let reloaded = try XCTUnwrap(try repo.fetch(id: summary.id))
        XCTAssertNil(reloaded.appliesToSources, "Re-enabling the last missing source must normalize back to nil (all sources).")
        XCTAssertTrue(reloaded.isAutoRun)
    }

    func testGlobalToggleAutoRunResetsScopeToAllSources() throws {
        var chapter = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Chapter Breakdown" }))
        chapter.isAutoRun = true
        chapter.appliesToSources = [.meeting]
        try repo.save(chapter)

        try repo.toggleAutoRun(id: chapter.id) // off
        XCTAssertFalse(try XCTUnwrap(repo.fetch(id: chapter.id)).isAutoRun)
        try repo.toggleAutoRun(id: chapter.id) // on

        let reloaded = try XCTUnwrap(try repo.fetch(id: chapter.id))
        XCTAssertTrue(reloaded.isAutoRun)
        XCTAssertNil(reloaded.appliesToSources, "The global Auto-Run toggle means all sources — re-enabling must clear per-source scoping.")
    }

    func testSetAutoRunAddsSourceToExistingPartialScope() throws {
        // Already auto-run, scoped to file only. Enabling for meeting must union
        // the sets rather than replace — and not normalize away the partial scope.
        var chapter = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Chapter Breakdown" }))
        chapter.isAutoRun = true
        chapter.appliesToSources = [.file]
        try repo.save(chapter)

        try repo.setAutoRun(id: chapter.id, source: .meeting, enabled: true)

        let reloaded = try XCTUnwrap(try repo.fetch(id: chapter.id))
        XCTAssertEqual(reloaded.appliesToSources, [.file, .meeting])
        XCTAssertTrue(reloaded.autoRuns(for: .file))
        XCTAssertTrue(reloaded.autoRuns(for: .meeting))
        XCTAssertFalse(reloaded.autoRuns(for: .youtube))
    }

    func testRestoreDefaultsClearsSourceScoping() throws {
        // A user scopes Summary to meetings only, then hits Restore Defaults.
        // Built-ins ship unscoped, so restore must clear appliesToSources —
        // otherwise Summary comes back "visible" but silently meeting-only.
        let summary = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Summary" }))
        try repo.setAutoRun(id: summary.id, source: .meeting, enabled: false) // → {file, youtube}
        XCTAssertNotNil(try XCTUnwrap(repo.fetch(id: summary.id)).appliesToSources)

        try repo.restoreDefaults()

        let reloaded = try XCTUnwrap(try repo.fetch(id: summary.id))
        XCTAssertNil(reloaded.appliesToSources, "Restore Defaults must return built-ins to their shipped unscoped state.")
        XCTAssertTrue(reloaded.isVisible)
    }

    func testReconcilerPreservesAppliesToSources() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-applies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let first = try DatabaseManager(path: dbPath)
        let firstRepo = PromptRepository(dbQueue: first.dbQueue)
        let summary = try XCTUnwrap((try firstRepo.fetchAll()).first(where: { $0.name == "Summary" }))
        try firstRepo.setAutoRun(id: summary.id, source: .meeting, enabled: false) // → {file, youtube}

        // Fresh boot re-runs the reconciler; the user's scoping must survive.
        let second = try DatabaseManager(path: dbPath)
        let secondRepo = PromptRepository(dbQueue: second.dbQueue)
        let reloaded = try XCTUnwrap(try secondRepo.fetch(id: summary.id))
        XCTAssertEqual(reloaded.appliesToSources, [.file, .youtube], "Reconciler must preserve user source-scoping on built-ins.")
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

    func testReconcilerMigratesLegacyDecideDefaultShortcut() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-decide-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let legacyShortcut = try XCTUnwrap(KeyboardShortcut.parse("opt+3"))

        do {
            let manager = try DatabaseManager(path: dbPath)
            let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
            var decide = try XCTUnwrap(
                (try promptRepo.fetchVisible(category: .transform))
                    .first(where: { $0.name == "Decide" })
            )
            decide.keyboardShortcut = legacyShortcut.encodedString()
            try promptRepo.save(decide)
        }

        let reopenedManager = try DatabaseManager(path: dbPath)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let reloaded = try XCTUnwrap(
            (try reopenedRepo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Decide" })
        )

        XCTAssertEqual(reloaded.shortcut?.displayString, "⌃⌥3")
    }

    func testReconcilerPreservesCustomDecideShortcut() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-decide-custom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        do {
            let manager = try DatabaseManager(path: dbPath)
            let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
            var decide = try XCTUnwrap(
                (try promptRepo.fetchVisible(category: .transform))
                    .first(where: { $0.name == "Decide" })
            )
            decide.keyboardShortcut = KeyboardShortcut.parse("opt+4")!.encodedString()
            try promptRepo.save(decide)
        }

        let reopenedManager = try DatabaseManager(path: dbPath)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let reloaded = try XCTUnwrap(
            (try reopenedRepo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Decide" })
        )

        XCTAssertEqual(reloaded.shortcut?.displayString, "⌥4")
    }

    func testReconcilerPreservesClearedDecideShortcut() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-decide-cleared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        do {
            let manager = try DatabaseManager(path: dbPath)
            let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
            var decide = try XCTUnwrap(
                (try promptRepo.fetchVisible(category: .transform))
                    .first(where: { $0.name == "Decide" })
            )
            decide.keyboardShortcut = nil
            try promptRepo.save(decide)
        }

        let reopenedManager = try DatabaseManager(path: dbPath)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let reloaded = try XCTUnwrap(
            (try reopenedRepo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Decide" })
        )

        XCTAssertNil(reloaded.shortcut)
    }

    func testReconcilerClearsLegacyDecideShortcutWhenNewDefaultIsAlreadyUsed() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-decide-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        do {
            let manager = try DatabaseManager(path: dbPath)
            let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
            var decide = try XCTUnwrap(
                (try promptRepo.fetchVisible(category: .transform))
                    .first(where: { $0.name == "Decide" })
            )
            decide.keyboardShortcut = KeyboardShortcut.parse("opt+3")!.encodedString()
            try promptRepo.save(decide)

            try promptRepo.save(Prompt(
                name: "Personal Decide",
                content: "Use my decision template.",
                category: .transform,
                isBuiltIn: false,
                sortOrder: 200,
                keyboardShortcut: KeyboardShortcut.parse("ctrl+opt+3")!.encodedString()
            ))
        }

        let reopenedManager = try DatabaseManager(path: dbPath)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let transforms = try reopenedRepo.fetchVisible(category: .transform)
        let decide = try XCTUnwrap(transforms.first(where: { $0.name == "Decide" }))
        let custom = try XCTUnwrap(transforms.first(where: { $0.name == "Personal Decide" }))

        XCTAssertNil(decide.shortcut)
        XCTAssertEqual(custom.shortcut?.displayString, "⌃⌥3")
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
