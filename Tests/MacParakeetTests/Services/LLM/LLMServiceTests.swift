import XCTest
@testable import MacParakeetCore

// MARK: - Mocks

final class MockLLMClient: LLMClientProtocol, @unchecked Sendable {
    var supportsInProcessLocalLLM = true
    var capturedMessages: [ChatMessage] = []
    var capturedContext: LLMExecutionContext?
    var capturedOptions: ChatCompletionOptions?
    var responseContent = "Mock response"
    var responseContents: [String] = []
    var chatCompletionCallCount = 0
    var chatCompletionStreamCallCount = 0
    var responseReasoningContent: String?
    var responseFinishReason: String?
    var responseModel = "mock-model"
    var responseUsage: TokenUsage?
    var streamTokens: [String]?
    var testConnectionError: Error?
    var testConnectionDelayNs: UInt64 = 0
    var chatCompletionError: Error?
    var holdInProcessModelRemoval = false
    var inProcessModelRemovalCallCount = 0
    private var inProcessModelRemovalContinuation: CheckedContinuation<Void, Never>?

    func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        chatCompletionCallCount += 1
        capturedMessages = messages
        capturedContext = context
        capturedOptions = options
        if let chatCompletionError { throw chatCompletionError }
        let content = responseContents.isEmpty ? responseContent : responseContents.removeFirst()
        return ChatCompletionResponse(
            content: content,
            reasoningContent: responseReasoningContent,
            finishReason: responseFinishReason,
            model: responseModel,
            usage: responseUsage,
            effectiveInferenceSettings: options.effectiveInferenceSettings
        )
    }

    func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        capturedMessages = messages
        capturedContext = context
        capturedOptions = options
        if let chatCompletionError {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: chatCompletionError)
            }
        }
        let tokens = streamTokens ?? [responseContent]
        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(token)
            }
            continuation.finish()
        }
    }

    func chatCompletionDetailedStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        chatCompletionStreamCallCount += 1
        capturedMessages = messages
        capturedContext = context
        capturedOptions = options
        if let chatCompletionError {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: chatCompletionError)
            }
        }
        let tokens = streamTokens ?? [responseContent]
        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(.text(token))
            }
            continuation.yield(.completed(LLMStreamTerminal(
                provider: context.providerConfig.id.rawValue,
                model: responseModel,
                usage: responseUsage.map(LLMUsage.init),
                stopReason: responseFinishReason,
                effectiveSettings: options.effectiveInferenceSettings
            )))
            continuation.finish()
        }
    }

    func testConnection(context: LLMExecutionContext) async throws {
        capturedContext = context
        if testConnectionDelayNs > 0 {
            try await Task.sleep(nanoseconds: testConnectionDelayNs)
        }
        if let error = testConnectionError { throw error }
    }

    var modelsList: [String] = []
    var listModelsError: Error?
    var listModelsCallCount = 0

    func listModels(context: LLMExecutionContext) async throws -> [String] {
        listModelsCallCount += 1
        capturedContext = context
        if let error = listModelsError { throw error }
        return modelsList
    }

    func withInProcessLocalModelRemoval(_ operation: @Sendable () async throws -> Void) async throws {
        inProcessModelRemovalCallCount += 1
        if holdInProcessModelRemoval {
            await withCheckedContinuation { continuation in
                inProcessModelRemovalContinuation = continuation
            }
        }
        try await operation()
    }

    func releaseInProcessModelRemoval() {
        holdInProcessModelRemoval = false
        inProcessModelRemovalContinuation?.resume()
        inProcessModelRemovalContinuation = nil
    }
}

final class MockLLMExecutionContextResolver: LLMExecutionContextResolving, @unchecked Sendable {
    let configStore: MockLLMConfigStore
    var localCLIConfig: LocalCLIConfig?
    var resolveError: Error?

    init(configStore: MockLLMConfigStore, localCLIConfig: LocalCLIConfig? = nil) {
        self.configStore = configStore
        self.localCLIConfig = localCLIConfig
    }

