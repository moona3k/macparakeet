import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SummaryViewModelTests: XCTestCase {
    var viewModel: SummaryViewModel!
    var llm: MockLLMService!
    var promptRepo: MockPromptRepository!
    var summaryRepo: MockSummaryRepository!
    var transcriptionRepo: MockTranscriptionRepository!

    override func setUp() {
        viewModel = SummaryViewModel()
        llm = MockLLMService()
        promptRepo = MockPromptRepository()
        summaryRepo = MockSummaryRepository()
        transcriptionRepo = MockTranscriptionRepository()
        promptRepo.prompts = Prompt.builtInPrompts()
    }

    func testConfigureLoadsVisiblePromptsAndDefaultSelection() {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )

        XCTAssertEqual(viewModel.visiblePrompts.count, 7)
        XCTAssertEqual(viewModel.selectedPrompt?.name, "General Summary")
    }

    func testConfigureShowsLocalCLIPresetName() throws {
        let defaults = UserDefaults(suiteName: "test.summaryvm.localcli.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(LocalCLIConfig(commandTemplate: "claude -p --model haiku"))

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo,
            configStore: configStore,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(viewModel.currentProviderID, .localCLI)
        XCTAssertEqual(viewModel.currentModelName, "Claude Code")
        XCTAssertEqual(viewModel.modelDisplayName, "Claude Code")
        XCTAssertEqual(viewModel.availableModels, ["Claude Code"])
    }

    func testConfigureShowsCustomCLILabel() throws {
        let defaults = UserDefaults(suiteName: "test.summaryvm.customcli.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(LocalCLIConfig(commandTemplate: "python llm_wrapper.py"))

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo,
            configStore: configStore,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(viewModel.modelDisplayName, "Custom CLI")
        XCTAssertEqual(viewModel.availableModels, ["Custom CLI"])
    }

    func testGenerateSummaryPersistsCustomPromptAndInstructions() async throws {
        let transcriptionID = UUID()
        var mirroredLegacySummary: String?
        let prompt = Prompt(
            name: "Action Items",
            content: "Extract action items only.",
            isBuiltIn: false,
            sortOrder: 99
        )
        promptRepo.prompts.append(prompt)
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.onLegacySummaryChanged = { _, summary in
            mirroredLegacySummary = summary
        }
        viewModel.selectedPrompt = prompt
        viewModel.extraInstructions = "Return terse bullet points."
        llm.streamTokens = ["Task ", "one"]

        viewModel.generateSummary(
            transcript: "Alice will send the draft tomorrow.",
            transcriptionId: transcriptionID
        )

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(summaryRepo.saveCalls.count, 1)
        XCTAssertEqual(summaryRepo.saveCalls[0].transcriptionId, transcriptionID)
        XCTAssertEqual(summaryRepo.saveCalls[0].promptName, "Action Items")
        XCTAssertEqual(summaryRepo.saveCalls[0].extraInstructions, "Return terse bullet points.")
        XCTAssertEqual(summaryRepo.saveCalls[0].content, "Task one")
        XCTAssertEqual(transcriptionRepo.updateSummaryCalls.last?.summary, "Task one")
        XCTAssertEqual(mirroredLegacySummary, "Task one")
        XCTAssertEqual(
            llm.lastSummarySystemPrompt,
            "Extract action items only.\n\nReturn terse bullet points."
        )
        XCTAssertEqual(viewModel.summaries.first?.content, "Task one")
    }

    func testGenerateSummarySetsBadgeOnlyWhenRequested() async throws {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.shouldShowBadge = { _ in false }
        llm.streamTokens = ["Done"]

        viewModel.generateSummary(transcript: "Transcript", transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(viewModel.badgedSummaryID)

        viewModel.shouldShowBadge = { _ in true }
        viewModel.generateSummary(transcript: "Transcript", transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNotNil(viewModel.badgedSummaryID)
        let badgedID = viewModel.badgedSummaryID!
        viewModel.clearBadge(for: badgedID)
        XCTAssertNil(viewModel.badgedSummaryID)
    }

    func testGenerateSummaryRequiresSelectedVisiblePrompt() {
        for index in promptRepo.prompts.indices {
            promptRepo.prompts[index].isVisible = false
            promptRepo.prompts[index].isAutoRun = false
        }

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )

        XCTAssertTrue(viewModel.canGenerateSummary)
        XCTAssertFalse(viewModel.canGenerateManualSummary)
        XCTAssertTrue(viewModel.visiblePrompts.isEmpty)
        XCTAssertNil(viewModel.selectedPrompt)

        let generationID = viewModel.generateSummary(transcript: "Transcript", transcriptionId: UUID())

        XCTAssertNil(generationID)
        XCTAssertEqual(llm.summarizeCallCount, 0)
        XCTAssertTrue(viewModel.pendingGenerations.isEmpty)
    }

    func testGenerateSummaryWhileStreamingQueuesSecondRequest() async throws {
        let transcriptionID = UUID()
        let secondPrompt = Prompt(
            name: "Action Items",
            content: "Extract action items only.",
            isBuiltIn: false,
            sortOrder: 99
        )
        promptRepo.prompts.append(secondPrompt)
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        llm.streamTokens = ["First ", "summary"]
        llm.streamDelayNs = 150_000_000

        let firstGenerationID = viewModel.generateSummary(
            transcript: "Transcript",
            transcriptionId: transcriptionID
        )
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertTrue(viewModel.isStreaming)
        XCTAssertTrue(viewModel.canGenerateSummary)
        XCTAssertEqual(llm.summarizeCallCount, 1)
        XCTAssertEqual(viewModel.streamingPromptName, "General Summary")
        XCTAssertEqual(viewModel.pendingGenerations.count, 1)
        XCTAssertEqual(viewModel.pendingGenerations.first?.id, firstGenerationID)

        viewModel.selectedPrompt = secondPrompt
        let secondGenerationID = viewModel.generateSummary(
            transcript: "Transcript",
            transcriptionId: transcriptionID
        )

        XCTAssertEqual(llm.summarizeCallCount, 1)
        XCTAssertEqual(viewModel.streamingPromptName, "General Summary")
        XCTAssertEqual(viewModel.pendingGenerations.count, 2)
        XCTAssertEqual(viewModel.pendingGenerations.last?.id, secondGenerationID)
        XCTAssertEqual(viewModel.pendingGenerations.last?.state, .queued)

        try await Task.sleep(for: .milliseconds(1500))

        XCTAssertEqual(summaryRepo.saveCalls.count, 2)
        XCTAssertEqual(summaryRepo.saveCalls[0].promptName, "General Summary")
        XCTAssertEqual(summaryRepo.saveCalls[1].promptName, "Action Items")
        XCTAssertEqual(llm.summarizeCallCount, 2)
        XCTAssertEqual(viewModel.pendingGenerations.count, 0)
        XCTAssertEqual(viewModel.summaries.map(\.promptName), ["Action Items", "General Summary"])
    }

    func testGenerateSummarySamePromptWithDifferentInstructionsCreatesAnotherSummary() async throws {
        let transcriptionID = UUID()
        let existing = Summary(
            transcriptionId: transcriptionID,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            extraInstructions: "Focus on decisions.",
            content: "Old summary",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        summaryRepo.summaries = [existing]
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.loadSummaries(transcriptionId: transcriptionID)
        viewModel.selectedPrompt = Prompt.defaultPrompt
        viewModel.extraInstructions = "Focus on risks."
        llm.streamTokens = ["New ", "summary"]

        viewModel.generateSummary(transcript: "Transcript", transcriptionId: transcriptionID)

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(llm.summarizeCallCount, 1)
        XCTAssertEqual(summaryRepo.saveCalls.count, 1)
        XCTAssertTrue(summaryRepo.replaceCalls.isEmpty)
        XCTAssertEqual(summaryRepo.saveCalls[0].promptName, "General Summary")
        XCTAssertEqual(summaryRepo.saveCalls[0].extraInstructions, "Focus on risks.")
        XCTAssertEqual(summaryRepo.summaries.count, 2)
        XCTAssertEqual(viewModel.pendingGenerations.count, 0)
        XCTAssertEqual(viewModel.summaries.count, 2)
        XCTAssertEqual(viewModel.summaries.first?.content, "New summary")
        XCTAssertEqual(viewModel.summaries.last?.id, existing.id)
    }

    func testRegenerateSummaryReplacesExistingSummaryForPrompt() async throws {
        let transcriptionID = UUID()
        let existing = Summary(
            transcriptionId: transcriptionID,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Old summary",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        summaryRepo.summaries = [existing]
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.loadSummaries(transcriptionId: transcriptionID)
        llm.streamTokens = ["New ", "summary"]

        var deletedSummaryID: UUID?
        var completedGeneration: (generationID: UUID, summaryID: UUID)?
        viewModel.onDeletedSummary = { deletedSummaryID = $0 }
        viewModel.onGenerationCompleted = { generationID, summaryID in
            completedGeneration = (generationID, summaryID)
        }

        let generationID = viewModel.regenerateSummary(existing, transcript: "Transcript")

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(summaryRepo.replaceCalls.count, 1)
        XCTAssertEqual(summaryRepo.replaceCalls[0].deletingExistingID, existing.id)
        XCTAssertEqual(summaryRepo.deleteCalls, [existing.id])
        XCTAssertEqual(summaryRepo.summaries.count, 1)
        XCTAssertEqual(summaryRepo.summaries.first?.content, "New summary")
        XCTAssertEqual(viewModel.summaries.count, 1)
        XCTAssertEqual(viewModel.summaries.first?.content, "New summary")
        XCTAssertEqual(deletedSummaryID, existing.id)
        XCTAssertEqual(completedGeneration?.generationID, generationID)
        XCTAssertEqual(completedGeneration?.summaryID, viewModel.summaries.first?.id)
        XCTAssertEqual(transcriptionRepo.updateSummaryCalls.last?.summary, "New summary")
    }

    func testRegenerateSummaryCompletesBeforeDeletedCallback() async throws {
        let transcriptionID = UUID()
        let existing = Summary(
            transcriptionId: transcriptionID,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Old summary",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        summaryRepo.summaries = [existing]
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.loadSummaries(transcriptionId: transcriptionID)
        llm.streamTokens = ["New ", "summary"]

        var callbackOrder: [String] = []
        viewModel.onGenerationCompleted = { _, _ in
            callbackOrder.append("completed")
        }
        viewModel.onDeletedSummary = { _ in
            callbackOrder.append("deleted")
        }

        _ = viewModel.regenerateSummary(existing, transcript: "Transcript")

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(callbackOrder, ["completed", "deleted"])
    }

    func testLoadSummariesSwitchesTranscriptions() {
        let transcriptionA = UUID()
        let transcriptionB = UUID()
        summaryRepo.summaries = [
            Summary(
                transcriptionId: transcriptionA,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "A1",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            Summary(
                transcriptionId: transcriptionB,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "B1",
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
        ]
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )

        viewModel.loadSummaries(transcriptionId: transcriptionA)
        XCTAssertEqual(viewModel.summaries.map(\.content), ["A1"])

        viewModel.loadSummaries(transcriptionId: transcriptionB)
        XCTAssertEqual(viewModel.summaries.map(\.content), ["B1"])
    }

    func testDeleteSummaryRemovesItFromState() {
        let transcriptionID = UUID()
        var mirroredLegacySummary: String?
        let summary = Summary(
            transcriptionId: transcriptionID,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Delete me"
        )
        summaryRepo.summaries = [summary]
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.onLegacySummaryChanged = { _, summary in
            mirroredLegacySummary = summary
        }
        viewModel.loadSummaries(transcriptionId: transcriptionID)

        viewModel.deleteSummary(summary)

        XCTAssertTrue(viewModel.summaries.isEmpty)
        XCTAssertEqual(summaryRepo.deleteCalls, [summary.id])
        XCTAssertEqual(transcriptionRepo.updateSummaryCalls.last?.summary, nil)
        XCTAssertNil(mirroredLegacySummary)
    }

    func testAutoSummarizeUsesGeneralSummaryPrompt() async throws {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        llm.streamTokens = ["Auto"]
        let longTranscript = String(repeating: "word ", count: 200)

        viewModel.autoSummarize(transcript: longTranscript, transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(llm.lastSummarySystemPrompt, Prompt.defaultPrompt.content)
        XCTAssertEqual(summaryRepo.saveCalls.count, 1)
        XCTAssertEqual(transcriptionRepo.updateSummaryCalls.last?.summary, "Auto")
    }

    func testLoadSummariesSameTranscriptionDoesNotCancelInFlightStream() async throws {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        let transcriptionID = UUID()
        llm.streamTokens = ["Auto ", "summary"]
        llm.streamDelayNs = 150_000_000

        viewModel.autoSummarize(
            transcript: String(repeating: "word ", count: 200),
            transcriptionId: transcriptionID
        )
        viewModel.loadSummaries(transcriptionId: transcriptionID)

        try await Task.sleep(for: .milliseconds(1000))

        XCTAssertEqual(summaryRepo.saveCalls.count, 1)
        XCTAssertEqual(viewModel.summaries.first?.content, "Auto summary")
    }

    func testLoadSummariesDifferentTranscriptionCancelsInFlightStream() async throws {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        llm.streamTokens = ["Auto ", "summary"]
        llm.streamDelayNs = 200_000_000

        viewModel.autoSummarize(
            transcript: String(repeating: "word ", count: 200),
            transcriptionId: UUID()
        )
        viewModel.loadSummaries(transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(summaryRepo.saveCalls.isEmpty)
    }

    func testLoadSummariesDifferentTranscriptionPreservesQueuedGenerationUntilReturn() async throws {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )
        let transcriptionA = UUID()
        let transcriptionB = UUID()
        let queuedPrompt = try XCTUnwrap(promptRepo.prompts.first(where: { $0.name == "Action Items" }))
        llm.streamTokens = ["First ", "summary"]
        llm.streamDelayNs = 200_000_000

        viewModel.selectedPrompt = Prompt.defaultPrompt
        _ = viewModel.generateSummary(transcript: "Transcript", transcriptionId: transcriptionA)
        viewModel.selectedPrompt = queuedPrompt
        let queuedGenerationID = viewModel.generateSummary(transcript: "Transcript", transcriptionId: transcriptionA)

        viewModel.loadSummaries(transcriptionId: transcriptionB)

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(summaryRepo.saveCalls.isEmpty)
        XCTAssertEqual(llm.summarizeCallCount, 1)
        XCTAssertEqual(viewModel.pendingGenerations.count, 1)
        XCTAssertEqual(viewModel.pendingGenerations.first?.id, queuedGenerationID)
        XCTAssertEqual(viewModel.pendingGenerations.first?.state, .queued)
        XCTAssertEqual(viewModel.pendingGenerations.first?.transcriptionId, transcriptionA)

        llm.streamTokens = ["Queued ", "summary"]
        llm.streamDelayNs = 100_000_000

        viewModel.loadSummaries(transcriptionId: transcriptionA)

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(llm.summarizeCallCount, 2)
        XCTAssertEqual(summaryRepo.saveCalls.count, 1)
        XCTAssertEqual(summaryRepo.saveCalls.first?.promptName, queuedPrompt.name)
        XCTAssertEqual(summaryRepo.saveCalls.first?.content, "Queued summary")
        XCTAssertEqual(viewModel.pendingGenerations.count, 0)
    }

    func testPendingGenerationsAreScopedToTranscription() {
        let transcriptionA = UUID()
        let transcriptionB = UUID()
        let pendingA = SummaryViewModel.PendingGeneration(
            transcriptionId: transcriptionA,
            promptName: "General Summary",
            promptContent: "Prompt A",
            extraInstructions: nil,
            transcript: "Transcript A"
        )
        let pendingB = SummaryViewModel.PendingGeneration(
            transcriptionId: transcriptionB,
            promptName: "Action Items",
            promptContent: "Prompt B",
            extraInstructions: nil,
            transcript: "Transcript B"
        )

        viewModel.pendingGenerations = [pendingA, pendingB]

        XCTAssertEqual(viewModel.pendingGenerations(for: transcriptionA).map(\.id), [pendingA.id])
        XCTAssertEqual(viewModel.pendingGenerations(for: transcriptionB).map(\.id), [pendingB.id])
        XCTAssertTrue(viewModel.hasPendingGeneration(promptName: "General Summary", transcriptionId: transcriptionA))
        XCTAssertFalse(viewModel.hasPendingGeneration(promptName: "General Summary", transcriptionId: transcriptionB))
    }
}
