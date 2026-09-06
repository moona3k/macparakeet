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
        XCTAssertEqual(polishShortcut.modifierFlags, [.control, .option])
        XCTAssertEqual(polishShortcut.displayString, "⌃⌥1")

        let distill = transforms[1]
        XCTAssertEqual(distill.runningLabel, "Distilling…")
        let distillShortcut = try XCTUnwrap(distill.shortcut)
        XCTAssertEqual(distillShortcut.keyLabel, "2")
        XCTAssertEqual(distillShortcut.modifierFlags, [.control, .option])
        XCTAssertEqual(distillShortcut.displayString, "⌃⌥2")

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

    func testInferenceSettingsRoundTripAndDefaultNormalization() throws {
        var prompt = Prompt(
            name: "Configured Summary",
            content: "Summarize this.",
            inferenceSettings: PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .enabled,
                reasoningEffort: .xhigh
            )
        )
        try repo.save(prompt)

        XCTAssertEqual(try repo.fetch(id: prompt.id)?.inferenceSettings, prompt.inferenceSettings)

        // Exercise repository-boundary normalization after mutation, rather
        // than relying only on the model initializer.
        prompt.inferenceSettings = PromptInferenceSettings()
        try repo.save(prompt)
        XCTAssertNil(try repo.fetch(id: prompt.id)?.inferenceSettings)

        let storedJSON = try manager.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT v.inferenceSettings
                    FROM prompt_versions v
                    JOIN prompts p ON p.activeVersionId = v.id
                    WHERE p.id = ?
                    """,
                arguments: [prompt.id]
            )
        }
        XCTAssertNil(storedJSON)

        XCTAssertEqual(
            try PromptVersionRepository(dbQueue: manager.dbQueue)
                .fetchAll(promptId: prompt.id).count,
            2,
            "Clearing configured settings creates one new immutable version."
        )
    }

    func testIncludeMeetingNotesRoundTripsAndCanBeUpdatedAtomically() throws {
        let prompt = Prompt(
            name: "Meeting Decisions",
            content: "Summarize.",
            includeMeetingNotes: true
        )
        try repo.save(prompt)
        XCTAssertEqual(try repo.fetch(id: prompt.id)?.includeMeetingNotes, true)

        try repo.setIncludeMeetingNotes(id: prompt.id, enabled: false)
        XCTAssertEqual(try repo.fetch(id: prompt.id)?.includeMeetingNotes, false)
    }

    func testTransformPromptsCannotEnableMeetingNotesContext() throws {
        var polish = try XCTUnwrap(
            (try repo.fetchVisible(category: .transform)).first(where: { $0.name == "Polish" })
        )
        polish.includeMeetingNotes = true
        try repo.save(polish)
        XCTAssertEqual(try repo.fetch(id: polish.id)?.includeMeetingNotes, false)

        try repo.setIncludeMeetingNotes(id: polish.id, enabled: true)
        XCTAssertEqual(try repo.fetch(id: polish.id)?.includeMeetingNotes, false)
    }

    func testMalformedInferenceSettingsIsAVisibleFetchError() throws {
        let prompt = Prompt(name: "Malformed Settings", content: "Summarize this.")
        try repo.save(prompt)
        try manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE prompt_versions SET inferenceSettings = ?
                    WHERE id = (SELECT activeVersionId FROM prompts WHERE id = ?)
                    """,
                arguments: ["{not-json", prompt.id]
            )
        }

        XCTAssertThrowsError(try repo.fetch(id: prompt.id))
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

        XCTAssertTrue(meetingAuto.contains("Summary"))  // unscoped → all
        XCTAssertTrue(meetingAuto.contains("Action Items & Decisions"))  // meeting-scoped
        XCTAssertTrue(youtubeAuto.contains("Summary"))
        XCTAssertFalse(youtubeAuto.contains("Action Items & Decisions"))  // not on YouTube
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
        XCTAssertEqual(
            reloaded.appliesToSources, [.meeting],
            "Enabling from off must scope to just that source — no leak onto other types.")
        XCTAssertFalse(try repo.fetchAutoRunPrompts(for: .file).contains(where: { $0.id == chapter.id }))
    }

    func testSetAutoRunDisableFromAllNarrowsToOtherSources() throws {
        // Summary is auto-run + unscoped (all). Turning it off for meetings
        // should keep it running for every other transcription source.
        let summary = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Summary" }))

        try repo.setAutoRun(id: summary.id, source: .meeting, enabled: false)

        let reloaded = try XCTUnwrap(try repo.fetch(id: summary.id))
        XCTAssertTrue(reloaded.isAutoRun)
        XCTAssertEqual(reloaded.appliesToSources, [.file, .youtube, .podcast])
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
        XCTAssertEqual(try XCTUnwrap(repo.fetch(id: summary.id)).appliesToSources, [.file, .youtube, .podcast])

        try repo.setAutoRun(id: summary.id, source: .meeting, enabled: true)
        let reloaded = try XCTUnwrap(try repo.fetch(id: summary.id))
        XCTAssertNil(
            reloaded.appliesToSources, "Re-enabling the last missing source must normalize back to nil (all sources).")
        XCTAssertTrue(reloaded.isAutoRun)
    }

    func testGlobalToggleAutoRunResetsScopeToAllSources() throws {
        var chapter = try XCTUnwrap((try repo.fetchAll()).first(where: { $0.name == "Chapter Breakdown" }))
        chapter.isAutoRun = true
        chapter.appliesToSources = [.meeting]
        try repo.save(chapter)

        try repo.toggleAutoRun(id: chapter.id)  // off
        XCTAssertFalse(try XCTUnwrap(repo.fetch(id: chapter.id)).isAutoRun)
        try repo.toggleAutoRun(id: chapter.id)  // on

        let reloaded = try XCTUnwrap(try repo.fetch(id: chapter.id))
        XCTAssertTrue(reloaded.isAutoRun)
        XCTAssertNil(
            reloaded.appliesToSources,
            "The global Auto-Run toggle means all sources — re-enabling must clear per-source scoping.")
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
        try repo.setAutoRun(id: summary.id, source: .meeting, enabled: false)  // -> {file, youtube, podcast}
        XCTAssertNotNil(try XCTUnwrap(repo.fetch(id: summary.id)).appliesToSources)

        try repo.restoreDefaults()

        let reloaded = try XCTUnwrap(try repo.fetch(id: summary.id))
        XCTAssertNil(
            reloaded.appliesToSources, "Restore Defaults must return built-ins to their shipped unscoped state.")
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
        try firstRepo.setAutoRun(id: summary.id, source: .meeting, enabled: false)  // -> {file, youtube, podcast}

        // Fresh boot re-runs the reconciler; the user's scoping must survive.
        let second = try DatabaseManager(path: dbPath)
        let secondRepo = PromptRepository(dbQueue: second.dbQueue)
        let reloaded = try XCTUnwrap(try secondRepo.fetch(id: summary.id))
        XCTAssertEqual(
            reloaded.appliesToSources, [.file, .youtube, .podcast],
            "Reconciler must preserve user source-scoping on built-ins.")
    }

    func testReconcilerPreservesBuiltInInferenceSettings() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-inference-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let first = try DatabaseManager(path: dbPath)
        let firstRepo = PromptRepository(dbQueue: first.dbQueue)
        var summary = try XCTUnwrap(
            (try firstRepo.fetchAll()).first(where: { $0.name == "Summary" })
        )
        summary.inferenceSettings = PromptInferenceSettings(
            temperature: 0.2,
            thinkingMode: .disabled
        )
        try firstRepo.save(summary)

        // A fresh launch updates canonical built-in content but must not clear
        // persisted fields that reconciliation does not own.
        let second = try DatabaseManager(path: dbPath)
        let secondRepo = PromptRepository(dbQueue: second.dbQueue)
        XCTAssertEqual(
            try secondRepo.fetch(id: summary.id)?.inferenceSettings,
            summary.inferenceSettings
        )
    }

    func testReconcilerPreservesBuiltInMeetingNotesPreference() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-meeting-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let first = try DatabaseManager(path: dbPath)
        let firstRepo = PromptRepository(dbQueue: first.dbQueue)
        let summary = try XCTUnwrap(
            (try firstRepo.fetchAll()).first(where: { $0.name == "Summary" })
        )
        try firstRepo.setIncludeMeetingNotes(id: summary.id, enabled: true)

        let second = try DatabaseManager(path: dbPath)
        let secondRepo = PromptRepository(dbQueue: second.dbQueue)
        XCTAssertEqual(try secondRepo.fetch(id: summary.id)?.includeMeetingNotes, true)
    }

    func testReconcilerPreservesLegacyPartialAppliesToSources() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-legacy-applies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let first = try DatabaseManager(path: dbPath)
        let firstRepo = PromptRepository(dbQueue: first.dbQueue)
        var summary = try XCTUnwrap((try firstRepo.fetchAll()).first(where: { $0.name == "Summary" }))
        summary.appliesToSources = [.file, .youtube]
        try firstRepo.save(summary)

        // A pre-podcast explicit file/YouTube scope is user intent, not an old
        // spelling of "all"; reconciliation must not widen it to podcasts.
        let second = try DatabaseManager(path: dbPath)
        let secondRepo = PromptRepository(dbQueue: second.dbQueue)
        let reloaded = try XCTUnwrap(try secondRepo.fetch(id: summary.id))
        XCTAssertEqual(reloaded.appliesToSources, [.file, .youtube])
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
            keyCode: 0x23,  // kVK_ANSI_P
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
        XCTAssertEqual(
            reloaded.content, "Rewrite this in my house style.",
            "Reconciler must not overwrite user-set Transform prompt bodies.")
        XCTAssertEqual(
            reloaded.updatedAt.timeIntervalSince1970, editDate.timeIntervalSince1970, accuracy: 0.001,
            "Reconciler must not overwrite the user's Transform edit timestamp.")
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

            try promptRepo.save(
                Prompt(
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

    func testReconcilerMigratesLegacyPolishDefaultShortcut() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-polish-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let legacyShortcut = try XCTUnwrap(KeyboardShortcut.parse("opt+1"))

        do {
            let manager = try DatabaseManager(path: dbPath)
            let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
            var polish = try XCTUnwrap(
                (try promptRepo.fetchVisible(category: .transform))
                    .first(where: { $0.name == "Polish" })
            )
            polish.keyboardShortcut = legacyShortcut.encodedString()
            try promptRepo.save(polish)
        }

        let reopenedManager = try DatabaseManager(path: dbPath)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let reloaded = try XCTUnwrap(
            (try reopenedRepo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )

        XCTAssertEqual(reloaded.shortcut?.displayString, "⌃⌥1")
    }

    func testReconcilerMigratesLegacyDistillDefaultShortcut() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-distill-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        let legacyShortcut = try XCTUnwrap(KeyboardShortcut.parse("opt+2"))

        do {
            let manager = try DatabaseManager(path: dbPath)
            let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
            var distill = try XCTUnwrap(
                (try promptRepo.fetchVisible(category: .transform))
                    .first(where: { $0.name == "Distill" })
            )
            distill.keyboardShortcut = legacyShortcut.encodedString()
            try promptRepo.save(distill)
        }

        let reopenedManager = try DatabaseManager(path: dbPath)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let reloaded = try XCTUnwrap(
            (try reopenedRepo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Distill" })
        )

        XCTAssertEqual(reloaded.shortcut?.displayString, "⌃⌥2")
    }

    func testReconcilerPreservesCustomPolishShortcut() throws {
        // A user who rebound Polish to ⌘D (a non-legacy binding) must keep it
        // across launches — the migration only rewrites the exact legacy
        // Option+digit default, never a custom chord.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-polish-custom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("macparakeet.db").path

        do {
            let manager = try DatabaseManager(path: dbPath)
            let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
            var polish = try XCTUnwrap(
                (try promptRepo.fetchVisible(category: .transform))
                    .first(where: { $0.name == "Polish" })
            )
            polish.keyboardShortcut = KeyboardShortcut.parse("cmd+d")!.encodedString()
            try promptRepo.save(polish)
        }

        let reopenedManager = try DatabaseManager(path: dbPath)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let reloaded = try XCTUnwrap(
            (try reopenedRepo.fetchVisible(category: .transform))
                .first(where: { $0.name == "Polish" })
        )

        XCTAssertEqual(reloaded.shortcut?.displayString, "⌘D")
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

    func testRestoreDefaultsRevealsBuiltInTransformsWithoutResettingThem() throws {
        var polish = try XCTUnwrap((try repo.fetchVisible(category: .transform)).first(where: { $0.name == "Polish" }))
        polish.name = "Personal Polish"
        polish.content = "Keep my transform."
        polish.keyboardShortcut = KeyboardShortcut.parse("cmd+d")?.encodedString()
        polish.isVisible = false
        try repo.save(polish)

        try repo.restoreDefaults()

        let reloaded = try XCTUnwrap(try repo.fetch(id: polish.id))
        XCTAssertTrue(reloaded.isVisible)
        XCTAssertEqual(reloaded.name, "Personal Polish")
        XCTAssertEqual(reloaded.content, "Keep my transform.")
        XCTAssertEqual(reloaded.shortcut?.displayString, "⌘D")
    }

    func testNameUniquenessConstraintIsCaseInsensitive() throws {
        let duplicate = Prompt(name: "summary", content: "Duplicate")

        XCTAssertThrowsError(try repo.save(duplicate))
    }

    func testSoftDeletedBuiltInIsNotResurrectedOnReopen() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-reconcile-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var blogID: UUID!
        do {
            let manager = try DatabaseManager(path: dbURL.path)
            let repository = PromptRepository(dbQueue: manager.dbQueue)
            let blog = try XCTUnwrap(repository.fetchAll().first { $0.name == "Blog Post" })
            blogID = blog.id
            XCTAssertTrue(try repository.delete(id: blog.id))
            XCTAssertNil(try repository.fetch(id: blog.id))
        }

        let reopenedManager = try DatabaseManager(path: dbURL.path)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        XCTAssertNil(try reopenedRepo.fetch(id: blogID))
        let deleted = try XCTUnwrap(reopenedRepo.fetchIncludingDeleted(id: blogID))
        XCTAssertNotNil(deleted.deletedAt)
        XCTAssertNotNil(deleted.userCustomizedAt)
    }

    func testRestoreDeletedUsesDeterministicUniqueNameWhenOriginalWasReused() throws {
        let service = PromptEditingService(dbQueue: manager.dbQueue)
        let original = try service.create(Prompt(name: "Reusable", content: "Original"))
        XCTAssertTrue(try service.softDelete(id: original.id))
        let replacement = try service.create(Prompt(name: "Reusable", content: "Replacement"))
        _ = try service.create(Prompt(name: "Reusable (Restored)", content: "Claim suffix"))

        XCTAssertTrue(try service.restoreDeleted(id: original.id))

        XCTAssertEqual(try repo.fetch(id: replacement.id)?.name, "Reusable")
        XCTAssertEqual(try repo.fetch(id: original.id)?.name, "Reusable (Restored 2)")
    }

    func testCanonicalUpdateSkipsActiveNameCollisionWithoutCreatingVersion() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-canonical-collision-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var summaryID: UUID!
        var customID: UUID!
        do {
            let first = try DatabaseManager(path: dbURL.path)
            let firstRepo = PromptRepository(dbQueue: first.dbQueue)
            let summary = try XCTUnwrap(firstRepo.fetchAll().first { $0.name == "Summary" })
            summaryID = summary.id
            try first.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE prompts SET name = 'Bundled Summary', lastAppliedCanonicalRevision = 0 WHERE id = ?",
                    arguments: [summary.id]
                )
            }
            let custom = Prompt(name: "Summary", content: "User-owned collision")
            try firstRepo.save(custom)
            customID = custom.id
        }

        let reopened = try DatabaseManager(path: dbURL.path)
        let reopenedRepo = PromptRepository(dbQueue: reopened.dbQueue)
        XCTAssertEqual(try reopenedRepo.fetch(id: summaryID)?.name, "Bundled Summary")
        XCTAssertEqual(try reopenedRepo.fetch(id: customID)?.content, "User-owned collision")
        XCTAssertEqual(
            try PromptVersionRepository(dbQueue: reopened.dbQueue)
                .fetchAll(promptId: summaryID).count,
            1
        )
    }

    func testCustomizedBuiltInNeverReceivesAutomaticSystemUpdate() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-custom-canonical-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var summaryID: UUID!
        do {
            let first = try DatabaseManager(path: dbURL.path)
            let firstRepo = PromptRepository(dbQueue: first.dbQueue)
            var summary = try XCTUnwrap(firstRepo.fetchAll().first { $0.name == "Summary" })
            summaryID = summary.id
            summary.content = "My customized summary"
            summary.updatedAt = Date()
            try firstRepo.save(summary)
            try first.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE prompts SET lastAppliedCanonicalRevision = 0 WHERE id = ?",
                    arguments: [summary.id]
                )
            }
        }

        let reopened = try DatabaseManager(path: dbURL.path)
        let prompt = try XCTUnwrap(PromptRepository(dbQueue: reopened.dbQueue).fetch(id: summaryID))
        XCTAssertEqual(prompt.content, "My customized summary")
        XCTAssertNotNil(prompt.userCustomizedAt)
        let versions = try PromptVersionRepository(dbQueue: reopened.dbQueue)
            .fetchAll(promptId: summaryID)
        XCTAssertEqual(versions.count, 2)
        XCTAssertFalse(versions.contains { $0.origin == .systemUpdate })
    }

    func testRemovedCustomizedBuiltInIsNotRetiredByReconciler() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-retired-customized-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let removedID = UUID()
        do {
            let first = try DatabaseManager(path: dbURL.path)
            try PromptRepository(dbQueue: first.dbQueue).save(
                Prompt(
                    id: removedID,
                    name: "Removed but customized",
                    content: "Keep me",
                    isBuiltIn: true,
                    userCustomizedAt: Date()
                )
            )
        }

        let reopened = try DatabaseManager(path: dbURL.path)
        let preserved = try XCTUnwrap(
            PromptRepository(dbQueue: reopened.dbQueue).fetch(id: removedID)
        )
        XCTAssertNil(preserved.deletedAt)
        XCTAssertNotNil(preserved.userCustomizedAt)
    }

    func testDeletedAutoRunPromptDoesNotEnableNewCanonicalAutoRun() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-deleted-autorun-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        do {
            let first = try DatabaseManager(path: dbURL.path)
            let firstRepo = PromptRepository(dbQueue: first.dbQueue)
            let summary = try XCTUnwrap(firstRepo.fetchAll().first { $0.name == "Summary" })
            let deletedAuto = Prompt(name: "Deleted Auto", content: "Run", isAutoRun: true)
            try firstRepo.save(deletedAuto)
            XCTAssertTrue(try firstRepo.delete(id: deletedAuto.id))
            try first.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [summary.id])
            }
        }

        let reopened = try DatabaseManager(path: dbURL.path)
        let summary = try XCTUnwrap(
            PromptRepository(dbQueue: reopened.dbQueue).fetchAll().first { $0.name == "Summary" }
        )
        XCTAssertFalse(summary.isAutoRun)
    }

    func testReconcileDoesNotOverwriteCustomPromptSharingBuiltInName() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-custom-conflict-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let customContent = "My custom blog format."

        do {
            let manager = try DatabaseManager(path: dbURL.path)
            let repository = PromptRepository(dbQueue: manager.dbQueue)
            let builtIn = try XCTUnwrap(repository.fetchAll().first { $0.name == "Blog Post" })
            XCTAssertTrue(try repository.delete(id: builtIn.id))
            try repository.save(Prompt(name: "Blog Post", content: customContent, sortOrder: 99))
        }

        let reopenedManager = try DatabaseManager(path: dbURL.path)
        let reopenedRepo = PromptRepository(dbQueue: reopenedManager.dbQueue)
        let prompts = try reopenedRepo.fetchAll()

        let blogPost = try XCTUnwrap(prompts.first(where: { $0.name == "Blog Post" }))
        XCTAssertEqual(blogPost.content, customContent)
        XCTAssertFalse(blogPost.isBuiltIn)
        XCTAssertEqual(prompts.filter { $0.name == "Blog Post" }.count, 1)
    }

    func testCreatingAndEditingPromptMaintainsImmutableVersionHistory() throws {
        let versionRepo = PromptVersionRepository(dbQueue: manager.dbQueue)
        let service = PromptEditingService(dbQueue: manager.dbQueue)
        var prompt = Prompt(name: "Versioned", content: "Version one")

        prompt = try service.create(prompt)
        let firstVersionID = try XCTUnwrap(prompt.activeVersionId)
        XCTAssertEqual(try versionRepo.fetchAll(promptId: prompt.id).map(\.versionNumber), [1])

        prompt.name = "Renamed only"
        prompt.updatedAt = Date()
        prompt = try service.save(prompt)
        XCTAssertEqual(prompt.activeVersionId, firstVersionID)
        XCTAssertEqual(try versionRepo.fetchAll(promptId: prompt.id).count, 1)

        prompt.content = "Version two"
        prompt.inferenceSettings = PromptInferenceSettings(temperature: 0.3)
        prompt.modelOverride = "local-model"
        prompt.updatedAt = Date()
        prompt = try service.save(prompt, changeNote: "Tune output")

        let versions = try versionRepo.fetchAll(promptId: prompt.id)
        XCTAssertEqual(versions.map(\.versionNumber), [2, 1])
        XCTAssertEqual(versions[0].content, "Version two")
        XCTAssertEqual(versions[0].inferenceSettings?.temperature, 0.3)
        XCTAssertEqual(versions[0].modelOverride, "local-model")
        XCTAssertEqual(versions[0].changeNote, "Tune output")
        XCTAssertEqual(prompt.content, "Version two")
    }

    func testPromptEditingServicePreservesMeetingNotesMetadataOutsideVersions() throws {
        let versionRepo = PromptVersionRepository(dbQueue: manager.dbQueue)
        let service = PromptEditingService(dbQueue: manager.dbQueue)
        var prompt = Prompt(
            name: "Meeting context",
            content: "Summarize the meeting",
            includeMeetingNotes: true
        )

        prompt = try service.create(prompt)
        XCTAssertTrue(prompt.includeMeetingNotes)
        XCTAssertEqual(try versionRepo.fetchAll(promptId: prompt.id).count, 1)

        prompt.includeMeetingNotes = false
        prompt.updatedAt = Date()
        prompt = try service.save(prompt)

        XCTAssertFalse(prompt.includeMeetingNotes)
        XCTAssertEqual(try versionRepo.fetchAll(promptId: prompt.id).count, 1)
    }

    func testRestoringOldVersionCreatesANewVersion() throws {
        let versionRepo = PromptVersionRepository(dbQueue: manager.dbQueue)
        let service = PromptEditingService(dbQueue: manager.dbQueue)
        let originalDate = Date(timeIntervalSince1970: 1_000)
        var prompt = try service.create(
            Prompt(name: "Restore", content: "Original", createdAt: originalDate, updatedAt: originalDate)
        )
        let originalVersionID = try XCTUnwrap(prompt.activeVersionId)
        prompt.content = "Changed"
        prompt.updatedAt = originalDate.addingTimeInterval(100)
        prompt = try service.save(prompt)
        let previousVersions = try versionRepo.fetchAll(promptId: prompt.id)
        let beforeRestore = Date()

        let restored = try service.restore(promptId: prompt.id, versionId: originalVersionID)
        let afterRestore = Date()
        XCTAssertEqual(restored.content, "Original")
        let versions = try versionRepo.fetchAll(promptId: prompt.id)
        XCTAssertEqual(versions.map(\.versionNumber), [3, 2, 1])
        XCTAssertEqual(versions.first?.origin, .restore)
        XCTAssertNotEqual(restored.activeVersionId, originalVersionID)
        // GRDB serializes database dates at millisecond precision.
        XCTAssertGreaterThanOrEqual(restored.updatedAt, beforeRestore.addingTimeInterval(-0.001))
        XCTAssertLessThanOrEqual(restored.updatedAt, afterRestore.addingTimeInterval(0.001))
        XCTAssertEqual(try XCTUnwrap(versions.first).createdAt, restored.updatedAt)
        XCTAssertEqual(restored.createdAt, originalDate)
        XCTAssertEqual(Array(versions.dropFirst()), previousVersions)
    }

    func testCurrentPromptSchemaHasNoLegacyVersionedColumns() throws {
        try manager.dbQueue.read { db in
            let promptColumns = Set(try db.columns(in: "prompts").map(\.name))
            XCTAssertFalse(promptColumns.contains("content"))
            XCTAssertFalse(promptColumns.contains("inferenceSettings"))
            XCTAssertTrue(promptColumns.contains("activeVersionId"))
            XCTAssertTrue(try db.tableExists("prompt_versions"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prompts"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prompt_versions")
            )
        }
    }
}
