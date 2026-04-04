import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class PromptsViewModelTests: XCTestCase {
    var viewModel: PromptsViewModel!
    var repo: MockPromptRepository!

    override func setUp() {
        viewModel = PromptsViewModel()
        repo = MockPromptRepository()
        repo.prompts = Prompt.builtInSummaryPrompts()
        viewModel.configure(repo: repo)
    }

    func testAddPromptCreatesCustomSummaryPrompt() {
        viewModel.newName = "Standup Notes"
        viewModel.newContent = "Summarize as a daily standup."

        viewModel.addPrompt()

        XCTAssertEqual(viewModel.prompts.count, 8)
        XCTAssertEqual(viewModel.prompts.last?.name, "Standup Notes")
        XCTAssertFalse(viewModel.prompts.last?.isBuiltIn ?? true)
    }

    func testAddPromptRejectsDuplicateNameCaseInsensitive() {
        viewModel.newName = "general summary"
        viewModel.newContent = "Duplicate"

        viewModel.addPrompt()

        XCTAssertEqual(viewModel.prompts.count, 7)
        XCTAssertEqual(viewModel.errorMessage, "'general summary' already exists")
    }

    func testAddPromptValidationClearsWhenFieldsChange() {
        viewModel.addPrompt()
        XCTAssertEqual(viewModel.errorMessage, "Prompt name and content are required.")

        viewModel.newName = "Hello"
        XCTAssertNil(viewModel.errorMessage)

        viewModel.addPrompt()
        XCTAssertEqual(viewModel.errorMessage, "Prompt name and content are required.")

        viewModel.newContent = "Prompt content"
        XCTAssertNil(viewModel.errorMessage)
    }

    func testToggleVisibilityChangesPromptState() {
        let prompt = viewModel.prompts.first { $0.name == "Meeting Notes" }!

        viewModel.toggleVisibility(prompt)

        XCTAssertFalse(viewModel.prompts.first(where: { $0.id == prompt.id })?.isVisible ?? true)
    }

    func testRestoreDefaultsShowsAllBuiltIns() {
        let prompt = viewModel.prompts.first { $0.name == "Meeting Notes" }!
        viewModel.toggleVisibility(prompt)
        XCTAssertFalse(viewModel.prompts.first(where: { $0.id == prompt.id })?.isVisible ?? true)

        viewModel.restoreDefaults()

        XCTAssertTrue(viewModel.prompts.filter(\.isBuiltIn).allSatisfy(\.isVisible))
    }

    func testUpdatePromptPersistsChanges() {
        let custom = Prompt(name: "Old", content: "Old content", isBuiltIn: false, sortOrder: 99)
        repo.prompts.append(custom)
        viewModel.loadPrompts()

        viewModel.updatePrompt(custom, name: "New", content: "New content")

        let updated = viewModel.prompts.first(where: { $0.id == custom.id })
        XCTAssertEqual(updated?.name, "New")
        XCTAssertEqual(updated?.content, "New content")
    }
}
