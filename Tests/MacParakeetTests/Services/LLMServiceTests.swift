import XCTest
@testable import MacParakeetCore

// MARK: - Mocks

final class MockLLMClient: LLMClientProtocol, @unchecked Sendable {
    var capturedMessages: [ChatMessage] = []
    var capturedConfig: LLMProviderConfig?
    var capturedOptions: ChatCompletionOptions?
    var responseContent = "Mock response"
    var responseModel = "mock-model"
    var streamTokens: [String]?
    var testConnectionError: Error?

    func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        capturedMessages = messages
        capturedConfig = config
        capturedOptions = options
        return ChatCompletionResponse(content: responseContent, model: responseModel)
    }

    func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        capturedMessages = messages
        capturedConfig = config
        capturedOptions = options
        let tokens = streamTokens ?? [responseContent]
        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(token)
            }
            continuation.finish()
        }
    }

    func testConnection(config: LLMProviderConfig) async throws {
        capturedConfig = config
        if let error = testConnectionError { throw error }
    }

    var modelsList: [String] = ["mock-model-1", "mock-model-2"]
    var listModelsError: Error?

    func listModels(config: LLMProviderConfig) async throws -> [String] {
        if let error = listModelsError { throw error }
        return modelsList
    }
}

final class MockLLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    var config: LLMProviderConfig?
    /// Per-provider key storage for testing provider switching.
    var storedKeys: [LLMProviderID: String] = [:]

    func loadConfig() throws -> LLMProviderConfig? { config }
    func saveConfig(_ config: LLMProviderConfig) throws {
        self.config = config
        if let key = config.apiKey {
            storedKeys[config.id] = key
        } else {
            storedKeys.removeValue(forKey: config.id)
        }
    }
    func deleteConfig() throws {
        if let id = config?.id {
            storedKeys.removeValue(forKey: id)
        }
        config = nil
    }
    func loadAPIKey() throws -> String? {
        guard let config else { return nil }
        return storedKeys[config.id]
    }
    func loadAPIKey(for provider: LLMProviderID) throws -> String? { storedKeys[provider] }

    func saveAPIKey(_ key: String) throws {
        guard let existing = config else { return }
        storedKeys[existing.id] = key
        config = LLMProviderConfig(
            id: existing.id, baseURL: existing.baseURL, apiKey: key,
            modelName: existing.modelName, isLocal: existing.isLocal
        )
    }

    func deleteAPIKey() throws {
        guard let existing = config else { return }
        storedKeys.removeValue(forKey: existing.id)
        config = LLMProviderConfig(
            id: existing.id, baseURL: existing.baseURL, apiKey: nil,
            modelName: existing.modelName, isLocal: existing.isLocal
        )
    }
}

final class LLMServiceTests: XCTestCase {
    var mockClient: MockLLMClient!
    var mockConfigStore: MockLLMConfigStore!
    var service: LLMService!

    override func setUp() {
        mockClient = MockLLMClient()
        mockConfigStore = MockLLMConfigStore()
        mockConfigStore.config = .openai(apiKey: "sk-test")
        service = LLMService(client: mockClient, configStore: mockConfigStore)
    }

    // MARK: - Not Configured

