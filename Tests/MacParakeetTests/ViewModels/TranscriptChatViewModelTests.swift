import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptChatViewModelTests: XCTestCase {
    var viewModel: TranscriptChatViewModel!
    var mockService: MockLLMService!
    var mockRepo: MockTranscriptionRepository!
    var mockConversationRepo: MockChatConversationRepository!

    override func setUp() {
        viewModel = TranscriptChatViewModel()
        mockService = MockLLMService()
        mockRepo = MockTranscriptionRepository()
        mockConversationRepo = MockChatConversationRepository()
        viewModel.configure(
            llmService: mockService,
            transcriptText: "Test transcript content here.",
            transcriptionRepo: mockRepo,
            conversationRepo: mockConversationRepo
        )
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Send Message

    func testSendMessageAppendsUserAndAssistant() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["Hello", " there"]
        viewModel.inputText = "What is this about?"

        viewModel.sendMessage()

        // Wait for streaming to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "What is this about?")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Hello there")
        XCTAssertFalse(viewModel.messages[1].isStreaming)
    }

    func testSendMessageClearsInput() {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        viewModel.inputText = "My question"
        viewModel.sendMessage()
        XCTAssertEqual(viewModel.inputText, "")
    }

    func testEmptyInputDoesNotSend() {
        viewModel.inputText = "   "
        viewModel.sendMessage()
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSendMessageWithoutLoadedTranscriptShowsConfigurationError() {
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "Question")
        XCTAssertEqual(viewModel.errorMessage, "Chat is unavailable until a transcript is loaded.")
    }

    func testSendMessageWithoutConversationRepoPreservesInput() {
        let vm = TranscriptChatViewModel()
        vm.configure(
            llmService: mockService,
            transcriptText: "Transcript",
            transcriptionRepo: mockRepo,
            conversationRepo: nil
        )
        vm.loadTranscript("Transcript", transcriptionId: UUID())
        vm.inputText = "Question"

        vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(vm.inputText, "Question")
        XCTAssertEqual(vm.errorMessage, "Chat storage is unavailable. Please relaunch.")
    }

    func testSendMessageWhileStreamingDoesNotSend() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["slow"]
        viewModel.inputText = "First"
        viewModel.sendMessage()

        // Try to send again immediately
        viewModel.inputText = "Second"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)

        // Only the first message pair should exist
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].content, "First")
    }

    // MARK: - Error Handling

    func testSendMessageWithError() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.errorToThrow = LLMError.authenticationFailed(nil)
        viewModel.inputText = "Will fail"

        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isStreaming)
        // User message stays, failed assistant message removed (empty content)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .user)
    }

    // MARK: - Clear History

    func testClearHistory() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.messages.count, 2)

        viewModel.clearHistory()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Update Transcript

    func testUpdateTranscriptClearsHistory() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.messages.count, 2)

        viewModel.updateTranscript("New transcript text")

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
    }

    func testUpdateTranscriptTextPreservesHistoryAndIsUsedOnNextSend() async throws {
        let transcriptionId = UUID()
        let conv = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Restored",
            messages: [
                ChatMessage(role: .user, content: "Question"),
                ChatMessage(role: .assistant, content: "Answer"),
            ]
        )
        mockConversationRepo.conversations = [conv]
        viewModel.loadTranscript("Plain transcript", transcriptionId: transcriptionId)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.conversations.count, 1)

        viewModel.updateTranscriptText("Rich upgraded context")

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].content, "Question")
        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.currentConversation?.id, conv.id)
        XCTAssertEqual(viewModel.inputText, "")

        mockService.streamTokens = ["ok"]
        viewModel.inputText = "Follow up"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(mockService.lastChatTranscript, "Rich upgraded context")
        XCTAssertEqual(viewModel.messages.count, 4)
    }

    func testEditRichContextUpgradeReturnsBeforeBuildCompletes() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        let transcription = Transcription(
            fileName: "edited.mp3",
            rawTranscript: "original",
            cleanTranscript: "edited",
            status: .completed
        )
        var applied: [String] = []

        let task = loader.schedule(
            transcription: transcription,
            mode: .richTranscript,
            contentRevision: 1
        ) { _, text in
            applied.append(text)
        }

        await builder.waitUntilStarted("edited")
        XCTAssertTrue(applied.isEmpty, "Scheduling must not synchronously build long rich context.")

        await builder.finish("edited", with: "rich edited context")
        await task.value
        XCTAssertEqual(applied, ["rich edited context"])
    }

    func testRevertRichContextUpgradeRejectsOlderEditCompletion() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        let transcriptionID = UUID()
        let edited = Transcription(
            id: transcriptionID,
            fileName: "edited.mp3",
            rawTranscript: "original",
            cleanTranscript: "edited",
            status: .completed
        )
        let reverted = Transcription(
            id: transcriptionID,
            fileName: "edited.mp3",
            rawTranscript: "original",
            status: .completed
        )
        var applied: [String] = []

        let editedTask = loader.schedule(
            transcription: edited,
            mode: .richTranscript,
            contentRevision: 1
        ) { _, text in
            applied.append(text)
        }
        await builder.waitUntilStarted("edited")

        let revertedTask = loader.schedule(
            transcription: reverted,
            mode: .richTranscript,
            contentRevision: 2
        ) { _, text in
            applied.append(text)
        }
        await builder.waitUntilStarted("original")

        await builder.finish("original", with: "reverted context")
        await revertedTask.value
        await builder.finish("edited", with: "stale edited context")
        await editedTask.value

        XCTAssertEqual(applied, ["reverted context"])
    }

    func testPromptActionWaitsForPreparedContextBeforeSubmitting() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        let transcription = Transcription(
            fileName: "large.mp3",
            rawTranscript: "ten-thousand-word transcript",
            status: .completed
        )
        var submitted: [String] = []

        let action = loader.startPromptAction(
            transcription: transcription,
            mode: .richTranscript,
            contentRevision: 8,
            onStale: { XCTFail("An unchanged prompt must not request a retry.") }
        ) { context in
            submitted.append(context)
        }

        await builder.waitUntilStarted("ten-thousand-word transcript")
        XCTAssertTrue(
            submitted.isEmpty,
            "Generate/Regenerate must not submit while rich context is still being prepared."
        )

        await builder.finish("ten-thousand-word transcript", with: "prepared rich context")
        await action?.value
        XCTAssertEqual(submitted, ["prepared rich context"])
    }

    func testPromptActionCannotSubmitWhenRevisionChangesDuringFormatting() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        let transcription = Transcription(
            fileName: "meeting.mp3",
            rawTranscript: "original revision",
            status: .completed
        )
        var currentRevision: UInt64 = 20
        var submitted: [String] = []
        var retryNotices = 0

        let action = loader.startPromptAction(
            transcription: transcription,
            mode: .richTranscript,
            contentRevision: 20,
            isCurrent: { request in
                request.contentRevision == currentRevision
            },
            onStale: { retryNotices += 1 }
        ) { context in
            submitted.append(context)
        }
        await builder.waitUntilStarted("original revision")

        currentRevision = 21
        await builder.finish("original revision", with: "stale context")
        await action?.value

        XCTAssertTrue(
            submitted.isEmpty,
            "A transcript changed during formatting must never submit stale context."
        )
        XCTAssertEqual(retryNotices, 1)
        XCTAssertFalse(loader.preparingPromptContext)
    }

    func testNavigationAllowsNewPromptActionBeforeOldFormatterFinishes() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        let oldTranscription = Transcription(
            fileName: "old.mp3",
            rawTranscript: "old transcript",
            status: .completed
        )
        let newTranscription = Transcription(
            fileName: "new.mp3",
            rawTranscript: "new transcript",
            status: .completed
        )
        var submitted: [String] = []
        var retryNotices = 0
        let oldAction = loader.startPromptAction(
            transcription: oldTranscription,
            mode: .richTranscript,
            contentRevision: 1,
            onStale: { retryNotices += 1 }
        ) { submitted.append($0) }
        await builder.waitUntilStarted("old transcript")

        // Navigation/disappearance releases action ownership even if the
        // detached formatter does not cooperate with cancellation.
        loader.invalidate()
        XCTAssertFalse(loader.preparingPromptContext)
        let newAction = loader.startPromptAction(
            transcription: newTranscription,
            mode: .richTranscript,
            contentRevision: 2,
            onStale: { retryNotices += 1 }
        ) { submitted.append($0) }
        guard newAction != nil else {
            XCTFail("Navigation must admit a prompt action before old formatting completes.")
            await builder.finish("old transcript", with: "stale context")
            await oldAction?.value
            return
        }
        await builder.waitUntilStarted("new transcript")

        await builder.finish("old transcript", with: "stale context")
        await oldAction?.value
        XCTAssertTrue(submitted.isEmpty, "The old action must not submit after navigation.")
        XCTAssertTrue(loader.preparingPromptContext, "Old completion must not clear the new action's busy state.")
        let duplicate = loader.startPromptAction(
            transcription: newTranscription,
            mode: .richTranscript,
            contentRevision: 2,
            onStale: { retryNotices += 1 }
        ) { submitted.append($0) }
        XCTAssertNil(duplicate, "The new action must retain exclusive submission ownership.")

        await builder.finish("new transcript", with: "new context")
        await newAction?.value
        await duplicate?.value
        XCTAssertEqual(submitted, ["new context"])
        XCTAssertFalse(loader.preparingPromptContext)
        XCTAssertEqual(retryNotices, 0, "Navigation must not notify the newly selected transcript.")
    }

    func testDisappearanceRejectsPromptCompletionWithoutReplacementAction() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        let transcription = Transcription(
            fileName: "closed.mp3",
            rawTranscript: "closed transcript",
            status: .completed
        )
        var submitted: [String] = []
        var retryNotices = 0
        let action = loader.startPromptAction(
            transcription: transcription,
            mode: .richTranscript,
            contentRevision: 1,
            onStale: { retryNotices += 1 }
        ) { submitted.append($0) }
        await builder.waitUntilStarted("closed transcript")

        loader.invalidate()
        XCTAssertFalse(loader.preparingPromptContext)
        await builder.finish("closed transcript", with: "stale context")
        await action?.value
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertFalse(loader.preparingPromptContext)
        XCTAssertEqual(retryNotices, 0)
    }

    func testPromptModeChangeRejectsInvalidatedPreparationWithRetryNotice() async {
        let builder = ControlledRichContextBuilder()
        let plainBuilder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            if mode == .plainTranscript {
                return await plainBuilder.build(transcription, mode)
            }
            return await builder.build(transcription, mode)
        }
        let transcription = Transcription(
            fileName: "meeting.mp3",
            rawTranscript: "mode change",
            status: .completed
        )
        var currentMode = TranscriptAIContextMode.richTranscript
        var submitted: [String] = []
        var retryNotices = 0
        let action = loader.startPromptAction(
            transcription: transcription,
            mode: currentMode,
            contentRevision: 1,
            isCurrent: { $0.mode == currentMode },
            onStale: { retryNotices += 1 }
        ) { submitted.append($0) }
        await builder.waitUntilStarted("mode change")

        currentMode = .plainTranscript
        // A chat refresh supersedes shared formatting, but not prompt ownership.
        let refresh = loader.schedule(
            transcription: transcription,
            mode: currentMode,
            contentRevision: 1
        ) { _, _ in }
        await plainBuilder.waitUntilStarted("mode change")
        await builder.finish("mode change", with: "old rich context")
        await action?.value
        await plainBuilder.finish("mode change", with: "plain context")
        await refresh.value

        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(retryNotices, 1)
        XCTAssertFalse(loader.preparingPromptContext)
    }

    func testCancelledPromptPreparationDoesNotShowRetryNotice() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        let transcription = Transcription(
            fileName: "cancelled.mp3",
            rawTranscript: "cancelled preparation",
            status: .completed
        )
        var currentRevision: UInt64 = 1
        var submitted: [String] = []
        var retryNotices = 0
        let action = loader.startPromptAction(
            transcription: transcription,
            mode: .richTranscript,
            contentRevision: 1,
            isCurrent: { $0.contentRevision == currentRevision },
            onStale: { retryNotices += 1 }
        ) { submitted.append($0) }
        await builder.waitUntilStarted("cancelled preparation")

        action?.cancel()
        currentRevision = 2
        await builder.finish("cancelled preparation", with: "stale context")
        await action?.value

        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(retryNotices, 0)
        XCTAssertFalse(loader.preparingPromptContext)
    }

    func testReplacementPromptOwnsRetryNoticeOnSameTranscript() async {
        let builder = ControlledRichContextBuilder()
        let loader = TranscriptRichContextLoader { transcription, mode in
            await builder.build(transcription, mode)
        }
        var transcription = Transcription(
            fileName: "replacement.mp3",
            rawTranscript: "old action",
            status: .completed
        )
        var currentRevision: UInt64 = 1
        var submitted: [String] = []
        var retryNotices: [String] = []
        let oldAction = loader.startPromptAction(
            transcription: transcription,
            mode: .richTranscript,
            contentRevision: 1,
            isCurrent: { $0.contentRevision == currentRevision },
            onStale: { retryNotices.append("old") }
        ) { submitted.append($0) }
        await builder.waitUntilStarted("old action")

        loader.invalidate()
        currentRevision = 2
        transcription.rawTranscript = "replacement action"
        let replacement = loader.startPromptAction(
            transcription: transcription,
            mode: .richTranscript,
            contentRevision: 2,
            isCurrent: { $0.contentRevision == currentRevision },
            onStale: { retryNotices.append("replacement") }
        ) { submitted.append($0) }
        await builder.waitUntilStarted("replacement action")

        await builder.finish("old action", with: "old context")
        await oldAction?.value
        XCTAssertTrue(retryNotices.isEmpty)
        XCTAssertTrue(loader.preparingPromptContext)

        currentRevision = 3
        await builder.finish("replacement action", with: "replacement context")
        await replacement?.value
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(retryNotices, ["replacement"])
        XCTAssertFalse(loader.preparingPromptContext)
    }

    // MARK: - Cancel Streaming

    func testCancelStreaming() {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        // Cancel immediately
        viewModel.cancelStreaming()

        XCTAssertFalse(viewModel.isStreaming)
    }

    func testCancelStreamingDoesNotSurfaceError() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["slow"]
        mockService.streamDelayNs = 200_000_000
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        viewModel.cancelStreaming()

        // Wait for cancelled task to settle
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(viewModel.errorMessage, "CancellationError should not surface in UI")
    }

    func testUpdateLLMServiceDoesNotClearHistory() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.messages.count, 2)

        let newService = MockLLMService()
        viewModel.updateLLMService(newService)

        XCTAssertEqual(viewModel.messages.count, 2, "Provider swap should NOT clear chat history")
    }

    // MARK: - Update LLM Service

    func testUpdateLLMServiceNilDisablesChat() {
        viewModel.updateLLMService(nil)
        viewModel.inputText = "Should not send"
        viewModel.sendMessage()
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testConfigureWithNilServiceStartsDisabled() {
        let vm = TranscriptChatViewModel()
        vm.configure(
            llmService: nil, transcriptText: "Transcript", transcriptionRepo: mockRepo,
            conversationRepo: mockConversationRepo)
        XCTAssertFalse(vm.canSendMessage)
    }

    func testRefreshModelInfoShowsLocalCLIPresetName() throws {
        let suiteName = "test.chat.localcli.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(
            LocalCLIConfig(commandTemplate: "codex exec --skip-git-repo-check --model gpt-5.4-mini")
        )

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        let vm = TranscriptChatViewModel()
        vm.configure(
            llmService: mockService,
            transcriptText: "Transcript",
            transcriptionRepo: mockRepo,
            configStore: configStore,
            conversationRepo: mockConversationRepo,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(vm.currentProviderID, .localCLI)
        XCTAssertEqual(vm.currentModelName, "Codex")
        XCTAssertEqual(vm.modelDisplayName, "Codex")
        XCTAssertEqual(vm.availableModels, ["Codex"])
    }

    func testRefreshModelInfoShowsCustomCLILabel() throws {
        let suiteName = "test.chat.customcli.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(LocalCLIConfig(commandTemplate: "python llm_wrapper.py"))

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        let vm = TranscriptChatViewModel()
        vm.configure(
            llmService: mockService,
            transcriptText: "Transcript",
            transcriptionRepo: mockRepo,
            configStore: configStore,
            conversationRepo: mockConversationRepo,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(vm.modelDisplayName, "Custom CLI")
        XCTAssertEqual(vm.availableModels, ["Custom CLI"])
    }

    func testRefreshModelInfoKeepsCurrentModelWhenDiscoveredListOmitsIt() async throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test", model: "fine-tuned-current")
        let llmClient = MockLLMClient()
        llmClient.modelsList = ["gpt-5.2", "gpt-5-mini"]

        let vm = TranscriptChatViewModel()
        vm.configure(
            llmService: mockService,
            transcriptText: "Transcript",
            transcriptionRepo: mockRepo,
            configStore: configStore,
            llmClient: llmClient,
            conversationRepo: mockConversationRepo
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.currentProviderID, .openai)
        XCTAssertEqual(vm.currentModelName, "fine-tuned-current")
        XCTAssertEqual(vm.availableModels, ["fine-tuned-current", "gpt-5.2", "gpt-5-mini"])
        XCTAssertEqual(llmClient.capturedContext?.providerConfig.id, .openai)
    }

    func testUpdateLLMServiceSwapsProvider() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        let newService = MockLLMService()
        newService.streamTokens = ["new", " provider"]
        viewModel.updateLLMService(newService)

        viewModel.inputText = "Hello"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.messages[1].content, "new provider")
    }

    // MARK: - Persistence

    func testLoadTranscriptRestoresPersistedChat() {
        let transcriptionId = UUID()
        let messages = [
            ChatMessage(role: .user, content: "Question"),
            ChatMessage(role: .assistant, content: "Answer"),
        ]
        let conv = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Restored",
            messages: messages
        )
        mockConversationRepo.conversations = [conv]

        viewModel.loadTranscript("Transcript text", transcriptionId: transcriptionId)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Question")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Answer")
    }

    func testSendMessagePersistsChatHistory() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        // First call saves user message, second saves user + assistant
        XCTAssertEqual(mockConversationRepo.updateMessagesCalls.count, 2)
        XCTAssertEqual(mockConversationRepo.updateMessagesCalls[0].messages?.count, 1)
        XCTAssertEqual(mockConversationRepo.updateMessagesCalls[0].messages?.first?.role, .user)
        XCTAssertEqual(mockConversationRepo.updateMessagesCalls[1].messages?.count, 2)
    }

    func testUpdateLLMServiceDuringStreamingRemovesPendingAssistantMessage() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["partial", " response"]
        mockService.streamDelayNs = 200_000_000
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 50_000_000)
        viewModel.updateLLMService(MockLLMService())
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Question")
        XCTAssertEqual(mockConversationRepo.updateMessagesCalls.last?.messages?.count, 1)
        XCTAssertEqual(mockConversationRepo.updateMessagesCalls.last?.messages?.first?.role, .user)
    }

    func testClearHistoryDeletesConversations() async throws {
        let transcriptionId = UUID()
        let conv = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Chat",
            messages: [ChatMessage(role: .user, content: "Hi")]
        )
        mockConversationRepo.conversations = [conv]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        viewModel.clearHistory()

        XCTAssertTrue(viewModel.conversations.isEmpty)
        XCTAssertNil(viewModel.currentConversation)
        XCTAssertTrue(mockConversationRepo.conversations.isEmpty)
    }

    func testDeleteConversationKeepsLocalStateWhenRepoDeleteFails() {
        enum DeleteFailure: Error { case failed }

        let transcriptionId = UUID()
        let conv = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Chat",
            messages: [ChatMessage(role: .user, content: "Hi")]
        )
        mockConversationRepo.conversations = [conv]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        mockConversationRepo.deleteError = DeleteFailure.failed

        viewModel.deleteConversation(conv)

        XCTAssertTrue(viewModel.conversations.contains(where: { $0.id == conv.id }))
        XCTAssertEqual(viewModel.currentConversation?.id, conv.id)
        XCTAssertEqual(viewModel.errorMessage, "Failed to delete conversation.")
    }

    func testClearHistoryKeepsLocalStateWhenRepoDeleteAllFails() {
        enum DeleteFailure: Error { case failed }

        let transcriptionId = UUID()
        let conv = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Chat",
            messages: [ChatMessage(role: .user, content: "Hi")]
        )
        mockConversationRepo.conversations = [conv]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        mockConversationRepo.deleteAllError = DeleteFailure.failed

        viewModel.clearHistory()

        XCTAssertFalse(viewModel.conversations.isEmpty)
        XCTAssertNotNil(viewModel.currentConversation)
        XCTAssertEqual(viewModel.errorMessage, "Failed to clear chat history.")
    }

    func testCanSendMessageFalseWhenNoService() {
        viewModel.updateLLMService(nil)
        XCTAssertFalse(viewModel.canSendMessage)
    }

    func testCanSendMessageTrueWhenServiceAvailable() {
        XCTAssertTrue(viewModel.canSendMessage)
    }

    // MARK: - Duplicate Question Regression

    func testChatHistoryDoesNotDuplicateQuestion() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["answer"]
        viewModel.inputText = "What happened?"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)

        let historyUserMessages = mockService.lastChatHistory?.filter { $0.role == .user } ?? []
        XCTAssertTrue(
            historyUserMessages.isEmpty, "First message history should be empty — question is passed separately")
        XCTAssertEqual(mockService.lastChatQuestion, "What happened?")
    }

    func testMultiTurnHistoryDoesNotDuplicateLatestQuestion() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // First turn
        mockService.streamTokens = ["first answer"]
        viewModel.inputText = "First question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Second turn
        mockService.streamTokens = ["second answer"]
        viewModel.inputText = "Second question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        let history = mockService.lastChatHistory ?? []
        XCTAssertEqual(history.count, 2, "History should have first user + first assistant")
        XCTAssertEqual(history[0].role, .user)
        XCTAssertEqual(history[0].content, "First question")
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertEqual(history[1].content, "first answer")
        XCTAssertEqual(mockService.lastChatQuestion, "Second question")
    }

    // MARK: - Multi-Conversation

    func testFirstMessageCreatesConversation() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        XCTAssertNil(viewModel.currentConversation)

        mockService.streamTokens = ["answer"]
        viewModel.inputText = "Hello world"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(viewModel.currentConversation)
        XCTAssertEqual(mockConversationRepo.saveCalls.count, 1)
        XCTAssertEqual(viewModel.conversations.count, 1)
    }

    func testAutoTitle() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["response"]
        viewModel.inputText = "What are the main takeaways from this transcript?"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        let title = viewModel.currentConversation?.title ?? ""
        XCTAssertTrue(title.count <= 50, "Auto-title should be truncated to 50 chars")
        XCTAssertTrue(title.hasPrefix("What are the main takeaways"))
    }

    func testNewChatArchivesCurrentConversation() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // Send a message to create a conversation
        mockService.streamTokens = ["answer"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        let firstConversationId = viewModel.currentConversation?.id
        XCTAssertNotNil(firstConversationId)
        XCTAssertEqual(viewModel.conversations.count, 1)

        // Start new chat
        viewModel.newChat()

        XCTAssertNil(viewModel.currentConversation)
        XCTAssertTrue(viewModel.messages.isEmpty)
        // The old conversation is still in the list
        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.conversations[0].id, firstConversationId)
    }

    func testNewChatDiscardsEmptyConversation() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // Send a message to create a first conversation
        mockService.streamTokens = ["answer"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Start new chat
        viewModel.newChat()

        // Now start new chat again without sending any message
        // (currentConversation is nil, so nothing to discard)
        viewModel.newChat()

        // Should only have 1 conversation (the original one with messages)
        XCTAssertEqual(viewModel.conversations.count, 1)
    }

    func testSwitchConversation() async throws {
        let transcriptionId = UUID()
        let conv1 = ChatConversation(
            transcriptionId: transcriptionId,
            title: "First Chat",
            messages: [ChatMessage(role: .user, content: "Q1")]
        )
        let conv2 = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Second Chat",
            messages: [
                ChatMessage(role: .user, content: "Q2"),
                ChatMessage(role: .assistant, content: "A2"),
            ]
        )
        mockConversationRepo.conversations = [conv2, conv1]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // Should load most recent (conv2)
        XCTAssertEqual(viewModel.currentConversation?.id, conv2.id)
        XCTAssertEqual(viewModel.messages.count, 2)

        // Switch to conv1
        viewModel.switchConversation(conv1)

        XCTAssertEqual(viewModel.currentConversation?.id, conv1.id)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].content, "Q1")
    }

    func testDeleteConversation() async throws {
        let transcriptionId = UUID()
        let conv1 = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Keep",
            messages: [ChatMessage(role: .user, content: "Q1")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        let conv2 = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Delete",
            messages: [ChatMessage(role: .user, content: "Q2")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        mockConversationRepo.conversations = [conv1, conv2]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        viewModel.inputText = "draft from deleted chat"
        viewModel.errorMessage = "stale error"

        // Delete conv1 (current)
        viewModel.deleteConversation(conv1)

        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.conversations[0].id, conv2.id)
        // Should switch to remaining conversation
        XCTAssertEqual(viewModel.currentConversation?.id, conv2.id)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(mockConversationRepo.deleteCalls.contains(conv1.id))
    }

    func testDeleteLastConversation() async throws {
        let transcriptionId = UUID()
        let conv = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Only",
            messages: [ChatMessage(role: .user, content: "Q")]
        )
        mockConversationRepo.conversations = [conv]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        viewModel.deleteConversation(conv)

        XCTAssertTrue(viewModel.conversations.isEmpty)
        XCTAssertNil(viewModel.currentConversation)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testConversationListOrder() throws {
        let transcriptionId = UUID()
        let older = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Older",
            messages: [ChatMessage(role: .user, content: "old")],
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let newer = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Newer",
            messages: [ChatMessage(role: .user, content: "new")],
            updatedAt: Date()
        )
        mockConversationRepo.conversations = [older, newer]

        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // Most recently updated should be first
        XCTAssertEqual(viewModel.conversations[0].title, "Newer")
        XCTAssertEqual(viewModel.conversations[1].title, "Older")
    }

    func testNewChatDuringStreamingPersistsResponseInBackground() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["background", " response"]
        mockService.streamDelayNs = 100_000_000  // 100ms per token
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        // Let first token arrive, then switch away
        try await Task.sleep(nanoseconds: 150_000_000)
        let originalConversationId = viewModel.currentConversation?.id
        XCTAssertNotNil(originalConversationId)

        viewModel.newChat()
        XCTAssertNil(viewModel.currentConversation)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isStreaming)

        // Wait for background streaming to complete and persist
        try await Task.sleep(nanoseconds: 300_000_000)

        // The detached task should have persisted the assistant response directly to repo
        let finalPersist = mockConversationRepo.updateMessagesCalls.last
        XCTAssertEqual(finalPersist?.id, originalConversationId)
        XCTAssertEqual(finalPersist?.messages?.count, 2)  // user + assistant
        XCTAssertEqual(finalPersist?.messages?.last?.role, .assistant)
        XCTAssertEqual(finalPersist?.messages?.last?.content, "background response")
    }

    func testSwitchConversationDuringStreamingPersistsResponseInBackground() async throws {
        let transcriptionId = UUID()
        let existingConv = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Existing",
            messages: [ChatMessage(role: .user, content: "Old")]
        )
        mockConversationRepo.conversations = [existingConv]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // Switch to empty state then send a message
        viewModel.newChat()
        mockService.streamTokens = ["will", " persist"]
        mockService.streamDelayNs = 100_000_000
        viewModel.inputText = "New question"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 150_000_000)
        let streamingConvId = viewModel.currentConversation?.id

        // Switch to existing conversation while streaming
        viewModel.switchConversation(existingConv)
        XCTAssertEqual(viewModel.currentConversation?.id, existingConv.id)

        // Wait for background task to complete
        try await Task.sleep(nanoseconds: 300_000_000)

        let finalPersist = mockConversationRepo.updateMessagesCalls.last(where: { $0.id == streamingConvId })
        XCTAssertNotNil(finalPersist)
        XCTAssertEqual(finalPersist?.messages?.count, 2)
        XCTAssertEqual(finalPersist?.messages?.last?.content, "will persist")
    }

    func testNavigateBackToDetachedConversationDoesNotCorruptHistory() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["detached", " response"]
        mockService.streamDelayNs = 100_000_000
        viewModel.inputText = "First question"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 150_000_000)
        let originalConv = viewModel.currentConversation!

        // Navigate away
        viewModel.newChat()

        // Navigate BACK to the same conversation before detached task finishes
        viewModel.switchConversation(originalConv)
        XCTAssertEqual(viewModel.currentConversation?.id, originalConv.id)

        // Send a second message — this modifies the conversation
        mockService.streamTokens = ["second"]
        mockService.streamDelayNs = 0
        viewModel.inputText = "Second question"
        viewModel.sendMessage()

        // Wait for both tasks to complete
        try await Task.sleep(nanoseconds: 500_000_000)

        // The active task (Q2 → A2) should have persisted normally via chatHistory
        // The detached task (Q1 → A1) should have been DROPPED because the conversation
        // was modified since detach (user sent Q2). This prevents stale overwrites.
        XCTAssertEqual(viewModel.messages.count, 3)  // Q1 (loaded), Q2, A2
        XCTAssertFalse(viewModel.isStreaming)

        // chatHistory should contain Q1, Q2, A2 (no stale A1 from detached task)
        let lastActivePersist = mockConversationRepo.updateMessagesCalls.last(where: {
            $0.messages?.contains(where: { $0.content == "Second question" }) == true
        })
        XCTAssertNotNil(lastActivePersist, "Active task should have persisted Q2")
        XCTAssertEqual(lastActivePersist?.messages?.count, 3, "Should have Q1, Q2, A2")
    }

    func testLoadTranscriptCleansEmptyConversations() {
        let transcriptionId = UUID()
        let empty = ChatConversation(transcriptionId: transcriptionId, title: "Empty")
        let withMessages = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Has Messages",
            messages: [ChatMessage(role: .user, content: "Hi")]
        )
        mockConversationRepo.conversations = [empty, withMessages]

        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        XCTAssertTrue(mockConversationRepo.deleteEmptyCalls.contains(transcriptionId))
    }

    // MARK: - userNotes provider (post-Memo-Steered-revert path)

    func testSendMessagePassesUserNotesFromProviderToLLM() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        viewModel.bindUserNotesProvider { "decision: ship Friday" }
        mockService.streamTokens = ["ok"]
        viewModel.inputText = "Why Friday?"

        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(mockService.lastChatUserNotes, "decision: ship Friday")
    }

    func testSendMessagePassesNilUserNotesWhenProviderUnset() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        // No bindUserNotesProvider call — closure is nil.
        mockService.streamTokens = ["ok"]
        viewModel.inputText = "Q"

        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(mockService.lastChatUserNotes)
    }

    func testProviderClosureIsReevaluatedOnEverySend() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // Mutable backing store the closure reads from each invocation —
        // simulates a live notepad where the user keeps typing between sends.
        let liveNotes = LockedString()
        liveNotes.set("first")
        viewModel.bindUserNotesProvider { liveNotes.get() }

        mockService.streamTokens = ["ok"]
        viewModel.inputText = "First send"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mockService.lastChatUserNotes, "first")

        liveNotes.set("first\nsecond — added between sends")
        viewModel.inputText = "Second send"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            mockService.lastChatUserNotes,
            "first\nsecond — added between sends",
            "Closure must read the latest notes at each chat-send, not snapshot at bind time"
        )
    }

    func testBindUserNotesProviderNilClearsExistingProvider() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)
        viewModel.bindUserNotesProvider { "some notes" }
        viewModel.bindUserNotesProvider(nil)

        mockService.streamTokens = ["ok"]
        viewModel.inputText = "Q"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(mockService.lastChatUserNotes)
    }

    // MARK: - Regenerate Last Response

    func testRegenerateLastResponseReissuesPriorPromptAndReplacesTail() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["First", " answer"]
        viewModel.inputText = "What is this about?"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[1].content, "First answer")
        let firstAssistantID = viewModel.messages[1].id

        mockService.streamTokens = ["Second", " answer"]
        viewModel.regenerateLastResponse()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Same shape (user + 1 assistant), new assistant content + new id.
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "What is this about?")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Second answer")
        XCTAssertNotEqual(viewModel.messages[1].id, firstAssistantID)

        // LLM saw the same user prompt and history excluded the trailing user turn.
        XCTAssertEqual(mockService.lastChatQuestion, "What is this about?")
        XCTAssertEqual(mockService.lastChatHistory?.count, 0)
    }

    func testRegenerateLastResponseReusesRichPrompt() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        let richPrompt = "Explain the unresolved risks in the meeting so far."
        mockService.streamTokens = ["First"]
        viewModel.inputText = "Tell me more"
        viewModel.sendMessage(richPrompt: richPrompt)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(mockConversationRepo.updateMessagesCalls.last?.messages?.first?.modelPromptOverride, richPrompt)

        mockService.streamTokens = ["Second"]
        viewModel.regenerateLastResponse()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.messages.map(\.content), ["Tell me more", "Second"])
        XCTAssertEqual(mockService.lastChatQuestion, richPrompt)
    }

    func testRegenerateLastResponseReusesPersistedRichPromptAfterReload() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        let richPrompt = "Explain the unresolved risks in the meeting so far."
        mockService.streamTokens = ["First"]
        viewModel.inputText = "Tell me more"
        viewModel.sendMessage(richPrompt: richPrompt)
        try await Task.sleep(nanoseconds: 200_000_000)

        let persisted = try XCTUnwrap(mockConversationRepo.conversations.first)
        XCTAssertEqual(persisted.messages?.first?.content, "Tell me more")
        XCTAssertEqual(persisted.messages?.first?.modelPromptOverride, richPrompt)

        let reloadedService = MockLLMService()
        let reloaded = TranscriptChatViewModel()
        reloaded.configure(
            llmService: reloadedService,
            transcriptText: "Transcript",
            transcriptionRepo: mockRepo,
            conversationRepo: mockConversationRepo
        )
        reloaded.loadTranscript("Transcript", transcriptionId: transcriptionId)

        reloadedService.streamTokens = ["Second"]
        reloaded.regenerateLastResponse()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(reloaded.messages.map(\.content), ["Tell me more", "Second"])
        XCTAssertEqual(reloadedService.lastChatQuestion, richPrompt)
    }

    func testRegenerateLastResponsePreservesEarlierTurnsInHistory() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["A1"]
        viewModel.inputText = "Q1"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        mockService.streamTokens = ["A2"]
        viewModel.inputText = "Q2"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.messages.count, 4)

        mockService.streamTokens = ["A2-prime"]
        viewModel.regenerateLastResponse()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Q1/A1/Q2 retained; A2 replaced.
        XCTAssertEqual(viewModel.messages.count, 4)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Q1", "A1", "Q2", "A2-prime"])

        // History sent to the LLM excludes the trailing user turn (Q2 is the question).
        XCTAssertEqual(mockService.lastChatQuestion, "Q2")
        XCTAssertEqual(mockService.lastChatHistory?.count, 2)
        XCTAssertEqual(mockService.lastChatHistory?[0].content, "Q1")
        XCTAssertEqual(mockService.lastChatHistory?[1].content, "A1")
    }

    func testRegenerateLastResponseDoesNothingWhenStreaming() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.streamTokens = ["slow"]
        mockService.streamDelayNs = 200_000_000
        viewModel.inputText = "Q"
        viewModel.sendMessage()

        // While streaming, regenerate must be a no-op.
        let countBefore = viewModel.messages.count
        viewModel.regenerateLastResponse()
        XCTAssertEqual(viewModel.messages.count, countBefore)
        XCTAssertTrue(viewModel.isStreaming)

        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func testRegenerateLastResponseDoesNothingOnEmptyThread() {
        viewModel.regenerateLastResponse()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isStreaming)
    }

    func testRegenerateLastResponseDoesNothingAfterErrorTail() async throws {
        let transcriptionId = UUID()
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        mockService.errorToThrow = LLMError.authenticationFailed(nil)
        viewModel.inputText = "Will fail"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        // After error, only the user turn remains — regenerate has nothing to replace.
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .user)

        let chatCallsBefore = mockService.chatCallCount
        viewModel.regenerateLastResponse()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            mockService.chatCallCount, chatCallsBefore, "Regenerate must not re-issue when tail isn't an assistant turn"
        )
        XCTAssertEqual(viewModel.messages.count, 1)
    }

    // MARK: - Chat source telemetry attribution

    /// Default-constructed VMs are the post-transcription transcript chat
    /// surface, so they pass `.transcriptChat` to the LLM service for
    /// `llm_chat_used` attribution.
    func testChatSourceDefaultsToTranscriptChat() async throws {
        viewModel.loadTranscript("Transcript", transcriptionId: UUID())
        mockService.streamTokens = ["hi"]
        viewModel.inputText = "Q"
        viewModel.sendMessage()
        // Match the 200ms streaming-task settle used throughout this suite.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(mockService.lastChatSource, .transcriptChat)
    }

    /// Once `markAsMeetingAskSurface()` flips the VM, every subsequent
    /// chat call attributes to `.meetingAsk` — including post-meeting
    /// continuation chats persisted to a conversation. This keeps the live
    /// Ask telemetry intact even after the meeting finalizes.
    func testChatSourceBecomesMeetingAskAfterFlip() async throws {
        viewModel.markAsMeetingAskSurface()
        viewModel.loadTranscript("Transcript", transcriptionId: UUID())
        mockService.streamTokens = ["hi"]
        viewModel.inputText = "Q"
        viewModel.sendMessage()
        // Match the 200ms streaming-task settle used throughout this suite.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(mockService.lastChatSource, .meetingAsk)
    }
}

private actor ControlledRichContextBuilder {
    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var buildContinuations: [String: CheckedContinuation<String, Never>] = [:]

    func build(_ transcription: Transcription, _ mode: TranscriptAIContextMode) async -> String {
        let key = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        started.insert(key)
        for waiter in startWaiters.removeValue(forKey: key) ?? [] {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            buildContinuations[key] = continuation
        }
    }

    func waitUntilStarted(_ key: String) async {
        guard !started.contains(key) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func finish(_ key: String, with result: String) {
        buildContinuations.removeValue(forKey: key)?.resume(returning: result)
    }
}

/// Tiny @unchecked-Sendable string box used by the closure-reevaluation test.
/// XCTest setup runs on @MainActor; the closure may be called from the LLM
/// service's task. A real lock would be overkill — this is a serialized
/// MainActor + Task hand-off in tests.
private final class LockedString: @unchecked Sendable {
    private var value: String = ""
    private let lock = NSLock()
    func get() -> String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ newValue: String) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
