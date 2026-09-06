import XCTest
import GRDB
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
        XCTAssertTrue(viewModel.managedPrompts.contains(where: { $0.name == "Polish" }))
    }

    func testCreatingPromptPersistsSelectedLabelTargets() throws {
        let manager = try DatabaseManager()
        let promptRepository = PromptRepository(dbQueue: manager.dbQueue)
        let labelRepository = MeetingLabelRepository(dbQueue: manager.dbQueue)
        let policyRepository = PromptLabelPolicyRepository(dbQueue: manager.dbQueue)
        let customer = MeetingLabel(name: "Customer")
        try labelRepository.save(customer)
        let subject = PromptsViewModel()
        subject.configure(
            repo: promptRepository,
            labelRepository: labelRepository,
            labelPolicyRepository: policyRepository
        )
        subject.newName = "Customer follow-up"
        subject.newContent = "Draft the next steps."
        subject.newTargetLabelIDs = [customer.id]

        subject.addPrompt()

        let created = try XCTUnwrap(
            promptRepository.fetchAll().first { $0.name == "Customer follow-up" }
        )
        XCTAssertEqual(subject.labelIDsByPromptID[created.id], [customer.id])
        XCTAssertEqual(
            Set(try policyRepository.fetchPolicies(promptId: created.id).compactMap {
                $0.scopeKind == .label && $0.isAvailable ? $0.labelId : nil
            }),
            [customer.id]
        )
    }

    func testUnrelatedEditsPreserveMigratedPolicyShapes() throws {
        for shape in 0..<3 {
            let manager = try DatabaseManager()
            let prompts = PromptRepository(dbQueue: manager.dbQueue)
            let labels = MeetingLabelRepository(dbQueue: manager.dbQueue)
            let policies = PromptLabelPolicyRepository(dbQueue: manager.dbQueue)
            let label = MeetingLabel(name: "Restricted")
            try labels.save(label)
            let prompt = Prompt(name: "Policy shape \(shape)", content: "Original")
            try prompts.save(prompt)
            if shape != 2 {
                try policies.setAvailability(promptId: prompt.id, labelId: nil, isAvailable: shape == 1)
            }
            if shape != 0 {
                // Seed the migrated shape exactly, including no fallback.
                try manager.dbQueue.write { db in
                    try PromptLabelPolicy(
                        promptId: prompt.id, scopeKind: .label, labelId: label.id, isAvailable: shape == 2
                    ).insert(db)
                }
            }
            let originalPolicies = try policies.fetchPolicies(promptId: prompt.id)
            let subject = PromptsViewModel()
            subject.configure(repo: prompts, labelRepository: labels, labelPolicyRepository: policies)
            subject.beginEditing(prompt)
            subject.updatePrompt(prompt, name: "Renamed", content: "Revised content")
            XCTAssertNil(subject.errorMessage)
            XCTAssertEqual(try policies.fetchPolicies(promptId: prompt.id), originalPolicies)
            // Non-editor callers must preserve the policy too.
            let revised = try XCTUnwrap(prompts.fetch(id: prompt.id))
            subject.updatePrompt(revised, name: "Renamed again", content: "Another revision")
            XCTAssertEqual(try policies.fetchPolicies(promptId: prompt.id), originalPolicies)
            let saved = try XCTUnwrap(prompts.fetch(id: prompt.id))
            for labelIDs in [Set<UUID>(), Set([label.id])] {
                XCTAssertEqual(
                    PromptLabelApplicabilityResolver.resolve(
                        prompt: saved, sourceType: .meeting, transcriptionLabelIDs: labelIDs,
                        policies: try policies.fetchPolicies(promptId: prompt.id)
                    ).isAvailable,
                    PromptLabelApplicabilityResolver.resolve(
                        prompt: prompt, sourceType: .meeting, transcriptionLabelIDs: labelIDs,
                        policies: originalPolicies
                    ).isAvailable
                )
            }
            // An explicit targeting edit still installs the simple picker rules.
            subject.beginEditing(saved)
            subject.editingTargetLabelIDs = [label.id]
            subject.updatePrompt(saved, name: saved.name, content: saved.content)
            XCTAssertNil(subject.errorMessage)
            let changed = try policies.fetchPolicies(promptId: prompt.id)
            XCTAssertTrue(changed.contains { $0.scopeKind == .all && !$0.isAvailable })
            XCTAssertTrue(changed.contains { $0.labelId == label.id && $0.isAvailable })
        }
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
        viewModel.newModelOverride = "  local-model-v2  "

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
        XCTAssertEqual(prompt.modelOverride, "local-model-v2")
        XCTAssertEqual(viewModel.newModelOverride, "")
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
        viewModel.editingModelOverride = "  qwen-next  "
        viewModel.updatePrompt(custom, name: "New", content: "New content")

        let updated = try XCTUnwrap(viewModel.prompts.first { $0.id == custom.id })
        XCTAssertEqual(updated.inferenceSettings?.temperature, 0)
        XCTAssertNil(updated.inferenceSettings?.topK)
        XCTAssertEqual(updated.inferenceSettings?.thinkingMode, .enabled)
        XCTAssertEqual(updated.inferenceSettings?.reasoningEffort, .xhigh)
        XCTAssertEqual(updated.modelOverride, "qwen-next")
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

    func testBuiltInPromptCanBeEditedThroughViewModel() throws {
        let builtIn = viewModel.prompts[0]

        viewModel.beginEditing(builtIn)
        viewModel.editingInferenceSettings.temperature = "0.3"
        viewModel.updatePrompt(builtIn, name: "Changed", content: "Changed")

        XCTAssertNil(viewModel.editingPrompt)
        let updated = try XCTUnwrap(repo.prompts.first { $0.id == builtIn.id })
        XCTAssertEqual(updated.name, "Changed")
        XCTAssertEqual(updated.content, "Changed")
        XCTAssertEqual(updated.inferenceSettings?.temperature, 0.3)
        XCTAssertTrue(updated.isBuiltIn)
    }

    func testBuiltInPromptCanBeDeletedThroughViewModel() {
        let builtIn = viewModel.prompts[0]

        viewModel.deletePrompt(builtIn)

        XCTAssertFalse(repo.prompts.contains { $0.id == builtIn.id })
        XCTAssertFalse(viewModel.prompts.contains { $0.id == builtIn.id })
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

    func testBeginEditingLoadsNewestVersions() {
        let prompt = viewModel.prompts[0]
        let versionRepo = MockPromptVersionRepository()
        versionRepo.versions = [
            PromptVersion(promptId: prompt.id, versionNumber: 1, content: "Old"),
            PromptVersion(promptId: prompt.id, versionNumber: 2, content: "Current"),
        ]
        viewModel.configure(repo: repo, versionRepo: versionRepo)

        viewModel.beginEditing(prompt)

        XCTAssertEqual(viewModel.promptVersions.map(\.versionNumber), [2, 1])
    }

    func testCreateAndEditPromptPersistCollectionMembership() throws {
        let collection = PromptCollection(name: "Meetings")
        let collectionRepo = MockPromptCollectionRepository(collections: [collection])
        viewModel.configure(repo: repo, collectionRepo: collectionRepo)
        viewModel.newName = "Customer recap"
        viewModel.newContent = "Summarize the meeting."
        viewModel.newCollectionID = collection.id

        viewModel.addPrompt()

        var prompt = try XCTUnwrap(viewModel.prompts.first { $0.name == "Customer recap" })
        XCTAssertEqual(prompt.collectionId, collection.id)
        XCTAssertEqual(viewModel.collections, [collection])

        viewModel.beginEditing(prompt)
        viewModel.editingCollectionID = nil
        viewModel.updatePrompt(prompt, name: prompt.name, content: prompt.content)
        prompt = try XCTUnwrap(viewModel.prompts.first { $0.id == prompt.id })
        XCTAssertNil(prompt.collectionId)
    }

    func testEditingCollectionMembershipCountsAsDirty() {
        let prompt = viewModel.prompts[0]
        viewModel.beginEditing(prompt)
        viewModel.editingCollectionID = UUID()

        XCTAssertTrue(
            viewModel.hasEditingChanges(
                prompt: prompt,
                name: prompt.name,
                content: prompt.content
            )
        )
    }

    func testModelOverrideAloneCountsAsCustomGenerationSettings() {
        XCTAssertTrue(
            PromptsViewModel.hasCustomGenerationSettings(
                draft: .init(),
                modelOverride: "qwen-next"
            )
        )
        XCTAssertFalse(
            PromptsViewModel.hasCustomGenerationSettings(
                draft: .init(),
                modelOverride: "  "
            )
        )
    }

    func testCollectionCRUDAndReorder() throws {
        let first = PromptCollection(name: "First", sortOrder: 0)
        let second = PromptCollection(name: "Second", sortOrder: 1)
        let collectionRepo = MockPromptCollectionRepository(collections: [first, second])
        viewModel.configure(repo: repo, collectionRepo: collectionRepo)

        viewModel.newCollectionName = "Third"
        viewModel.createCollection()
        let third = try XCTUnwrap(viewModel.collections.first { $0.name == "Third" })
        viewModel.renameCollection(third, name: "Renamed")
        let renamed = try XCTUnwrap(viewModel.collections.first { $0.id == third.id })
        XCTAssertEqual(renamed.name, "Renamed")

        viewModel.moveCollection(renamed, by: -1)
        XCTAssertEqual(viewModel.collections.map(\.id), [first.id, renamed.id, second.id])

        viewModel.deleteCollection(renamed)
        XCTAssertFalse(viewModel.collections.contains { $0.id == renamed.id })
    }

    func testTrashRestoresBuiltInAndCustomPrompts() {
        let editingService = MockPromptEditingService(repo: repo)
        viewModel.configure(repo: repo, editingService: editingService)
        let builtIn = viewModel.prompts[0]
        let custom = Prompt(name: "Custom", content: "Content")
        repo.prompts.append(custom)
        viewModel.loadPrompts()

        viewModel.deletePrompt(builtIn)
        viewModel.deletePrompt(custom)
        XCTAssertEqual(Set(viewModel.deletedPrompts.map(\.id)), Set([builtIn.id, custom.id]))

        viewModel.restoreDeletedPrompt(builtIn)
        viewModel.restoreDeletedPrompt(custom)
        XCTAssertTrue(viewModel.deletedPrompts.isEmpty)
        XCTAssertTrue(viewModel.managedPrompts.contains { $0.id == builtIn.id })
        XCTAssertTrue(viewModel.managedPrompts.contains { $0.id == custom.id })
    }

}

private final class MockPromptVersionRepository: PromptVersionRepositoryProtocol, @unchecked Sendable {
    var versions: [PromptVersion] = []

    func fetch(id: UUID) throws -> PromptVersion? {
        versions.first { $0.id == id }
    }

    func fetchAll(promptId: UUID) throws -> [PromptVersion] {
        versions
            .filter { $0.promptId == promptId }
            .sorted { $0.versionNumber > $1.versionNumber }
    }

    func fetchActive(promptId: UUID) throws -> PromptVersion? {
        try fetchAll(promptId: promptId).first
    }
}

private final class MockPromptCollectionRepository: PromptCollectionRepositoryProtocol, @unchecked Sendable {
    var collections: [PromptCollection]

    init(collections: [PromptCollection]) {
        self.collections = collections
    }

    func save(_ collection: PromptCollection) throws {
        collections.removeAll { $0.id == collection.id }
        collections.append(collection)
    }

    func fetch(id: UUID) throws -> PromptCollection? {
        collections.first { $0.id == id }
    }

    func fetchAll() throws -> [PromptCollection] {
        collections.sorted { $0.sortOrder < $1.sortOrder }
    }

    func reorder(ids: [UUID]) throws {
        for (index, id) in ids.enumerated() {
            guard let collectionIndex = collections.firstIndex(where: { $0.id == id }) else { continue }
            collections[collectionIndex].sortOrder = index
        }
    }

    func delete(id: UUID) throws -> Bool {
        let oldCount = collections.count
        collections.removeAll { $0.id == id }
        return collections.count != oldCount
    }
}

private final class MockPromptEditingService: PromptEditingServiceProtocol, @unchecked Sendable {
    let repo: MockPromptRepository

    init(repo: MockPromptRepository) {
        self.repo = repo
    }

    func restore(promptId: UUID, versionId: UUID, changeNote: String?) throws -> Prompt {
        guard let prompt = repo.prompts.first(where: { $0.id == promptId }) else {
            throw PromptEditingError.promptNotFound
        }
        return prompt
    }

    func restoreDeleted(id: UUID) throws -> Bool {
        guard let index = repo.deletedPrompts.firstIndex(where: { $0.id == id }) else { return false }
        var prompt = repo.deletedPrompts.remove(at: index)
        prompt.deletedAt = nil
        repo.prompts.append(prompt)
        return true
    }
}
