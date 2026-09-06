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

    func testUpdatingOtherPromptWithInvalidLegacySettingsPreservesEditorErrors() throws {
        let editing = Prompt(name: "Editing", content: "Content", category: .result, isBuiltIn: false)
        let invalid = Prompt(
            name: "Legacy invalid", content: "Old", category: .result, isBuiltIn: false,
            inferenceSettings: PromptInferenceSettings(temperature: 99))
        try repo.save(editing)
        try repo.save(invalid)
        viewModel.beginEditing(editing)
        viewModel.editingInferenceSettings.temperature = "bad"
        viewModel.updatePrompt(editing, name: editing.name, content: editing.content)
        let editorErrors = viewModel.editingInferenceValidationErrors
        XCTAssertFalse(editorErrors.isEmpty)
        viewModel.updatePrompt(invalid, name: "Renamed", content: "New")
        XCTAssertEqual(viewModel.editingInferenceValidationErrors, editorErrors)
        XCTAssertEqual(viewModel.editingPrompt?.id, editing.id)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(try repo.fetch(id: invalid.id)?.content, "Old")
    }

    func testAddPromptCreatesCustomSummaryPrompt() {
        viewModel.newName = "Standup Notes"
        viewModel.newContent = "Summarize as a daily standup."

        viewModel.addPrompt()

        // 6 `.result` built-ins + 1 custom. Transform built-ins live in the
        // same table but are intentionally not part of the summary library.
        XCTAssertEqual(viewModel.prompts.count, 7)
        let prompt = viewModel.prompts.first { $0.name == "Standup Notes" && !$0.isBuiltIn }
        XCTAssertNotNil(prompt)
        XCTAssertFalse(prompt?.includeMeetingNotes ?? true)
    }

    func testAddPromptPersistsMeetingNotesPreferenceAndResetsDraft() throws {
        viewModel.newName = "Meeting Follow-up"
        viewModel.newContent = "Extract decisions."
        viewModel.newIncludeMeetingNotes = true

        viewModel.addPrompt()

        let prompt = try XCTUnwrap(viewModel.prompts.first { $0.name == "Meeting Follow-up" })
        XCTAssertTrue(prompt.includeMeetingNotes)
        XCTAssertFalse(viewModel.newIncludeMeetingNotes)
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

    func testEditPromptLoadsAndPersistsMeetingNotesPreference() throws {
        let custom = Prompt(
            name: "Old",
            content: "Old content",
            isBuiltIn: false,
            sortOrder: 99,
            includeMeetingNotes: true
        )
        repo.prompts.append(custom)
        viewModel.loadPrompts()

        viewModel.beginEditing(custom)
        XCTAssertTrue(viewModel.editingIncludeMeetingNotes)
        viewModel.editingIncludeMeetingNotes = false
        viewModel.updatePrompt(custom, name: "New", content: "New content")

        let updated = try XCTUnwrap(viewModel.prompts.first { $0.id == custom.id })
        XCTAssertFalse(updated.includeMeetingNotes)
        XCTAssertFalse(viewModel.editingIncludeMeetingNotes)
    }

    func testCancelEditingRestoresMeetingNotesDraftDefaultWithoutPersisting() throws {
        let custom = Prompt(
            name: "Meeting",
            content: "Summarize.",
            isBuiltIn: false,
            sortOrder: 99,
            includeMeetingNotes: true
        )
        repo.prompts.append(custom)
        viewModel.loadPrompts()

        viewModel.beginEditing(custom)
        viewModel.editingIncludeMeetingNotes = false
        viewModel.cancelEditing()

        XCTAssertFalse(viewModel.editingIncludeMeetingNotes)
        XCTAssertTrue(try XCTUnwrap(repo.fetch(id: custom.id)).includeMeetingNotes)

        viewModel.beginEditing(custom)
        XCTAssertTrue(viewModel.editingIncludeMeetingNotes)
    }

    func testSetIncludeMeetingNotesUpdatesBuiltInAndCustomResultPrompts() throws {
        let builtIn = try XCTUnwrap(viewModel.prompts.first(where: \.isBuiltIn))
        let custom = Prompt(name: "Custom", content: "Summarize.", isBuiltIn: false, sortOrder: 99)
        repo.prompts.append(custom)
        viewModel.loadPrompts()

        viewModel.setIncludeMeetingNotes(builtIn, enabled: true)
        viewModel.setIncludeMeetingNotes(custom, enabled: true)

        XCTAssertTrue(try XCTUnwrap(viewModel.prompts.first { $0.id == builtIn.id }).includeMeetingNotes)
        XCTAssertTrue(try XCTUnwrap(viewModel.prompts.first { $0.id == custom.id }).includeMeetingNotes)
    }

    func testSetIncludeMeetingNotesIgnoresTransformPrompts() throws {
        let transform = try XCTUnwrap(repo.prompts.first { $0.category == .transform })

        viewModel.setIncludeMeetingNotes(transform, enabled: true)

        XCTAssertFalse(try XCTUnwrap(repo.fetch(id: transform.id)).includeMeetingNotes)
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

    func testCompactInferenceSummaryUsesStableOrdering() {
        let summary = PromptsViewModel.compactInferenceSummary(
            PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .enabled,
                reasoningEffort: .medium
            )
        )

        XCTAssertEqual(
            summary,
            "Temp 0.2 · Top P 0.9 · Top K 20 · Max 4096 · Thinking on · Effort Medium"
        )
        XCTAssertNil(PromptsViewModel.compactInferenceSummary(nil))
    }

    func testCompatibilityMessageUsesCoreProviderResolver() {
        let config = LLMProviderConfig(
            id: .localCLI,
            baseURL: URL(fileURLWithPath: "/usr/bin/false"),
            apiKey: nil,
            modelName: "Custom CLI",
            isLocal: true
        )

        let message = PromptsViewModel.inferenceCompatibilityMessage(
            settings: PromptInferenceSettings(temperature: 0.2, topK: 20),
            config: config
        )

        XCTAssertEqual(message, "Not supported by this provider/model: Temperature, Top K.")
    }
}
