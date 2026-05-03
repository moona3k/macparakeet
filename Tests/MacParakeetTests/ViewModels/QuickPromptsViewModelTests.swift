import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class QuickPromptsViewModelTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: QuickPromptRepository!
    var viewModel: QuickPromptsViewModel!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = QuickPromptRepository(dbQueue: manager.dbQueue)
        viewModel = QuickPromptsViewModel()
        viewModel.configure(repo: repo)
    }

    func testSaveEditRejectsEmptyFieldsWithoutClearingEditingPrompt() {
        var prompt = viewModel.allUnpinned.first!
        viewModel.editingPrompt = prompt
        prompt.label = " "

        XCTAssertFalse(viewModel.saveEdit(prompt))
        XCTAssertNotNil(viewModel.editingPrompt)
        XCTAssertEqual(viewModel.errorMessage, "Label and prompt are required.")
    }

    func testCommitCreatingRejectsEmptyFieldsWithoutClearingDraft() {
        viewModel.startCreating()
        viewModel.creating?.label = "New"

        XCTAssertFalse(viewModel.commitCreating())
        XCTAssertNotNil(viewModel.creating)
        XCTAssertEqual(viewModel.errorMessage, "Label and prompt are required.")
    }

    func testCommitCreatingSuccessClearsDraftAndLandsUnpinned() {
        viewModel.startCreating()
        viewModel.creating?.label = "ELI5"
        viewModel.creating?.prompt = "Explain simply."

        XCTAssertTrue(viewModel.commitCreating())
        XCTAssertNil(viewModel.creating)
        let added = viewModel.allPrompts.first { $0.label == "ELI5" }
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.isPinned, false, "new prompts default unpinned regardless of draft hint")
    }

    func testReorderUpdatesPinnedBucketOrder() {
        let original = viewModel.allPinned
        XCTAssertEqual(original.count, 5)
        let reversedIDs = original.reversed().map(\.id)

        viewModel.reorder(ids: reversedIDs, pinned: true)

        XCTAssertEqual(viewModel.allPinned.map(\.id), reversedIDs)
    }

    // MARK: - Pin / unpin

    func testTogglePinUnpinsAlreadyPinnedRow() throws {
        let pinned = viewModel.allPinned.first!
        viewModel.togglePin(pinned)
        XCTAssertEqual(try repo.fetch(id: pinned.id)?.isPinned, false)
        XCTAssertNil(viewModel.swapRequest)
    }

    func testTogglePinAtCapPopulatesSwapRequest() throws {
        // Add a 6th candidate as a custom unpinned row.
        let candidate = QuickPrompt(label: "Maybe pin me", prompt: "body")
        try repo.save(candidate)
        viewModel.refresh()

        viewModel.togglePin(candidate)

        XCTAssertNotNil(viewModel.swapRequest)
        XCTAssertEqual(viewModel.swapRequest?.candidate.id, candidate.id)
        XCTAssertEqual(viewModel.swapRequest?.currentlyPinned.count, 5)
        // Candidate itself is still unpinned — VM only stages the request.
        XCTAssertEqual(try repo.fetch(id: candidate.id)?.isPinned, false)
    }

    func testConfirmSwapAtomicallyExchangesPinState() throws {
        let candidate = QuickPrompt(label: "New favorite", prompt: "body")
        try repo.save(candidate)
        viewModel.refresh()
        viewModel.togglePin(candidate)
        let victim = try XCTUnwrap(viewModel.swapRequest?.currentlyPinned.first)

        viewModel.confirmSwap(unpin: victim)

        XCTAssertNil(viewModel.swapRequest)
        XCTAssertEqual(try repo.fetch(id: candidate.id)?.isPinned, true)
        XCTAssertEqual(try repo.fetch(id: victim.id)?.isPinned, false)
        XCTAssertEqual(viewModel.allPinned.count, 5)
    }

    func testCancelSwapClearsRequestWithoutMutation() throws {
        let candidate = QuickPrompt(label: "Maybe", prompt: "body")
        try repo.save(candidate)
        viewModel.refresh()
        viewModel.togglePin(candidate)

        viewModel.cancelSwap()

        XCTAssertNil(viewModel.swapRequest)
        XCTAssertEqual(try repo.fetch(id: candidate.id)?.isPinned, false)
        XCTAssertEqual(viewModel.allPinned.count, 5)
    }

    // MARK: - Visibility & grouping

    func testVisiblePinnedExcludesHidden() throws {
        let pinned = viewModel.allPinned.first!
        viewModel.toggleVisibility(pinned)
        XCTAssertFalse(viewModel.visiblePinned.contains { $0.id == pinned.id })
    }

    func testVisiblePinnedCapsRowsEvenIfDatabaseIsOverCap() throws {
        let overflow = QuickPrompt(
            label: "Imported sixth",
            prompt: "body",
            sortOrder: 999,
            isPinned: true
        )
        try manager.dbQueue.write { db in try overflow.insert(db) }
        viewModel.refresh()

        XCTAssertEqual(viewModel.allPinned.count, QuickPrompt.pinnedCap + 1)
        XCTAssertEqual(viewModel.visiblePinned.count, QuickPrompt.pinnedCap)
        XCTAssertFalse(viewModel.visiblePinned.contains { $0.id == overflow.id })
    }

    func testVisiblePromptGroupsIncludesAllVisible() {
        let groupCount = viewModel.visiblePromptGroups.flatMap(\.prompts).count
        XCTAssertEqual(groupCount, QuickPrompt.builtInPrompts().count)
    }

    func testVisiblePromptGroupsBucketsCaseInsensitively() throws {
        // The repo snaps casing on save, so to actually exercise the
        // view-layer fold we have to bypass save() and inject a row whose
        // `groupLabel` differs in case from the canonical "CAPTURE" seed.
        let mismatched = QuickPrompt(
            label: "Custom",
            prompt: "body",
            groupLabel: "Capture"
        )
        try manager.dbQueue.write { db in try mismatched.insert(db) }
        viewModel.refresh()

        let captureGroups = viewModel.visiblePromptGroups.filter {
            $0.label.lowercased() == "capture"
        }
        XCTAssertEqual(captureGroups.count, 1, "Capture and CAPTURE should fold into one group")
        XCTAssertTrue(captureGroups.first?.prompts.contains { $0.id == mismatched.id } ?? false)
    }
}
