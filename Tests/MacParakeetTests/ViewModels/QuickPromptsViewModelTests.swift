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
        var prompt = viewModel.allStarters.first!
        viewModel.editingPrompt = prompt
        prompt.label = " "

        XCTAssertFalse(viewModel.saveEdit(prompt))
        XCTAssertNotNil(viewModel.editingPrompt)
        XCTAssertEqual(viewModel.errorMessage, "Label and prompt are required.")
    }

    func testCommitCreatingRejectsEmptyFieldsWithoutClearingDraft() {
        viewModel.startCreating(kind: .starter)
        viewModel.creating?.label = "New"

        XCTAssertFalse(viewModel.commitCreating())
        XCTAssertNotNil(viewModel.creating)
        XCTAssertEqual(viewModel.errorMessage, "Label and prompt are required.")
    }

    func testCommitCreatingSuccessClearsDraft() {
        viewModel.startCreating(kind: .followUp)
        viewModel.creating?.label = "ELI5"
        viewModel.creating?.prompt = "Explain simply."

        XCTAssertTrue(viewModel.commitCreating())
        XCTAssertNil(viewModel.creating)
        XCTAssertTrue(viewModel.allFollowUps.contains { $0.label == "ELI5" })
    }

    func testReorderUpdatesFollowUpOrder() {
        let original = viewModel.allFollowUps
        let reversedIDs = original.reversed().map(\.id)

        viewModel.reorder(ids: reversedIDs, within: .followUp)

        XCTAssertEqual(viewModel.allFollowUps.map(\.id), reversedIDs)
    }
}