    func resolveContext() throws -> LLMExecutionContext? {
        if let resolveError {
            throw resolveError
        }
        guard let config = try configStore.loadConfig() else { return nil }
        let resolvedLocalCLIConfig = config.id == .localCLI ? localCLIConfig : nil
        return LLMExecutionContext(
            providerConfig: config,
            localCLIConfig: resolvedLocalCLIConfig
        )
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

    func updateModelName(_ modelName: String) throws {
        guard let existing = config else { return }
        config = LLMProviderConfig(
            id: existing.id, baseURL: existing.baseURL, apiKey: existing.apiKey,
            modelName: modelName, isLocal: existing.isLocal
        )
    }
}

private final class LLMTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEventSpec] = []

    func send(_ event: TelemetryEventSpec) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return true
    }

    func flush() async {}
    func clearQueue() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
    func flushForTermination() {}

    func snapshot() -> [TelemetryEventSpec] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class LLMServiceTests: XCTestCase {
    var mockClient: MockLLMClient!
    var mockConfigStore: MockLLMConfigStore!
    var mockContextResolver: MockLLMExecutionContextResolver!
    var service: LLMService!

    override func setUp() {
        mockClient = MockLLMClient()
        mockConfigStore = MockLLMConfigStore()
        mockConfigStore.config = .openai(apiKey: "sk-test")
        mockContextResolver = MockLLMExecutionContextResolver(configStore: mockConfigStore)
        service = LLMService(client: mockClient, contextResolver: mockContextResolver)
    }

    override func tearDown() {
        Telemetry.configure(NoOpTelemetryService())
        service = nil
        mockContextResolver = nil
        mockConfigStore = nil
        mockClient = nil
        super.tearDown()
    }

    // MARK: - Not Configured

    func testThrowsNotConfiguredWhenNoProvider() async {
        mockConfigStore.config = nil

        do {
            _ = try await service.summarize(transcript: "Test")
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {
            } else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChatThrowsNotConfiguredWhenNoProvider() async {
        mockConfigStore.config = nil

        do {
            _ = try await service.chat(
                question: "Q", transcript: "T", userNotes: nil, history: [], source: .transcriptChat,
                conversationID: UUID())
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {
            } else {
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
            if case .notConfigured = error {
            } else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFormatTranscriptThrowsNotConfiguredWhenNoProvider() async {
        mockConfigStore.config = nil

        do {
            _ = try await service.formatTranscript(
                transcript: "T",
                promptTemplate: "P",
                source: .dictation,
                defaultPromptUsed: true
            )
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {
            } else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSetupCancellationEmitsCancelledLLMOperationWithoutErrorType() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockContextResolver.resolveError = CancellationError()

        do {
            _ = try await service.summarize(transcript: "Test")
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let operations = llmOperationProps(in: telemetry.snapshot())
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?["feature"], "prompt_result")
        XCTAssertEqual(operations.first?["provider"], "unknown")
        XCTAssertEqual(operations.first?["streaming"], "false")
        XCTAssertEqual(operations.first?["outcome"], "cancelled")
        XCTAssertNil(operations.first?["error_type"])
    }

    // MARK: - Summarize

    func testSummarizeAssemblesCorrectPrompt() async throws {
        _ = try await service.summarize(transcript: "The meeting discussed budgets.")

        XCTAssertEqual(mockClient.capturedMessages.count, 2)
        XCTAssertEqual(mockClient.capturedMessages[0].role, .system)
        XCTAssertTrue(mockClient.capturedMessages[0].content.contains("Summarize this transcript"))
        XCTAssertEqual(mockClient.capturedMessages[1].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[1].content, "The meeting discussed budgets.")
    }

    // MARK: - Chat

    func testChatAssemblesSystemPromptWithTranscript() async throws {
        _ = try await service.chat(
            question: "What was discussed?", transcript: "We talked about the release.", userNotes: nil, history: [],
            source: .transcriptChat, conversationID: UUID())

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
            question: "What did Alice say?", transcript: "Alice said hello.", userNotes: nil, history: history,
            source: .transcriptChat, conversationID: UUID())

        // system + 2 history + user question = 4
        XCTAssertEqual(mockClient.capturedMessages.count, 4)
        XCTAssertEqual(mockClient.capturedMessages[1].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[1].content, "Who spoke?")
        XCTAssertEqual(mockClient.capturedMessages[2].role, .assistant)
        XCTAssertEqual(mockClient.capturedMessages[3].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[3].content, "What did Alice say?")
    }

    func testChatInjectsUserNotesIntoSystemPromptWhenPresent() async throws {
        _ = try await service.chat(
            question: "Why did we delay?", transcript: "Alice: We're slipping by a week.",
            userNotes: "decision: ship Friday\nQA owns smoke tests", history: [], source: .transcriptChat,
            conversationID: UUID())

        let systemPrompt = mockClient.capturedMessages[0].content
        XCTAssertTrue(systemPrompt.contains("User's notes from the meeting"))
        XCTAssertTrue(systemPrompt.contains("decision: ship Friday"))
        XCTAssertTrue(systemPrompt.contains("QA owns smoke tests"))
        // The notes block must precede the transcript block — the LLM reads
        // them as context for what the user cares about, applied while reading
        // the transcript that follows.
        let notesIdx = systemPrompt.range(of: "User's notes from the meeting")!.lowerBound
        let transcriptIdx = systemPrompt.range(of: "Transcript:")!.lowerBound
        XCTAssertLessThan(notesIdx, transcriptIdx)
    }

    func testChatOmitsUserNotesBlockWhenNotesAreNil() async throws {
        _ = try await service.chat(
            question: "Q", transcript: "T", userNotes: nil, history: [], source: .transcriptChat, conversationID: UUID()
        )
        XCTAssertFalse(
            mockClient.capturedMessages[0].content.contains("User's notes from the meeting"),
            "Nil userNotes must not introduce the notes block"
        )
    }

    func testChatOmitsUserNotesBlockWhenNotesAreEmpty() async throws {
        _ = try await service.chat(
            question: "Q", transcript: "T", userNotes: "", history: [], source: .transcriptChat, conversationID: UUID())
        XCTAssertFalse(
            mockClient.capturedMessages[0].content.contains("User's notes from the meeting"),
            "Empty userNotes must not introduce the notes block"
        )
    }

    func testChatOmitsUserNotesBlockWhenNotesAreWhitespaceOnly() async throws {
        _ = try await service.chat(
            question: "Q", transcript: "T", userNotes: "   \n\t  \n  ", history: [], source: .transcriptChat,
            conversationID: UUID())
        XCTAssertFalse(
            mockClient.capturedMessages[0].content.contains("User's notes from the meeting"),
            "Whitespace-only userNotes must not introduce the notes block"
        )
    }

    func testChatWithNilNotesIsByteIdenticalToOmittedBlock() async throws {
        _ = try await service.chat(
            question: "Q", transcript: "T", userNotes: nil, history: [], source: .transcriptChat, conversationID: UUID()
        )
        let withoutNotes = mockClient.capturedMessages[0].content

        // Re-init the mock and exercise with empty/whitespace notes; output
        // should be identical to the nil-notes case (no degraded behavior for
        // chats where the user simply hasn't typed during the meeting).
        mockClient.capturedMessages = []
        _ = try await service.chat(
            question: "Q", transcript: "T", userNotes: "   ", history: [], source: .transcriptChat,
            conversationID: UUID())
        let withWhitespace = mockClient.capturedMessages[0].content
        XCTAssertEqual(withoutNotes, withWhitespace)
    }

    // MARK: - Detailed (Envelope) Variants

    func testSummarizeDetailedReturnsEnvelopeWithUsageAndModel() async throws {
        mockClient.responseContent = "summary"
        mockClient.responseModel = "gpt-4.1"
        mockClient.responseFinishReason = "stop"
        mockClient.responseUsage = TokenUsage(promptTokens: 50, completionTokens: 75)

        let result = try await service.summarizeDetailed(transcript: "hello world")

        XCTAssertEqual(result.output, "summary")
        XCTAssertEqual(result.model, "gpt-4.1")
        XCTAssertEqual(result.provider, "openai")
        XCTAssertEqual(result.usage?.promptTokens, 50)
        XCTAssertEqual(result.usage?.completionTokens, 75)
        XCTAssertEqual(result.usage?.totalTokens, 125)
        XCTAssertEqual(result.stopReason, "stop")
        XCTAssertGreaterThanOrEqual(result.latencyMs, 0)
    }

    func testSummarizeStringDelegatesToDetailed() async throws {
        // The string variant must end up in the same network call site as
        // detailed — proven by the call only landing once on the mock and
        // the captured user message matching what summarize() would assemble.
        mockClient.responseContent = "delegated"

        let output = try await service.summarize(transcript: "input text")

        XCTAssertEqual(output, "delegated")
        XCTAssertEqual(mockClient.capturedMessages.count, 2)
        XCTAssertEqual(mockClient.capturedMessages[1].content, "input text")
    }

    func testPromptResultDetailedAppliesAndReturnsEffectiveInferenceSettings() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "gpt-4.1")
        let requested = PromptInferenceSettings(
            temperature: 0.2,
            topP: 0.8,
            maxTokens: 512
        )

        let result = try await service.generatePromptResultDetailed(
            transcript: "input text",
            systemPrompt: nil,
            inferenceSettings: requested
        )

        XCTAssertEqual(result.effectiveSettings?.temperature, 0.2)
        XCTAssertEqual(result.effectiveSettings?.topP, 0.8)
        XCTAssertEqual(result.effectiveSettings?.maxTokens, 512)
        XCTAssertTrue(try XCTUnwrap(mockClient.capturedOptions).usesPromptInferenceSettings)
        XCTAssertEqual(mockClient.capturedOptions?.effectiveInferenceSettings, result.effectiveSettings)
    }

    func testPromptResultDetailedUsesRequestScopedModelOverrideWithoutMutatingStore() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "global-model")

        _ = try await service.generatePromptResultDetailed(
            transcript: "input text",
            systemPrompt: nil,
            inferenceSettings: nil,
            modelOverride: "prompt-model"
        )

        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "prompt-model")
        XCTAssertEqual(mockConfigStore.config?.modelName, "global-model")
    }

    func testPromptResultRejectsEmptyModelOverrideBeforeClientRequest() async {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "gpt-4.1")

        do {
            _ = try await service.generatePromptResultDetailed(
                transcript: "input text",
                systemPrompt: nil,
                inferenceSettings: nil,
                modelOverride: "   "
            )
            XCTFail("Expected an invalid model override error")
        } catch let error as LLMError {
            guard case .invalidModelOverride = error else {
                return XCTFail("Unexpected LLM error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Choose a compatible model"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(mockClient.chatCompletionCallCount, 0)
    }

    func testPromptResultRejectsLocallyIncompatibleProviderModelBeforeClientRequest() async {
        mockConfigStore.config = .anthropic(apiKey: "sk-ant-test", model: "claude-sonnet-5")

        do {
            _ = try await service.generatePromptResultDetailed(
                transcript: "input text",
                systemPrompt: nil,
                inferenceSettings: nil,
                modelOverride: "gpt-5.5"
            )
            XCTFail("Expected an incompatible model override error")
        } catch let error as LLMError {
            guard case .invalidModelOverride(_, let provider, _) = error else {
                return XCTFail("Unexpected LLM error: \(error)")
            }
            XCTAssertEqual(provider, .anthropic)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(mockClient.chatCompletionCallCount, 0)
    }

    func testPromptResultAcceptsSelectedGemmaModelSnapshotForBothExecutionPaths() async throws {
        let model = "gemma-3-27b-it"
        mockConfigStore.config = .gemini(apiKey: "test-key", model: model)

        _ = try await service.generatePromptResultDetailed(
            transcript: "input", systemPrompt: nil,
            inferenceSettings: nil, modelOverride: model
        )
        XCTAssertEqual(mockClient.chatCompletionCallCount, 1)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, model)

        for try await _ in service.generatePromptResultDetailedStream(
            transcript: "input", systemPrompt: nil,
            inferenceSettings: nil, modelOverride: model
        ) {}
        XCTAssertEqual(mockClient.chatCompletionStreamCallCount, 1)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, model)
        XCTAssertEqual(mockConfigStore.config?.modelName, model)
        XCTAssertEqual(mockClient.listModelsCallCount, 0)
    }

    func testPromptResultAcceptsGemmaOverrideWithoutMutatingSelectedGeminiModel() async throws {
        mockConfigStore.config = .gemini(apiKey: "test-key", model: "gemini-2.5-flash")

        _ = try await service.generatePromptResultDetailed(
            transcript: "input", systemPrompt: nil,
            inferenceSettings: nil, modelOverride: "gemma-3-27b-it"
        )

        XCTAssertEqual(mockClient.chatCompletionCallCount, 1)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "gemma-3-27b-it")
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.id, .gemini)
        XCTAssertEqual(mockConfigStore.config?.modelName, "gemini-2.5-flash")
    }

    func testPromptResultAcceptsOllamaAliasAbsentFromDiscovery() async throws {
        mockConfigStore.config = .ollama(model: "mistral")
        mockClient.modelsList = ["mistral:latest"]

        _ = try await service.generatePromptResultDetailed(
            transcript: "input text", systemPrompt: nil,
            inferenceSettings: nil, modelOverride: "mistral"
        )

        XCTAssertEqual(mockClient.chatCompletionCallCount, 1)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "mistral")
        XCTAssertEqual(mockClient.listModelsCallCount, 0)
    }

    func testPromptResultStreamAcceptsProviderAliasAbsentFromDiscovery() async throws {
        mockConfigStore.config = .anthropic(apiKey: "sk-test", model: "claude-default")
        mockClient.modelsList = ["claude-sonnet-versioned"]

        for try await _ in service.generatePromptResultDetailedStream(
            transcript: "input text", systemPrompt: nil,
            inferenceSettings: nil, modelOverride: "claude-sonnet-latest"
        ) {}

        XCTAssertEqual(mockClient.chatCompletionStreamCallCount, 1)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "claude-sonnet-latest")
        XCTAssertEqual(mockClient.listModelsCallCount, 0)
    }

    func testPromptResultPropagatesProviderModelRejectionWithoutFallback() async {
        mockClient.modelsList = ["gpt-existing"]
        mockClient.chatCompletionError = LLMError.modelNotFound("gpt-missing")

        do {
            _ = try await service.generatePromptResultDetailed(
                transcript: "input", systemPrompt: nil,
                inferenceSettings: nil, modelOverride: "gpt-missing"
            )
            XCTFail("Expected the provider model error")
        } catch let error as LLMError {
            guard case .modelNotFound(let model) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(model, "gpt-missing")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(mockClient.chatCompletionCallCount, 1)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "gpt-missing")
    }

    func testTransformAcceptsOllamaAliasForBothExecutionPaths() async throws {
        mockConfigStore.config = .ollama(model: "mistral")
        mockClient.modelsList = ["mistral:latest"]
        _ = try await service.transformDetailed(
            text: "input", prompt: "Rewrite", inferenceSettings: nil, modelOverride: "mistral"
        )
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "mistral")
        for try await _ in service.transformStream(
            text: "input", prompt: "Rewrite", inferenceSettings: nil, modelOverride: "mistral"
        ) {}
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "mistral")
        XCTAssertEqual(mockClient.listModelsCallCount, 0)
    }

    func testLocalCLIRejectsDifferentModelAcrossPromptAndTransformPaths() async {
        mockConfigStore.config = .localCLI()
        for path in 0..<4 {
            do {
                switch path {
                case 0:
                    _ = try await service.generatePromptResultDetailed(
                        transcript: "input", systemPrompt: nil,
                        inferenceSettings: nil, modelOverride: "different-model"
                    )
                case 1:
                    for try await _ in service.generatePromptResultDetailedStream(
                        transcript: "input", systemPrompt: nil,
                        inferenceSettings: nil, modelOverride: "different-model"
                    ) {}
                case 2:
                    _ = try await service.transformDetailed(
                        text: "input", prompt: "Rewrite",
                        inferenceSettings: nil, modelOverride: "different-model"
                    )
                default:
                    for try await _ in service.transformStream(
                        text: "input", prompt: "Rewrite",
                        inferenceSettings: nil, modelOverride: "different-model"
                    ) {}
                }
                XCTFail("Expected Local CLI model rejection for path \(path)")
            } catch let error as LLMError {
                guard case .invalidModelOverride(let model, let provider, let reason) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(model, "different-model")
                XCTAssertEqual(provider, .localCLI)
                XCTAssertTrue(reason.contains("command controls its model"))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(mockClient.capturedContext, "No client execution path should be reached")
    }

    func testLocalCLIPreservesUnchangedModelSnapshotAndInheritedModel() async throws {
        mockConfigStore.config = .localCLI()
        for model in [nil, "cli"] as [String?] {
            _ = try await service.generatePromptResultDetailed(
                transcript: "input", systemPrompt: nil,
                inferenceSettings: nil, modelOverride: model
            )
            XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "cli")
        }
        XCTAssertEqual(mockClient.chatCompletionCallCount, 2)
        XCTAssertEqual(mockConfigStore.config?.modelName, "cli")
    }

    func testPromptResultDetailedStreamEmitsOneTerminalReceipt() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "gpt-4.1")
        mockClient.streamTokens = ["one", " two"]
        mockClient.responseModel = "gpt-4.1"
        mockClient.responseFinishReason = "stop"
        mockClient.responseUsage = TokenUsage(promptTokens: 4, completionTokens: 2)
        let requested = PromptInferenceSettings(temperature: 0.3, maxTokens: 64)

        let stream = service.generatePromptResultDetailedStream(
            transcript: "input",
            systemPrompt: nil,
            inferenceSettings: requested
        )
        var text: [String] = []
        var terminals: [LLMStreamTerminal] = []
        for try await event in stream {
            switch event {
            case .text(let chunk): text.append(chunk)
            case .completed(let terminal): terminals.append(terminal)
            }
        }

        XCTAssertEqual(text, ["one", " two"])
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals[0].provider, "openai")
        XCTAssertEqual(terminals[0].model, "gpt-4.1")
        XCTAssertEqual(terminals[0].usage?.totalTokens, 6)
        XCTAssertEqual(terminals[0].stopReason, "stop")
        XCTAssertEqual(
            terminals[0].effectiveSettings,
            PromptInferenceSettings(temperature: 0.3, maxTokens: 64)
        )
    }

    func testPromptResultDetailedStreamUsesRequestScopedModelOverride() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "global-model")
        mockClient.streamTokens = ["done"]

        for try await _ in service.generatePromptResultDetailedStream(
            transcript: "input",
            systemPrompt: nil,
            inferenceSettings: nil,
            modelOverride: "queued-model"
        ) {}

        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "queued-model")
        XCTAssertEqual(mockConfigStore.config?.modelName, "global-model")
    }

    func testLegacyPromptResultStreamProjectsOnlyTextFromDetailedStream() async throws {
        mockClient.streamTokens = ["legacy", " output"]

        var chunks: [String] = []
        for try await chunk in service.generatePromptResultStream(
            transcript: "input",
            systemPrompt: nil,
            inferenceSettings: PromptInferenceSettings(maxTokens: 32)
        ) {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, ["legacy", " output"])
    }

    func testChatDetailedReturnsEnvelope() async throws {
        mockClient.responseContent = "answer"
        mockClient.responseModel = "claude-sonnet-4-6"
        mockClient.responseUsage = TokenUsage(promptTokens: 200, completionTokens: 30)

        let result = try await service.chatDetailed(
            question: "Who?", transcript: "Alice and Bob spoke.", userNotes: nil, history: [], source: .transcriptChat,
            conversationID: UUID())

        XCTAssertEqual(result.output, "answer")
        XCTAssertEqual(result.model, "claude-sonnet-4-6")
        XCTAssertEqual(result.usage?.totalTokens, 230)
    }

    func testTransformDetailedReturnsEnvelopeWithoutUsageWhenAbsent() async throws {
        mockClient.responseContent = "TRANSFORMED"
        mockClient.responseModel = "qwen-4b"
        mockClient.responseUsage = nil

        let result = try await service.transformDetailed(text: "hello", prompt: "uppercase")

        XCTAssertEqual(result.output, "TRANSFORMED")
        XCTAssertEqual(result.model, "qwen-4b")
        XCTAssertNil(result.usage)
    }

    func testTransformDetailedUsesInferenceSettingsAndRequestScopedModelOverride() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "global-model")
        let settings = PromptInferenceSettings(temperature: 0.4, maxTokens: 321)

        _ = try await service.transformDetailed(
            text: "hello",
            prompt: "uppercase",
            inferenceSettings: settings,
            modelOverride: "transform-model"
        )

        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "transform-model")
        XCTAssertEqual(mockClient.capturedOptions?.effectiveInferenceSettings, settings.normalized)
        XCTAssertEqual(mockConfigStore.config?.modelName, "global-model")
    }

    func testFormatTranscriptDetailedReturnsEnvelopeAndFormatterMetadata() async throws {
        mockClient.responseContent = "Hello, world."
        mockClient.responseModel = "formatter-model"
        mockClient.responseFinishReason = "stop"
        mockClient.responseUsage = TokenUsage(promptTokens: 11, completionTokens: 4)

        let result = try await service.formatTranscriptDetailed(
            transcript: "hello world",
            promptTemplate: AIFormatter.defaultPromptTemplate,
            source: .dictation,
            defaultPromptUsed: true
        )

        XCTAssertEqual(result.output, "Hello, world.")
        XCTAssertEqual(result.result.provider, "openai")
        XCTAssertEqual(result.result.model, "formatter-model")
        XCTAssertEqual(result.result.usage?.promptTokens, 11)
        XCTAssertEqual(result.result.usage?.completionTokens, 4)
        XCTAssertEqual(result.result.usage?.totalTokens, 15)
        XCTAssertEqual(result.result.stopReason, "stop")
        XCTAssertFalse(result.operationID.isEmpty)
        XCTAssertEqual(result.inputChars, "hello world".count)
        XCTAssertEqual(result.outputChars, "Hello, world.".count)
        XCTAssertFalse(result.inputTruncated)
        XCTAssertTrue(result.defaultPromptUsed)
        XCTAssertEqual(result.messageCount, 2)
    }

    func testFormatTranscriptDetailedSubtractsPromptOverheadFromTranscriptBudget() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2")
        let transcript = "SENTINEL_TRANSCRIPT"
        let longPromptTemplate =
            String(repeating: "instruction ", count: 9_000)
            + AIFormatter.transcriptPlaceholder

        let result = try await service.formatTranscriptDetailed(
            transcript: transcript,
            promptTemplate: longPromptTemplate,
            source: .dictation,
            defaultPromptUsed: false
        )

        XCTAssertTrue(result.inputTruncated)
        XCTAssertEqual(mockClient.capturedMessages.count, 2)
        XCTAssertFalse(mockClient.capturedMessages[1].content.contains(transcript))
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

    func testFormatTranscriptRendersPromptTemplateWithTranscriptPlaceholder() async throws {
        _ = try await service.formatTranscript(
            transcript: "hello world",
            promptTemplate: "Clean this transcript:\n\(AIFormatter.transcriptPlaceholder)",
            source: .dictation,
            defaultPromptUsed: false
        )

        XCTAssertEqual(mockClient.capturedMessages.count, 2)
        XCTAssertEqual(mockClient.capturedMessages[0].role, .system)
        XCTAssertTrue(mockClient.capturedMessages[0].content.contains("formatted transcript"))
        XCTAssertEqual(mockClient.capturedMessages[1].role, .user)
        XCTAssertEqual(mockClient.capturedMessages[1].content, "Clean this transcript:\nhello world")
    }

    func testFormatTranscriptForLMStudioUsesStructuredOutputFromReasoningContent() async throws {
        mockConfigStore.config = LLMProviderConfig(
            id: .lmstudio,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            apiKey: nil,
            modelName: "qwen3.5-4b-mlx",
            isLocal: true
        )
        mockClient.responseContent = ""
        mockClient.responseReasoningContent = #"{"cleaned_text":"Hello world. This is a test."}"#

        let result = try await service.formatTranscript(
            transcript: "hello world this is a test",
            promptTemplate: AIFormatter.defaultPromptTemplate,
            source: .dictation,
            defaultPromptUsed: true
        )

        XCTAssertEqual(result, "Hello world. This is a test.")
        XCTAssertEqual(
            mockClient.capturedOptions?.responseFormat,
            .jsonSchema(
                name: "formatter_output",
                schema: ChatJSONSchema(
                    type: "object",
                    properties: [
                        "cleaned_text": ChatJSONSchemaProperty(type: "string")
                    ],
                    required: ["cleaned_text"],
                    additionalProperties: false
                )
            )
        )
    }

    func testFormatTranscriptForLMStudioNormalizesEscapedParagraphBreaks() async throws {
        mockConfigStore.config = LLMProviderConfig(
            id: .lmstudio,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            apiKey: nil,
            modelName: "qwen3.5-4b-mlx",
            isLocal: true
        )
        mockClient.responseContent = ""
        mockClient.responseReasoningContent =
            #"{"cleaned_text":"First paragraph.\\nSecond paragraph.\\nThird paragraph."}"#

        let result = try await service.formatTranscript(
            transcript: "first paragraph second paragraph third paragraph",
            promptTemplate: AIFormatter.defaultPromptTemplate,
            source: .dictation,
            defaultPromptUsed: true
        )

        XCTAssertEqual(result, "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
    }

    func testFormatTranscriptForLMStudioPreservesParagraphsWhenOutputMixesRealAndEscapedNewlines() async throws {
        mockConfigStore.config = LLMProviderConfig(
            id: .lmstudio,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            apiKey: nil,
            modelName: "qwen3.5-4b-mlx",
            isLocal: true
        )
        mockClient.responseContent = ""
        mockClient.responseReasoningContent =
            #"{"cleaned_text":"Intro line.\nSecond line in same paragraph.\\nNew paragraph starts here."}"#

        let result = try await service.formatTranscript(
            transcript: "intro and follow-up then new paragraph",
            promptTemplate: AIFormatter.defaultPromptTemplate,
            source: .dictation,
            defaultPromptUsed: true
        )

        XCTAssertEqual(result, "Intro line.\nSecond line in same paragraph.\n\nNew paragraph starts here.")
    }

    func testFormatTranscriptForLMStudioThrowsWhenOutputIsTruncated() async throws {
        mockConfigStore.config = LLMProviderConfig(
            id: .lmstudio,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            apiKey: nil,
            modelName: "qwen3.5-4b-mlx",
            isLocal: true
        )
        mockClient.responseContent = #"{"cleaned_text":"Partial output"}"#
        mockClient.responseFinishReason = "length"

        do {
            _ = try await service.formatTranscript(
                transcript: "long transcript content",
                promptTemplate: AIFormatter.defaultPromptTemplate,
                source: .dictation,
                defaultPromptUsed: true
            )
            XCTFail("Expected truncated formatter output to throw")
        } catch let error as LLMError {
            if case .formatterTruncated = error {
                // Expected
            } else {
                XCTFail("Expected formatterTruncated, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFormatTranscriptForLMStudioThrowsWhenResponseIsEmpty() async throws {
        mockConfigStore.config = LLMProviderConfig(
            id: .lmstudio,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            apiKey: nil,
            modelName: "qwen3.5-4b-mlx",
            isLocal: true
        )
        // Cold-start LM Studio reasoning models can return an empty body or
        // whitespace-only content. We should route those through the failure
        // path so the success-rate metric isn't inflated with runs that
        // produced nothing usable.
        mockClient.responseContent = ""
        mockClient.responseReasoningContent = #"{"cleaned_text":"   \n  "}"#

        do {
            _ = try await service.formatTranscript(
                transcript: "hello world",
                promptTemplate: AIFormatter.defaultPromptTemplate,
                source: .dictation,
                defaultPromptUsed: true
            )
            XCTFail("Expected empty formatter output to throw")
        } catch let error as LLMError {
            if case .formatterEmptyResponse = error {
                // Expected
            } else {
                XCTFail("Expected formatterEmptyResponse, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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
        let text = String(repeating: "word ", count: 200)  // 1000 chars
        let result = LLMService.truncateMiddle(text, limit: 100)
        XCTAssertTrue(result.contains("\n\n[... content truncated ...]\n\n"))
        XCTAssertLessThanOrEqual(result.count, 200)  // head + tail + marker
    }

    func testTruncationSnapsToWordBoundary() {
        let text = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        let result = LLMService.truncateMiddle(text, limit: 60)
        XCTAssertTrue(result.contains("[... content truncated ...]"))
        // Should not split mid-word
        let parts = result.components(separatedBy: "\n\n[... content truncated ...]\n\n")
        XCTAssertEqual(parts.count, 2)
        guard parts.count == 2 else { return }
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
        XCTAssertEqual(LLMService.cloudContextBudget, 500_000)
    }

    func testLocalContextBudget() {
        XCTAssertEqual(LLMService.localContextBudget, 80_000)
    }

    func testLMStudioContextBudget() {
        XCTAssertEqual(LLMService.lmStudioContextBudget, 8_000)
    }

    func testLocalProviderUsesLocalBudget() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2")

        // Create text that exceeds local budget but not cloud budget
        let text = String(repeating: "word ", count: 18_000)  // 90_000 chars > 80_000 local budget
        _ = try await service.summarize(transcript: text)

        // The user message should be truncated
        let userMessage = mockClient.capturedMessages.last!
        XCTAssertTrue(userMessage.content.contains("[... content truncated ...]"))
    }

    func testLMStudioPromptResultUsesConservativeBudgetIncludingSystemPrompt() async throws {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")

        let text = String(repeating: "word ", count: 3_000)
        _ = try await service.generatePromptResultDetailed(
            transcript: text,
            systemPrompt: "Extract the action items."
        )

        let systemMessage = try XCTUnwrap(mockClient.capturedMessages.first)
        let userMessage = try XCTUnwrap(mockClient.capturedMessages.last)
        XCTAssertTrue(userMessage.content.contains("[... content truncated ...]"))
        XCTAssertLessThanOrEqual(
            userMessage.content.count,
            LLMService.lmStudioContextBudget - systemMessage.content.count
        )
    }

    func testOllamaPromptResultsUseConfiguredContextWindowInBothPaths() async throws {
        mockConfigStore.config = .ollama(model: "qwen3")
        let transcript = String(repeating: "x", count: 80_000)
        for maxTokens: Int? in [nil, 2048] {
            let settings = maxTokens.map { PromptInferenceSettings(maxTokens: $0) }
            let expectedInputCharacters = (OllamaLLMHTTPAdapter.contextWindowTokens - (maxTokens ?? 0)) * 7 / 2
            _ = try await service.generatePromptResultDetailed(
                transcript: transcript, systemPrompt: "S", inferenceSettings: settings
            )
            XCTAssertEqual(mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }, expectedInputCharacters)
            XCTAssertEqual(mockClient.capturedOptions?.maxTokens, maxTokens)
            for try await _ in service.generatePromptResultDetailedStream(
                transcript: transcript, systemPrompt: "S", inferenceSettings: settings
            ) {}
            XCTAssertEqual(mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }, expectedInputCharacters)
            XCTAssertEqual(mockClient.capturedOptions?.maxTokens, maxTokens)
        }
    }

    func testOllamaPromptResultsRejectOutputThatFillsContextBeforeDispatchInBothPaths() async {
        mockConfigStore.config = .ollama(model: "qwen3")
        let settings = PromptInferenceSettings(maxTokens: OllamaLLMHTTPAdapter.contextWindowTokens)
        do {
            _ = try await service.generatePromptResultDetailed(
                transcript: "input", systemPrompt: "S", inferenceSettings: settings
            )
            XCTFail("Expected output occupying the full context to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("leave no room for prompt input"))
        }
        do {
            for try await _ in service.generatePromptResultDetailedStream(
                transcript: "input", systemPrompt: "S", inferenceSettings: settings
            ) {}
            XCTFail("Expected output occupying the full context to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("leave no room for prompt input"))
        }
        XCTAssertEqual(mockClient.chatCompletionCallCount, 0)
        XCTAssertTrue(mockClient.capturedMessages.isEmpty)
        XCTAssertNil(mockClient.capturedOptions)
    }

    func testAnthropicPromptResultsReserveInheritedOutputLimitInBothPaths() async throws {
        mockConfigStore.config = .anthropic(apiKey: "test-key", model: "claude-sonnet-4-5")
        let transcript = String(repeating: "x", count: LLMService.cloudContextBudget)
        let result = try await service.generatePromptResultDetailed(
            transcript: transcript,
            systemPrompt: "S"
        )
        let expectedInputCharacters = LLMService.cloudContextBudget - 4096 * 7 / 2
        XCTAssertEqual(mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }, expectedInputCharacters)
        XCTAssertNil(mockClient.capturedOptions?.maxTokens, "Preserve the adapter's inherited wire default")
        XCTAssertEqual(result.effectiveSettings?.maxTokens, 4096)

        for try await _ in service.generatePromptResultDetailedStream(
            transcript: transcript,
            systemPrompt: "S",
            inferenceSettings: nil
        ) {}
        XCTAssertEqual(mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }, expectedInputCharacters)
        XCTAssertNil(mockClient.capturedOptions?.maxTokens)
    }

    func testLMStudioPromptResultReservesCeilingThreePointFiveCharactersPerOutputToken() async throws {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")

        _ = try await service.generatePromptResultDetailed(
            transcript: String(repeating: "x", count: 20_000),
            systemPrompt: "S",
            inferenceSettings: PromptInferenceSettings(maxTokens: 3)
        )

        let totalInputCharacters = mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }
        // ceil(3.5 * 3) = 11, leaving 7,989 input characters.
        XCTAssertEqual(totalInputCharacters, LLMService.lmStudioContextBudget - 11)
        XCTAssertEqual(mockClient.capturedOptions?.maxTokens, 3)
    }

    func testLMStudioPromptResultRejectsOutputBudgetThatLeavesNoInputBeforeCallingClient() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")

        do {
            _ = try await service.generatePromptResultDetailed(
                transcript: "input",
                systemPrompt: "S",
                inferenceSettings: PromptInferenceSettings(maxTokens: 4096)
            )
            XCTFail("Expected an oversized output reservation to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Maximum output tokens (4096) leave no room for prompt input. Reduce Max tokens."
            )
        }

        XCTAssertEqual(mockClient.chatCompletionCallCount, 0)
        XCTAssertTrue(mockClient.capturedMessages.isEmpty)
        let operations = llmOperationProps(in: telemetry.snapshot())
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?["feature"], "prompt_result")
        XCTAssertEqual(operations.first?["provider"], "lmstudio")
        XCTAssertEqual(operations.first?["streaming"], "false")
        XCTAssertEqual(operations.first?["outcome"], "failure")
        XCTAssertNotNil(operations.first?["error_type"])
        XCTAssertNil(operations.first?["input_truncated"])
    }

    func testLMStudioPromptResultBoundsRenderedSystemPromptContainingTranscript() async throws {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")

        let transcript = String(repeating: "word ", count: 3_000)
        _ = try await service.generatePromptResultDetailed(
            transcript: transcript,
            systemPrompt: "Read this inline transcript:\n\(transcript)"
        )

        let systemMessage = try XCTUnwrap(mockClient.capturedMessages.first)
        let userMessage = try XCTUnwrap(mockClient.capturedMessages.last)
        XCTAssertLessThanOrEqual(
            systemMessage.content.count + userMessage.content.count,
            LLMService.lmStudioContextBudget
        )
        XCTAssertTrue(systemMessage.content.contains("[... content truncated ...]"))
        XCTAssertEqual(userMessage.content, "")
    }

    func testLMStudioStreamingPromptResultUsesConservativeBudgetIncludingSystemPrompt() async throws {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")
        mockClient.streamTokens = ["done"]

        let text = String(repeating: "word ", count: 3_000)
        let stream = service.generatePromptResultStream(
            transcript: text,
            systemPrompt: "Extract the action items."
        )
        for try await _ in stream {}

        let systemMessage = try XCTUnwrap(mockClient.capturedMessages.first)
        let userMessage = try XCTUnwrap(mockClient.capturedMessages.last)
        XCTAssertTrue(userMessage.content.contains("[... content truncated ...]"))
        XCTAssertLessThanOrEqual(
            userMessage.content.count,
            LLMService.lmStudioContextBudget - systemMessage.content.count
        )
    }

    func testLMStudioStreamingPromptResultReservesSameOutputBudgetAsNonStreaming() async throws {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")
        mockClient.streamTokens = ["done"]

        for try await _ in service.generatePromptResultDetailedStream(
            transcript: String(repeating: "x", count: 20_000),
            systemPrompt: "S",
            inferenceSettings: PromptInferenceSettings(maxTokens: 3)
        ) {}

        let totalInputCharacters = mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }
        XCTAssertEqual(totalInputCharacters, LLMService.lmStudioContextBudget - 11)
        XCTAssertEqual(mockClient.capturedOptions?.maxTokens, 3)
    }

    func testLMStudioStreamingPromptResultRejectsOutputBudgetThatLeavesNoInputBeforeCallingClient() async {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")

        do {
            for try await _ in service.generatePromptResultDetailedStream(
                transcript: "input",
                systemPrompt: "S",
                inferenceSettings: PromptInferenceSettings(maxTokens: 4096)
            ) {}
            XCTFail("Expected an oversized output reservation to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Maximum output tokens (4096) leave no room for prompt input. Reduce Max tokens."
            )
        }

        XCTAssertTrue(mockClient.capturedMessages.isEmpty)
        XCTAssertNil(mockClient.capturedOptions)
    }

    func testLMStudioTransformSubtractsPromptOverheadFromTextBudget() async throws {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")

        let text = String(repeating: "word ", count: 3_000)
        _ = try await service.transformDetailed(text: text, prompt: "Make it concise.")

        let totalMessageChars = mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }
        XCTAssertLessThanOrEqual(totalMessageChars, LLMService.lmStudioContextBudget)
        XCTAssertTrue(mockClient.capturedMessages.last?.content.contains("[... content truncated ...]") == true)
    }

    func testLMStudioStreamingTransformSubtractsPromptOverheadFromTextBudget() async throws {
        mockConfigStore.config = .lmstudio(model: "qwen/qwen3-4b-2507")
        mockClient.streamTokens = ["done"]

        let text = String(repeating: "word ", count: 3_000)
        let stream = service.transformStream(text: text, prompt: "Make it concise.")
        for try await _ in stream {}

        let totalMessageChars = mockClient.capturedMessages.reduce(0) { $0 + $1.content.count }
        XCTAssertLessThanOrEqual(totalMessageChars, LLMService.lmStudioContextBudget)
        XCTAssertTrue(mockClient.capturedMessages.last?.content.contains("[... content truncated ...]") == true)
    }

    func testCloudProviderDoesNotTruncateWithinBudget() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test")

        // 30K chars is comfortably within cloud budget (500K)
        let text = String(repeating: "word ", count: 6000)
        _ = try await service.summarize(transcript: text)

        let userMessage = mockClient.capturedMessages.last!
        XCTAssertFalse(userMessage.content.contains("[... content truncated ...]"))
    }

    // MARK: - Chat History Overflow

    func testChatDropsOldHistoryWhenOverBudget() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2")  // local = 80K budget

        // Create a long transcript that uses most of the budget
        let transcript = String(repeating: "word ", count: 14_000)  // 70K chars

        // Create history with identifiable messages (~210 chars each)
        let history = (0..<50).flatMap { i -> [ChatMessage] in
            [
                ChatMessage(role: .user, content: "Question \(i) " + String(repeating: "x", count: 200)),
                ChatMessage(role: .assistant, content: "Answer \(i) " + String(repeating: "y", count: 200)),
            ]
        }

        _ = try await service.chat(
            question: "Latest question", transcript: transcript, userNotes: nil, history: history,
            source: .transcriptChat, conversationID: UUID())

        let messages = mockClient.capturedMessages
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "Latest question")
        // Should have dropped most of the 100 history messages
        XCTAssertLessThan(messages.count, history.count + 2)
        XCTAssertGreaterThan(messages.count, 2, "Should keep at least some recent history")
    }

    func testChatWithNegativeHistoryBudgetDropsAllHistory() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2")  // local = 80K budget

        // The truncated transcript fills almost all available local context.
        // System prompt prefix + truncated transcript + question leave little history budget.
        // Make each history entry large enough (>8K each) so none fit.
        let transcript = String(repeating: "word ", count: 40_000)  // 200K chars

        let history = [
            ChatMessage(role: .user, content: String(repeating: "z", count: 10_000)),
            ChatMessage(role: .assistant, content: String(repeating: "z", count: 10_000)),
        ]

        _ = try await service.chat(
            question: "New question", transcript: transcript, userNotes: nil, history: history, source: .transcriptChat,
            conversationID: UUID())

        let messages = mockClient.capturedMessages
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "New question")
        // Each history entry is 10K chars, but only ~7-8K budget — none fit
        XCTAssertEqual(messages.count, 2)
    }

    func testChatBudgetsUserNotesAndTranscriptTogether() async throws {
        mockConfigStore.config = .ollama(model: "llama3.2")

        let transcript = String(repeating: "transcript word ", count: 12_000)
        let notes = String(repeating: "notes word ", count: 12_000)
        let history = [
            ChatMessage(role: .user, content: "Earlier question"),
            ChatMessage(role: .assistant, content: "Earlier answer"),
        ]
        let question = "Latest question"

        _ = try await service.chat(
            question: question, transcript: transcript, userNotes: notes, history: history, source: .transcriptChat,
            conversationID: UUID())

        let messages = mockClient.capturedMessages
        let systemPrompt = try XCTUnwrap(messages.first?.content)
        XCTAssertLessThanOrEqual(
            systemPrompt.count + question.count,
            LLMService.localContextBudget
        )
        XCTAssertTrue(systemPrompt.contains("User's notes from the meeting"))
        XCTAssertTrue(systemPrompt.contains("Transcript:"))
        XCTAssertEqual(messages.last?.content, question)
        XCTAssertGreaterThan(
            messages.count, 2, "Small recent history should still fit after notes/transcript budgeting")
    }

    func testChatHistoryUsesModelPromptOverrideForRichPromptTurns() async throws {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "gpt-4")

        let richPrompt = "Explain the unresolved risks in the meeting so far."
        let history = [
            ChatMessage(role: .user, content: "Tell me more", modelPromptOverride: richPrompt),
            ChatMessage(role: .assistant, content: "The main risk is timeline compression."),
        ]

        _ = try await service.chat(
            question: "What should we do next?", transcript: "The team discussed delivery risks.", userNotes: nil,
            history: history, source: .transcriptChat, conversationID: UUID())

        let messages = mockClient.capturedMessages
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == richPrompt })
        XCTAssertFalse(messages.contains { $0.role == .user && $0.content == "Tell me more" })
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
            question: "What happened?", transcript: "Something happened.", userNotes: nil, history: [],
            source: .transcriptChat, conversationID: UUID())

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
            if case .notConfigured = error {
            } else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSummarizeStreamSetupCancellationEmitsOneCancelledLLMOperationWithoutErrorType() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockContextResolver.resolveError = CancellationError()
        let stream = service.summarizeStream(transcript: "Test")

        do {
            for try await _ in stream {
                XCTFail("Expected stream to throw")
            }
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = telemetry.snapshot()
        let operations = llmOperationProps(in: events)
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?["feature"], "prompt_result")
        XCTAssertEqual(operations.first?["provider"], "unknown")
        XCTAssertEqual(operations.first?["streaming"], "true")
        XCTAssertEqual(operations.first?["outcome"], "cancelled")
        XCTAssertNil(operations.first?["error_type"])
        XCTAssertFalse(
            events.contains { event in
                if case .llmPromptResultFailed = event { return true }
                return false
            })
    }

    func testChatStreamThrowsWhenNotConfigured() async {
        mockConfigStore.config = nil
        let stream = service.chatStream(
            question: "Q", transcript: "T", userNotes: nil, history: [], source: .transcriptChat, conversationID: UUID()
        )

        do {
            for try await _ in stream {
                XCTFail("Expected stream to throw")
            }
            XCTFail("Expected LLMError.notConfigured")
        } catch let error as LLMError {
            if case .notConfigured = error {
            } else {
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
            if case .notConfigured = error {
            } else {
                XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Provider-Unavailable Routing
    //
    // Persistent user-environment errors (Ollama down, model name typo,
    // missing CLI, bad API key) are emitted as `llm_provider_unavailable`
    // instead of `llm_*_failed`. The `*_failed` buckets should reflect real
    // failures worth investigating, not "this user's Ollama isn't running."

    func testFormatTranscriptEmitsProviderUnavailableOnConnectionFailed() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = LLMProviderConfig(
            id: .ollama,
            baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: nil,
            modelName: "llama3:8b",
            isLocal: true
        )
        mockClient.chatCompletionError = LLMError.connectionFailed("refused")

        do {
            _ = try await service.formatTranscript(
                transcript: "hello",
                promptTemplate: AIFormatter.defaultPromptTemplate,
                source: .dictation,
                defaultPromptUsed: true
            )
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmProviderUnavailable(let provider, let errorType, let feature, let source) = event {
                    return provider == "ollama"
                        && errorType == "LLMError.connectionFailed"
                        && feature == .formatter
                        && source == .dictation
                }
                return false
            }, "Expected llmProviderUnavailable in: \(events)")
        XCTAssertFalse(
            events.contains { event in
                if case .llmFormatterFailed = event { return true }
                return false
            }, "Expected NO llmFormatterFailed (user-config errors should not pollute the failure bucket)")
    }

    func testFormatTranscriptStillEmitsFormatterFailedOnRealFailure() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = LLMProviderConfig(
            id: .lmstudio,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            apiKey: nil,
            modelName: "qwen3.5-4b-mlx",
            isLocal: true
        )
        mockClient.responseContent = "ignored"
        mockClient.responseFinishReason = "length"

        do {
            _ = try await service.formatTranscript(
                transcript: "hello",
                promptTemplate: AIFormatter.defaultPromptTemplate,
                source: .dictation,
                defaultPromptUsed: true
            )
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmFormatterFailed = event { return true }
                return false
            }, "Real formatter failures (truncation, etc.) should still emit llmFormatterFailed")
        XCTAssertFalse(
            events.contains { event in
                if case .llmProviderUnavailable = event { return true }
                return false
            })
    }

    func testGeneratePromptResultEmitsProviderUnavailableOnModelNotFound() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = LLMProviderConfig(
            id: .ollama,
            baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: nil,
            modelName: "missing-model",
            isLocal: true
        )
        mockClient.chatCompletionError = LLMError.modelNotFound("missing-model")

        do {
            _ = try await service.generatePromptResult(transcript: "hi", systemPrompt: nil)
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmProviderUnavailable(let provider, let errorType, let feature, _) = event {
                    return provider == "ollama"
                        && errorType == "LLMError.modelNotFound"
                        && feature == .promptResult
                }
                return false
            })
        XCTAssertFalse(
            events.contains { event in
                if case .llmPromptResultFailed = event { return true }
                return false
            })
    }

    func testChatEmitsProviderUnavailableOnCLIError() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = LLMProviderConfig(
            id: .localCLI,
            baseURL: URL(string: "file:///usr/local/bin/llm")!,
            apiKey: nil,
            modelName: "claude",
            isLocal: false
        )
        mockClient.chatCompletionError = LLMError.cliError("not found")

        do {
            _ = try await service.chat(
                question: "Q", transcript: "T", userNotes: nil, history: [], source: .transcriptChat,
                conversationID: UUID())
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmProviderUnavailable(let provider, let errorType, let feature, let source) = event {
                    return provider == "localCLI"
                        && errorType == "LLMError.cliError"
                        && feature == .chat
                        && source == .transcriptChat
                }
                return false
            })
        XCTAssertFalse(
            events.contains { event in
                if case .llmChatFailed = event { return true }
                return false
            })
        XCTAssertEqual(llmOperationProps(in: events).first?["outcome"], "unavailable")
    }

    func testTransformEmitsProviderUnavailableOnAuthFailed() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = .anthropic(apiKey: "bad-key")
        mockClient.chatCompletionError = LLMError.authenticationFailed(nil)

        do {
            _ = try await service.transform(text: "T", prompt: "P")
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmProviderUnavailable(let provider, let errorType, let feature, _) = event {
                    return provider == "anthropic"
                        && errorType == "LLMError.authenticationFailed"
                        && feature == .transform
                }
                return false
            })
        XCTAssertFalse(
            events.contains { event in
                if case .llmTransformFailed = event { return true }
                return false
            })
    }

    func testStreamingPromptResultEmitsProviderUnavailableOnConnectionFailed() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = LLMProviderConfig(
            id: .ollama,
            baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: nil,
            modelName: "llama3:8b",
            isLocal: true
        )
        mockClient.chatCompletionError = LLMError.connectionFailed("refused")
        let stream = service.generatePromptResultStream(transcript: "hi", systemPrompt: nil)

        do {
            for try await _ in stream {}
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmProviderUnavailable(let provider, _, let feature, _) = event {
                    return provider == "ollama" && feature == .promptResult
                }
                return false
            })
        XCTAssertFalse(
            events.contains { event in
                if case .llmPromptResultFailed = event { return true }
                return false
            })
    }

    func testStreamingChatEmitsProviderUnavailableOnModelNotFound() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = LLMProviderConfig(
            id: .ollama,
            baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: nil,
            modelName: "missing",
            isLocal: true
        )
        mockClient.chatCompletionError = LLMError.modelNotFound("missing")
        let stream = service.chatStream(
            question: "Q", transcript: "T", userNotes: nil, history: [], source: .transcriptChat, conversationID: UUID()
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmProviderUnavailable(let provider, _, let feature, let source) = event {
                    return provider == "ollama" && feature == .chat && source == .transcriptChat
                }
                return false
            })
        XCTAssertFalse(
            events.contains { event in
                if case .llmChatFailed = event { return true }
                return false
            })
        XCTAssertEqual(llmOperationProps(in: events).first?["outcome"], "unavailable")
    }

    func testStreamingTransformEmitsProviderUnavailableOnAuthFailed() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = .anthropic(apiKey: "bad-key")
        mockClient.chatCompletionError = LLMError.authenticationFailed(nil)
        let stream = service.transformStream(text: "T", prompt: "P")

        do {
            for try await _ in stream {}
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmProviderUnavailable(let provider, _, let feature, _) = event {
                    return provider == "anthropic" && feature == .transform
                }
                return false
            })
        XCTAssertFalse(
            events.contains { event in
                if case .llmTransformFailed = event { return true }
                return false
            })
    }

    func testProviderErrorStillRoutedToLegacyFailedBucket() async {
        let telemetry = LLMTelemetrySpy()
        Telemetry.configure(telemetry)
        mockConfigStore.config = .openai(apiKey: "sk-test")
        // providerError indicates an API-side failure with a message; the
        // user's environment is fine. This should stay in llm_chat_failed,
        // not get reclassified as user-config drift.
        mockClient.chatCompletionError = LLMError.providerError("500 Internal")

        do {
            _ = try await service.chat(
                question: "Q", transcript: "T", userNotes: nil, history: [], source: .transcriptChat,
                conversationID: UUID())
            XCTFail("Expected throw")
        } catch {}

        let events = telemetry.snapshot()
        XCTAssertTrue(
            events.contains { event in
                if case .llmChatFailed = event { return true }
                return false
            })
        XCTAssertFalse(
            events.contains { event in
                if case .llmProviderUnavailable = event { return true }
                return false
            })
    }

    // MARK: - Model Selection

    func testUpdateModelNamePreservesProviderAndBaseURL() throws {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "gpt-5.4")

        try mockConfigStore.updateModelName("gpt-5-mini")

        let config = try mockConfigStore.loadConfig()
        XCTAssertEqual(config?.modelName, "gpt-5-mini")
        XCTAssertEqual(config?.id, .openai)
        XCTAssertEqual(config?.apiKey, "sk-test")
        XCTAssertEqual(config?.isLocal, false)
    }

    func testUpdateModelNameOnNilConfigIsNoOp() throws {
        mockConfigStore.config = nil
        try mockConfigStore.updateModelName("gpt-5-mini")
        XCTAssertNil(try mockConfigStore.loadConfig())
    }

    private func llmOperationProps(in events: [TelemetryEventSpec]) -> [[String: String]] {
        events.compactMap { event in
            guard case .llmOperation = event else { return nil }
            return event.props ?? [:]
        }
    }
}
