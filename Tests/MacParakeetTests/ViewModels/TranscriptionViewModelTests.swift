import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptionViewModelTests: XCTestCase {
    var viewModel: TranscriptionViewModel!
    var mockService: MockTranscriptionService!
    var mockRepo: MockTranscriptionRepository!

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    override func setUp() {
        mockService = MockTranscriptionService()
        mockRepo = MockTranscriptionRepository()
        viewModel = TranscriptionViewModel()
    }

    // MARK: - Configure

    func testConfigureLoadsTranscriptions() {
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        XCTAssertEqual(viewModel.transcriptions.count, 1)
        XCTAssertEqual(viewModel.transcriptions[0].fileName, "test.mp3")
    }

    func testConfigureWithEmptyRepo() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        XCTAssertTrue(viewModel.transcriptions.isEmpty)
    }

    func testConfigureShowsLocalCLIPresetName() throws {
        let defaults = UserDefaults(suiteName: "test.summary.localcli.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(
            LocalCLIConfig(commandTemplate: "claude -p --model haiku")
        )

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        viewModel.configure(
            transcriptionService: mockService,
            transcriptionRepo: mockRepo,
            llmService: MockLLMService(),
            configStore: configStore,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(viewModel.currentProviderID, .localCLI)
        XCTAssertEqual(viewModel.currentModelName, "Claude Code")
        XCTAssertEqual(viewModel.modelDisplayName, "Claude Code")
        XCTAssertEqual(viewModel.availableModels, ["Claude Code"])
    }

    func testConfigureShowsCustomCLILabel() throws {
        let defaults = UserDefaults(suiteName: "test.summary.customcli.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(LocalCLIConfig(commandTemplate: "python llm_wrapper.py"))

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        viewModel.configure(
            transcriptionService: mockService,
            transcriptionRepo: mockRepo,
            llmService: MockLLMService(),
            configStore: configStore,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(viewModel.modelDisplayName, "Custom CLI")
        XCTAssertEqual(viewModel.availableModels, ["Custom CLI"])
    }

    // MARK: - Transcribe File

    func testTranscribeFileUpdatesState() async throws {
        let expectedResult = Transcription(
            fileName: "audio.mp3",
            rawTranscript: "Transcribed text",
            status: .completed
        )
        await mockService.configure(result: expectedResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        // The transcribeFile method uses a Task internally, so the state should be set synchronously first
        XCTAssertTrue(viewModel.isTranscribing, "Should be transcribing immediately after call")
        XCTAssertEqual(viewModel.progress, "Preparing...")
        XCTAssertNil(viewModel.errorMessage)

        // Wait for the async task to complete
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.isTranscribing, "Should not be transcribing after completion")
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertNotNil(viewModel.currentTranscription)
        XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "Transcribed text")
    }

    func testTranscribeFileErrorHandling() async throws {
        await mockService.configure(error: NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Transcription failed"
        ]))

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        XCTAssertTrue(viewModel.isTranscribing)

        // Wait for the async task to complete
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.isTranscribing, "Should not be transcribing after error")
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertNotNil(viewModel.errorMessage, "Error message should be set")
        XCTAssertEqual(viewModel.errorMessage, "Transcription failed")
        XCTAssertNil(viewModel.currentTranscription, "No transcription on error")
    }

    func testTranscribeFileProgressMessage() async throws {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let url = URL(fileURLWithPath: "/tmp/myfile.wav")
        viewModel.transcribeFile(url: url)

        XCTAssertEqual(viewModel.progress, "Preparing...", "Initial progress should be 'Preparing...'")
    }

    func testTranscribeFileClearsErrorMessage() async throws {
        await mockService.configure(error: NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "First error"
        ]))

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        // First transcription: error
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(viewModel.errorMessage)

        // Second transcription: success
        let expectedResult = Transcription(
            fileName: "audio.mp3",
            rawTranscript: "OK",
            status: .completed
        )
        await mockService.configure(result: expectedResult)
        viewModel.transcribeFile(url: url)
        XCTAssertNil(viewModel.errorMessage, "Error should be cleared when starting new transcription")
    }

    func testCancelTranscriptionResetsToIdleWithoutError() async throws {
        let expectedResult = Transcription(
            fileName: "audio.mp3",
            rawTranscript: "Transcribed text",
            status: .completed
        )
        await mockService.configure(result: expectedResult)
        await mockService.configureDelay(milliseconds: 500)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        XCTAssertTrue(viewModel.isTranscribing)

        viewModel.cancelTranscription()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.currentTranscription)
    }

    func testStartingNewTranscriptionCancelsInFlightRequest() async throws {
        let firstResult = Transcription(
            fileName: "first.mp3",
            rawTranscript: "First result",
            status: .completed
        )
        let secondResult = Transcription(
            fileName: "second.mp3",
            rawTranscript: "Second result",
            status: .completed
        )

        await mockService.configure(result: firstResult)
        await mockService.configureDelay(milliseconds: 500)
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        viewModel.transcribeFile(url: URL(fileURLWithPath: "/tmp/first.mp3"))
        try await Task.sleep(for: .milliseconds(50))

        await mockService.configure(result: secondResult)
        await mockService.configureDelay(milliseconds: 0)
        viewModel.transcribeFile(url: URL(fileURLWithPath: "/tmp/second.mp3"))

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "Second result")
        XCTAssertNil(viewModel.errorMessage)

        let callCount = await mockService.transcribeCallCount
        XCTAssertEqual(callCount, 2)
    }

    // MARK: - Transcribe URL

    func testTranscribeURLUpdatesState() async throws {
        let expectedResult = Transcription(
            fileName: "YouTube Video",
            rawTranscript: "URL transcript",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        await mockService.configure(result: expectedResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"

        viewModel.transcribeURL()

        XCTAssertTrue(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.progress, "Preparing...")
        XCTAssertEqual(viewModel.urlInput, "")

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "URL transcript")
        let callCount = await mockService.transcribeURLCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testTranscribeURLInvalidInputNoOp() async {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://notyoutube.com/watch?v=dQw4w9WgXcQ"

        viewModel.transcribeURL()

        XCTAssertFalse(viewModel.isTranscribing)
        let callCount = await mockService.transcribeURLCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testTranscribeURLProgressParsesDownloadPercent() async throws {
        let expectedResult = Transcription(
            fileName: "YouTube Video",
            rawTranscript: "URL transcript",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        await mockService.configure(result: expectedResult)
        await mockService.configureURLProgress(phases: [.downloading(percent: 42)])
        await mockService.configureURLDelay(milliseconds: 200)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"
        viewModel.transcribeURL()

        try await waitUntil { self.viewModel.transcriptionProgress == 0.42 }
        let progress = try XCTUnwrap(viewModel.transcriptionProgress)
        XCTAssertEqual(progress, 0.42, accuracy: 0.0001)
    }

    func testTranscribeURLProgressTracksTranscribingPercent() async throws {
        let expectedResult = Transcription(
            fileName: "YouTube Video",
            rawTranscript: "URL transcript",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        await mockService.configure(result: expectedResult)
        await mockService.configureURLProgress(phases: [.transcribing(percent: 42)])
        await mockService.configureURLDelay(milliseconds: 200)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"
        viewModel.transcribeURL()

        try await waitUntil { self.viewModel.transcriptionProgress == 0.42 }
        let progress = try XCTUnwrap(viewModel.transcriptionProgress)
        XCTAssertEqual(progress, 0.42, accuracy: 0.0001)
    }

    func testTranscribeURLProgressClearsPercentOnNonPercentPhase() async throws {
        let expectedResult = Transcription(
            fileName: "YouTube Video",
            rawTranscript: "URL transcript",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        await mockService.configure(result: expectedResult)
        await mockService.configureURLProgress(phases: [
            .downloading(percent: 42),
            .converting
        ])
        await mockService.configureURLDelay(milliseconds: 200)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"
        viewModel.transcribeURL()

        try await waitUntil { self.viewModel.progressPhase == .converting }
        XCTAssertNil(viewModel.transcriptionProgress, "Non-percent phase should clear stale progress values")
    }

    func testTranscribeURLProgressTracksPhaseHeadlineAndSourceKind() async throws {
        let expectedResult = Transcription(
            fileName: "YouTube Video",
            rawTranscript: "URL transcript",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        await mockService.configure(result: expectedResult)
        await mockService.configureURLProgress(phases: [.converting, .transcribing(percent: 12)])
        await mockService.configureURLDelay(milliseconds: 200)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"
        viewModel.transcribeURL()

        XCTAssertEqual(viewModel.sourceKind, .youtubeURL)

        try await waitUntil { self.viewModel.progressPhase == .transcribing }
        XCTAssertEqual(viewModel.progressPhase, .transcribing)
        XCTAssertEqual(viewModel.sourceKind, .youtubeURL)
        XCTAssertEqual(viewModel.progressHeadline, "Running speech recognition")
    }

    // MARK: - Duplicate URL Detection

    func testTranscribeURLShowsExistingWhenAlreadyTranscribed() async {
        let existing = Transcription(
            fileName: "Already Done",
            rawTranscript: "Existing transcript",
            status: .completed,
            sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        mockRepo.transcriptions = [existing]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"

        viewModel.transcribeURL()

        // Should show existing result immediately, no transcription started
        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.currentTranscription?.id, existing.id)
        XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "Existing transcript")
        XCTAssertEqual(viewModel.urlInput, "")
        let callCount = await mockService.transcribeURLCallCount
        XCTAssertEqual(callCount, 0, "Should not call service when duplicate exists")
    }

    func testTranscribeURLIgnoresFailedDuplicates() async throws {
        let failed = Transcription(
            fileName: "Failed Video",
            status: .error,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        mockRepo.transcriptions = [failed]

        let expectedResult = Transcription(
            fileName: "YouTube Video",
            rawTranscript: "Fresh transcript",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        await mockService.configure(result: expectedResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.urlInput = "https://youtu.be/dQw4w9WgXcQ"

        viewModel.transcribeURL()

        // Should start fresh transcription since existing one failed
        XCTAssertTrue(viewModel.isTranscribing)

        try await Task.sleep(for: .milliseconds(200))
        let finalCount = await mockService.transcribeURLCallCount
        XCTAssertEqual(finalCount, 1, "Should transcribe when only failed duplicates exist")
    }

    func testTranscribeURLMatchesDifferentURLFormats() async {
        let existing = Transcription(
            fileName: "Video",
            rawTranscript: "Transcript",
            status: .completed,
            sourceURL: "https://www.youtube.com/watch?v=awOxxHnsiv0"
        )
        mockRepo.transcriptions = [existing]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        // Same video, different URL format
        viewModel.urlInput = "https://youtu.be/awOxxHnsiv0"
        viewModel.transcribeURL()

        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.currentTranscription?.id, existing.id)
    }

    // MARK: - Delete

    func testDeleteTranscription() {
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        XCTAssertEqual(viewModel.transcriptions.count, 1)

        viewModel.deleteTranscription(t)

        XCTAssertTrue(viewModel.transcriptions.isEmpty)
        XCTAssertTrue(mockRepo.deleteCalledWith.contains(t.id))
    }

    func testDeleteYouTubeTranscriptionRemovesStoredAudioFile() throws {
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yt-audio-\(UUID().uuidString).m4a")
        let created = FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
        XCTAssertTrue(created)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let t = Transcription(
            fileName: "yt",
            filePath: audioURL.path,
            rawTranscript: "Hello",
            status: .completed,
            sourceURL: "https://youtu.be/dQw4w9WgXcQ"
        )
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.deleteTranscription(t)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDeleteCurrentTranscriptionClearsSelection() {
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.deleteTranscription(t)

        XCTAssertNil(viewModel.currentTranscription, "Deleting current transcription should clear it")
    }

    func testDeleteDoesNotClearUnrelatedCurrentTranscription() {
        let t1 = Transcription(fileName: "one.mp3", rawTranscript: "First", status: .completed)
        let t2 = Transcription(fileName: "two.mp3", rawTranscript: "Second", status: .completed)
        mockRepo.transcriptions = [t1, t2]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t1

        viewModel.deleteTranscription(t2)

        XCTAssertNotNil(viewModel.currentTranscription)
        XCTAssertEqual(viewModel.currentTranscription?.id, t1.id)
    }

    // MARK: - File Drop

    func testHandleFileDropReturnsFalseWhenAlreadyTranscribing() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.isTranscribing = true
        let handled = viewModel.handleFileDrop(providers: [])
        XCTAssertFalse(handled)
    }

    func testHandleFileDropSkipsUnsupportedAndUsesSupportedProvider() async throws {
        let expectedResult = Transcription(
            fileName: "clip.wav",
            rawTranscript: "Dropped transcript",
            status: .completed
        )
        await mockService.configure(result: expectedResult)
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        let tempDir = FileManager.default.temporaryDirectory
        let unsupportedURL = tempDir.appendingPathComponent("drop-\(UUID().uuidString).txt")
        let supportedURL = tempDir.appendingPathComponent("drop-\(UUID().uuidString).wav")
        try "text".write(to: unsupportedURL, atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: supportedURL)
        defer {
            try? FileManager.default.removeItem(at: unsupportedURL)
            try? FileManager.default.removeItem(at: supportedURL)
        }

        let unsupportedProvider = NSItemProvider(contentsOf: unsupportedURL)
        let supportedProvider = NSItemProvider(contentsOf: supportedURL)
        XCTAssertNotNil(unsupportedProvider)
        XCTAssertNotNil(supportedProvider)

        var accepted = false
        let handled = viewModel.handleFileDrop(
            providers: [unsupportedProvider!, supportedProvider!],
            onAccepted: { accepted = true }
        )
        XCTAssertTrue(handled)

        try await Task.sleep(for: .milliseconds(300))

        let callCount = await mockService.transcribeCallCount
        let lastFileURL = await mockService.lastFileURL
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(lastFileURL?.pathExtension.lowercased(), "wav")
        XCTAssertTrue(accepted)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Load

    func testLoadTranscriptionsRefreshesFromRepo() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        XCTAssertTrue(viewModel.transcriptions.isEmpty)

        // Add transcription to repo after configure
        let t = Transcription(fileName: "new.mp3", rawTranscript: "New", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.loadTranscriptions()

        XCTAssertEqual(viewModel.transcriptions.count, 1)
        XCTAssertEqual(viewModel.transcriptions[0].fileName, "new.mp3")
    }

    // MARK: - Unconfigured

    func testTranscribeFileBeforeConfigureIsNoOp() {
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        // Should not crash and state should remain unchanged
        XCTAssertFalse(viewModel.isTranscribing)
    }

    func testLoadTranscriptionsBeforeConfigureIsNoOp() {
        viewModel.loadTranscriptions()
        XCTAssertTrue(viewModel.transcriptions.isEmpty)
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertTrue(viewModel.transcriptions.isEmpty)
        XCTAssertNil(viewModel.currentTranscription)
        XCTAssertFalse(viewModel.isTranscribing)
        XCTAssertEqual(viewModel.progress, "")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isDragging)
    }

    // MARK: - LLM Integration

    func testLLMAvailableReflectsConfigState() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        XCTAssertFalse(viewModel.llmAvailable, "No LLM service = not available")

        let llm = MockLLMService()
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)
        XCTAssertTrue(viewModel.llmAvailable, "With LLM service = available")
    }

    func testGenerateSummaryStreamsTokens() async throws {
        let llm = MockLLMService()
        llm.streamTokens = ["Key ", "points ", "here."]
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)

        viewModel.generateSummary(text: "Some long transcript text")

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.summaryState, .complete)
        XCTAssertEqual(viewModel.summary, "Key points here.")
    }

    func testGenerateSummaryError() async throws {
        let llm = MockLLMService()
        llm.errorToThrow = LLMError.authenticationFailed(nil)
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)

        viewModel.generateSummary(text: "Some text")

        try await Task.sleep(nanoseconds: 200_000_000)

        if case .error = viewModel.summaryState {
            // Expected
        } else {
            XCTFail("Expected error state, got \(viewModel.summaryState)")
        }
    }

    func testCancelSummary() {
        let llm = MockLLMService()
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)

        viewModel.generateSummary(text: "Text")
        viewModel.cancelSummary()

        XCTAssertNotEqual(viewModel.summaryState, .streaming)
    }

    func testDismissSummaryResetsState() async throws {
        let llm = MockLLMService()
        llm.streamTokens = ["Summary"]
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)

        viewModel.generateSummary(text: "Text")
        try await Task.sleep(nanoseconds: 200_000_000)

        viewModel.dismissSummary()

        XCTAssertEqual(viewModel.summary, "")
        XCTAssertEqual(viewModel.summaryState, .idle)
        XCTAssertFalse(viewModel.summaryBadge)
    }

    func testAutoSummarizeTriggersForLongTranscript() async throws {
        let llm = MockLLMService()
        llm.streamTokens = ["Auto ", "summary"]
        let longText = String(repeating: "word ", count: 200) // > 500 chars

        let expectedResult = Transcription(
            fileName: "audio.mp3",
            rawTranscript: longText,
            status: .completed
        )
        await mockService.configure(result: expectedResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)

        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(llm.summarizeCallCount, 1)
        XCTAssertEqual(viewModel.summary, "Auto summary")
    }

    func testAutoSummarizeSkipsShortTranscript() async throws {
        let llm = MockLLMService()

        let expectedResult = Transcription(
            fileName: "audio.mp3",
            rawTranscript: "Short",
            status: .completed
        )
        await mockService.configure(result: expectedResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)

        let url = URL(fileURLWithPath: "/tmp/audio.mp3")
        viewModel.transcribeFile(url: url)

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(llm.summarizeCallCount, 0)
    }

    func testSummaryBadgeSetWhenNotOnSummaryTab() async throws {
        let llm = MockLLMService()
        llm.streamTokens = ["Done"]
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)
        viewModel.selectedTab = .transcript

        viewModel.generateSummary(text: "Some text to summarize for testing badge behavior")

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(viewModel.summaryBadge)
    }

    func testUpdateLLMAvailability() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        XCTAssertFalse(viewModel.llmAvailable)

        let llm = MockLLMService()
        viewModel.updateLLMAvailability(true, llmService: llm)
        XCTAssertTrue(viewModel.llmAvailable)
    }

    func testUpdateLLMAvailabilityClearsServiceWhenDisabled() {
        let llm = MockLLMService()
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)
        XCTAssertTrue(viewModel.llmAvailable)

        // Clearing config should nil out the service so summary can't trigger
        viewModel.updateLLMAvailability(false)
        XCTAssertFalse(viewModel.llmAvailable)

        // generateSummary should be a no-op now (guards on llmService)
        viewModel.generateSummary(text: String(repeating: "x", count: 600))
        XCTAssertEqual(viewModel.summaryState, .idle)
    }

    // MARK: - Speaker Rename

    func testRenameSpeakerUpdatesInMemoryState() {
        let speakers = [
            SpeakerInfo(id: "S1", label: "Speaker 1"),
            SpeakerInfo(id: "S2", label: "Speaker 2")
        ]
        let t = Transcription(fileName: "test.mp3", speakers: speakers, status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.renameSpeaker(id: "S1", to: "Sarah")

        XCTAssertEqual(viewModel.currentTranscription?.speakers?[0].label, "Sarah")
        XCTAssertEqual(viewModel.currentTranscription?.speakers?[1].label, "Speaker 2")
    }

    func testRenameSpeakerPersistsToRepo() {
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        let t = Transcription(fileName: "test.mp3", speakers: speakers, status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.renameSpeaker(id: "S1", to: "Alice")

        XCTAssertEqual(mockRepo.updateSpeakersCalls.count, 1)
        XCTAssertEqual(mockRepo.updateSpeakersCalls[0].speakers?[0].label, "Alice")
    }

    func testRenameSpeakerIgnoresEmptyLabel() {
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        let t = Transcription(fileName: "test.mp3", speakers: speakers, status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.renameSpeaker(id: "S1", to: "   ")

        XCTAssertEqual(viewModel.currentTranscription?.speakers?[0].label, "Speaker 1")
        XCTAssertTrue(mockRepo.updateSpeakersCalls.isEmpty)
    }

    func testRenameSpeakerIgnoresUnknownId() {
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        let t = Transcription(fileName: "test.mp3", speakers: speakers, status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.renameSpeaker(id: "S999", to: "Nobody")

        XCTAssertEqual(viewModel.currentTranscription?.speakers?[0].label, "Speaker 1")
        XCTAssertTrue(mockRepo.updateSpeakersCalls.isEmpty)
    }

    func testRenameSpeakerNoOpWithoutCurrentTranscription() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        viewModel.renameSpeaker(id: "S1", to: "Alice")

        XCTAssertTrue(mockRepo.updateSpeakersCalls.isEmpty)
    }

    func testRenameSpeakerEmptySpeakersArrayIsNoOp() {
        let t = Transcription(fileName: "test.mp3", speakers: [], status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.renameSpeaker(id: "S1", to: "Alice")

        XCTAssertTrue(mockRepo.updateSpeakersCalls.isEmpty)
        XCTAssertEqual(viewModel.currentTranscription?.speakers?.count, 0)
    }

    func testRenameSpeakerSameLabelIsNoOp() {
        let speakers = [SpeakerInfo(id: "S1", label: "Alice")]
        let t = Transcription(fileName: "test.mp3", speakers: speakers, status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.renameSpeaker(id: "S1", to: "Alice")

        XCTAssertTrue(mockRepo.updateSpeakersCalls.isEmpty, "Same label should not trigger DB write")
    }

    func testRenameSpeakerTrimsWhitespace() {
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        let t = Transcription(fileName: "test.mp3", speakers: speakers, status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.renameSpeaker(id: "S1", to: "  Alice  ")

        XCTAssertEqual(viewModel.currentTranscription?.speakers?[0].label, "Alice")
    }

    // MARK: - Tab Visibility

    func testShowTabsTrueWhenLLMAvailable() {
        let llm = MockLLMService()
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)
        XCTAssertTrue(viewModel.showTabs)
    }

    func testShowTabsTrueWhenSavedSummaryExists() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = Transcription(
            fileName: "test.mp3", summary: "A summary", status: .completed
        )
        XCTAssertFalse(viewModel.llmAvailable)
        XCTAssertTrue(viewModel.showTabs)
    }

    func testShowTabsTrueWhenHasConversations() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = Transcription(
            fileName: "test.mp3",
            status: .completed
        )
        viewModel.hasConversations = true
        XCTAssertFalse(viewModel.llmAvailable)
        XCTAssertTrue(viewModel.showTabs)
    }

    func testShowTabsFalseWhenNothingAvailable() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = Transcription(fileName: "test.mp3", status: .completed)
        XCTAssertFalse(viewModel.showTabs)
    }

    func testUpdateConversationStatusUpdatesShowTabs() {
        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        let transcription = Transcription(
            fileName: "test.mp3",
            status: .completed
        )
        viewModel.currentTranscription = transcription
        viewModel.hasConversations = true

        XCTAssertTrue(viewModel.showTabs)

        viewModel.updateConversationStatus(id: transcription.id, hasConversations: false)

        XCTAssertFalse(viewModel.showTabs)
        XCTAssertFalse(viewModel.hasConversations)
    }

    // MARK: - Summary Persistence

    func testDismissSummaryPersistsNull() async throws {
        let llm = MockLLMService()
        llm.streamTokens = ["Summary"]
        let t = Transcription(fileName: "test.mp3", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)
        viewModel.currentTranscription = t

        viewModel.generateSummary(text: "Some text")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.summaryState, .complete)

        viewModel.dismissSummary()

        XCTAssertEqual(mockRepo.updateSummaryCalls.last?.summary, nil)
        XCTAssertNil(viewModel.currentTranscription?.summary)
    }

    func testGenerateSummaryPersistsResult() async throws {
        let llm = MockLLMService()
        llm.streamTokens = ["Persisted ", "summary"]
        let t = Transcription(fileName: "test.mp3", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)
        viewModel.currentTranscription = t

        viewModel.generateSummary(text: "Some text")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.summaryState, .complete)
        XCTAssertEqual(mockRepo.updateSummaryCalls.last?.summary, "Persisted summary")
        XCTAssertEqual(viewModel.currentTranscription?.summary, "Persisted summary")
    }

    // MARK: - Load Persisted Summary

    func testResetSummaryStateDoesNotPersistToDatabase() async throws {
        let llm = MockLLMService()
        llm.streamTokens = ["Summary"]
        let t = Transcription(fileName: "test.mp3", summary: "Existing summary", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo, llmService: llm)
        viewModel.currentTranscription = t

        viewModel.resetSummaryState()

        XCTAssertEqual(viewModel.summary, "")
        XCTAssertEqual(viewModel.summaryState, .idle)
        XCTAssertTrue(mockRepo.updateSummaryCalls.isEmpty, "resetSummaryState should NOT touch the database")
        // The transcription's persisted summary should be untouched
        XCTAssertEqual(mockRepo.transcriptions[0].summary, "Existing summary")
    }

    func testLoadPersistedContentRestoresSummary() {
        let t = Transcription(fileName: "test.mp3", summary: "Saved summary", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        viewModel.loadPersistedContent()

        XCTAssertEqual(viewModel.summary, "Saved summary")
        XCTAssertEqual(viewModel.summaryState, .complete)
    }

    func testLoadPersistedContentRefreshesFromDB() {
        let t = Transcription(fileName: "test.mp3", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        viewModel.currentTranscription = t

        // Simulate summary persisted to DB but not in the in-memory currentTranscription
        mockRepo.transcriptions[0].summary = "DB summary"

        viewModel.loadPersistedContent()

        XCTAssertEqual(viewModel.summary, "DB summary")
        XCTAssertEqual(viewModel.summaryState, .complete)
        XCTAssertEqual(viewModel.currentTranscription?.summary, "DB summary")
    }

    // MARK: - Retranscribe

    func testRetranscribeDeletesOriginalAndCreatesNewRecord() async throws {
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("retranscribe-test.mp3")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let original = Transcription(
            id: UUID(),
            fileName: "lecture.mp3",
            filePath: tmpFile.path,
            rawTranscript: "Old transcript",
            status: .completed,
            sourceURL: "https://youtube.com/watch?v=abc123"
        )
        mockRepo.transcriptions = [original]

        let newResult = Transcription(
            fileName: tmpFile.lastPathComponent,
            rawTranscript: "New transcript",
            status: .completed
        )
        await mockService.configure(result: newResult)

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        viewModel.retranscribe(original)

        try await Task.sleep(for: .milliseconds(300))

        // Original should be deleted
        XCTAssertTrue(mockRepo.deleteCalledWith.contains(original.id),
                       "Original transcription should be deleted after retranscribe")

        // New record should be saved (the one from the service, with metadata preserved)
        let saved = mockRepo.transcriptions
        XCTAssertEqual(saved.count, 1, "Should have exactly one record (old deleted, new saved)")
        XCTAssertNotEqual(saved.first?.id, original.id, "New record should have a different ID")
        XCTAssertEqual(saved.first?.fileName, "lecture.mp3", "Should preserve original fileName")
        XCTAssertEqual(saved.first?.sourceURL, "https://youtube.com/watch?v=abc123",
                       "Should preserve original sourceURL")
    }

    func testRetranscribeDoesNothingWhenFileIsMissing() async throws {
        let original = Transcription(
            fileName: "gone.mp3",
            filePath: "/tmp/nonexistent-\(UUID()).mp3",
            rawTranscript: "Old transcript",
            status: .completed
        )
        mockRepo.transcriptions = [original]

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        viewModel.retranscribe(original)

        try await Task.sleep(for: .milliseconds(100))

        // Should not start transcription at all
        XCTAssertFalse(viewModel.isTranscribing)
        let callCount = await mockService.transcribeCallCount
        XCTAssertEqual(callCount, 0, "Should not call transcribe when file is missing")
        XCTAssertTrue(mockRepo.deleteCalledWith.isEmpty, "Should not delete anything")
    }

    func testRetranscribeFailureLeavesOriginalIntact() async throws {
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("retranscribe-fail-test.mp3")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let original = Transcription(
            fileName: "lecture.mp3",
            filePath: tmpFile.path,
            rawTranscript: "Old transcript",
            status: .completed
        )
        mockRepo.transcriptions = [original]

        await mockService.configure(error: NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "STT engine failed"
        ]))

        viewModel.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)

        viewModel.retranscribe(original)

        try await Task.sleep(for: .milliseconds(300))

        // Original should NOT be deleted on failure
        XCTAssertTrue(mockRepo.deleteCalledWith.isEmpty,
                       "Original should not be deleted when retranscribe fails")
        XCTAssertEqual(mockRepo.transcriptions.count, 1, "Original should still exist")
        XCTAssertEqual(mockRepo.transcriptions.first?.id, original.id)
    }
}
