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
            promptResultRepo: promptResultRepo
        )

        // 7 built-in prompts as of v0.8 (ADR-020 added "Memo-Steered Notes").
        XCTAssertEqual(viewModel.visiblePrompts.count, 7)
        // The new "Memo-Steered Notes" prompt is sortOrder=0 and isAutoRun=true,
        // so it becomes the auto-selected default when no prior selection exists.
        XCTAssertEqual(viewModel.selectedPrompt?.name, "Memo-Steered Notes")
        XCTAssertTrue(viewModel.canGeneratePromptResult)
        XCTAssertTrue(viewModel.canGenerateManualPromptResult)
    }

    func testGeneratePromptResultPersistsCustomPromptResult() async throws {
        let transcriptionID = UUID()
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
            promptResultRepo: promptResultRepo
        )
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
            promptResultRepo: promptResultRepo
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
            promptResultRepo: promptResultRepo
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
            promptResultRepo: promptResultRepo
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

    func testDeletePromptResultRemovesResultAndKeepsRemainingPromptResults() throws {
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
            promptResultRepo: promptResultRepo
        )
        viewModel.loadPromptResults(transcriptionId: transcriptionID)

        viewModel.deletePromptResult(newer)

        XCTAssertEqual(promptResultRepo.deleteCalls, [newer.id])
        XCTAssertEqual(viewModel.promptResults.map(\.content), ["Older"])
    }

    func testAutoGeneratePromptResultsSkipsShortTranscript() {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo
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
            promptResultRepo: promptResultRepo
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
            promptResultRepo: promptResultRepo
        )

        let queuedIDs = viewModel.autoGeneratePromptResults(
            transcript: String(repeating: "Long transcript ", count: 50),
            transcriptionId: UUID()
        )

        XCTAssertTrue(queuedIDs.isEmpty)
        XCTAssertTrue(viewModel.pendingGenerations.isEmpty)
        XCTAssertEqual(llm.summarizeCallCount, 0)
    }

    // MARK: - ADR-020 §4–§6 — userNotes plumbing

    func testGeneratePromptResultSubstitutesUserNotesIntoSystemPrompt() async throws {
        let transcriptionID = UUID()
        // Seed the transcription with the user's in-meeting notes so the VM
        // picks them up via fetchUserNotes(for:).
        try transcriptionRepo.save(
            Transcription(
                id: transcriptionID,
                fileName: "meeting.m4a",
                sourceType: .meeting,
                userNotes: "decision: ship Friday\nQA owns smoke tests"
            )
        )

        let memoSteered = Prompt(
            name: "Memo-Steered Notes",
            content: "Notes:\n{{userNotes}}\n---\nProduce structured output.",
            category: .result,
            isBuiltIn: false,
            sortOrder: 0
        )
        promptRepo.prompts = [memoSteered]

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.selectedPrompt = memoSteered
        llm.streamTokens = ["done"]

        viewModel.generatePromptResult(
            transcript: "Some transcript",
            transcriptionId: transcriptionID
        )
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            llm.lastSummarySystemPrompt,
            "Notes:\ndecision: ship Friday\nQA owns smoke tests\n---\nProduce structured output."
        )
    }

    func testGeneratePromptResultSnapshotsUserNotesOntoSavedPromptResult() async throws {
        let transcriptionID = UUID()
        try transcriptionRepo.save(
            Transcription(
                id: transcriptionID,
                fileName: "meeting.m4a",
                sourceType: .meeting,
                userNotes: "snapshot me"
            )
        )

        let prompt = Prompt(
            name: "Memo",
            content: "{{userNotes}}",
            category: .result,
            isBuiltIn: false,
            sortOrder: 0
        )
        promptRepo.prompts = [prompt]

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.selectedPrompt = prompt
        llm.streamTokens = ["ok"]

        viewModel.generatePromptResult(transcript: "transcript", transcriptionId: transcriptionID)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(promptResultRepo.saveCalls.first?.userNotesSnapshot, "snapshot me")
    }

    func testGeneratePromptResultRendersEmptyWhenUserNotesAreNil() async throws {
        let transcriptionID = UUID()
        // No userNotes set — non-meeting transcript or untouched notepad.
        try transcriptionRepo.save(
            Transcription(id: transcriptionID, fileName: "podcast.m4a")
        )

        let prompt = Prompt(
            name: "Memo",
            content: "Notes: [{{userNotes}}] end",
            category: .result,
            isBuiltIn: false,
            sortOrder: 0
        )
        promptRepo.prompts = [prompt]

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.selectedPrompt = prompt
        llm.streamTokens = ["ok"]

        viewModel.generatePromptResult(transcript: "transcript", transcriptionId: transcriptionID)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(llm.lastSummarySystemPrompt, "Notes: [] end")
        XCTAssertNil(promptResultRepo.saveCalls.first?.userNotesSnapshot)
    }

    func testGeneratePromptResultLeavesNonNotesPromptsUnchangedWhenUserNotesEmpty() async throws {
        let transcriptionID = UUID()
        try transcriptionRepo.save(
            Transcription(id: transcriptionID, fileName: "f.m4a")
        )

        // A "classic" prompt with no `{{userNotes}}` reference — no regression
        // on default output for users who took no notes.
        let classic = Prompt(
            name: "Classic",
            content: "Summarize the transcript in 3 bullet points.",
            category: .result,
            isBuiltIn: false,
            sortOrder: 0
        )
        promptRepo.prompts = [classic]

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.selectedPrompt = classic
        llm.streamTokens = ["ok"]

        viewModel.generatePromptResult(transcript: "transcript", transcriptionId: transcriptionID)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            llm.lastSummarySystemPrompt,
            "Summarize the transcript in 3 bullet points."
        )
    }

    func testTruncateNotesForPromptStaysUnderSoftCap() {
        let shortNotes = "one two three four five"
        XCTAssertEqual(
            PromptResultsViewModel.truncateNotesForPrompt(shortNotes),
            shortNotes,
            "notes under the cap pass through unmodified"
        )

        let longNotes = String(repeating: "word ", count: PromptResultsViewModel.userNotesPromptWordCap + 100)
            .trimmingCharacters(in: .whitespaces)
        let truncated = PromptResultsViewModel.truncateNotesForPrompt(longNotes)
        let truncatedWordCount = truncated
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.contains("[") && !$0.contains("words") && !$0.contains("(") }
            .count
        XCTAssertLessThanOrEqual(
            truncatedWordCount,
            PromptResultsViewModel.userNotesPromptWordCap + 25,
            "truncated notes must be near the soft cap (allowing for the suffix banner)"
        )
        XCTAssertTrue(
            truncated.contains("Notes truncated to \(PromptResultsViewModel.userNotesPromptWordCap) words"),
            "truncation must include the explanatory suffix"
        )
    }

    /// Regression: Gemini review of PR #143 flagged that `truncateNotesForPrompt`
    /// used `split + join(" ")`, flattening newlines/tabs/indentation into
    /// single spaces. That destroys the structural cues (bullet lists, section
    /// headings, slash-command markers) the user typed *to steer* the summary.
    func testTruncateNotesForPromptPreservesWhitespaceInKeptPortion() {
        let cap = PromptResultsViewModel.userNotesPromptWordCap
        // Build a structured prefix the kept portion must preserve verbatim.
        let structuredPrefix = "## Roadmap\n\n**Action:** ship infra refactor\n\t- subtask: review staffing plan\n\n[6:02] confirmed"
        let filler = String(repeating: " filler", count: cap + 50)
        let input = structuredPrefix + filler

        let truncated = PromptResultsViewModel.truncateNotesForPrompt(input)

        XCTAssertTrue(
            truncated.contains("## Roadmap\n\n**Action:** ship infra refactor\n\t- subtask: review staffing plan\n\n[6:02] confirmed"),
            "Original whitespace (newlines, blank lines, tab indentation) must survive in the kept portion"
        )
        XCTAssertTrue(
            truncated.contains("Notes truncated"),
            "Truncation must still include the explanatory suffix"
        )
    }

    /// Regression: Gemini review of PR #143 flagged that `assembledSystemPrompt`
    /// didn't pass the transcript to `PromptTemplateRenderer`, so prompts
    /// containing `{{transcript}}` would render with an empty string instead
    /// of the actual transcript text. ADR-020 §4 lists `{{transcript}}` as a
    /// supported variable; this test pins the substitution.
    func testGeneratePromptResultSubstitutesTranscriptIntoSystemPrompt() async throws {
        let transcriptionID = UUID()
        try transcriptionRepo.save(
            Transcription(
                id: transcriptionID,
                fileName: "meeting.m4a",
                sourceType: .meeting
            )
        )

        let transcriptInlinePrompt = Prompt(
            name: "Inline-Transcript",
            content: "Read this:\nTRANSCRIPT:\n{{transcript}}\n---\nReply.",
            category: .result,
            isBuiltIn: false,
            sortOrder: 0
        )
        promptRepo.prompts = [transcriptInlinePrompt]

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            transcriptionRepo: transcriptionRepo
        )
        viewModel.selectedPrompt = transcriptInlinePrompt
        llm.streamTokens = ["done"]

        viewModel.generatePromptResult(
            transcript: "Sarah pushed back on shipping early.",
            transcriptionId: transcriptionID
        )
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            llm.lastSummarySystemPrompt,
            "Read this:\nTRANSCRIPT:\nSarah pushed back on shipping early.\n---\nReply.",
            "{{transcript}} must be substituted with the transcript text passed to generatePromptResult"
        )
    }

    /// Regression for the truncation-banner edge case caught in Codex
    /// fresh-eye review of PR #143: `indexAfterNthWord` returned a non-nil
    /// index whenever the n-th word was followed by trailing whitespace,
    /// triggering a false `[Notes truncated...]` banner even though the
    /// entire input fit under the cap.
    func testTruncateNotesForPromptDoesNotBannerWhenInputFitsExactlyWithTrailingWhitespace() {
        let cap = PromptResultsViewModel.userNotesPromptWordCap

        // Exactly `cap` words, ending with trailing whitespace (newline).
        let exactlyAtCap = String(repeating: "word ", count: cap) + "\n"
        let resultExact = PromptResultsViewModel.truncateNotesForPrompt(exactlyAtCap)
        XCTAssertFalse(
            resultExact.contains("Notes truncated"),
            "Input with exactly \(cap) words must NOT be banner-tagged even when followed by trailing whitespace."
        )
        XCTAssertEqual(resultExact, exactlyAtCap, "No truncation → input passes through verbatim.")

        // Fewer than `cap` words, also ending with trailing whitespace.
        let underCap = String(repeating: "word ", count: cap - 50) + "\n\n"
        let resultUnder = PromptResultsViewModel.truncateNotesForPrompt(underCap)
        XCTAssertFalse(resultUnder.contains("Notes truncated"))
        XCTAssertEqual(resultUnder, underCap)
    }
}
