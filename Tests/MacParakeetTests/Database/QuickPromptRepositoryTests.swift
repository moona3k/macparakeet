import XCTest
import GRDB
@testable import MacParakeetCore

final class QuickPromptRepositoryTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: QuickPromptRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = QuickPromptRepository(dbQueue: manager.dbQueue)
    }

    // MARK: Seeding

    func testBuiltInsSeededAfterMigration() throws {
        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, QuickPrompt.builtInPrompts().count)
        XCTAssertTrue(all.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(all.allSatisfy(\.isVisible))
    }

    func testStarterAndFollowUpCounts() throws {
        let starters = try repo.fetchAll(kind: .starter)
        let followUps = try repo.fetchAll(kind: .followUp)
        XCTAssertEqual(starters.count, 9)
        XCTAssertEqual(followUps.count, 5)
    }

    func testStartersHaveGroupLabels() throws {
        let starters = try repo.fetchAll(kind: .starter)
        XCTAssertTrue(starters.allSatisfy { $0.groupLabel != nil })
    }

    func testFollowUpsHaveNoGroupLabel() throws {
        let followUps = try repo.fetchAll(kind: .followUp)
        XCTAssertTrue(followUps.allSatisfy { $0.groupLabel == nil })
    }

    func testSeedIfNeededIsIdempotent() throws {
        let countBefore = try repo.fetchAll().count
        try repo.seedIfNeeded()
        try repo.seedIfNeeded()
        XCTAssertEqual(try repo.fetchAll().count, countBefore)
    }

    func testSeedIfNeededDoesNotClobberEdits() throws {
        guard var firstStarter = try repo.fetchAll(kind: .starter).first else {
            return XCTFail("expected built-in starter")
        }
        firstStarter.label = "EDITED LABEL"
        firstStarter.prompt = "edited body"
        try repo.save(firstStarter)

        try repo.seedIfNeeded()

        let after = try repo.fetch(id: firstStarter.id)
        XCTAssertEqual(after?.label, "EDITED LABEL")
        XCTAssertEqual(after?.prompt, "edited body")
    }

    func testNoUUIDCollisionsAcrossBuiltIns() {
        let ids = QuickPrompt.builtInPrompts().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate UUIDs in built-in seed list")
    }

    func testRetiredBuiltInIsRemovedOnReseed() throws {
        // Insert a fake "retired" built-in by a UUID not in the canonical list.
        let retiredID = UUID(uuidString: "DEADBEEF-0000-4000-8000-000000000000")!
        let retired = QuickPrompt(
            id: retiredID,
            kind: .starter,
            label: "Retired",
            prompt: "retired body",
            groupLabel: "RETIRED",
            isBuiltIn: true
        )
        try manager.dbQueue.write { db in try retired.insert(db) }

        try repo.seedIfNeeded()

        XCTAssertNil(try repo.fetch(id: retiredID))
    }

    func testRetiredBuiltInDoesNotDeleteCustoms() throws {
        let custom = QuickPrompt(kind: .starter, label: "Mine", prompt: "my body")
        try repo.save(custom)
        try repo.seedIfNeeded()
        XCTAssertNotNil(try repo.fetch(id: custom.id))
    }

    // MARK: CRUD

    func testSaveAndFetchCustom() throws {
        let custom = QuickPrompt(kind: .followUp, label: "ELI5", prompt: "Explain like I'm five.")
        try repo.save(custom)
        XCTAssertEqual(try repo.fetch(id: custom.id)?.label, "ELI5")
    }

    func testSaveCollapsesWhitespaceOnlyGroupLabelToNil() throws {
        let custom = QuickPrompt(
            kind: .starter,
            label: "Custom",
            prompt: "body",
            groupLabel: "   "
        )
        try repo.save(custom)
        XCTAssertNil(try repo.fetch(id: custom.id)?.groupLabel)
    }

    func testDeleteBuiltInRejected() throws {
        let builtIn = try repo.fetchAll(kind: .starter).first!
        let deleted = try repo.delete(id: builtIn.id)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(try repo.fetch(id: builtIn.id))
    }

    func testDeleteCustomSucceeds() throws {
        let custom = QuickPrompt(kind: .followUp, label: "X", prompt: "x")
        try repo.save(custom)
        XCTAssertTrue(try repo.delete(id: custom.id))
        XCTAssertNil(try repo.fetch(id: custom.id))
    }

    func testToggleVisibility() throws {
        let prompt = try repo.fetchAll(kind: .followUp).first!
        try repo.toggleVisibility(id: prompt.id)
        XCTAssertEqual(try repo.fetch(id: prompt.id)?.isVisible, false)
        XCTAssertTrue(try repo.fetchVisible(kind: .followUp).allSatisfy { $0.id != prompt.id })
        try repo.toggleVisibility(id: prompt.id)
        XCTAssertEqual(try repo.fetch(id: prompt.id)?.isVisible, true)
    }

    func testReorderUpdatesSortOrder() throws {
        var followUps = try repo.fetchAll(kind: .followUp)
        XCTAssertEqual(followUps.count, 5)
        followUps.reverse()
        try repo.reorder(ids: followUps.map(\.id), within: .followUp)

        let after = try repo.fetchAll(kind: .followUp)
        XCTAssertEqual(after.map(\.id), followUps.map(\.id))
    }

    // MARK: Restore defaults

    func testRestoreSingleDefaultRevertsLabelAndPromptButPreservesVisibility() throws {
        guard var firstStarter = try repo.fetchAll(kind: .starter).first else {
            return XCTFail("expected built-in starter")
        }
        let canonicalLabel = firstStarter.label
        let canonicalPrompt = firstStarter.prompt
        firstStarter.label = "DRIFTED"
        firstStarter.prompt = "drifted"
        firstStarter.isVisible = false
        try repo.save(firstStarter)

        try repo.restoreBuiltInDefault(id: firstStarter.id)

        let restored = try repo.fetch(id: firstStarter.id)
        XCTAssertEqual(restored?.label, canonicalLabel)
        XCTAssertEqual(restored?.prompt, canonicalPrompt)
        XCTAssertEqual(restored?.isVisible, false, "visibility should be preserved across restore")
    }

    func testRestoreDefaultsByKindLeavesOtherKindAlone() throws {
        guard var followUp = try repo.fetchAll(kind: .followUp).first,
              var starter = try repo.fetchAll(kind: .starter).first
        else { return XCTFail("expected both built-in kinds") }
        let originalFollowUpLabel = followUp.label
        followUp.label = "DRIFT-FOLLOW"
        starter.label = "DRIFT-STARTER"
        try repo.save(followUp)
        try repo.save(starter)

        try repo.restoreBuiltInDefaults(kind: .starter)

        XCTAssertEqual(try repo.fetch(id: followUp.id)?.label, "DRIFT-FOLLOW",
                       "follow-up should be untouched when restoring starters only")
        XCTAssertEqual(try repo.fetch(id: starter.id)?.label,
                       QuickPrompt.builtInPrompts(kind: .starter).first { $0.id == starter.id }?.label)
        _ = originalFollowUpLabel
    }

    func testRestoreDefaultsLeavesCustomsAlone() throws {
        let custom = QuickPrompt(kind: .followUp, label: "Mine", prompt: "my body")
        try repo.save(custom)
        try repo.restoreBuiltInDefaults(kind: nil)
        XCTAssertNotNil(try repo.fetch(id: custom.id))
    }

    // MARK: Import — merge

    func testImportMergeUpsertsByID() throws {
        // Existing custom that we'll update via import
        let custom = QuickPrompt(kind: .followUp, label: "Old", prompt: "old body")
        try repo.save(custom)

        let updated = QuickPromptBundle.ExportedQuickPrompt(
            id: custom.id,
            kind: .followUp,
            label: "New",
            prompt: "new body",
            groupLabel: nil,
            sortOrder: 99,
            isVisible: true,
            isBuiltIn: false
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [updated])

        let summary = try repo.applyImport(bundle, mode: .merge, dryRun: false)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(try repo.fetch(id: custom.id)?.label, "New")
    }

    func testImportMergeAddsNewRows() throws {
        let newID = UUID()
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: newID,
            kind: .followUp,
            label: "Brand New",
            prompt: "fresh",
            groupLabel: nil,
            sortOrder: 100,
            isVisible: true,
            isBuiltIn: false
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [entry])

        let summary = try repo.applyImport(bundle, mode: .merge, dryRun: false)
        XCTAssertEqual(summary.added, 1)
        XCTAssertNotNil(try repo.fetch(id: newID))
    }

    func testImportMergePreservesUntouchedRows() throws {
        let starterCount = try repo.fetchAll(kind: .starter).count
        let followUpCount = try repo.fetchAll(kind: .followUp).count

        // Empty bundle — should change nothing.
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [])
        let summary = try repo.applyImport(bundle, mode: .merge, dryRun: false)

        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.deleted, 0)
        XCTAssertEqual(try repo.fetchAll(kind: .starter).count, starterCount)
        XCTAssertEqual(try repo.fetchAll(kind: .followUp).count, followUpCount)
    }

    func testImportDryRunMakesNoWrites() throws {
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: UUID(),
            kind: .followUp,
            label: "Should not land",
            prompt: "ghost",
            groupLabel: nil,
            sortOrder: 200,
            isVisible: true,
            isBuiltIn: false
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [entry])
        let summary = try repo.applyImport(bundle, mode: .merge, dryRun: true)

        XCTAssertEqual(summary.added, 1)
        XCTAssertNil(try repo.fetch(id: entry.id))
    }

    func testImportForgedBuiltInIsCoercedToCustom() throws {
        let forgedID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: forgedID,
            kind: .followUp,
            label: "I claim to be built-in",
            prompt: "fake",
            groupLabel: nil,
            sortOrder: 0,
            isVisible: true,
            isBuiltIn: true
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [entry])
        _ = try repo.applyImport(bundle, mode: .merge, dryRun: false)

        XCTAssertEqual(try repo.fetch(id: forgedID)?.isBuiltIn, false)
    }

    func testImportRejectsDuplicateIDsWithoutTrapping() throws {
        let duplicateID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let first = QuickPromptBundle.ExportedQuickPrompt(
            id: duplicateID,
            kind: .followUp,
            label: "First",
            prompt: "first",
            groupLabel: nil,
            sortOrder: 0,
            isVisible: true,
            isBuiltIn: false
        )
        let second = QuickPromptBundle.ExportedQuickPrompt(
            id: duplicateID,
            kind: .followUp,
            label: "Second",
            prompt: "second",
            groupLabel: nil,
            sortOrder: 1,
            isVisible: true,
            isBuiltIn: false
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [first, second])

        XCTAssertThrowsError(try repo.applyImport(bundle, mode: .merge, dryRun: false)) { error in
            XCTAssertEqual(error as? QuickPromptImportError, .duplicateID(duplicateID))
        }
    }

    func testImportCanonicalizesBuiltInKind() throws {
        let starter = QuickPrompt.builtInPrompts(kind: .starter).first!
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: starter.id,
            kind: .followUp,
            label: "Still a starter",
            prompt: "updated body",
            groupLabel: "CATCH UP",
            sortOrder: 99,
            isVisible: true,
            isBuiltIn: true
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [entry])

        _ = try repo.applyImport(bundle, mode: .merge, dryRun: false)

        let saved = try repo.fetch(id: starter.id)
        XCTAssertEqual(saved?.kind, .starter)
        XCTAssertTrue(saved?.isBuiltIn ?? false)
        XCTAssertEqual(saved?.label, "Still a starter")
    }

    func testRestoreDefaultRestoresKind() throws {
        let starter = try repo.fetchAll(kind: .starter).first!
        try manager.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE quick_prompts SET kind = ? WHERE id = ?",
                arguments: [QuickPrompt.Kind.followUp.rawValue, starter.id]
            )
        }

        try repo.restoreBuiltInDefault(id: starter.id)

        XCTAssertEqual(try repo.fetch(id: starter.id)?.kind, .starter)
    }

    // MARK: Import — replace

    func testImportReplaceWipesCustomsAndReseeds() throws {
        let custom = QuickPrompt(kind: .followUp, label: "Doomed", prompt: "doomed")
        try repo.save(custom)

        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [])
        let summary = try repo.applyImport(bundle, mode: .replace, dryRun: false)

        XCTAssertEqual(summary.deleted, 1)
        XCTAssertNil(try repo.fetch(id: custom.id))
        XCTAssertEqual(try repo.fetchAll().count, QuickPrompt.builtInPrompts().count)
    }

    func testImportReplaceDryRunCountsBuiltInResetsWithoutWriting() throws {
        var starter = try repo.fetchAll(kind: .starter).first!
        let canonicalLabel = starter.label
        starter.label = "Edited"
        starter.isVisible = false
        try repo.save(starter)

        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [])
        let summary = try repo.applyImport(bundle, mode: .replace, dryRun: true)

        XCTAssertEqual(summary.updated, 1)
        let after = try repo.fetch(id: starter.id)
        XCTAssertEqual(after?.label, "Edited")
        XCTAssertEqual(after?.isVisible, false)
        XCTAssertNotEqual(after?.label, canonicalLabel)
    }
}
