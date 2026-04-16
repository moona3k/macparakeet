import XCTest
@testable import MacParakeetCore

// MARK: - Mock URL Protocol

private final class MockURLProtocol: URLProtocol {
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

final class LLMClientTests: XCTestCase {
    var llmClient: LLMClient!
    var session: URLSession!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        llmClient = LLMClient(session: session)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
    }

    // MARK: - URL Construction

    func testRequestURLAppendsChatCompletions() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hello")],
            config: config,
            options: .default
        )

        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
    }

    // MARK: - Auth Headers

    func testOpenAIAuthHeaderSetFromAPIKey() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test-key")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - Anthropic Native API

    func testAnthropicUsesNativeMessagesEndpoint() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }

        let config = LLMProviderConfig.anthropic(apiKey: "sk-ant-test-key")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        // Should use /v1/messages, NOT /v1/chat/completions
        XCTAssertTrue(capturedRequest?.url?.path.hasSuffix("/messages") == true,
                       "Anthropic should use /messages endpoint, got: \(capturedRequest?.url?.path ?? "nil")")
        // Should use x-api-key, NOT Bearer
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
        // Should include anthropic-version
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testAnthropicExtractsSystemPrompt() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }

        let config = LLMProviderConfig.anthropic(apiKey: "sk-ant-test-key")
        _ = try await llmClient.chatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are helpful."),
                ChatMessage(role: .user, content: "Hi"),
            ],
            config: config,
            options: .default
        )

        // System prompt should be a top-level field, not in messages
        XCTAssertEqual(capturedBody?["system"] as? String, "You are helpful.")
        let messages = capturedBody?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 1, "System message should be extracted from messages array")
        XCTAssertEqual(messages?[0]["role"], "user")
    }

    func testAnthropicResponseParsedCorrectly() async throws {
        MockURLProtocol.handler = { request in
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }

        let config = LLMProviderConfig.anthropic(apiKey: "sk-ant-test-key")
        let response = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        XCTAssertEqual(response.content, "Hello!")
        XCTAssertEqual(response.model, "claude-sonnet-4-6")
        XCTAssertEqual(response.usage?.promptTokens, 10)
        XCTAssertEqual(response.usage?.completionTokens, 5)
    }

    func testAnthropicIncludesMaxTokens() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validAnthropicResponseData())
        }

        let config = LLMProviderConfig.anthropic(apiKey: "sk-ant-test-key")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: ChatCompletionOptions(maxTokens: 1000)
        )

        XCTAssertEqual(capturedBody?["max_tokens"] as? Int, 1000)
    }

    func testOllamaUsesNativeAPI() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOllamaResponseData())
        }

        let config = LLMProviderConfig.ollama(model: "qwen3.5:4b")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        // Should hit native /api/chat, not /v1/chat/completions
        XCTAssertTrue(capturedRequest?.url?.path.contains("/api/chat") == true)
        // No auth header for native API
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testCustomProviderWithNoAPIKeyOmitsAuthHeader() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig(
            id: .openaiCompatible,
            baseURL: URL(string: "http://localhost:8080/v1")!,
            apiKey: nil,
            modelName: "test-model",
            isLocal: false
        )
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Request Body

    func testRequestBodyContainsModelAndMessages() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test", model: "gpt-4o-mini")
        _ = try await llmClient.chatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are helpful."),
                ChatMessage(role: .user, content: "Hi"),
            ],
            config: config,
            options: ChatCompletionOptions(temperature: 0.5, maxTokens: 100)
        )

        XCTAssertEqual(capturedBody?["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(capturedBody?["stream"] as? Bool, false)
        XCTAssertEqual(capturedBody?["temperature"] as? Double, 0.5)
        XCTAssertEqual(capturedBody?["max_tokens"] as? Int, 100)

        let messages = capturedBody?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"], "system")
        XCTAssertEqual(messages?[0]["content"], "You are helpful.")
        XCTAssertEqual(messages?[1]["role"], "user")
        XCTAssertEqual(messages?[1]["content"], "Hi")
    }

    // MARK: - Response Parsing

    func testValidResponseParsedCorrectly() async throws {
        MockURLProtocol.handler = { request in
            let json = """
            {
                "model": "gpt-4o",
                "choices": [{"message": {"content": "Hello there!"}}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5}
            }
            """
            return (self.okResponse(for: request), Data(json.utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        let response = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        XCTAssertEqual(response.content, "Hello there!")
        XCTAssertEqual(response.model, "gpt-4o")
        XCTAssertEqual(response.usage?.promptTokens, 10)
        XCTAssertEqual(response.usage?.completionTokens, 5)
    }

    func testInvalidResponseThrowsInvalidResponse() async {
        MockURLProtocol.handler = { request in
            return (self.okResponse(for: request), Data("not json".utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.invalidResponse")
        } catch let error as LLMError {
            if case .invalidResponse = error {} else {
                XCTFail("Expected invalidResponse, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Error Mapping

    func testUnauthorizedThrowsAuthenticationFailed() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"error\":{\"message\":\"Invalid API key\"}}".utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "bad-key")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.authenticationFailed")
        } catch let error as LLMError {
            if case .authenticationFailed = error {} else {
                XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRateLimitThrowsRateLimited() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"error\":{\"message\":\"Rate limit exceeded\"}}".utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.rateLimited")
        } catch let error as LLMError {
            if case .rateLimited = error {} else {
                XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNotFoundThrowsModelNotFound() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"error\":{\"message\":\"Model not found\"}}".utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test", model: "nonexistent")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.modelNotFound")
        } catch let error as LLMError {
            if case .modelNotFound = error {} else {
                XCTFail("Expected modelNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testGenericNotFoundReturnsProviderError() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"error\":{\"message\":\"Route not found\"}}".utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.providerError")
        } catch let error as LLMError {
            if case .providerError(let msg) = error {
                XCTAssertEqual(msg, "Route not found")
            } else {
                XCTFail("Expected providerError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testContextLengthErrorMappedCorrectly() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"error\":{\"message\":\"This model's maximum context length is exceeded\"}}".utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.contextTooLong")
        } catch let error as LLMError {
            if case .contextTooLong = error {} else {
                XCTFail("Expected contextTooLong, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testServerErrorReturnsProviderError() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"error\":{\"message\":\"Internal server error\"}}".utf8))
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.providerError")
        } catch let error as LLMError {
            if case .providerError(let msg) = error {
                XCTAssertEqual(msg, "Internal server error")
            } else {
                XCTFail("Expected providerError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test Connection

    func testTestConnectionSendsMinimalRequest() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        try await llmClient.testConnection(config: config)

        XCTAssertEqual(capturedBody?["max_tokens"] as? Int, 1)
    }

    // MARK: - SSE Parsing

    func testParseSSELineWithValidContent() {
        let result = llmClient.parseSSELine("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}")
        if case .content(let text) = result {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected .content, got \(result)")
        }
    }

    func testParseSSELineExtractsDifferentContent() {
        let result = llmClient.parseSSELine("data: {\"choices\":[{\"delta\":{\"content\":\"World 123!\"}}]}")
        if case .content(let text) = result {
            XCTAssertEqual(text, "World 123!")
        } else {
            XCTFail("Expected .content, got \(result)")
        }
    }

    func testParseSSELineDoneReturnsDone() {
        let result = llmClient.parseSSELine("data: [DONE]")
        if case .done = result {} else {
            XCTFail("Expected .done, got \(result)")
        }
    }

    func testParseSSELineBlankLine() {
        let result = llmClient.parseSSELine("")
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineRoleOnlyFrame() {
        let result = llmClient.parseSSELine("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}")
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineEmptyDelta() {
        let result = llmClient.parseSSELine("data: {\"choices\":[{\"delta\":{}}]}")
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineEmptyContent() {
        let result = llmClient.parseSSELine("data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}")
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineFinishReason() {
        let result = llmClient.parseSSELine("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineNonDataPrefix() {
        let result = llmClient.parseSSELine("event: message")
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineMalformedJSON() {
        let result = llmClient.parseSSELine("data: {\"invalid json}")
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineDataWithNoSpace() {
        let result = llmClient.parseSSELine("data:{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}")
        if case .content(let text) = result {
            XCTAssertEqual(text, "Hi")
        } else {
            XCTFail("Expected .content, got \(result)")
        }
    }

    func testParseSSEEventCombinesMultilineDataPayload() {
        let result = llmClient.parseSSEEvent([
            "data: {\"choices\":[{\"delta\":",
            "data: {\"content\":\"Hello\"}}]}",
        ])
        if case .content(let text) = result {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected .content, got \(result)")
        }
    }

    func testParseSSEEventIgnoresNonDataLines() {
        let result = llmClient.parseSSEEvent([
            "event: message",
            "id: 123",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}",
        ])
        if case .content(let text) = result {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected .content, got \(result)")
        }
    }

    func testParseSSEEventDoneReturnsDone() {
        let result = llmClient.parseSSEEvent([
            "data: [DONE]",
        ])
        if case .done = result {} else {
            XCTFail("Expected .done, got \(result)")
        }
    }

    func testParseSSEEventEmptyLinesReturnsSkip() {
        let result = llmClient.parseSSEEvent([])
        if case .skip = result {} else {
            XCTFail("Expected .skip, got \(result)")
        }
    }

    func testParseSSELineTruncatedJSONSkips() {
        // Provider sends incomplete JSON (e.g. network cut mid-frame)
        let result = llmClient.parseSSELine("data: {\"choices\":[{\"delta\":{\"content\":\"Hel")
        if case .skip = result {} else {
            XCTFail("Expected .skip for truncated JSON, got \(result)")
        }
    }

    func testParseSSELineEmptyChoicesSkips() {
        let result = llmClient.parseSSELine("data: {\"choices\":[]}")
        if case .skip = result {} else {
            XCTFail("Expected .skip for empty choices, got \(result)")
        }
    }

    func testValidateStreamCompletionAcceptsMissingDoneMarker() {
        // Many providers (Gemini, Ollama) don't send [DONE] — this should not throw
        XCTAssertNoThrow(try llmClient.validateStreamCompletion(sawDone: false))
    }

    func testValidateStreamCompletionAcceptsDoneMarker() throws {
        XCTAssertNoThrow(try llmClient.validateStreamCompletion(sawDone: true))
    }

    // MARK: - OpenAI Reasoning Model Handling

    func testReasoningModelUsesMaxCompletionTokens() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test", model: "o3-mini")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: ChatCompletionOptions(temperature: 0.7, maxTokens: 500)
        )

        // Reasoning models must use max_completion_tokens, not max_tokens
        XCTAssertNil(capturedBody?["max_tokens"])
        XCTAssertEqual(capturedBody?["max_completion_tokens"] as? Int, 500)
        // Reasoning models must not send temperature
        XCTAssertNil(capturedBody?["temperature"])
    }

    func testGPT5UsesMaxCompletionTokensButKeepsTemperature() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test", model: "gpt-5.2")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: ChatCompletionOptions(temperature: 0.7, maxTokens: 500)
        )

        // GPT-5.x requires max_completion_tokens, not max_tokens
        XCTAssertNil(capturedBody?["max_tokens"])
        XCTAssertEqual(capturedBody?["max_completion_tokens"] as? Int, 500)
        // But GPT-5.x still accepts temperature (unlike reasoning models)
        XCTAssertEqual(capturedBody?["temperature"] as? Double, 0.7)
    }

    func testNonReasoningModelUsesMaxTokens() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test", model: "gpt-4o")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: ChatCompletionOptions(temperature: 0.7, maxTokens: 500)
        )

        XCTAssertEqual(capturedBody?["max_tokens"] as? Int, 500)
        XCTAssertNil(capturedBody?["max_completion_tokens"])
        XCTAssertEqual(capturedBody?["temperature"] as? Double, 0.7)
    }

    func testOpenAICompatibleProviderDoesNotApplyOpenAISpecificTokenParameters() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openaiCompatible(
            apiKey: "sk-test",
            model: "gpt-5.2",
            baseURL: URL(string: "https://api.example.com/v1")!
        )
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: ChatCompletionOptions(temperature: 0.7, maxTokens: 500)
        )

        XCTAssertEqual(capturedBody?["max_tokens"] as? Int, 500)
        XCTAssertNil(capturedBody?["max_completion_tokens"])
        XCTAssertEqual(capturedBody?["temperature"] as? Double, 0.7)
    }

    // MARK: - Ollama Context Window

    func testOllamaRequestIncludesNumCtxAndThinkFalse() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validOllamaResponseData())
        }

        let config = LLMProviderConfig.ollama(model: "qwen3.5:4b")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        let options = capturedBody?["options"] as? [String: Any]
        XCTAssertEqual(options?["num_ctx"] as? Int, 8192)
        XCTAssertEqual(capturedBody?["think"] as? Bool, false)
    }

    func testNonOllamaRequestOmitsOptions() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.handler = { request in
            if let body = self.extractBody(from: request) {
                capturedBody = body
            }
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        XCTAssertNil(capturedBody?["options"])
    }

    // MARK: - Gemini Error Array Format

    func testGeminiErrorArrayParsedCorrectly() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            let json = """
            [{"error":{"code":404,"message":"models/fake-model is not found","status":"NOT_FOUND"}}]
            """
            return (response, Data(json.utf8))
        }

        let config = LLMProviderConfig.gemini(apiKey: "test-key", model: "fake-model")
        do {
            _ = try await llmClient.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                config: config,
                options: .default
            )
            XCTFail("Expected LLMError.modelNotFound")
        } catch let error as LLMError {
            if case .modelNotFound(let msg) = error {
                XCTAssert(msg.contains("fake-model"), "Error should mention model name")
            } else {
                XCTFail("Expected modelNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Stream Error Detection

    func testParseSSELineDetectsOllamaStreamError() {
        let result = llmClient.parseSSELine("data: {\"error\":\"out of memory\"}")
        if case .error(let msg) = result {
            XCTAssertEqual(msg, "out of memory")
        } else {
            XCTFail("Expected .error, got \(result)")
        }
    }

    // MARK: - Local Provider Timeouts

    func testLocalProviderUsesLongerTimeout() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOllamaResponseData())
        }

        let config = LLMProviderConfig.ollama(model: "qwen3.5:4b")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        XCTAssertEqual(capturedRequest?.timeoutInterval, 300)
    }

    func testCloudProviderUsesStandardTimeout() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validResponseData())
        }

        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        _ = try await llmClient.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            config: config,
            options: .default
        )

        XCTAssertEqual(capturedRequest?.timeoutInterval, 30)
    }

    // MARK: - Helpers

    private func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func validResponseData() -> Data {
        Data("""
        {"model":"gpt-4o","choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        """.utf8)
    }

    private func validAnthropicResponseData() -> Data {
        Data("""
        {"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Hello!"}],"usage":{"input_tokens":10,"output_tokens":5},"stop_reason":"end_turn"}
        """.utf8)
    }

    private func validOllamaResponseData() -> Data {
        Data("""
        {"model":"qwen3.5:4b","message":{"role":"assistant","content":"OK"},"done":true,"prompt_eval_count":5,"eval_count":1}
        """.utf8)
    }

    private func extractBody(from request: URLRequest) -> [String: Any]? {
        var bodyData: Data?
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 { collected.append(buffer, count: count) }
                else { break }
            }
            stream.close()
            bodyData = collected
        }
        guard let data = bodyData else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
