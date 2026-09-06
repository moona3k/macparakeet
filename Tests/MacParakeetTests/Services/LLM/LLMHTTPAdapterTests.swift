import XCTest
import Network
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private final class AdapterRequestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LLMHTTPAdapterTests: XCTestCase {
    private var session: URLSession!
    private var transport: LLMHTTPTransport!
    private var openAIAdapter: OpenAICompatibleLLMHTTPAdapter!
    private var anthropicAdapter: AnthropicLLMHTTPAdapter!
    private var ollamaAdapter: OllamaLLMHTTPAdapter!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AdapterRequestURLProtocol.self]
        session = URLSession(configuration: config)
        transport = LLMHTTPTransport(session: session)
        openAIAdapter = OpenAICompatibleLLMHTTPAdapter(transport: transport)
        anthropicAdapter = AnthropicLLMHTTPAdapter(transport: transport)
        ollamaAdapter = OllamaLLMHTTPAdapter(transport: transport)
    }

    override func tearDown() {
        AdapterRequestURLProtocol.handler = nil
    }

    func testOpenCodeServicePreservesConversationIdentityForNonstreamingChat() async throws {
        let conversationID = UUID()
        var sessionIDs: [String?] = []
        AdapterRequestURLProtocol.handler = { request in
            sessionIDs.append(request.value(forHTTPHeaderField: "x-opencode-session"))
            return (self.okResponse(for: request), self.validOpenAIResponseData())
        }
        let service = openCodeService()
        _ = try await service.chat(
            question: "Question", transcript: "Transcript", userNotes: nil, history: [],
            source: .transcriptChat, conversationID: conversationID
        )
        _ = try await service.chatDetailed(
            question: "Follow-up", transcript: "Transcript", userNotes: nil,
            history: [ChatMessage(role: .user, content: "Question"), ChatMessage(role: .assistant, content: "OK")],
            source: .transcriptChat, conversationID: conversationID
        )
        XCTAssertEqual(sessionIDs, [conversationID.uuidString, conversationID.uuidString])
    }

    func testOpenCodeRedirectsRefuseUnapprovedDestinations() async throws {
        var original = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!)
        original.httpMethod = "POST"
        original.httpBody = Data("Private synthetic prompt".utf8)
        original.setValue("Bearer synthetic-key", forHTTPHeaderField: "Authorization")
        original.setValue("synthetic-api-key", forHTTPHeaderField: "x-api-key")
        let conversationID = UUID()
        OpenCodeRequestHeaders.apply(to: &original, conversationID: conversationID)
        let delegate = try XCTUnwrap(OpenCodeRequestHeaders.redirectDelegate(for: original))
        let task = session.dataTask(with: original)
        defer { task.cancel() }
        for destination in [
            "https://opencode.ai/zen/go/v1/messages",
            "https://opencode.ai.evil.example/zen/go/v1/chat/completions",
            "https://opencode.ai/unrelated",
            "http://opencode.ai/zen/go/v1/chat/completions",
        ] {
            var proposed = original
            proposed.url = URL(string: destination)!
            let completed = expectation(description: "redirect decision")
            delegate.urlSession?(
                session, task: task,
                willPerformHTTPRedirection: HTTPURLResponse(
                    url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil
                )!,
                newRequest: proposed
            ) { result in
                if destination == "https://opencode.ai/zen/go/v1/messages" {
                    XCTAssertEqual(result?.url?.absoluteString, destination)
                    XCTAssertEqual(result?.value(forHTTPHeaderField: "x-opencode-session"), conversationID.uuidString)
                    XCTAssertEqual(result?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
                    XCTAssertEqual(result?.value(forHTTPHeaderField: "x-api-key"), "synthetic-api-key")
                    XCTAssertEqual(result?.httpBody, Data("Private synthetic prompt".utf8))
                } else {
                    XCTAssertNil(result, "Neither credentials nor prompt content may follow an unapproved redirect")
                }
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
        }
    }

    func testOpenCodeConversationIdentityAcrossHTTPModesAndIsolatedOperations() async throws {
        let baseURL = URL(string: "https://opencode.ai/zen/go/v1")!
        for provider in [LLMProviderID.openaiCompatible, .anthropic] {
            let config = LLMProviderConfig(
                id: provider, baseURL: baseURL, apiKey: "test-key", modelName: "test-model", isLocal: false
            )
            let client = LLMClient(session: session)
            let conversationID = UUID()
            var requests: [URLRequest] = []
            AdapterRequestURLProtocol.handler = { request in
                requests.append(request)
                if request.httpMethod == "GET" {
                    return (self.okResponse(for: request), Data(#"{"data":[{"id":"test-model"}]}"#.utf8))
                }
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: XCTUnwrap(self.bodyData(from: request))) as? [String: Any]
                )
                if body["stream"] as? Bool == true {
                    let stream =
                        provider == .anthropic
                        ? "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
                        : "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"
                    return (self.okResponse(for: request), Data(stream.utf8))
                }
                return (
                    self.okResponse(for: request),
                    provider == .anthropic
                        ? self.validAnthropicResponseData() : self.validOpenAIResponseData()
                )
            }

            let options = ChatCompletionOptions(temperature: 0.25, maxTokens: 123, conversationID: conversationID)
            _ = try await client.chatCompletion(messages: goldenMessages, config: config, options: options)
            let chunks = try await collect(
                client.chatCompletionStream(messages: goldenMessages, config: config, options: options))
            XCTAssertEqual(chunks, ["Hello"])
            _ = try await client.chatCompletion(
                messages: goldenMessages, config: config, options: ChatCompletionOptions(conversationID: UUID())
            )
            _ = try await client.chatCompletion(messages: goldenMessages, config: config, options: .default)
            _ = try await client.chatCompletion(messages: goldenMessages, config: config, options: .default)
            try await client.testConnection(config: config)
            _ = try await client.listModels(config: config)
            _ = try await client.listModels(config: config)

            let ids = try requests.map { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MacParakeet")
                return try XCTUnwrap(
                    UUID(uuidString: XCTUnwrap(request.value(forHTTPHeaderField: "x-opencode-session"))))
            }
            XCTAssertEqual(Array(ids.prefix(2)), [conversationID, conversationID])
            XCTAssertEqual(
                Set(ids.dropFirst()).count, 7, "Distinct conversations, one-shots and probes must not share IDs")
            let expectedBody =
                provider == .anthropic
                ? #"{"max_tokens":123,"messages":[{"content":"Hello","role":"user"}],"model":"test-model","stream":false,"system":"System"}"#
                : #"{"max_tokens":123,"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"test-model","stream":false,"temperature":0.25}"#
            XCTAssertEqual(try canonicalJSONBody(from: XCTUnwrap(requests.first)), expectedBody)
            XCTAssertNil(requests.last?.httpBody)
        }
    }

    func testOpenCodeHeadersDoNotLeakToOtherOriginsOrPaths() async throws {
        let urls = [
            "https://api.openai.com/v1",
            "https://opencode.ai.evil.example/zen/go/v1",
            "https://evilopencode.ai/zen/go/v1",
            "https://api.opencode.ai/zen/go/v1",
            "https://opencode.ai/zen/go/v10",
            "https://opencode.ai/zen/v1",
            "https://opencode.ai/other",
            "http://opencode.ai/zen/go/v1",
            "https://opencode.ai:8443/zen/go/v1",
        ]
        AdapterRequestURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-session"), request.url!.absoluteString)
            XCTAssertNotEqual(request.value(forHTTPHeaderField: "User-Agent"), "MacParakeet")
            return (
                self.okResponse(for: request),
                request.httpMethod == "GET"
                    ? Data(#"{"data":[]}"#.utf8) : self.validOpenAIResponseData()
            )
        }
        for url in urls {
            let config = LLMProviderConfig.openaiCompatible(model: "test", baseURL: URL(string: url)!)
            _ = try await openAIAdapter.chatCompletion(
                messages: goldenMessages, config: config, options: ChatCompletionOptions(conversationID: UUID())
            )
            _ = try await openAIAdapter.listModels(config: config)
        }
    }

    @MainActor
    func testOpenCodeUIChatReusesSavedThreadAcrossTurnsRegenerationAndReload() async throws {
        var sessionIDs: [String?] = []
        AdapterRequestURLProtocol.handler = { request in
            sessionIDs.append(request.value(forHTTPHeaderField: "x-opencode-session"))
            return (
                self.okResponse(for: request),
                Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n".utf8)
            )
        }
        let service = openCodeService()
        let repo = MockChatConversationRepository()
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: service, transcriptText: "Transcript", conversationRepo: repo)
        let transcriptionID = UUID()
        vm.loadTranscript("Transcript", transcriptionId: transcriptionID)
        vm.inputText = "Question"
        vm.sendMessage()
        try await finishChat(vm)
        let first = try XCTUnwrap(vm.currentConversation)
        vm.inputText = "Follow-up"
        vm.sendMessage()
        try await finishChat(vm)
        vm.regenerateLastResponse()
        try await finishChat(vm)
        vm.newChat()
        vm.inputText = "Question"
        vm.sendMessage()
        try await finishChat(vm)
        let second = try XCTUnwrap(vm.currentConversation)
        XCTAssertNotEqual(first.id, second.id)
        vm.switchConversation(first)
        vm.inputText = "Back to first"
        vm.sendMessage()
        try await finishChat(vm)
        let reloaded = TranscriptChatViewModel()
        reloaded.configure(llmService: service, transcriptText: "Transcript", conversationRepo: repo)
        reloaded.loadTranscript("Transcript", transcriptionId: transcriptionID)
        reloaded.switchConversation(try XCTUnwrap(repo.conversations.first { $0.id == first.id }))
        reloaded.inputText = "After reload"
        reloaded.sendMessage()
        try await finishChat(reloaded)
        XCTAssertEqual(
            sessionIDs,
            [
                first.id.uuidString, first.id.uuidString, first.id.uuidString,
                second.id.uuidString, first.id.uuidString, first.id.uuidString,
            ])
    }

    @MainActor
    func testOpenCodeLiveChatKeepsIdentityWhenPromotedAndResetsForNewChat() async throws {
        var sessionIDs: [String?] = []
        AdapterRequestURLProtocol.handler = { request in
            sessionIDs.append(request.value(forHTTPHeaderField: "x-opencode-session"))
            return (
                self.okResponse(for: request),
                Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n".utf8)
            )
        }
        let vm = TranscriptChatViewModel()
        vm.configure(llmService: openCodeService(), transcriptText: "Live")
        vm.inputText = "Question"
        vm.sendMessage()
        try await finishChat(vm)
        let liveHeader = try XCTUnwrap(try XCTUnwrap(sessionIDs.first))
        let liveID = try XCTUnwrap(UUID(uuidString: liveHeader))
        vm.updateTranscriptText("Live transcript grew")
        vm.inputText = "Follow-up"
        vm.sendMessage()
        try await finishChat(vm)
        vm.bindPersistedConversation(
            transcriptionId: UUID(), transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository()
        )
        XCTAssertEqual(vm.currentConversation?.id, liveID)
        vm.inputText = "After meeting"
        vm.sendMessage()
        try await finishChat(vm)
        XCTAssertEqual(sessionIDs, Array(repeating: liveID.uuidString, count: 3))
        vm.newChat()
        vm.inputText = "New thread"
        vm.sendMessage()
        try await finishChat(vm)
        let newHeader = try XCTUnwrap(try XCTUnwrap(sessionIDs.last))
        XCTAssertNotEqual(newHeader, liveID.uuidString)
    }

    private func openCodeService() -> LLMService {
        LLMService(
            client: LLMClient(session: session),
            contextResolver: StaticLLMExecutionContextResolver(
                context: LLMExecutionContext(
                    providerConfig: .openaiCompatible(
                        model: "test-model", baseURL: URL(string: "https://opencode.ai/zen/go/v1")!
                    )
                ))
        )
    }

    @MainActor
    private func finishChat(_ vm: TranscriptChatViewModel) async throws {
        let deadline = Date().addingTimeInterval(2)
        while vm.isStreaming && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.messages.last?.content, "Hello")
    }

    func testOpenAICompatibleAdapterBuildsGoldenRequest() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOpenAIResponseData())
        }

        _ = try await openAIAdapter.chatCompletion(
            messages: goldenMessages,
            config: .openai(apiKey: "sk-golden", model: "gpt-4o"),
            options: ChatCompletionOptions(temperature: 0.25, maxTokens: 123)
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-golden")
        XCTAssertEqual(
            try canonicalJSONBody(from: request),
            """
            {"max_tokens":123,"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"gpt-4o","stream":false,"temperature":0.25}
            """
        )
    }

    func testOpenAIAdapterOmitsTemperatureForGPT5ReasoningTierModels() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOpenAIResponseData())
        }

        _ = try await openAIAdapter.chatCompletion(
            messages: goldenMessages,
            config: .openai(apiKey: "sk-golden", model: "gpt-5.5"),
            options: ChatCompletionOptions(
                temperature: 0.25,
                topP: 0.8,
                topK: 20,
                maxTokens: 123,
                thinkingMode: .disabled
            )
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            try canonicalJSONBody(from: request),
            """
            {"max_completion_tokens":123,"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"gpt-5.5","stream":false}
            """
        )
    }

    func testCustomOpenAICompatibleAdapterBuildsAllInferenceSettings() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOpenAIResponseData())
        }

        let providerConfig = LLMProviderConfig.openaiCompatible(
            model: "local-model",
            baseURL: URL(string: "http://localhost:8080/v1")!
        )
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: providerConfig,
            requested: PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .enabled,
                reasoningEffort: .medium
            )
        )

        _ = try await openAIAdapter.chatCompletion(
            messages: goldenMessages,
            config: providerConfig,
            options: resolution.options
        )

        try assertJSONBody(
            try XCTUnwrap(capturedRequest),
            equals: """
                {"chat_template_kwargs":{"enable_thinking":true,"reasoning_effort":"medium"},"max_tokens":4096,"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"local-model","stream":false,"temperature":0.2,"top_k":20,"top_p":0.9}
                """
        )
    }

    func testCustomOpenAICompatibleThinkingKwargsAreExplicitOnly() throws {
        let config = LLMProviderConfig.openaiCompatible(
            model: "local-model",
            baseURL: URL(string: "http://localhost:8080/v1")!
        )

        let inherited = PromptInferenceCapabilityResolver.resolve(
            config: config,
            requested: nil
        )
        let inheritedBody = try jsonBody(
            from: openAIAdapter.buildRequest(
                messages: goldenMessages,
                config: config,
                options: inherited.options,
                stream: false
            ))
        XCTAssertNil(inheritedBody["chat_template_kwargs"])

        let enabled = PromptInferenceCapabilityResolver.resolve(
            config: config,
            requested: PromptInferenceSettings(thinkingMode: .enabled, reasoningEffort: .xhigh)
        )
        let enabledBody = try jsonBody(
            from: openAIAdapter.buildRequest(
                messages: goldenMessages,
                config: config,
                options: enabled.options,
                stream: false
            ))
        XCTAssertEqual(
            (enabledBody["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool,
            true
        )
        XCTAssertEqual(
            (enabledBody["chat_template_kwargs"] as? [String: Any])?["reasoning_effort"] as? String,
            "xhigh"
        )

        let disabled = PromptInferenceCapabilityResolver.resolve(
            config: config,
            requested: PromptInferenceSettings(thinkingMode: .disabled)
        )
        let disabledBody = try jsonBody(
            from: openAIAdapter.buildRequest(
                messages: goldenMessages,
                config: config,
                options: disabled.options,
                stream: false
            ))
        XCTAssertEqual(
            (disabledBody["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool,
            false
        )
        XCTAssertNil(
            (disabledBody["chat_template_kwargs"] as? [String: Any])?["reasoning_effort"]
        )

        let staleEffortBody = try jsonBody(
            from: openAIAdapter.buildRequest(
                messages: goldenMessages,
                config: config,
                options: ChatCompletionOptions(
                    thinkingMode: .disabled,
                    reasoningEffort: .high,
                    usesPromptInferenceSettings: true
                ),
                stream: false
            ))
        XCTAssertNil(
            (staleEffortBody["chat_template_kwargs"] as? [String: Any])?["reasoning_effort"]
        )
    }

    func testNativeOpenAIAdapterOmitsCustomEndpointOnlySettings() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOpenAIResponseData())
        }

        _ = try await openAIAdapter.chatCompletion(
            messages: goldenMessages,
            config: .openai(apiKey: "sk-golden", model: "gpt-4o"),
            options: ChatCompletionOptions(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .disabled
            )
        )

        try assertJSONBody(
            try XCTUnwrap(capturedRequest),
            equals: """
                {"max_tokens":4096,"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"gpt-4o","stream":false,"temperature":0.2,"top_p":0.9}
                """
        )
    }

    func testOpenAIAdapterKeepsTemperatureForGPT5ChatTierModels() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOpenAIResponseData())
        }

        _ = try await openAIAdapter.chatCompletion(
            messages: goldenMessages,
            config: .openai(apiKey: "sk-golden", model: "gpt-5.3-chat-latest"),
            options: ChatCompletionOptions(temperature: 0.25, maxTokens: 123)
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            try canonicalJSONBody(from: request),
            """
            {"max_completion_tokens":123,"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"gpt-5.3-chat-latest","stream":false,"temperature":0.25}
            """
        )
    }

    func testOpenAIShouldOmitTemperatureModelMatrix() {
        let rejecting = ["o3", "o4-mini", "gpt-5.5", "gpt-5.4", "gpt-5.4-nano", "GPT-5.4-Mini", "gpt-10"]
        for model in rejecting {
            XCTAssertTrue(
                OpenAICompatibleLLMHTTPAdapter.openAIShouldOmitTemperature(model),
                "\(model) should omit temperature"
            )
        }
        let accepting = ["gpt-5.3-chat-latest", "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "chatgpt-4o-latest"]
        for model in accepting {
            XCTAssertFalse(
                OpenAICompatibleLLMHTTPAdapter.openAIShouldOmitTemperature(model),
                "\(model) should keep temperature"
            )
        }
    }

    func testOpenAICompatibleAdapterEncodesNullableKnowledgeCardOwnerSchema() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOpenAIResponseData())
        }

        _ = try await openAIAdapter.chatCompletion(
            messages: goldenMessages,
            config: .openai(apiKey: "sk-golden", model: "gpt-4o"),
            options: ChatCompletionOptions(
                responseFormat: LLMService.knowledgeCardResponseFormat
            )
        )

        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(bodyData(from: request)))
                as? [String: Any]
        )
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        let schemaSpec = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(schemaSpec["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        let items = try XCTUnwrap(actions["items"] as? [String: Any])
        let actionProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        let owner = try XCTUnwrap(actionProperties["owner"] as? [String: Any])

        XCTAssertEqual(owner["type"] as? [String], ["string", "null"])
        XCTAssertTrue(try XCTUnwrap(items["required"] as? [String]).contains("owner"))
    }

    func testAnthropicAdapterBuildsGoldenRequest() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }

        _ = try await anthropicAdapter.chatCompletion(
            messages: goldenMessages,
            config: .anthropic(apiKey: "sk-ant-golden", model: "claude-sonnet-4-6"),
            options: ChatCompletionOptions(temperature: 0.25, maxTokens: 123)
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-golden")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(
            try canonicalJSONBody(from: request),
            """
            {"max_tokens":123,"messages":[{"content":"Hello","role":"user"}],"model":"claude-sonnet-4-6","stream":false,"system":"System","temperature":0.25}
            """
        )
    }

    func testAnthropicAdapterDeclaresPromptEmbeddedStructuredOutput() {
        XCTAssertEqual(
            anthropicAdapter.structuredOutputCapability,
            .promptEmbeddedJSONSchema
        )
        XCTAssertEqual(
            openAIAdapter.structuredOutputCapability,
            .nativeJSONSchema
        )
    }

    func testAnthropicAdapterBuildsSupportedInferenceSettingsOnly() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }

        _ = try await anthropicAdapter.chatCompletion(
            messages: goldenMessages,
            config: .anthropic(apiKey: "sk-ant-golden", model: "claude-sonnet-4-6"),
            options: ChatCompletionOptions(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .disabled
            )
        )

        try assertJSONBody(
            try XCTUnwrap(capturedRequest),
            equals: """
                {"max_tokens":4096,"messages":[{"content":"Hello","role":"user"}],"model":"claude-sonnet-4-6","stream":false,"system":"System","top_p":0.9}
                """
        )
    }

    func testAnthropicTopPRequestAndReceiptOmitInheritedTemperature() async throws {
        var capturedRequest: URLRequest?
        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }
        let config = LLMProviderConfig.anthropic(apiKey: "key", model: "claude-haiku-4-5")
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: config,
            requested: PromptInferenceSettings(topP: 0.9)
        )

        let response = try await anthropicAdapter.chatCompletion(
            messages: goldenMessages,
            config: config,
            options: resolution.options
        )

        try assertJSONBody(
            try XCTUnwrap(capturedRequest),
            equals: """
                {"max_tokens":4096,"messages":[{"content":"Hello","role":"user"}],"model":"claude-haiku-4-5","stream":false,"system":"System","top_p":0.9}
                """
        )
        XCTAssertEqual(
            response.effectiveInferenceSettings,
            PromptInferenceSettings(topP: 0.9, maxTokens: 4096)
        )
    }

    func testAnthropicAdapterOmitsSamplingForUnknownFutureModel() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }

        _ = try await anthropicAdapter.chatCompletion(
            messages: goldenMessages,
            config: .anthropic(apiKey: "sk-ant-golden", model: "claude-sonnet-6"),
            options: ChatCompletionOptions(temperature: 0.2, topP: 0.9, maxTokens: 4096)
        )

        XCTAssertEqual(
            try canonicalJSONBody(from: try XCTUnwrap(capturedRequest)),
            """
            {"max_tokens":4096,"messages":[{"content":"Hello","role":"user"}],"model":"claude-sonnet-6","stream":false,"system":"System"}
            """
        )
    }

    func testOllamaAdapterBuildsGoldenRequest() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOllamaResponseData())
        }

        _ = try await ollamaAdapter.chatCompletion(
            messages: goldenMessages,
            config: .ollama(model: "qwen3.5:4b"),
            options: .default
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 300)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            try canonicalJSONBody(from: request),
            """
            {"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"qwen3.5:4b","options":{"num_ctx":8192},"stream":false,"think":false}
            """
        )
    }

    func testOpenAIDetailedStreamEmitsOneTerminalReceipt() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(self.bodyData(from: request))) as? [String: Any]
            )
            XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
            let data = Data(
                """
                data: {"model":"gpt-4.1","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}

                data: {"model":"gpt-4.1","choices":[{"delta":{},"finish_reason":"stop"}]}

                data: {"model":"gpt-4.1","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}

                data: [DONE]

                """.utf8)
            return (self.okResponse(for: request), data)
        }
        let settings = PromptInferenceSettings(temperature: 0.2)
        let options = ChatCompletionOptions(temperature: 0.2).withInferenceReceipt(
            usesPromptInferenceSettings: true,
            effectiveSettings: settings
        )

        let events = try await collectDetailed(
            openAIAdapter.chatCompletionDetailedStream(
                messages: goldenMessages,
                config: .openai(apiKey: "test", model: "gpt-4.1"),
                options: options
            ))

        XCTAssertEqual(events.filter { $0.isTerminal }.count, 1)
        guard case .completed(let terminal) = events.last else {
            return XCTFail("Expected terminal event")
        }
        XCTAssertEqual(terminal.model, "gpt-4.1")
        XCTAssertEqual(terminal.stopReason, "stop")
        XCTAssertEqual(terminal.usage?.totalTokens, 4)
        XCTAssertEqual(terminal.effectiveSettings, settings)
    }

    func testStreamUsageIsRequestedOnlyForNativeOpenAIStreaming() throws {
        for provider in [LLMProviderID.openai, .openaiCompatible, .gemini, .openrouter, .lmstudio, .ollama] {
            for streaming in [false, true] {
                let config = LLMProviderConfig(
                    id: provider, baseURL: URL(string: "https://example.test/v1")!,
                    apiKey: "test", modelName: "test-model", isLocal: false
                )
                let request = try openAIAdapter.buildRequest(
                    messages: goldenMessages, config: config, options: .default, stream: streaming
                )
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
                )
                if provider == .openai && streaming {
                    XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
                } else {
                    XCTAssertNil(body["stream_options"], "Unexpected stream options for \(provider), stream=\(streaming)")
                }
            }
        }
    }

    func testCompatibleStreamDerivesTotalOnlyWhenBothCountsArePresent() async throws {
        let cases: [(String, Int?)] = [
            (#"{"prompt_tokens":3,"completion_tokens":1}"#, 4),
            (#"{"prompt_tokens":3,"completion_tokens":1,"total_tokens":9}"#, 9),
            (#"{"prompt_tokens":3}"#, nil),
            (#"{"completion_tokens":1}"#, nil),
            ("{\"prompt_tokens\":\(Int.max),\"completion_tokens\":1}", nil),
            ("{\"prompt_tokens\":\(Int.max),\"completion_tokens\":0}", Int.max),
            ("{\"prompt_tokens\":\(Int.max),\"completion_tokens\":1,\"total_tokens\":9}", 9),
        ]
        for (usage, expectedTotal) in cases {
            AdapterRequestURLProtocol.handler = { request in
                let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n"
                    + "data: {\"choices\":[],\"usage\":\(usage)}\n\ndata: [DONE]\n\n"
                return (self.okResponse(for: request), Data(body.utf8))
            }
            let config = LLMProviderConfig(
                id: .openaiCompatible, baseURL: URL(string: "https://example.test/v1")!,
                apiKey: "test", modelName: "test-model", isLocal: false
            )
            let events = try await collectDetailed(openAIAdapter.chatCompletionDetailedStream(
                messages: goldenMessages, config: config, options: .default
            ))
            guard case .completed(let terminal) = events.last else { return XCTFail("Expected terminal receipt") }
            XCTAssertNotNil(terminal.usage)
            let reported = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(usage.utf8)) as? [String: Any])
            XCTAssertEqual(terminal.usage?.promptTokens, reported["prompt_tokens"] as? Int)
            XCTAssertEqual(terminal.usage?.completionTokens, reported["completion_tokens"] as? Int)
            XCTAssertEqual(terminal.usage?.totalTokens, expectedTotal, usage)
        }
    }

    func testAnthropicDetailedStreamEmitsTerminalMetadata() async throws {
        var capturedRequest: URLRequest?
        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            let data = Data(
                """
                data: {"type":"message_start","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":8,"output_tokens":0}}}

                data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

                data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

                data: {"type":"message_stop"}

                """.utf8)
            return (self.okResponse(for: request), data)
        }

        let config = LLMProviderConfig.anthropic(apiKey: "test", model: "claude-sonnet-4-6")
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: config,
            requested: PromptInferenceSettings(topP: 0.9)
        )
        let events = try await collectDetailed(
            anthropicAdapter.chatCompletionDetailedStream(
                messages: goldenMessages,
                config: config,
                options: resolution.options
            ))

        try assertJSONBody(
            try XCTUnwrap(capturedRequest),
            equals: """
                {"max_tokens":4096,"messages":[{"content":"Hello","role":"user"}],"model":"claude-sonnet-4-6","stream":true,"system":"System","top_p":0.9}
                """
        )
        XCTAssertEqual(events.filter { $0.isTerminal }.count, 1)
        guard case .completed(let terminal) = events.last else {
            return XCTFail("Expected terminal event")
        }
        XCTAssertEqual(terminal.stopReason, "end_turn")
        XCTAssertEqual(terminal.usage?.promptTokens, 8)
        XCTAssertEqual(terminal.usage?.completionTokens, 2)
        XCTAssertEqual(terminal.usage?.totalTokens, 10)
        XCTAssertEqual(terminal.effectiveSettings, PromptInferenceSettings(topP: 0.9, maxTokens: 4096))
    }

    func testOllamaDetailedStreamEmitsTerminalOnDone() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let data = Data(
                """
                {"model":"qwen3.5:4b","message":{"role":"assistant","content":"OK"},"done":false}
                {"model":"qwen3.5:4b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":5,"eval_count":1}
                """.utf8)
            return (self.okResponse(for: request), data)
        }

        let events = try await collectDetailed(
            ollamaAdapter.chatCompletionDetailedStream(
                messages: goldenMessages,
                config: .ollama(model: "qwen3.5:4b"),
                options: .default
            ))

        XCTAssertEqual(events.filter { $0.isTerminal }.count, 1)
        XCTAssertEqual(events.first, .text("OK"))
        guard case .completed(let terminal) = events.last else {
            return XCTFail("Expected terminal event")
        }
        XCTAssertEqual(terminal.stopReason, "stop")
        XCTAssertEqual(terminal.usage?.totalTokens, 6)
    }

    func testOllamaDetailedStreamAcceptsLenientEOFWithObservedReceipt() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let data = Data(
                """
                {"model":"requested-alias","message":{"role":"assistant","content":"Hello"},"done":false}
                {"model":"resolved-model","message":{"role":"assistant","content":" world"},"done":false,"done_reason":"length","prompt_eval_count":5,"eval_count":2}
                """.utf8)
            return (self.okResponse(for: request), data)
        }
        let settings = PromptInferenceSettings(temperature: 0.3)
        let events = try await collectDetailed(ollamaAdapter.chatCompletionDetailedStream(
            messages: goldenMessages,
            config: .ollama(model: "requested-alias"),
            options: ChatCompletionOptions(temperature: 0.3).withInferenceReceipt(
                usesPromptInferenceSettings: true, effectiveSettings: settings
            )
        ))
        XCTAssertEqual(events.filter { !$0.isTerminal }, [.text("Hello"), .text(" world")])
        XCTAssertEqual(events.filter { $0.isTerminal }.count, 1)
        guard case .completed(let terminal) = events.last else { return XCTFail("Expected EOF receipt") }
        XCTAssertEqual(terminal.provider, LLMProviderID.ollama.rawValue)
        XCTAssertEqual(terminal.model, "resolved-model")
        XCTAssertEqual(terminal.stopReason, "length")
        XCTAssertEqual(terminal.usage?.promptTokens, 5)
        XCTAssertEqual(terminal.usage?.completionTokens, 2)
        XCTAssertEqual(terminal.usage?.totalTokens, 7)
        XCTAssertEqual(terminal.effectiveSettings, settings)
    }

    func testOllamaDetailedStreamEOFDoesNotInventMissingMetadata() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let data = Data(
                """
                {"model":"actual-model","message":{"role":"assistant","content":"Hello"},"done":false,"prompt_eval_count":5}
                """.utf8)
            return (self.okResponse(for: request), data)
        }
        let events = try await collectDetailed(ollamaAdapter.chatCompletionDetailedStream(
            messages: goldenMessages, config: .ollama(model: "requested-alias"), options: .default
        ))
        XCTAssertEqual(events.filter { $0.isTerminal }.count, 1)
        guard case .completed(let terminal) = events.last else { return XCTFail("Expected EOF receipt") }
        XCTAssertEqual(terminal.model, "actual-model")
        XCTAssertNil(terminal.stopReason)
        XCTAssertEqual(terminal.usage?.promptTokens, 5)
        XCTAssertNil(terminal.usage?.completionTokens)
        XCTAssertNil(terminal.usage?.totalTokens)
    }

    func testOllamaStreamingUsageHandlesOverflowAtDoneAndLenientEOF() async throws {
        for done in [true, false] {
            AdapterRequestURLProtocol.handler = { request in
                let body = "{\"model\":\"test\",\"message\":{\"content\":\"Hello\",\"role\":\"assistant\"},\"done\":\(done),\"prompt_eval_count\":\(Int.max),\"eval_count\":1}\n"
                return (self.okResponse(for: request), Data(body.utf8))
            }
            let events = try await collectDetailed(ollamaAdapter.chatCompletionDetailedStream(
                messages: goldenMessages, config: .ollama(model: "test"), options: .default
            ))
            guard case .completed(let terminal) = events.last else { return XCTFail("Expected successful receipt") }
            XCTAssertEqual(terminal.usage?.promptTokens, Int.max)
            XCTAssertEqual(terminal.usage?.completionTokens, 1)
            XCTAssertNil(terminal.usage?.totalTokens)
        }
    }

    func testAnthropicStreamingUsageHandlesOverflow() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let body = """
                data: {"type":"message_start","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":\(Int.max)}}}

                data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

                data: {"type":"message_delta","usage":{"output_tokens":1}}

                data: {"type":"message_stop"}

                """
            return (self.okResponse(for: request), Data(body.utf8))
        }
        let events = try await collectDetailed(anthropicAdapter.chatCompletionDetailedStream(
            messages: goldenMessages, config: .anthropic(apiKey: "test"), options: .default
        ))
        guard case .completed(let terminal) = events.last else { return XCTFail("Expected successful receipt") }
        XCTAssertEqual(terminal.usage?.promptTokens, Int.max)
        XCTAssertEqual(terminal.usage?.completionTokens, 1)
        XCTAssertNil(terminal.usage?.totalTokens)
    }

    func testOllamaErrorOnlyFramesFailBothStreamsBeforeAndAfterContent() async throws {
        let chunk = #"{"model":"test","message":{"role":"assistant","content":"Partial"},"done":false}"#
        for prefix in ["", chunk + "\n"] {
            AdapterRequestURLProtocol.handler = { request in
                let body = prefix + #"{"error":"model failed to generate"}"# + "\n"
                return (self.okResponse(for: request), Data(body.utf8))
            }
            var text: [String] = []
            do {
                for try await chunk in ollamaAdapter.chatCompletionStream(
                    messages: goldenMessages, config: .ollama(model: "test"), options: .default
                ) {
                    text.append(chunk)
                }
                XCTFail("Provider errors must fail the legacy stream")
            } catch let error as LLMError {
                guard case .streamingError(let detail) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(detail, "model failed to generate")
            }
            XCTAssertEqual(text, prefix.isEmpty ? [] : ["Partial"])

            var events: [LLMStreamEvent] = []
            do {
                for try await event in ollamaAdapter.chatCompletionDetailedStream(
                    messages: goldenMessages, config: .ollama(model: "test"), options: .default
                ) {
                    events.append(event)
                }
                XCTFail("Provider errors must fail the detailed stream")
            } catch let error as LLMError {
                guard case .streamingError(let detail) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(detail, "model failed to generate")
            }
            XCTAssertEqual(events, prefix.isEmpty ? [] : [.text("Partial")])
            XCTAssertFalse(events.contains { $0.isTerminal }, "A provider failure must never produce a success receipt")
        }
    }

    func testOllamaDetailedStreamRejectsEOFWithoutContent() async throws {
        for body in ["", "{\"model\":\"actual-model\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":false}"] {
            AdapterRequestURLProtocol.handler = { request in
                (self.okResponse(for: request), Data(body.utf8))
            }
            var events: [LLMStreamEvent] = []
            do {
                for try await event in ollamaAdapter.chatCompletionDetailedStream(
                    messages: goldenMessages, config: .ollama(model: "requested-alias"), options: .default
                ) {
                    events.append(event)
                }
                XCTFail("Empty output must still fail")
            } catch let error as LLMError {
                guard case .streamingError(let detail) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertTrue(detail.contains("no content"))
            }
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testOllamaAdapterIgnoresInferenceValuesOutsidePromptSettings() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOllamaResponseData())
        }

        _ = try await ollamaAdapter.chatCompletion(
            messages: goldenMessages,
            config: .ollama(model: "qwen3.5:4b"),
            options: ChatCompletionOptions(
                temperature: 0.25,
                topP: 0.8,
                topK: 20,
                maxTokens: 123,
                thinkingMode: .enabled
            )
        )

        XCTAssertEqual(
            try canonicalJSONBody(from: try XCTUnwrap(capturedRequest)),
            """
            {"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"qwen3.5:4b","options":{"num_ctx":8192},"stream":false,"think":false}
            """
        )
    }

    func testOllamaAdapterBuildsAllInferenceSettings() async throws {
        var capturedRequest: URLRequest?
        let config = LLMProviderConfig.ollama(model: "qwen3.5:4b")

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOllamaResponseData())
        }

        _ = try await ollamaAdapter.chatCompletion(
            messages: goldenMessages,
            config: config,
            options: PromptInferenceCapabilityResolver.resolve(
                config: config,
                requested: PromptInferenceSettings(
                    temperature: 0.2,
                    topP: 0.9,
                    topK: 20,
                    maxTokens: 4096,
                    thinkingMode: .enabled
                )
            ).options
        )

        try assertJSONBody(
            try XCTUnwrap(capturedRequest),
            equals: """
                {"messages":[{"content":"System","role":"system"},{"content":"Hello","role":"user"}],"model":"qwen3.5:4b","options":{"num_ctx":8192,"num_predict":4096,"temperature":0.2,"top_k":20,"top_p":0.9},"stream":false,"think":true}
                """
        )
    }

    func testOpenAICompatibleAdapterRejectsStrictEOFMissingDone() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
            return (self.okResponse(for: request), Data(body.utf8))
        }

        let stream = openAIAdapter.chatCompletionStream(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: .openai(apiKey: "sk-test"),
            options: .default
        )

        do {
            _ = try await collect(stream)
            XCTFail("Expected strict OpenAI EOF to throw")
        } catch let error as LLMError {
            guard case .streamingError(let detail) = error else {
                XCTFail("Expected streamingError, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("truncated"))
        }
    }

    func testOpenAICompatibleAdapterAcceptsLenientEOFForCompatibleProvider() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
            return (self.okResponse(for: request), Data(body.utf8))
        }

        let stream = openAIAdapter.chatCompletionStream(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: .openaiCompatible(
                model: "llama-3.1-8b-instruct",
                baseURL: URL(string: "https://custom.example.test/v1")!
            ),
            options: .default
        )

        let chunks = try await collect(stream)
        XCTAssertEqual(chunks, ["Hello"])
    }

    func testAnthropicAdapterRejectsStrictEOFMissingMessageStop() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let body = """
                data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

                """
            return (self.okResponse(for: request), Data(body.utf8))
        }

        let stream = anthropicAdapter.chatCompletionStream(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: .anthropic(apiKey: "sk-ant-test"),
            options: .default
        )

        do {
            _ = try await collect(stream)
            XCTFail("Expected strict Anthropic EOF to throw")
        } catch let error as LLMError {
            guard case .streamingError(let detail) = error else {
                XCTFail("Expected streamingError, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("truncated"))
        }
    }

    func testOllamaAdapterAcceptsLenientEOFWithoutDoneAfterContent() async throws {
        AdapterRequestURLProtocol.handler = { request in
            let body = """
                {"model":"qwen3.5:4b","message":{"role":"assistant","content":"Hello"},"done":false}

                """
            return (self.okResponse(for: request), Data(body.utf8))
        }

        let stream = ollamaAdapter.chatCompletionStream(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: .ollama(model: "qwen3.5:4b"),
            options: .default
        )

        let chunks = try await collect(stream)
        XCTAssertEqual(chunks, ["Hello"])
    }

    func testOpenAICompatibleAdapterCancelsStreamingRequestMidStream() async throws {
        let server = try StreamingHTTPServer(
            firstChunk: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
        )
        defer { server.stop() }
        let adapter = OpenAICompatibleLLMHTTPAdapter(transport: LLMHTTPTransport(session: .shared))

        try await assertCancelsAfterFirstChunk(
            stream: adapter.chatCompletionStream(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: .openaiCompatible(
                    model: "local-model",
                    baseURL: server.baseURL
                ),
                options: .default
            ),
            expectedFirstChunk: "Hello"
        )
    }

    func testAnthropicAdapterCancelsStreamingRequestMidStream() async throws {
        let server = try StreamingHTTPServer(
            firstChunk: """
                data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

                """
        )
        defer { server.stop() }
        let adapter = AnthropicLLMHTTPAdapter(transport: LLMHTTPTransport(session: .shared))

        try await assertCancelsAfterFirstChunk(
            stream: adapter.chatCompletionStream(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: .anthropic(apiKey: "sk-ant-test", baseURL: server.baseURL),
                options: .default
            ),
            expectedFirstChunk: "Hello"
        )
    }

    func testOllamaAdapterCancelsStreamingRequestMidStream() async throws {
        let server = try StreamingHTTPServer(
            firstChunk: """
                {"model":"qwen3.5:4b","message":{"role":"assistant","content":"Hello"},"done":false}

                """
        )
        defer { server.stop() }
        let adapter = OllamaLLMHTTPAdapter(transport: LLMHTTPTransport(session: .shared))

        try await assertCancelsAfterFirstChunk(
            stream: adapter.chatCompletionStream(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: .ollama(model: "qwen3.5:4b", baseURL: server.baseURL.appendingPathComponent("v1")),
                options: .default
            ),
            expectedFirstChunk: "Hello"
        )
    }

    private var goldenMessages: [ChatMessage] {
        [
            ChatMessage(role: .system, content: "System"),
            ChatMessage(role: .user, content: "Hello"),
        ]
    }

    private func assertCancelsAfterFirstChunk(
        stream: AsyncThrowingStream<String, Error>,
        expectedFirstChunk: String
    ) async throws {
        let yielded = expectation(description: "stream yields first chunk")

        let consumer = Task {
            var didYield = false
            for try await chunk in stream {
                XCTAssertEqual(chunk, expectedFirstChunk)
                yielded.fulfill()
                didYield = true
                break
            }
            XCTAssertTrue(didYield)
        }

        await fulfillment(of: [yielded], timeout: 2)
        _ = await consumer.result
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private func collectDetailed(
        _ stream: AsyncThrowingStream<LLMStreamEvent, Error>
    ) async throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func validOpenAIResponseData() -> Data {
        Data(
            """
            {"model":"gpt-4o","choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
            """.utf8)
    }

    private func validAnthropicResponseData() -> Data {
        Data(
            """
            {"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Hello!"}],"usage":{"input_tokens":10,"output_tokens":5},"stop_reason":"end_turn"}
            """.utf8)
    }

    private func validOllamaResponseData() -> Data {
        Data(
            """
            {"model":"qwen3.5:4b","message":{"role":"assistant","content":"OK"},"done":true,"done_reason":"stop","prompt_eval_count":5,"eval_count":1}
            """.utf8)
    }

    private func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(bodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertJSONBody(
        _ request: URLRequest,
        equals expectedJSON: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try jsonBody(from: request) as NSDictionary
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(expectedJSON.utf8)) as? NSDictionary
        )
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func canonicalJSONBody(from request: URLRequest) throws -> String {
        let data = try XCTUnwrap(bodyData(from: request))
        let json = try JSONSerialization.jsonObject(with: data)
        let canonicalData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(data: canonicalData, encoding: .utf8)!
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

private extension LLMStreamEvent {
    var isTerminal: Bool {
        if case .completed = self { return true }
        return false
    }
}

private final class StreamingHTTPServer: @unchecked Sendable {
    private let firstChunk: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LLMHTTPAdapterTests.StreamingHTTPServer")
    private var activeConnection: NWConnection?
    private let closeState = StreamingHTTPServerCloseState()

    private(set) var baseURL: URL

    init(firstChunk: String) throws {
        self.firstChunk = firstChunk
        listener = try NWListener(using: .tcp, on: .any)
        baseURL = URL(string: "http://127.0.0.1")!

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success,
            let port = listener.port
        else {
            throw URLError(.cannotConnectToHost)
        }

        baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    func stop() {
        activeConnection?.cancel()
        listener.cancel()
    }

    func waitForClientClose(timeoutSeconds: TimeInterval) async -> Bool {
        await closeState.waitForClose(timeoutSeconds: timeoutSeconds)
    }

    private func handle(_ connection: NWConnection) {
        activeConnection = connection
        connection.start(queue: queue)

        let chunkData = Data(firstChunk.utf8)
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Transfer-Encoding: chunked\r
            Connection: keep-alive\r
            \r
            \(String(chunkData.count, radix: 16))\r
            \(firstChunk)\r
            """

        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { [weak self] _ in
                self?.observeClose(on: connection)
            })
    }

    private func observeClose(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.markClosed()
                return
            }
            self?.observeClose(on: connection)
        }
    }

    private func markClosed() {
        Task {
            await closeState.markClosed()
        }
    }
}

private actor StreamingHTTPServerCloseState {
    private var didClose = false

    func markClosed() {
        didClose = true
    }

    func waitForClose(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if didClose { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
