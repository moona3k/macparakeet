import Foundation

// MARK: - Protocol

public protocol LLMClientProtocol: Sendable {
    func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse

    func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error>

    func testConnection(config: LLMProviderConfig) async throws

    /// Fetches available model IDs from the provider's /models endpoint.
    func listModels(config: LLMProviderConfig) async throws -> [String]
}

// MARK: - Implementation

public final class LLMClient: LLMClientProtocol, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        // Provider-specific native API paths
        if config.id == .ollama {
            return try await ollamaChatCompletion(messages: messages, config: config, options: options)
        }
        if config.id == .anthropic {
            return try await anthropicChatCompletion(messages: messages, config: config, options: options)
        }

        let request = try buildRequest(messages: messages, config: config, options: options, stream: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.connectionFailed("Invalid response.")
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, data: data)
        }

        guard let openAIResponse = try? JSONDecoder().decode(OpenAIResponse.self, from: data) else {
            throw LLMError.invalidResponse
        }

        let content = openAIResponse.choices.first?.message.content ?? ""

        let usage: TokenUsage?
        if let u = openAIResponse.usage {
            usage = TokenUsage(promptTokens: u.prompt_tokens, completionTokens: u.completion_tokens)
        } else {
            usage = nil
        }

        return ChatCompletionResponse(
            content: content,
            model: openAIResponse.model,
            usage: usage
        )
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        if config.id == .ollama {
            return ollamaChatCompletionStream(messages: messages, config: config, options: options)
        }
        if config.id == .anthropic {
            return anthropicChatCompletionStream(messages: messages, config: config, options: options)
        }

        return openAIChatCompletionStream(messages: messages, config: config, options: options)
    }

    private func openAIChatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(messages: messages, config: config, options: options, stream: true)

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch {
                        throw LLMError.connectionFailed(error.localizedDescription)
                    }

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.connectionFailed("Invalid response.")
                    }

                    guard (200...299).contains(http.statusCode) else {
                        // Collect error body from stream
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        throw mapError(statusCode: http.statusCode, data: errorData)
                    }

                    // Process each line individually. Some providers (Gemini)
                    // don't send blank line separators between SSE events,
                    // so we parse each `data:` line as it arrives.
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        switch parseSSELine(line) {
                        case .content(let text):
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .error(let message):
                            throw LLMError.streamingError(message)
                        case .skip:
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Ollama Native API

    /// Uses Ollama's native /api/chat with think:false to disable extended thinking.
    /// The OpenAI-compatible /v1 endpoint doesn't support disabling thinking mode.
    private func ollamaChatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let request = try buildOllamaRequest(messages: messages, config: config, stream: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.connectionFailed("Invalid response.")
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, data: data)
        }

        guard let ollamaResponse = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
            throw LLMError.invalidResponse
        }

        let usage = TokenUsage(
            promptTokens: ollamaResponse.prompt_eval_count ?? 0,
            completionTokens: ollamaResponse.eval_count ?? 0
        )

        return ChatCompletionResponse(
            content: ollamaResponse.message.content,
            model: ollamaResponse.model,
            usage: usage
        )
    }

    private func ollamaChatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildOllamaRequest(messages: messages, config: config, stream: true)

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch {
                        throw LLMError.connectionFailed(error.localizedDescription)
                    }

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.connectionFailed("Invalid response.")
                    }

                    guard (200...299).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        throw mapError(statusCode: http.statusCode, data: errorData)
                    }

                    // Ollama streams NDJSON: one JSON object per line
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                            continue
                        }

                        // Check for errors
                        if let error = chunk.error {
                            throw LLMError.streamingError(error)
                        }

                        let content = chunk.message.content
                        if !content.isEmpty {
                            continuation.yield(content)
                        }

                        // done:true means stream is complete
                        if chunk.done == true {
                            continuation.finish()
                            return
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func buildOllamaRequest(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        stream: Bool
    ) throws -> URLRequest {
        // Use native /api/chat endpoint (strip /v1 suffix if present)
        var baseStr = config.baseURL.absoluteString
        if baseStr.hasSuffix("/v1") {
            baseStr = String(baseStr.dropLast(3))
        } else if baseStr.hasSuffix("/v1/") {
            baseStr = String(baseStr.dropLast(4))
        }
        guard let base = URL(string: baseStr) else {
            throw LLMError.connectionFailed("Invalid Ollama base URL: \(baseStr)")
        }
        let url = base.appendingPathComponent("api/chat")

        var request = URLRequest(url: url, timeoutInterval: stream ? 600 : 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OllamaChatRequest(
            model: config.modelName,
            messages: messages.map { OllamaMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            think: false,
            options: OllamaRequestOptions(num_ctx: 8192)
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Anthropic Native API

    private func anthropicChatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let request = try buildAnthropicRequest(messages: messages, config: config, options: options, stream: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.connectionFailed("Invalid response.")
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, data: data)
        }

        guard let anthropicResponse = try? JSONDecoder().decode(AnthropicResponse.self, from: data) else {
            throw LLMError.invalidResponse
        }

        let content = anthropicResponse.content
            .compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }
            .joined()

        let usage = TokenUsage(
            promptTokens: anthropicResponse.usage.input_tokens,
            completionTokens: anthropicResponse.usage.output_tokens
        )

        return ChatCompletionResponse(content: content, model: anthropicResponse.model, usage: usage)
    }

    private func anthropicChatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildAnthropicRequest(messages: messages, config: config, options: options, stream: true)

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch {
                        throw LLMError.connectionFailed(error.localizedDescription)
                    }

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.connectionFailed("Invalid response.")
                    }

                    guard (200...299).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        throw mapError(statusCode: http.statusCode, data: errorData)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data: ") || trimmed.hasPrefix("data:") else { continue }

                        let payload = trimmed.hasPrefix("data: ")
                            ? String(trimmed.dropFirst(6))
                            : String(trimmed.dropFirst(5))

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }

                        let eventType = json["type"] as? String

                        if eventType == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        } else if eventType == "message_stop" {
                            continuation.finish()
                            return
                        } else if eventType == "error",
                                  let error = json["error"] as? [String: Any],
                                  let message = error["message"] as? String {
                            throw LLMError.streamingError(message)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func buildAnthropicRequest(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions,
        stream: Bool
    ) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("messages")

        var request = URLRequest(url: url, timeoutInterval: stream ? 120 : 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        if let apiKey = config.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let systemPrompt = messages.first(where: { $0.role == .system })?.content
        let nonSystemMessages = messages.filter { $0.role != .system }

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": nonSystemMessages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": options.maxTokens ?? 4096,
            "stream": stream,
        ]

        if let systemPrompt {
            body["system"] = systemPrompt
        }

        if let temp = options.temperature {
            body["temperature"] = temp
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func testConnection(config: LLMProviderConfig) async throws {
        let messages = [ChatMessage(role: .user, content: "Hi")]
        // Models that use reasoning tokens (o1/o3/o4, gpt-5.x) need more budget since
        // max_completion_tokens covers both reasoning and visible output.
        // 128 is enough for a minimal response. Older models can use 1 to minimize cost.
        let needsMoreTokens = config.id == .openai && Self.openAIRequiresMaxCompletionTokens(config.modelName)
        let options = ChatCompletionOptions(maxTokens: needsMoreTokens ? 128 : 1)
        _ = try await chatCompletion(messages: messages, config: config, options: options)
    }

    public func listModels(config: LLMProviderConfig) async throws -> [String] {
        let url = config.baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"

        switch config.id {
        case .anthropic:
            // Anthropic uses x-api-key header and anthropic-version
            if let key = config.apiKey {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        case .gemini:
            // Gemini uses ?key= query parameter on their native endpoint
            // But since we use the OpenAI-compatible endpoint, Bearer works
            if let key = config.apiKey {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .ollama:
            request.setValue("Bearer ollama", forHTTPHeaderField: "Authorization")
        default:
            if let key = config.apiKey {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed("Failed to fetch models.")
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.connectionFailed("Failed to fetch models.")
        }

        // Try OpenAI-compatible format: { "data": [{ "id": "..." }] }
        if let modelsResponse = try? JSONDecoder().decode(ModelsListResponse.self, from: data) {
            return modelsResponse.data
                .map { id in
                    // Gemini returns "models/gemini-2.5-flash" — strip prefix
                    id.id.hasPrefix("models/") ? String(id.id.dropFirst(7)) : id.id
                }
                .sorted()
        }

        throw LLMError.invalidResponse
    }

    // MARK: - Private Helpers

    private func buildRequest(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions,
        stream: Bool
    ) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("chat/completions")

        // Local models need longer timeouts for cold starts (model loading from disk)
        let timeout: TimeInterval
        if config.isLocal {
            timeout = stream ? 600 : 300
        } else {
            timeout = stream ? 120 : 30
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth: use apiKey if present, inject "ollama" for Ollama when nil
        let authToken: String?
        if let key = config.apiKey {
            authToken = key
        } else if config.id == .ollama {
            authToken = "ollama"
        } else {
            authToken = nil
        }

        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // OpenAI reasoning models (o1/o3/o4) reject temperature AND max_tokens.
        // Newer OpenAI models (gpt-5.x) reject max_tokens but accept temperature.
        // All of them require max_completion_tokens instead of max_tokens.
        let isReasoningModel = config.id == .openai && Self.isOpenAIReasoningModel(config.modelName)
        let needsNewTokenParam = config.id == .openai && Self.openAIRequiresMaxCompletionTokens(config.modelName)
        let temperature = isReasoningModel ? nil : options.temperature
        let maxTokens = needsNewTokenParam ? nil : options.maxTokens
        let maxCompletionTokens = needsNewTokenParam ? options.maxTokens : nil

        // Ollama defaults to 2048-token context regardless of model capability.
        // Inject num_ctx to use the model's actual context window.
        let ollamaOptions: OllamaRequestOptions?
        if config.id == .ollama {
            ollamaOptions = OllamaRequestOptions(num_ctx: 8192)
        } else {
            ollamaOptions = nil
        }

        let body = OpenAIRequestBody(
            model: config.modelName,
            messages: messages.map { OpenAIMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            temperature: temperature,
            max_tokens: maxTokens,
            max_completion_tokens: maxCompletionTokens,
            options: ollamaOptions
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// OpenAI reasoning models that reject temperature and max_tokens parameters.
    private static func isOpenAIReasoningModel(_ model: String) -> Bool {
        let lowered = model.lowercased()
        return lowered.hasPrefix("o1") || lowered.hasPrefix("o3") || lowered.hasPrefix("o4")
    }

    /// OpenAI models that require max_completion_tokens instead of max_tokens.
    /// Includes reasoning models (o1/o3/o4) and newer GPT models (5.x+).
    private static func openAIRequiresMaxCompletionTokens(_ model: String) -> Bool {
        let lowered = model.lowercased()
        if isOpenAIReasoningModel(lowered) { return true }
        // GPT-5.x and beyond reject max_tokens
        if lowered.hasPrefix("gpt-"), let digit = lowered.dropFirst(4).first, let version = digit.wholeNumberValue, version >= 5 {
            return true
        }
        return false
    }

    internal enum SSEResult {
        case content(String)
        case done
        case skip
        case error(String)
    }

    internal func parseSSELine(_ line: String) -> SSEResult {
        // Blank lines are SSE event separators
        guard !line.isEmpty else { return .skip }

        // Only process data: lines
        guard line.hasPrefix("data: ") || line.hasPrefix("data:") else { return .skip }

        let payload = line.hasPrefix("data: ")
            ? String(line.dropFirst(6))
            : String(line.dropFirst(5))

        let trimmed = payload.trimmingCharacters(in: .whitespaces)

        // Stream terminator
        if trimmed == "[DONE]" { return .done }

        guard let data = trimmed.data(using: .utf8) else { return .skip }

        // Ollama can emit {"error": "..."} mid-stream on OOM or model failure.
        // Detect and surface as a streaming error instead of silently dropping.
        if let streamError = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
           streamError.error != nil {
            return .error(streamError.error!)
        }

        guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
            return .skip
        }

        // Extract content delta, ignoring role-only and finish_reason frames
        guard let delta = chunk.choices.first?.delta,
              let content = delta.content,
              !content.isEmpty else {
            return .skip
        }

        return .content(content)
    }

    internal func parseSSEEvent(_ lines: [String]) -> SSEResult {
        guard !lines.isEmpty else { return .skip }

        let payloadLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data: ") || line.hasPrefix("data:") else { return nil }
            return line.hasPrefix("data: ")
                ? String(line.dropFirst(6))
                : String(line.dropFirst(5))
        }

        guard !payloadLines.isEmpty else { return .skip }

        let payload = payloadLines.joined(separator: "\n")
        return parseSSELine("data: \(payload)")
    }

    internal func validateStreamCompletion(sawDone: Bool) throws {
        // Many OpenAI-compatible providers (Gemini, Ollama) don't send [DONE].
        // A clean stream end without [DONE] is acceptable.
    }

    private func mapError(statusCode: Int, data: Data) -> LLMError {
        // Try to extract error message from response body.
        // Providers use different formats:
        //   OpenAI/Anthropic: {"error": {"message": "..."}}
        //   Gemini:           [{"error": {"code": 404, "message": "...", "status": "NOT_FOUND"}}]
        let message: String
        if let errorBody = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            message = errorBody.error.message
        } else if let geminiArray = try? JSONDecoder().decode([GeminiErrorWrapper].self, from: data),
                  let first = geminiArray.first {
            message = first.error.message
        } else {
            message = String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        switch statusCode {
        case 401:
            return .authenticationFailed(message)
        case 429:
            return .rateLimited
        case 404:
            if message.lowercased().contains("model") {
                return .modelNotFound(message)
            }
            return .providerError(message)
        case 400:
            if message.lowercased().contains("context") || message.lowercased().contains("token") {
                return .contextTooLong
            }
            return .providerError(message)
        default:
            return .providerError(message)
        }
    }
}

// MARK: - Internal Wire Types

struct OpenAIRequestBody: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool
    let temperature: Double?
    let max_tokens: Int?
    let max_completion_tokens: Int?
    let options: OllamaRequestOptions? // Ollama-specific: num_ctx etc.
}

/// Ollama-specific request options to override defaults (e.g., context window size).
struct OllamaRequestOptions: Encodable {
    let num_ctx: Int
}

struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

struct OpenAIResponse: Decodable {
    let model: String
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?

    struct OpenAIChoice: Decodable {
        let message: OpenAIChoiceMessage
    }

    struct OpenAIChoiceMessage: Decodable {
        let content: String?
    }

    struct OpenAIUsage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
    }
}

struct OpenAIStreamChunk: Decodable {
    let choices: [StreamChoice]

    struct StreamChoice: Decodable {
        let delta: StreamDelta?
        let finish_reason: String?
    }

    struct StreamDelta: Decodable {
        let role: String?
        let content: String?
    }
}

struct OpenAIErrorResponse: Decodable {
    let error: ErrorDetail

    struct ErrorDetail: Decodable {
        let message: String
    }
}

/// Gemini wraps errors in a JSON array: [{"error": {"code": 404, "message": "...", "status": "NOT_FOUND"}}]
struct GeminiErrorWrapper: Decodable {
    let error: ErrorDetail

    struct ErrorDetail: Decodable {
        let message: String
    }
}

/// Ollama can emit {"error": "..."} mid-stream on OOM or model failure.
struct StreamErrorResponse: Decodable {
    let error: String?
}

struct ModelsListResponse: Decodable {
    let data: [ModelEntry]

    struct ModelEntry: Decodable {
        let id: String
    }
}

// MARK: - Anthropic Native API Types

struct AnthropicResponse: Decodable {
    let model: String
    let content: [ContentBlock]
    let usage: AnthropicUsage

    enum ContentBlock: Decodable {
        case text(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            if type == "text", let text = try container.decodeIfPresent(String.self, forKey: .text) {
                self = .text(text)
            } else {
                self = .other
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, text
        }
    }

    struct AnthropicUsage: Decodable {
        let input_tokens: Int
        let output_tokens: Int
    }
}

// MARK: - Ollama Native API Types

struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let think: Bool
    let options: OllamaRequestOptions
}

struct OllamaMessage: Encodable {
    let role: String
    let content: String
}

struct OllamaChatResponse: Decodable {
    let model: String
    let message: OllamaResponseMessage
    let done: Bool?
    let error: String?
    let prompt_eval_count: Int?
    let eval_count: Int?

    struct OllamaResponseMessage: Decodable {
        let role: String
        let content: String
    }
}
