import XCTest
@testable import MacParakeetCore

final class SavedAudioAutoPromptCompletionServiceTests: XCTestCase {
    private var promptRepo: MockPromptRepository!
    private var promptResultRepo: MockPromptResultRepository!
    private var llm: MockLLMService!

    override func setUp() {
        super.setUp()
        promptRepo = MockPromptRepository()
        promptResultRepo = MockPromptResultRepository()
        llm = MockLLMService()
    }

    private func makeService(
        cardGenerator: CardGenerating? = nil,
        meetingArtifactStore: MeetingArtifactStoring? = nil
    ) -> SavedAudioAutoPromptCompletionService {
        SavedAudioAutoPromptCompletionService(
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            llmService: llm,
            meetingArtifactStore: meetingArtifactStore,
            cardGenerator: cardGenerator
        )
    }

    private func makeChild(
        id: UUID = UUID(),
        cleanTranscript: String = "Hello there from the freshly transcribed child meeting.",
        meetingArtifactFolderPath: String? = nil
    ) -> Transcription {
        Transcription(
            id: id,
            fileName: "Part 2",
            meetingArtifactFolderPath: meetingArtifactFolderPath,
            cleanTranscript: cleanTranscript,
            status: .completed,
            sourceType: .meeting
        )
    }

    func testCardAndArtifactFailuresRemainVisibleWithoutAutoPrompts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = makeService(cardGenerator: FailingCompletionCardGenerator(), meetingArtifactStore: FailingCompletionArtifactStore())
        let result = try await service.completeAutoPrompts(for: makeChild(meetingArtifactFolderPath: folder.path))
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertTrue(result.warnings.contains { if case .knowledgeCardFailed = $0 { return true }; return false })
        XCTAssertTrue(result.warnings.contains { if case .artifactRefreshFailed = $0 { return true }; return false })
        XCTAssertFalse(result.hasFailures, "Existing split callers only use prompt failures")
        XCTAssertTrue(result.outcomes.isEmpty)
    }

    func testArtifactRefreshStillRunsWithoutAutoPrompts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let artifacts = RecordingMeetingArtifactStore()
        let child = makeChild(meetingArtifactFolderPath: folder.path)
        let result = try await makeService(meetingArtifactStore: artifacts).completeAutoPrompts(for: child)
        let ids = await artifacts.materializedTranscriptionIDs
        XCTAssertEqual(ids, [child.id])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - No auto prompts

    func testNoAutoRunPromptsProducesNoLLMCallAndNoOutcomes() async throws {
        promptRepo.prompts = [
            Prompt(name: "Manual only", content: "Summarize {{transcript}}", isAutoRun: false)
        ]
        let service = makeService()

        let result = try await service.completeAutoPrompts(for: makeChild())

        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertEqual(llm.summarizeCallCount, 0)
        XCTAssertTrue(promptResultRepo.promptResults.isEmpty)
    }

    // MARK: - Source policy selection

    func testSourceScopedAutoRunPromptOnlyRunsForItsApplicableSource() async throws {
        let meetingOnly = Prompt(
            name: "Meeting Notes", content: "Summarize", isAutoRun: true, appliesToSources: [.meeting]
        )
        let fileOnly = Prompt(
            name: "File Notes", content: "Summarize", isAutoRun: true, appliesToSources: [.file]
        )
        promptRepo.prompts = [meetingOnly, fileOnly]
        llm.summarizeResult = "Meeting summary"
        let service = makeService()

        let result = try await service.completeAutoPrompts(for: makeChild())

        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertEqual(result.outcomes.first?.promptName, "Meeting Notes")
        XCTAssertEqual(llm.summarizeCallCount, 1)
    }

    // MARK: - Saved against the child, not the parent

    func testGeneratesAndSavesResultAgainstTheSuppliedChildTranscription() async throws {
        let parentID = UUID()
        let child = makeChild()
        promptRepo.prompts = [Prompt(name: "Summary", content: "Summarize {{transcript}}", isAutoRun: true)]
        llm.summarizeResult = "Child summary"
        let service = makeService()

        let result = try await service.completeAutoPrompts(for: child)

        XCTAssertEqual(result.outcomes.count, 1)
        guard case .generated(let promptResultID) = result.outcomes[0].status else {
            return XCTFail("expected .generated, got \(result.outcomes[0].status)")
        }
        let saved = try XCTUnwrap(promptResultRepo.promptResults.first(where: { $0.id == promptResultID }))
        XCTAssertEqual(saved.transcriptionId, child.id)
        XCTAssertNotEqual(saved.transcriptionId, parentID)
        XCTAssertEqual(saved.content, "Child summary")
    }

    // MARK: - Repeated first-processing completion is idempotent

    func testRepeatedFirstProcessingCompletionSkipsAlreadySavedResultWithoutDuplicating() async throws {
        let prompt = Prompt(name: "Summary", content: "Summarize", isAutoRun: true)
        promptRepo.prompts = [prompt]
        let child = makeChild()
        llm.summarizeResult = "First run"
        let service = makeService()

        let first = try await service.completeAutoPrompts(for: child)
        guard case .generated = first.outcomes[0].status else {
            return XCTFail("expected first attempt to generate")
        }
        XCTAssertEqual(promptResultRepo.promptResults.count, 1)

        llm.summarizeCallCount = 0
        let second = try await service.completeAutoPrompts(for: child)

        guard case .alreadyCompleted = second.outcomes[0].status else {
            return XCTFail("expected retry to skip an already-saved result")
        }
        XCTAssertEqual(llm.summarizeCallCount, 0, "retry must not call the provider again")
        XCTAssertEqual(promptResultRepo.promptResults.count, 1, "retry must not duplicate the saved result")
    }

    // MARK: - Provider failure and cancellation never fake success

    func testProviderFailureRecordsFailureWithoutSavingThenRetrySucceeds() async throws {
        let prompt = Prompt(name: "Summary", content: "Summarize", isAutoRun: true)
        promptRepo.prompts = [prompt]
        let child = makeChild()
        llm.errorToThrow = LLMError.providerError("boom")
        let service = makeService()

        let failedResult = try await service.completeAutoPrompts(for: child)

        guard case .failed(let message) = failedResult.outcomes[0].status else {
            return XCTFail("expected a failed outcome, got \(failedResult.outcomes[0].status)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(promptResultRepo.promptResults.isEmpty, "a failed generation must not save a fake result")

        llm.errorToThrow = nil
        llm.summarizeResult = "Recovered"
        let retryResult = try await service.completeAutoPrompts(for: child)

        guard case .generated = retryResult.outcomes[0].status else {
            return XCTFail("expected retry after clearing the provider error to succeed")
        }
        XCTAssertEqual(promptResultRepo.promptResults.count, 1)
        XCTAssertEqual(promptResultRepo.promptResults.first?.content, "Recovered")
    }

    func testCancellationPropagatesWithoutSavingOrRecordingAFailedOutcome() async throws {
        let prompt = Prompt(name: "Summary", content: "Summarize", isAutoRun: true)
        promptRepo.prompts = [prompt]
        let child = makeChild()
        llm.errorToThrow = CancellationError()
        let service = makeService()

        do {
            _ = try await service.completeAutoPrompts(for: child)
            XCTFail("expected CancellationError to propagate")
        } catch is CancellationError {
            // expected: cancellation is not reported as a per-prompt failure.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertTrue(promptResultRepo.promptResults.isEmpty)
    }

    // MARK: - A later failure does not erase an earlier success

    func testSuccessfulPriorPromptRetainedWhenALaterPromptFails() async throws {
        let first = Prompt(name: "Actions", content: "Actions", isAutoRun: true, sortOrder: 0)
        let second = Prompt(name: "Summary", content: "Summary", isAutoRun: true, sortOrder: 1)
        promptRepo.prompts = [first, second]
        let child = makeChild()
        llm.detailedResultsQueue = [
            .success(LLMResult(output: "Action items", provider: "mock", model: "mock-model", latencyMs: 0)),
            .failure(LLMError.providerError("second prompt failed")),
        ]
        let service = makeService()

        let result = try await service.completeAutoPrompts(for: child)

        XCTAssertEqual(result.outcomes.count, 2)
        guard case .generated = result.outcomes[0].status else {
            return XCTFail("expected the first prompt to succeed")
        }
        guard case .failed = result.outcomes[1].status else {
            return XCTFail("expected the second prompt to fail")
        }
        XCTAssertEqual(promptResultRepo.promptResults.count, 1)
        XCTAssertEqual(promptResultRepo.promptResults.first?.content, "Action items")
    }

    // MARK: - No parent content copied

    func testExistingParentPromptResultIsNeverConsideredForTheChild() async throws {
        let prompt = Prompt(name: "Summary", content: "Summarize", isAutoRun: true)
        promptRepo.prompts = [prompt]
        let parentID = UUID()
        promptResultRepo.promptResults = [
            PromptResult(
                transcriptionId: parentID,
                promptId: prompt.id,
                promptName: prompt.name,
                promptContent: prompt.content,
                content: "Parent summary"
            )
        ]
        let child = makeChild()
        llm.summarizeResult = "Child summary"
        let service = makeService()

        let result = try await service.completeAutoPrompts(for: child)

        guard case .generated = result.outcomes[0].status else {
            return XCTFail("the parent's saved result must not cause the child to be skipped")
        }
        XCTAssertEqual(promptResultRepo.promptResults.filter { $0.transcriptionId == child.id }.count, 1)
        XCTAssertEqual(promptResultRepo.promptResults.filter { $0.transcriptionId == parentID }.count, 1)
        XCTAssertEqual(promptResultRepo.promptResults.first(where: { $0.transcriptionId == child.id })?.content, "Child summary")
    }

    // MARK: - Injected configuration is respected

    func testInjectedCardGeneratorIsInvokedForConfiguredMeeting() async throws {
        promptRepo.prompts = [Prompt(name: "Summary", content: "Summarize", isAutoRun: false)]
        let child = makeChild()
        let cardGenerator = RecordingCardGenerator()
        let service = makeService(cardGenerator: cardGenerator)

        _ = try await service.completeAutoPrompts(for: child)

        let recordedIDs = await cardGenerator.transcriptionIDs
        XCTAssertEqual(recordedIDs, [child.id])
    }

    func testCompletionDoesNotReturnWhileKnowledgeCardProviderIsRunning() async throws {
        promptRepo.prompts = [Prompt(name: "Summary", content: "Summarize", isAutoRun: false)]
        let child = makeChild()
        let cardGenerator = BlockingCardGenerator()
        let completionProbe = CompletionProbe()
        let service = makeService(cardGenerator: cardGenerator)

        let completion = Task {
            let result = try await service.completeAutoPrompts(for: child)
            await completionProbe.markCompleted()
            return result
        }
        await cardGenerator.waitUntilStarted()
        await Task.yield()

        let completedWhileProviderWasBlocked = await completionProbe.didComplete
        XCTAssertFalse(completedWhileProviderWasBlocked)

        await cardGenerator.release()
        _ = try await completion.value
        let providerDidFinish = await cardGenerator.didFinish
        XCTAssertTrue(providerDidFinish)
    }

    func testCancellationDuringKnowledgeCardGenerationPropagatesWithoutAutoPrompts() async throws {
        promptRepo.prompts = [Prompt(name: "Summary", content: "Summarize", isAutoRun: false)]
        let cardGenerator = BlockingCardGenerator()
        let service = makeService(cardGenerator: cardGenerator)
        let completion = Task {
            try await service.completeAutoPrompts(for: makeChild())
        }
        await cardGenerator.waitUntilStarted()

        completion.cancel()
        await cardGenerator.release()

        do {
            _ = try await completion.value
            XCTFail("expected cancellation to propagate after card generation settles")
        } catch is CancellationError {
            // expected
        }
    }

    func testWithoutInjectedCardGeneratorNoCardGenerationIsAttempted() async throws {
        promptRepo.prompts = [Prompt(name: "Summary", content: "Summarize", isAutoRun: false)]
        let service = makeService()

        // No crash / no-op is the only assertable behavior without a
        // generator configured; this documents that omission is safe.
        _ = try await service.completeAutoPrompts(for: makeChild())
    }

    func testInjectedMeetingArtifactStoreIsRefreshedAfterCompletion() async throws {
        let prompt = Prompt(name: "Summary", content: "Summarize", isAutoRun: true)
        promptRepo.prompts = [prompt]
        let folderURL = try makeTemporaryMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let child = makeChild(meetingArtifactFolderPath: folderURL.path)
        llm.summarizeResult = "Child summary"
        let artifactStore = RecordingMeetingArtifactStore()
        let service = makeService(meetingArtifactStore: artifactStore)

        _ = try await service.completeAutoPrompts(for: child)

        let materializedIDs = await artifactStore.materializedTranscriptionIDs
        XCTAssertEqual(materializedIDs, [child.id])
    }

    /// The refresh's existence check and the materialize call happen under
    /// the same meeting-media mutation lease `TranscriptionAssetCleanup` (and
    /// a concurrent split) also acquire. Deterministic barrier, not a
    /// delete-before-check race: while another holder has that exact lease,
    /// the refresh must skip cleanly rather than resurrect/crash, and it must
    /// proceed normally once the lease is free.
    func testMeetingArtifactRefreshSkipsWhileMediaMutationLeaseIsHeldElsewhere() async throws {
        let prompt = Prompt(name: "Summary", content: "Summarize", isAutoRun: true)
        promptRepo.prompts = [prompt]
        let folderURL = try makeTemporaryMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let child = makeChild(meetingArtifactFolderPath: folderURL.path)
        llm.summarizeResult = "Child summary"
        let artifactStore = RecordingMeetingArtifactStore()
        let service = makeService(meetingArtifactStore: artifactStore)

        let root = folderURL.deletingLastPathComponent()
        let externalLease = try MeetingMediaMutationLease.acquire(roots: [root])
        defer { externalLease.release() }

        let result = try await service.completeAutoPrompts(for: child)

        XCTAssertEqual(result.outcomes.count, 1, "prompt completion itself must still succeed")
        let materializedIDs = await artifactStore.materializedTranscriptionIDs
        XCTAssertTrue(materializedIDs.isEmpty, "refresh must skip, not wait or resurrect, while the lease is held elsewhere")
    }

    private func makeTemporaryMeetingFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-audio-completion-tests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private actor RecordingCardGenerator: CardGenerating {
    private(set) var transcriptionIDs: [UUID] = []

    func generate(transcriptionId: UUID, force _: Bool) async throws -> CardGenerationOutcome {
        transcriptionIDs.append(transcriptionId)
        return CardGenerationOutcome(card: nil, usage: nil, wasSkipped: true)
    }
}

private actor BlockingCardGenerator: CardGenerating {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var released = false
    private(set) var didFinish = false

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func generate(transcriptionId _: UUID, force _: Bool) async throws -> CardGenerationOutcome {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !released {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        didFinish = true
        return CardGenerationOutcome(card: nil, usage: nil, wasSkipped: true)
    }
}

private actor CompletionProbe {
    private(set) var didComplete = false

    func markCompleted() {
        didComplete = true
    }
}

private actor RecordingMeetingArtifactStore: MeetingArtifactStoring {
    private(set) var materializedTranscriptionIDs: [UUID] = []

    func materialize(
        transcription: Transcription,
        promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot {
        materializedTranscriptionIDs.append(transcription.id)
        return MeetingArtifactSnapshot(
            generatedAt: Date(),
            meetingID: transcription.id,
            title: transcription.fileName,
            folderPath: "/tmp/mock",
            manifestPath: "/tmp/mock/manifest.json",
            markdownPath: nil,
            transcriptPath: "/tmp/mock/transcript.md",
            notesPath: nil,
            promptResultsPath: "/tmp/mock/prompt-results.json",
            promptResultsDirectoryPath: "/tmp/mock/prompt-results",
            promptResultCount: promptResults.count
        )
    }
}

private enum CompletionWarningTestError: Error { case failed }
private struct FailingCompletionCardGenerator: CardGenerating {
    func generate(transcriptionId: UUID, force: Bool) async throws -> CardGenerationOutcome {
        throw CompletionWarningTestError.failed
    }
}
private struct FailingCompletionArtifactStore: MeetingArtifactStoring {
    func materialize(transcription: Transcription, promptResults: [PromptResult]) async throws -> MeetingArtifactSnapshot {
        throw CompletionWarningTestError.failed
    }
}