    func testThrowsNotConfiguredWhenNoProvider() async {
        mockConfigStore.config = nil

        do {
            _ = try await service.summarize(transcript: "Test")
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {} else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChatThrowsNotConfiguredWhenNoProvider() async {
        mockConfigStore.config = nil

        do {
            _ = try await service.chat(question: "Q", transcript: "T", history: [])
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {} else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTransformThrowsNotConfiguredWhenNoProvider() async {
        mockConfigStore.config = nil

        do {
            _ = try await service.transform(text: "T", prompt: "P")
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {} else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Summarize

    func testSummarizeAssemblesCorrectPrompt() async throws {
        _ = try await service.summarize(transcript: "The meeting discussed budgets.")

        XCTAssertEqual(mockClient.capturedMessages.count, 2)
        XCTAssertEqual(mockClient.capturedMessages[0].role, .system)
        XCTAssertTrue(mockClient.capturedMessages[0].content.contains("summarizes transcripts"))
        XCTAssertEqual(mockClient.capturedMessages[1].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[1].content, "The meeting discussed budgets.")
    }

    // MARK: - Chat

    func testChatAssemblesSystemPromptWithTranscript() async throws {
        _ = try await service.chat(
            question: "What was discussed?",
            transcript: "We talked about the release.",
            history: []
        )

        XCTAssertEqual(mockClient.capturedMessages.count, 2)
        XCTAssertEqual(mockClient.capturedMessages[0].role, .system)
        XCTAssertTrue(mockClient.capturedMessages[0].content.contains("We talked about the release."))
        XCTAssertEqual(mockClient.capturedMessages[1].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[1].content, "What was discussed?")
    }

    func testChatIncludesHistory() async throws {
        let history = [
            ChatMessage(role: .user, content: "Who spoke?"),
            ChatMessage(role: .assistant, content: "Alice and Bob."),
        ]

        _ = try await service.chat(
            question: "What did Alice say?",
            transcript: "Alice said hello.",
            history: history
        )

        // system + 2 history + user question = 4
        XCTAssertEqual(mockClient.capturedMessages.count, 4)
        XCTAssertEqual(mockClient.capturedMessages[1].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[1].content, "Who spoke?")
        XCTAssertEqual(mockClient.capturedMessages[2].role, .assistant)
        XCTAssertEqual(mockClient.capturedMessages[3].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[3].content, "What did Alice say?")
    }

    // MARK: - Transform

    func testTransformAssemblesCorrectPrompt() async throws {
        _ = try await service.transform(text: "hello world", prompt: "Make it uppercase")

        XCTAssertEqual(mockClient.capturedMessages.count, 2)
        XCTAssertEqual(mockClient.capturedMessages[0].role, .system)
        XCTAssertTrue(mockClient.capturedMessages[0].content.contains("transforms text"))
        XCTAssertEqual(mockClient.capturedMessages[1].role, .user)
        XCTAssertTrue(mockClient.capturedMessages[1].content.contains("Make it uppercase"))
        XCTAssertTrue(mockClient.capturedMessages[1].content.contains("hello world"))
    }

    // MARK: - Context Truncation

    func testShortTextNotTruncated() {
        let text = "Short text"
        let result = LLMService.truncateMiddle(text, limit: 1000)
        XCTAssertEqual(result, text)
    }

    func testEmptyTextNotTruncated() {
        let result = LLMService.truncateMiddle("", limit: 100)
        XCTAssertEqual(result, "")
    }

    func testLongTextTruncatedFromMiddle() {
        let text = String(repeating: "word ", count: 200) // 1000 chars
        let result = LLMService.truncateMiddle(text, limit: 100)
        XCTAssertTrue(result.contains("\n\n[... content truncated ...]\n\n"))
        XCTAssertLessThanOrEqual(result.count, 200) // head + tail + marker
    }

    func testTruncationSnapsToWordBoundary() {
        let text = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        let result = LLMService.truncateMiddle(text, limit: 40)
        XCTAssertTrue(result.contains("[... content truncated ...]"))
        // Should not split mid-word
        let parts = result.components(separatedBy: "\n\n[... content truncated ...]\n\n")
        XCTAssertEqual(parts.count, 2)
        let head = parts[0]
        let tail = parts[1]
        XCTAssertFalse(head.isEmpty)
        XCTAssertFalse(tail.isEmpty)
        // Head should end with a space (snapped to word boundary)
        XCTAssertTrue(head.hasSuffix(" "))
    }

    func testUnicodeTruncation() {
        // Emoji and CJK characters
        let text = "Hello 🌍 世界 こんにちは " + String(repeating: "x ", count: 100)
        let result = LLMService.truncateMiddle(text, limit: 50)
        // Should not crash or produce invalid Unicode
        XCTAssertTrue(result.contains("[... content truncated ...]"))
        XCTAssertTrue(result.utf8.count > 0)
    }

    func testCloudContextBudget() {
        XCTAssertEqual(LLMService.cloudContextBudget, 100_000)
    }

    func testLocalContextBudget() {
        XCTAssertEqual(LLMService.localContextBudget, 24_000)
    }

    func testLocalProviderUsesLocalBudget() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2")

        // Create text that exceeds local budget but not cloud budget
        let text = String(repeating: "word ", count: 6000) // 30_000 chars > 24_000 local budget
        _ = try await service.summarize(transcript: text)

        // The user message should be truncated
        let userMessage = mockClient.capturedMessages.last!
        XCTAssertTrue(userMessage.content.contains("[... content truncated ...]"))
    }

    func testCloudProviderDoesNotTruncateWithinBudget() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test")

        // 30K chars is within cloud budget (100K)
        let text = String(repeating: "word ", count: 6000)
        _ = try await service.summarize(transcript: text)

        let userMessage = mockClient.capturedMessages.last!
        XCTAssertFalse(userMessage.content.contains("[... content truncated ...]"))
    }

    // MARK: - Chat History Overflow

    func testChatDropsOldHistoryWhenOverBudget() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2") // local = 24K budget

        // Create a long transcript that uses most of the budget
        let transcript = String(repeating: "word ", count: 4000) // 20K chars

        // Create history with identifiable messages (~210 chars each)
        let history = (0..<50).flatMap { i -> [ChatMessage] in
            [
                ChatMessage(role: .user, content: "Question \(i) " + String(repeating: "x", count: 200)),
                ChatMessage(role: .assistant, content: "Answer \(i) " + String(repeating: "y", count: 200)),
            ]
        }

        _ = try await service.chat(
            question: "Latest question",
            transcript: transcript,
            history: history
        )

        let messages = mockClient.capturedMessages
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "Latest question")
        // Should have dropped most of the 100 history messages
        XCTAssertLessThan(messages.count, history.count + 2)
        XCTAssertGreaterThan(messages.count, 2, "Should keep at least some recent history")
    }

    func testChatWithNegativeHistoryBudgetDropsAllHistory() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2") // local = 24K budget

        // The truncated transcript is ~90% of budget (45% head + 45% tail).
        // System prompt prefix + truncated transcript + question leaves ~2K chars.
        // Make each history entry large enough (>2K each) so none fit.
        let transcript = String(repeating: "word ", count: 20000) // 100K chars

        let history = [
            ChatMessage(role: .user, content: String(repeating: "z", count: 3000)),
            ChatMessage(role: .assistant, content: String(repeating: "z", count: 3000)),
        ]

        _ = try await service.chat(
            question: "New question",
            transcript: transcript,
            history: history
        )

        let messages = mockClient.capturedMessages
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "New question")
        // Each history entry is 3K chars, but only ~2K budget — none fit
        XCTAssertEqual(messages.count, 2)
    }

