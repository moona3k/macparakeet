import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class PromptResultsViewModelTests: XCTestCase {
    var viewModel: PromptResultsViewModel!
    var llm: MockLLMService!
    var promptRepo: MockPromptRepository!
    var promptResultRepo: MockPromptResultRepository!
    var transcriptionRepo: MockTranscriptionRepository!

    override func setUp() {
        viewModel = PromptResultsViewModel()
        llm = MockLLMService()
        promptRepo = MockPromptRepository()
        promptResultRepo = MockPromptResultRepository()
        transcriptionRepo = MockTranscriptionRepository()
        promptRepo.prompts = Prompt.builtInPrompts()
    }

    func testConfigureLoadsVisiblePromptsAndDefaultSelection() {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )

        XCTAssertEqual(viewModel.visiblePrompts.count, 6)
        XCTAssertEqual(viewModel.selectedPrompt?.name, "Summary")
        XCTAssertTrue(viewModel.canGeneratePromptResult)
        XCTAssertTrue(viewModel.canGenerateManualPromptResult)
    }

    func testGeneratePromptResultPersistsCustomPromptAndLegacySummary() async throws {
        let transcriptionID = UUID()
        var mirroredLegacySummary: String?
        let prompt = Prompt(
            name: "Action Items",
            content: "Extract action items only.",
            category: .result,
            isBuiltIn: false,
            sortOrder: 99
        )
        promptRepo.prompts.append(prompt)

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.onLegacySummaryChanged = { _, summary in
            mirroredLegacySummary = summary
        }
        viewModel.selectedPrompt = prompt
        viewModel.extraInstructions = "Return terse bullet points."
        llm.streamTokens = ["Task ", "one"]

        viewModel.generatePromptResult(
            transcript: "Alice will send the draft tomorrow.",
            transcriptionId: transcriptionID
        )

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(promptResultRepo.saveCalls.count, 1)
        XCTAssertEqual(promptResultRepo.saveCalls[0].transcriptionId, transcriptionID)
        XCTAssertEqual(promptResultRepo.saveCalls[0].promptName, "Action Items")
        XCTAssertEqual(promptResultRepo.saveCalls[0].extraInstructions, "Return terse bullet points.")
        XCTAssertEqual(promptResultRepo.saveCalls[0].content, "Task one")
        XCTAssertEqual(transcriptionRepo.updateSummaryCalls.last?.summary, "Task one")
        XCTAssertEqual(mirroredLegacySummary, "Task one")
        XCTAssertEqual(
            llm.lastSummarySystemPrompt,
            "Extract action items only.\n\nReturn terse bullet points."
        )
        XCTAssertEqual(viewModel.promptResults.first?.content, "Task one")
    }

    func testUnreadPromptResultsTrackMultipleCompletedResults() async throws {
        let transcriptionID = UUID()
        let secondPrompt = Prompt(
            name: "Action Items",
            content: "Extract action items only.",
            category: .result,
            isBuiltIn: false,
            sortOrder: 99
        )
        promptRepo.prompts.append(secondPrompt)

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.shouldMarkPromptResultUnread = { _ in true }
        llm.streamTokens = ["Done"]

        _ = viewModel.generatePromptResult(transcript: "Transcript", transcriptionId: transcriptionID)
        viewModel.selectedPrompt = secondPrompt
        _ = viewModel.generatePromptResult(transcript: "Transcript", transcriptionId: transcriptionID)

        try await Task.sleep(for: .milliseconds(300))

        let ids = Set(viewModel.promptResults.map(\.id))
        XCTAssertEqual(viewModel.unreadPromptResultIDs, ids)

        let firstID = try XCTUnwrap(viewModel.promptResults.last?.id)
        viewModel.markPromptResultViewed(firstID)

        XCTAssertFalse(viewModel.hasUnreadPromptResult(firstID))
        XCTAssertEqual(viewModel.unreadPromptResultIDs.count, 1)
    }

    func testGeneratePromptResultRequiresSelectedVisiblePrompt() {
        for index in promptRepo.prompts.indices {
            promptRepo.prompts[index].isVisible = false
            promptRepo.prompts[index].isAutoRun = false
        }

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )

        XCTAssertTrue(viewModel.canGeneratePromptResult)
        XCTAssertFalse(viewModel.canGenerateManualPromptResult)
        XCTAssertTrue(viewModel.visiblePrompts.isEmpty)
        XCTAssertNil(viewModel.selectedPrompt)
        XCTAssertNil(viewModel.generatePromptResult(transcript: "Transcript", transcriptionId: UUID()))
        XCTAssertEqual(llm.summarizeCallCount, 0)
    }

    func testRegeneratePromptResultReplacesExistingResult() async throws {
        let transcriptionID = UUID()
        let existing = PromptResult(
            transcriptionId: transcriptionID,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Old summary"
        )
        promptResultRepo.promptResults = [existing]

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.loadPromptResults(transcriptionId: transcriptionID)
        llm.streamTokens = ["New ", "summary"]

        let generationID = viewModel.regeneratePromptResult(existing, transcript: "Transcript")

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(promptResultRepo.replaceCalls.count, 1)
        XCTAssertEqual(promptResultRepo.replaceCalls[0].deletingExistingID, existing.id)
        XCTAssertEqual(promptResultRepo.promptResults.count, 1)
        XCTAssertEqual(promptResultRepo.promptResults.first?.content, "New summary")
        XCTAssertEqual(viewModel.promptResults.first?.content, "New summary")
        XCTAssertEqual(viewModel.promptResults.first?.id, generationID)
    }

    func testDeletePromptResultUpdatesLegacySummaryFromLatestRemainingResult() throws {
        let transcriptionID = UUID()
        let older = PromptResult(
            transcriptionId: transcriptionID,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Older",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = PromptResult(
            transcriptionId: transcriptionID,
            promptName: "Action Items",
            promptContent: "Extract action items only.",
            content: "Newer",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        promptResultRepo.promptResults = [older, newer]

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.loadPromptResults(transcriptionId: transcriptionID)

        viewModel.deletePromptResult(newer)

        XCTAssertEqual(promptResultRepo.deleteCalls, [newer.id])
        XCTAssertEqual(viewModel.promptResults.map(\.content), ["Older"])
        XCTAssertEqual(transcriptionRepo.updateSummaryCalls.last?.summary, "Older")
    }

    func testAutoGeneratePromptResultsSkipsShortTranscript() {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )

        let queuedIDs = viewModel.autoGeneratePromptResults(
            transcript: "too short",
            transcriptionId: UUID()
        )

        XCTAssertTrue(queuedIDs.isEmpty)
        XCTAssertTrue(viewModel.pendingGenerations.isEmpty)
    }

    func testLoadPromptResultsClearsPendingGenerationsWhenSwitchingTranscriptions() {
        let firstTranscriptionID = UUID()
        let secondTranscriptionID = UUID()
        llm.streamDelayNs = 1_000_000_000

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )

        let transcript = String(repeating: "Long transcript ", count: 50)
        _ = viewModel.generatePromptResult(transcript: transcript, transcriptionId: firstTranscriptionID)
        _ = viewModel.generatePromptResult(transcript: transcript, transcriptionId: firstTranscriptionID)

        XCTAssertEqual(viewModel.pendingGenerations.count, 2)
        XCTAssertTrue(viewModel.hasPendingGenerations)

        viewModel.loadPromptResults(transcriptionId: secondTranscriptionID)

        XCTAssertTrue(viewModel.pendingGenerations.isEmpty)
        XCTAssertFalse(viewModel.hasPendingGenerations)
        XCTAssertEqual(viewModel.queuedGenerationCount, 0)
        XCTAssertNil(viewModel.streamingPromptResultID)
    }

    func testAutoGeneratePromptResultsDoesNothingWhenNoAutoRunPromptsAreEnabled() {
        for index in promptRepo.prompts.indices {
            promptRepo.prompts[index].isAutoRun = false
        }

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )

        let queuedIDs = viewModel.autoGeneratePromptResults(
            transcript: String(repeating: "Long transcript ", count: 50),
            transcriptionId: UUID()
        )

        XCTAssertTrue(queuedIDs.isEmpty)
        XCTAssertTrue(viewModel.pendingGenerations.isEmpty)
        XCTAssertEqual(llm.summarizeCallCount, 0)
    }
}
