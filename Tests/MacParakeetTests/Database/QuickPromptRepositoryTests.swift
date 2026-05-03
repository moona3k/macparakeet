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

    func testPinnedAndUnpinnedDefaultCounts() throws {
        let pinned = try repo.fetchAll().filter(\.isPinned)
        let unpinned = try repo.fetchAll().filter { !$0.isPinned }
        XCTAssertEqual(unpinned.count, 9)
        XCTAssertEqual(pinned.count, 5)
    }

    func testUnpinnedSeedsHaveGroupLabels() throws {
        let unpinned = try repo.fetchAll().filter { !$0.isPinned }
        XCTAssertTrue(unpinned.allSatisfy { $0.groupLabel != nil })
    }

    func testPinnedSeedsHaveNoGroupLabel() throws {
        let pinned = try repo.fetchAll().filter(\.isPinned)
        XCTAssertTrue(pinned.allSatisfy { $0.groupLabel == nil })
    }

    func testSeedIfNeededIsIdempotent() throws {
        let countBefore = try repo.fetchAll().count
        try repo.seedIfNeeded()
        try repo.seedIfNeeded()
        XCTAssertEqual(try repo.fetchAll().count, countBefore)
    }

    func testSeedIfNeededDoesNotClobberEdits() throws {
        guard var firstUnpinned = try repo.fetchAll().first(where: { !$0.isPinned }) else {
            return XCTFail("expected built-in unpinned prompt")
        }
        firstUnpinned.label = "EDITED LABEL"
        firstUnpinned.prompt = "edited body"
        try repo.save(firstUnpinned)

        try repo.seedIfNeeded()

        let after = try repo.fetch(id: firstUnpinned.id)
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
            label: "Retired",
            prompt: "retired body",
            groupLabel: "RETIRED",
            isPinned: false,
            isBuiltIn: true
        )
        try manager.dbQueue.write { db in try retired.insert(db) }

        try repo.seedIfNeeded()

        XCTAssertNil(try repo.fetch(id: retiredID))
    }

    func testRetiredBuiltInDoesNotDeleteCustoms() throws {
        let custom = QuickPrompt(label: "Mine", prompt: "my body")
        try repo.save(custom)
        try repo.seedIfNeeded()
        XCTAssertNotNil(try repo.fetch(id: custom.id))
    }

    // MARK: CRUD

    func testSaveAndFetchCustom() throws {
        let custom = QuickPrompt(label: "ELI5", prompt: "Explain like I'm five.")
        try repo.save(custom)
        XCTAssertEqual(try repo.fetch(id: custom.id)?.label, "ELI5")
    }

    func testSaveCollapsesWhitespaceOnlyGroupLabelToNil() throws {
        let custom = QuickPrompt(
            label: "Custom",
            prompt: "body",
            groupLabel: "   "
        )
        try repo.save(custom)
        XCTAssertNil(try repo.fetch(id: custom.id)?.groupLabel)
    }

    func testSaveSnapsGroupLabelToExistingCanonicalCasing() throws {
        // A canonical built-in carries groupLabel "CAPTURE". Saving a custom
        // with "capture" should snap to the existing casing.
        let custom = QuickPrompt(label: "Custom catch-up", prompt: "body", groupLabel: "capture")
        try repo.save(custom)
        XCTAssertEqual(try repo.fetch(id: custom.id)?.groupLabel, "CAPTURE")
    }

    func testSaveSnapsGroupLabelCaseInsensitivelyAcrossCustoms() throws {
        let first = QuickPrompt(label: "Note A", prompt: "body", groupLabel: "Wins")
        try repo.save(first)
        let second = QuickPrompt(label: "Note B", prompt: "body", groupLabel: "WINS")
        try repo.save(second)
        // First-seen casing wins for both.
        XCTAssertEqual(try repo.fetch(id: first.id)?.groupLabel, "Wins")
        XCTAssertEqual(try repo.fetch(id: second.id)?.groupLabel, "Wins")
    }

    func testSaveAllowsRenamingExistingGroupCasing() throws {
        // Editing the only row in a group should let the user change its
        // casing without snapping back to itself.
        let only = QuickPrompt(label: "Solo", prompt: "body", groupLabel: "Mood")
        try repo.save(only)
        var edited = try XCTUnwrap(try repo.fetch(id: only.id))
        edited.groupLabel = "MOOD"
        try repo.save(edited)
        XCTAssertEqual(try repo.fetch(id: only.id)?.groupLabel, "MOOD")
    }

    func testCustomMayCarryGroupLabelEvenWhenPinned() throws {
        var custom = QuickPrompt(label: "Pinned with group", prompt: "body", groupLabel: "REFINE")
        try repo.save(custom)
        // Pin it via setPinned (drops a default to free a slot first).
        let firstPinned = try repo.fetchAll().first(where: \.isPinned)!
        try repo.setPinned(id: firstPinned.id, isPinned: false)
        custom = try XCTUnwrap(try repo.fetch(id: custom.id))
        let result = try repo.setPinned(id: custom.id, isPinned: true)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(try repo.fetch(id: custom.id)?.groupLabel, "REFINE")
    }

    func testDeleteBuiltInRejected() throws {
        let builtIn = try repo.fetchAll().first { $0.isBuiltIn }!
        let deleted = try repo.delete(id: builtIn.id)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(try repo.fetch(id: builtIn.id))
    }

    func testDeleteCustomSucceeds() throws {
        let custom = QuickPrompt(label: "X", prompt: "x")
        try repo.save(custom)
        XCTAssertTrue(try repo.delete(id: custom.id))
        XCTAssertNil(try repo.fetch(id: custom.id))
    }

    func testToggleVisibility() throws {
        let prompt = try repo.fetchAll().first(where: \.isPinned)!
        try repo.toggleVisibility(id: prompt.id)
        XCTAssertEqual(try repo.fetch(id: prompt.id)?.isVisible, false)
        XCTAssertFalse(try repo.fetchPinned().contains { $0.id == prompt.id })
        try repo.toggleVisibility(id: prompt.id)
        XCTAssertEqual(try repo.fetch(id: prompt.id)?.isVisible, true)
    }

    func testReorderWithinPinnedBucketUpdatesSortOrder() throws {
        var pinned = try repo.fetchAll().filter(\.isPinned).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(pinned.count, 5)
        pinned.reverse()
        try repo.reorder(ids: pinned.map(\.id), pinned: true)

        let after = try repo.fetchAll().filter(\.isPinned).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(after.map(\.id), pinned.map(\.id))
    }

    func testReorderWithinPinnedDoesNotTouchUnpinned() throws {
        let unpinnedBefore = try repo.fetchAll().filter { !$0.isPinned }.map(\.id)
        let pinned = try repo.fetchAll().filter(\.isPinned).sorted { $0.sortOrder < $1.sortOrder }
        try repo.reorder(ids: pinned.reversed().map(\.id), pinned: true)
        let unpinnedAfter = try repo.fetchAll().filter { !$0.isPinned }.map(\.id)
        XCTAssertEqual(unpinnedBefore, unpinnedAfter)
    }

    // MARK: Pin / unpin / cap / swap

    func testFetchPinnedReturnsVisiblePinnedOnly() throws {
        let all = try repo.fetchAll().filter(\.isPinned)
        let pinned = try repo.fetchPinned()
        XCTAssertEqual(pinned.count, all.count)
        // Hide one and confirm it falls out.
        try repo.toggleVisibility(id: all.first!.id)
        XCTAssertEqual(try repo.fetchPinned().count, all.count - 1)
    }

    func testFetchPinnedReturnsAllVisiblePinnedRows() throws {
        // Pinning is unbounded — fetchPinned returns every visible pinned row,
        // ordered by sortOrder. Strip overflow is handled by the view-layer
        // ScrollView's edge-fade affordance, not by truncation.
        let extra = QuickPrompt(
            label: "Imported pinned",
            prompt: "body",
            sortOrder: 999,
            isPinned: true
        )
        let bundle = QuickPromptBundle(
            exportedAt: Date(),
            appVersion: nil,
            prompts: [
                QuickPromptBundle.ExportedQuickPrompt(extra)
            ]
        )

        _ = try repo.applyImport(bundle, mode: .merge, dryRun: false)

        let allPinned = try repo.fetchAll().filter(\.isPinned)
        let stripPinned = try repo.fetchPinned()
        XCTAssertEqual(stripPinned.count, allPinned.count)
        XCTAssertTrue(stripPinned.contains { $0.id == extra.id })
    }

    func testSetPinnedTogglesUnpinnedToPinned() throws {
        let candidate = try XCTUnwrap(try repo.fetchAll().first { !$0.isPinned })
        let result = try repo.setPinned(id: candidate.id, isPinned: true)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(try repo.fetch(id: candidate.id)?.isPinned, true)
    }

    func testSetPinnedAllowsPinningBeyondDefaultSeedCount() throws {
        // No cap — the strip is unbounded; overflow is handled visually by
        // the horizontal ScrollView's edge-fade affordance.
        for i in 0..<20 {
            let extra = QuickPrompt(label: "Extra\(i)", prompt: "body")
            try repo.save(extra)
            XCTAssertEqual(try repo.setPinned(id: extra.id, isPinned: true), .ok)
        }
        XCTAssertEqual(try repo.fetchAll().filter(\.isPinned).count, 25)
    }

    func testSetPinnedReturnsNotFoundForMissingID() throws {
        let result = try repo.setPinned(id: UUID(), isPinned: true)
        XCTAssertEqual(result, .notFound)
    }

    func testSetPinnedToSameStateIsIdempotentNoOp() throws {
        let pinned = try repo.fetchAll().first(where: \.isPinned)!
        let result = try repo.setPinned(id: pinned.id, isPinned: true)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(try repo.fetch(id: pinned.id)?.isPinned, true)
    }

    // MARK: Restore defaults

    func testRestoreSingleDefaultRevertsLabelAndPromptButPreservesVisibility() throws {
        guard var first = try repo.fetchAll().first(where: { !$0.isPinned }) else {
            return XCTFail("expected built-in unpinned prompt")
        }
        let canonicalLabel = first.label
        let canonicalPrompt = first.prompt
        first.label = "DRIFTED"
        first.prompt = "drifted"
        first.isVisible = false
        try repo.save(first)

        try repo.restoreBuiltInDefault(id: first.id)

        let restored = try repo.fetch(id: first.id)
        XCTAssertEqual(restored?.label, canonicalLabel)
        XCTAssertEqual(restored?.prompt, canonicalPrompt)
        XCTAssertEqual(restored?.isVisible, false, "visibility should be preserved across restore")
    }

    func testRestoreAllBuiltInDefaultsLeavesCustomsAlone() throws {
        let custom = QuickPrompt(label: "Mine", prompt: "my body")
        try repo.save(custom)
        try repo.restoreBuiltInDefaults()
        XCTAssertNotNil(try repo.fetch(id: custom.id))
    }

    func testRestoreSingleDefaultRevertsPinState() throws {
        // Take a built-in pinned row and unpin it; restoreSingle should pin it again.
        let pinned = try repo.fetchAll().first(where: \.isPinned)!
        try repo.setPinned(id: pinned.id, isPinned: false)
        XCTAssertEqual(try repo.fetch(id: pinned.id)?.isPinned, false)

        try repo.restoreBuiltInDefault(id: pinned.id)

        XCTAssertEqual(try repo.fetch(id: pinned.id)?.isPinned, true)
    }

    // MARK: Import — merge

    func testImportMergeUpsertsByID() throws {
        let custom = QuickPrompt(label: "Old", prompt: "old body")
        try repo.save(custom)

        let updated = QuickPromptBundle.ExportedQuickPrompt(
            id: custom.id,
            label: "New",
            prompt: "new body",
            groupLabel: nil,
            sortOrder: 99,
            isVisible: true,
            isPinned: false,
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
            label: "Brand New",
            prompt: "fresh",
            groupLabel: nil,
            sortOrder: 100,
            isVisible: true,
            isPinned: false,
            isBuiltIn: false
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [entry])

        let summary = try repo.applyImport(bundle, mode: .merge, dryRun: false)
        XCTAssertEqual(summary.added, 1)
        XCTAssertNotNil(try repo.fetch(id: newID))
    }

    func testImportMergePreservesUntouchedRows() throws {
        let unpinnedCount = try repo.fetchAll().filter { !$0.isPinned }.count
        let pinnedCount = try repo.fetchAll().filter(\.isPinned).count

        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [])
        let summary = try repo.applyImport(bundle, mode: .merge, dryRun: false)

        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.deleted, 0)
        XCTAssertEqual(try repo.fetchAll().filter { !$0.isPinned }.count, unpinnedCount)
        XCTAssertEqual(try repo.fetchAll().filter(\.isPinned).count, pinnedCount)
    }

    func testImportDryRunMakesNoWrites() throws {
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: UUID(),
            label: "Should not land",
            prompt: "ghost",
            groupLabel: nil,
            sortOrder: 200,
            isVisible: true,
            isPinned: false,
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
            label: "I claim to be built-in",
            prompt: "fake",
            groupLabel: nil,
            sortOrder: 0,
            isVisible: true,
            isPinned: false,
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
            label: "First",
            prompt: "first",
            groupLabel: nil,
            sortOrder: 0,
            isVisible: true,
            isPinned: false,
            isBuiltIn: false
        )
        let second = QuickPromptBundle.ExportedQuickPrompt(
            id: duplicateID,
            label: "Second",
            prompt: "second",
            groupLabel: nil,
            sortOrder: 1,
            isVisible: true,
            isPinned: false,
            isBuiltIn: false
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [first, second])

        XCTAssertThrowsError(try repo.applyImport(bundle, mode: .merge, dryRun: false)) { error in
            XCTAssertEqual(error as? QuickPromptImportError, .duplicateID(duplicateID))
        }
    }

    func testImportPreservesBuiltInPinState() throws {
        // Take an unpinned built-in; import should preserve pin state because
        // pinning is user-controlled and backup/restore must be lossless.
        let unpinned = QuickPrompt.builtInPrompts().first { !$0.isPinned }!
        let entry = QuickPromptBundle.ExportedQuickPrompt(
            id: unpinned.id,
            label: "Now pinned",
            prompt: "updated body",
            groupLabel: "CATCH UP",
            sortOrder: 99,
            isVisible: true,
            isPinned: true,
            isBuiltIn: true
        )
        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [entry])

        _ = try repo.applyImport(bundle, mode: .merge, dryRun: false)

        let saved = try repo.fetch(id: unpinned.id)
        XCTAssertEqual(saved?.isPinned, true, "import should preserve user-controlled built-in pin state")
        XCTAssertTrue(saved?.isBuiltIn ?? false)
        XCTAssertEqual(saved?.label, "Now pinned")
    }

    // MARK: Import — replace

    func testImportReplaceWipesCustomsAndReseeds() throws {
        let custom = QuickPrompt(label: "Doomed", prompt: "doomed")
        try repo.save(custom)

        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [])
        let summary = try repo.applyImport(bundle, mode: .replace, dryRun: false)

        XCTAssertEqual(summary.deleted, 1)
        XCTAssertNil(try repo.fetch(id: custom.id))
        XCTAssertEqual(try repo.fetchAll().count, QuickPrompt.builtInPrompts().count)
    }

    func testImportReplaceDryRunCountsBuiltInResetsWithoutWriting() throws {
        var unpinned = try repo.fetchAll().first(where: { !$0.isPinned })!
        let canonicalLabel = unpinned.label
        unpinned.label = "Edited"
        unpinned.isVisible = false
        try repo.save(unpinned)

        let bundle = QuickPromptBundle(exportedAt: Date(), appVersion: nil, prompts: [])
        let summary = try repo.applyImport(bundle, mode: .replace, dryRun: true)

        XCTAssertEqual(summary.updated, 1)
        let after = try repo.fetch(id: unpinned.id)
        XCTAssertEqual(after?.label, "Edited")
        XCTAssertEqual(after?.isVisible, false)
        XCTAssertNotEqual(after?.label, canonicalLabel)
    }
}
