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
        promptRepo.prompts = Prompt.builtInSummaryPrompts()
    }

    func testConfigureLoadsVisiblePromptsAndDefaultSelection() {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            transcriptionRepo: transcriptionRepo
        )

        XCTAssertEqual(viewModel.visiblePrompts.count, 2)
        XCTAssertEqual(viewModel.selectedPrompt?.name, "Concise Summary")
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
        viewModel.shouldShowBadge = { false }
        llm.streamTokens = ["Done"]

        viewModel.generateSummary(transcript: "Transcript", transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.summaryBadge)

        viewModel.shouldShowBadge = { true }
        viewModel.generateSummary(transcript: "Transcript", transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(viewModel.summaryBadge)
        viewModel.markSummaryTabViewed()
        XCTAssertFalse(viewModel.summaryBadge)
    }

    func testLoadSummariesSwitchesTranscriptions() {
        let transcriptionA = UUID()
        let transcriptionB = UUID()
        summaryRepo.summaries = [
            Summary(
                transcriptionId: transcriptionA,
                promptName: "Concise Summary",
                promptContent: Prompt.defaultSummaryPrompt.content,
                content: "A1",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            Summary(
                transcriptionId: transcriptionB,
                promptName: "Concise Summary",
                promptContent: Prompt.defaultSummaryPrompt.content,
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
        XCTAssertEqual(viewModel.expandedSummaryIDs.count, 1)
    }

    func testDeleteSummaryRemovesItFromState() {
        let transcriptionID = UUID()
        var mirroredLegacySummary: String?
        let summary = Summary(
            transcriptionId: transcriptionID,
            promptName: "Concise Summary",
            promptContent: Prompt.defaultSummaryPrompt.content,
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

        XCTAssertEqual(llm.lastSummarySystemPrompt, Prompt.defaultSummaryPrompt.content)
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

        try await Task.sleep(for: .milliseconds(450))

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
}