    // MARK: - Streaming

    func testSummarizeStreamYieldsTokens() async throws {
        mockClient.streamTokens = ["Hello", " ", "world"]
        let stream = service.summarizeStream(transcript: "Test transcript")

        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        XCTAssertEqual(tokens, ["Hello", " ", "world"])
    }

    func testChatStreamYieldsTokens() async throws {
        mockClient.streamTokens = ["Chat", " ", "response"]
        let stream = service.chatStream(
            question: "What happened?",
            transcript: "Something happened.",
            history: []
        )

        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        XCTAssertEqual(tokens, ["Chat", " ", "response"])
    }

    func testTransformStreamYieldsTokens() async throws {
        mockClient.streamTokens = ["HELLO", " ", "WORLD"]
        let stream = service.transformStream(text: "hello world", prompt: "uppercase")

        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
        }

        XCTAssertEqual(tokens, ["HELLO", " ", "WORLD"])
    }

    func testSummarizeStreamThrowsWhenNotConfigured() async {
        mockConfigStore.config = nil
        let stream = service.summarizeStream(transcript: "Test")

        do {
            for try await _ in stream {
                XCTFail("Expected stream to throw")
            }
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {} else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChatStreamThrowsWhenNotConfigured() async {
        mockConfigStore.config = nil
        let stream = service.chatStream(question: "Q", transcript: "T", history: [])

        do {
            for try await _ in stream {
                XCTFail("Expected stream to throw")
            }
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {} else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTransformStreamThrowsWhenNotConfigured() async {
        mockConfigStore.config = nil
        let stream = service.transformStream(text: "T", prompt: "P")

        do {
            for try await _ in stream {
                XCTFail("Expected stream to throw")
            }
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {} else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
