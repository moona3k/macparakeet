import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptChatViewModelTests: XCTestCase {
    var viewModel: TranscriptChatViewModel!
    var mockService: MockLLMService!
    var mockRepo: MockTranscriptionRepository!

    override func setUp() {
        viewModel = TranscriptChatViewModel()
        mockService = MockLLMService()
        mockRepo = MockTranscriptionRepository()
        viewModel.configure(llmService: mockService, transcriptText: "Test transcript content here.", transcriptionRepo: mockRepo)
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
        viewModel.inputText = "My question"
        viewModel.sendMessage()
        XCTAssertEqual(viewModel.inputText, "")
    }

    func testEmptyInputDoesNotSend() {
        viewModel.inputText = "   "
        viewModel.sendMessage()
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSendMessageWhileStreamingDoesNotSend() async throws {
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
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        // Cancel immediately
        viewModel.cancelStreaming()

        XCTAssertFalse(viewModel.isStreaming)
    }

    func testCancelStreamingDoesNotSurfaceError() async throws {
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
        vm.configure(llmService: nil, transcriptText: "Transcript", transcriptionRepo: mockRepo)
        XCTAssertFalse(vm.canSendMessage)
    }

    func testUpdateLLMServiceSwapsProvider() async throws {
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
        let messages = [
            ChatMessage(role: .user, content: "Question"),
            ChatMessage(role: .assistant, content: "Answer")
        ]
        let id = UUID()

        viewModel.loadTranscript("Transcript text", transcriptionId: id, chatMessages: messages)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Question")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Answer")
    }

    func testSendMessagePersistsChatHistory() async throws {
        let transcriptionId = UUID()
        let t = Transcription(id: transcriptionId, fileName: "test.mp3", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId, chatMessages: nil)

        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(mockRepo.updateChatMessagesCalls.count, 2)
        XCTAssertEqual(mockRepo.updateChatMessagesCalls[0].chatMessages?.count, 1)
        XCTAssertEqual(mockRepo.updateChatMessagesCalls[0].chatMessages?.first?.role, .user)
        XCTAssertEqual(mockRepo.updateChatMessagesCalls[1].chatMessages?.count, 2)
    }

    func testUpdateLLMServiceDuringStreamingRemovesPendingAssistantMessage() async throws {
        let transcriptionId = UUID()
        let t = Transcription(id: transcriptionId, fileName: "test.mp3", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId, chatMessages: nil)
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
        XCTAssertEqual(mockRepo.updateChatMessagesCalls.last?.chatMessages?.count, 1)
        XCTAssertEqual(mockRepo.updateChatMessagesCalls.last?.chatMessages?.first?.role, .user)
    }

    func testClearHistoryPersistsEmptyArray() async throws {
        let transcriptionId = UUID()
        let t = Transcription(id: transcriptionId, fileName: "test.mp3", status: .completed)
        mockRepo.transcriptions = [t]

        viewModel.loadTranscript("Transcript", transcriptionId: transcriptionId, chatMessages: [
            ChatMessage(role: .user, content: "Hi")
        ])

        viewModel.clearHistory()

        // Should persist nil (empty history)
        XCTAssertEqual(mockRepo.updateChatMessagesCalls.count, 1)
        XCTAssertNil(mockRepo.updateChatMessagesCalls[0].chatMessages)
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
        // Regression: chatHistory was capturing the user message before passing to chatStream,
        // which then appends the question again via buildChatMessages → double question.
        mockService.streamTokens = ["answer"]
        viewModel.inputText = "What happened?"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)

        // The history passed to chatStream should NOT contain the current question
        // (buildChatMessages appends it separately)
        let historyUserMessages = mockService.lastChatHistory?.filter { $0.role == .user } ?? []
        XCTAssertTrue(historyUserMessages.isEmpty, "First message history should be empty — question is passed separately")
        XCTAssertEqual(mockService.lastChatQuestion, "What happened?")
    }

    func testMultiTurnHistoryDoesNotDuplicateLatestQuestion() async throws {
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

        // History should contain turn 1 (user + assistant) but NOT "Second question"
        let history = mockService.lastChatHistory ?? []
        XCTAssertEqual(history.count, 2, "History should have first user + first assistant")
        XCTAssertEqual(history[0].role, .user)
        XCTAssertEqual(history[0].content, "First question")
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertEqual(history[1].content, "first answer")
        XCTAssertEqual(mockService.lastChatQuestion, "Second question")
    }
}
