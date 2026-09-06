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
        repo.prompts = Prompt.builtInPrompts()
        viewModel.configure(repo: repo)
    }

    func testLoadPromptsFiltersOutTransformCategory() {
        XCTAssertEqual(viewModel.prompts.count, 6)
        XCTAssertTrue(viewModel.prompts.allSatisfy { $0.category == .result })
        XCTAssertFalse(viewModel.prompts.contains(where: { $0.name == "Polish" }))
    }

    func testAddPromptCreatesCustomSummaryPrompt() {
        viewModel.newName = "Standup Notes"
        viewModel.newContent = "Summarize as a daily standup."

        viewModel.addPrompt()

        // 6 `.result` built-ins + 1 custom. Transform built-ins live in the
        // same table but are intentionally not part of the summary library.
        XCTAssertEqual(viewModel.prompts.count, 7)
        XCTAssertTrue(viewModel.prompts.contains(where: { $0.name == "Standup Notes" && !$0.isBuiltIn }))
    }

    func testAddPromptPersistsValidatedInferenceSettings() throws {
        viewModel.newName = "Deterministic Notes"
        viewModel.newContent = "Summarize precisely."
        viewModel.newInferenceSettings = .init(
            temperature: "0.2",
            topP: "0.9",
            topK: "20",
            maxTokens: "4096",
            thinkingMode: .enabled,
            reasoningEffort: .medium
        )

        viewModel.addPrompt()

        let prompt = try XCTUnwrap(viewModel.prompts.first { $0.name == "Deterministic Notes" })
        XCTAssertEqual(
            prompt.inferenceSettings,
            PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .enabled,
                reasoningEffort: .medium
            )
        )
        XCTAssertTrue(viewModel.newInferenceSettings.isDefault)
        XCTAssertTrue(viewModel.newInferenceValidationErrors.isEmpty)
    }

    func testAddPromptKeepsBlankInferenceFieldsUnset() throws {
        viewModel.newName = "Defaults"
        viewModel.newContent = "Use defaults."
        viewModel.newInferenceSettings = .init(
            temperature: "  ",
            topP: "",
            topK: "\n",
            maxTokens: ""
        )

        viewModel.addPrompt()

        let prompt = try XCTUnwrap(viewModel.prompts.first { $0.name == "Defaults" })
        XCTAssertNil(prompt.inferenceSettings)
    }

    func testAddPromptReportsFieldLevelInferenceValidationErrorsWithoutSaving() {
        viewModel.newName = "Invalid"
        viewModel.newContent = "Invalid settings."
        viewModel.newInferenceSettings = .init(
            temperature: "NaN",
            topP: "1.1",
            topK: "2.5",
            maxTokens: "0"
        )

        viewModel.addPrompt()

        XCTAssertFalse(viewModel.prompts.contains { $0.name == "Invalid" })
        XCTAssertNotNil(viewModel.newInferenceValidationErrors[.temperature])
        XCTAssertNotNil(viewModel.newInferenceValidationErrors[.topP])
        XCTAssertNotNil(viewModel.newInferenceValidationErrors[.topK])
        XCTAssertNotNil(viewModel.newInferenceValidationErrors[.maxTokens])
    }

    func testChangingInferenceDraftClearsItsValidationErrors() {
        viewModel.newName = "Invalid"
        viewModel.newContent = "Invalid settings."
        viewModel.newInferenceSettings.temperature = "3"
        viewModel.addPrompt()
        XCTAssertNotNil(viewModel.newInferenceValidationErrors[.temperature])

        viewModel.newInferenceSettings.temperature = "0.3"

        XCTAssertTrue(viewModel.newInferenceValidationErrors.isEmpty)
    }

    func testAddPromptRejectsDuplicateNameCaseInsensitive() {
        viewModel.newName = "summary"
        viewModel.newContent = "Duplicate"

        viewModel.addPrompt()

        // Rejected; the 6 summary built-ins remain (no add).
        XCTAssertEqual(viewModel.prompts.count, 6)
        XCTAssertEqual(viewModel.errorMessage, "'summary' already exists")
    }

    func testAddPromptRejectsDuplicateTransformNameHiddenFromLibrary() {
        viewModel.newName = "Polish"
        viewModel.newContent = "Duplicate transform name"

        viewModel.addPrompt()

        XCTAssertEqual(viewModel.prompts.count, 6)
        XCTAssertEqual(viewModel.errorMessage, "'Polish' already exists")
    }

    func testUpdatePromptRejectsDuplicateTransformNameHiddenFromLibrary() {
        let custom = Prompt(name: "Old", content: "Old content", isBuiltIn: false, sortOrder: 99)
        repo.prompts.append(custom)
        viewModel.loadPrompts()

        viewModel.updatePrompt(custom, name: "Polish", content: "New content")

        let unchanged = repo.prompts.first(where: { $0.id == custom.id })
        XCTAssertEqual(unchanged?.name, "Old")
        XCTAssertEqual(viewModel.errorMessage, "'Polish' already exists")
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
        let prompt = viewModel.prompts.first { $0.name == "Chapter Breakdown" }!

        viewModel.toggleVisibility(prompt)

        XCTAssertFalse(viewModel.prompts.first(where: { $0.id == prompt.id })?.isVisible ?? true)
    }

    func testRestoreDefaultsShowsAllBuiltIns() {
        let prompt = viewModel.prompts.first { $0.name == "Chapter Breakdown" }!
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

    func testEditPromptLoadsAndPersistsInferenceSettings() throws {
        let custom = Prompt(
            name: "Old",
            content: "Old content",
            isBuiltIn: false,
            sortOrder: 99,
            inferenceSettings: PromptInferenceSettings(temperature: 0.4, topK: 10)
        )
        repo.prompts.append(custom)
        viewModel.loadPrompts()

        viewModel.beginEditing(custom)
        XCTAssertEqual(viewModel.editingInferenceSettings.temperature, "0.4")
        XCTAssertEqual(viewModel.editingInferenceSettings.topK, "10")
        viewModel.editingInferenceSettings.temperature = "0"
        viewModel.editingInferenceSettings.topK = ""
        viewModel.editingInferenceSettings.thinkingMode = .enabled
        viewModel.editingInferenceSettings.reasoningEffort = .xhigh
        viewModel.updatePrompt(custom, name: "New", content: "New content")

        let updated = try XCTUnwrap(viewModel.prompts.first { $0.id == custom.id })
        XCTAssertEqual(updated.inferenceSettings?.temperature, 0)
        XCTAssertNil(updated.inferenceSettings?.topK)
        XCTAssertEqual(updated.inferenceSettings?.thinkingMode, .enabled)
        XCTAssertEqual(updated.inferenceSettings?.reasoningEffort, .xhigh)
    }

    func testResetInferenceDraftClearsEveryField() {
        viewModel.newInferenceSettings = .init(
            temperature: "0.2",
            topP: "0.9",
            topK: "20",
            maxTokens: "4096",
            thinkingMode: .enabled,
            reasoningEffort: .high
        )

        viewModel.resetNewInferenceSettings()

        XCTAssertEqual(viewModel.newInferenceSettings, .init())
    }

    func testBuiltInPromptCannotBeEditedThroughViewModel() {
        let builtIn = viewModel.prompts[0]

        viewModel.beginEditing(builtIn)
        viewModel.updatePrompt(builtIn, name: "Changed", content: "Changed")

        XCTAssertNil(viewModel.editingPrompt)
        XCTAssertEqual(repo.prompts.first { $0.id == builtIn.id }?.name, builtIn.name)
        XCTAssertNil(repo.prompts.first { $0.id == builtIn.id }?.inferenceSettings)
    }


}
