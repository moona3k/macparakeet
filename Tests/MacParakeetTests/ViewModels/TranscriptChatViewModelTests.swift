import XCTest
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
        XCTAssertEqual(viewModel.errorMessage, "Chat is unavailable until a transcript is loaded.")
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
        vm.configure(llmService: nil, transcriptText: "Transcript", transcriptionRepo: mockRepo, conversationRepo: mockConversationRepo)
        XCTAssertFalse(vm.canSendMessage)
    }

    func testRefreshModelInfoShowsLocalCLIPresetName() throws {
        let defaults = UserDefaults(suiteName: "test.chat.localcli.\(UUID().uuidString)")!
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
        let defaults = UserDefaults(suiteName: "test.chat.customcli.\(UUID().uuidString)")!
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
        XCTAssertTrue(historyUserMessages.isEmpty, "First message history should be empty — question is passed separately")
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
            messages: [ChatMessage(role: .user, content: "Q1")]
        )
        let conv2 = ChatConversation(
            transcriptionId: transcriptionId,
            title: "Delete",
            messages: [ChatMessage(role: .user, content: "Q2")]
        )
        mockConversationRepo.conversations = [conv1, conv2]
        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId)

        // Delete conv1 (current)
        viewModel.deleteConversation(conv1)

        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.conversations[0].id, conv2.id)
        // Should switch to remaining conversation
        XCTAssertEqual(viewModel.currentConversation?.id, conv2.id)
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
}
