import XCTest
import Network
@testable import MacParakeetCore

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

    func testOllamaAdapterBuildsGoldenRequest() async throws {
        var capturedRequest: URLRequest?

        AdapterRequestURLProtocol.handler = { request in
            capturedRequest = request
            return (self.okResponse(for: request), self.validOllamaResponseData())
        }

        _ = try await ollamaAdapter.chatCompletion(
            messages: goldenMessages,
            config: .ollama(model: "qwen3.5:4b"),
            options: ChatCompletionOptions(temperature: 0.25, maxTokens: 123)
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

    private func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func validOpenAIResponseData() -> Data {
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
        {"model":"qwen3.5:4b","message":{"role":"assistant","content":"OK"},"done":true,"done_reason":"stop","prompt_eval_count":5,"eval_count":1}
        """.utf8)
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
              let port = listener.port else {
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

        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
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
