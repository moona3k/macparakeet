import Foundation

// MARK: - Protocol

public protocol LLMClientProtocol: Sendable {
    func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse

    func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error>

    func testConnection(context: LLMExecutionContext) async throws

    /// Fetches available model IDs from the provider's /models endpoint.
    func listModels(context: LLMExecutionContext) async throws -> [String]
}

public extension LLMClientProtocol {
    func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        try await chatCompletion(
            messages: messages,
            context: LLMExecutionContext(providerConfig: config),
            options: options
        )
    }

    func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        chatCompletionStream(
            messages: messages,
            context: LLMExecutionContext(providerConfig: config),
            options: options
        )
    }

    func testConnection(config: LLMProviderConfig) async throws {
        try await testConnection(context: LLMExecutionContext(providerConfig: config))
    }

    func listModels(config: LLMProviderConfig) async throws -> [String] {
        try await listModels(context: LLMExecutionContext(providerConfig: config))
    }
}

// MARK: - Implementation

public final class LLMClient: LLMClientProtocol, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let config = context.providerConfig
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
            reasoningContent: openAIResponse.choices.first?.message.reasoning_content,
            finishReason: openAIResponse.choices.first?.finish_reason,
            model: openAIResponse.model,
            usage: usage
        )
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        let config = context.providerConfig
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
                    var sawDone = false
                    var yieldedAnyContent = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        switch parseSSELine(line) {
                        case .content(let text):
                            yieldedAnyContent = true
                            continuation.yield(text)
                        case .done:
                            sawDone = true
                            try validateStreamCompletion(
                                providerID: config.id,
                                sawSentinel: sawDone,
                                yieldedAnyContent: yieldedAnyContent
                            )
                            continuation.finish()
                            return
                        case .error(let message):
                            throw mapStreamingError(message: message)
                        case .skip:
                            break
                        }
                    }

                    // Stream ended without `[DONE]`. For strict providers
                    // (OpenAI, OpenRouter — both contractually emit `[DONE]`),
                    // a missing sentinel means the connection dropped mid-
                    // response and the user is looking at truncated output.
                    // Lenient providers (Gemini, OpenAI-Compatible aggregators
                    // like Together/Fireworks, LM Studio) frequently omit it,
                    // so we accept a clean end-of-stream there.
                    try validateStreamCompletion(
                        providerID: config.id,
                        sawSentinel: sawDone,
                        yieldedAnyContent: yieldedAnyContent
                    )
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

        // Emit usage only when both halves are present. Defaulting missing
        // counts to 0 (the previous `?? 0` behavior) is misleading for any
        // downstream consumer that has to distinguish "really 0 tokens"
        // from "Ollama didn't report it" — most acutely the public
        // `--json` envelope shape, which would otherwise show a
        // fabricated `totalTokens` for partial reports.
        let usage: TokenUsage?
        if let prompt = ollamaResponse.prompt_eval_count,
           let completion = ollamaResponse.eval_count {
            usage = TokenUsage(promptTokens: prompt, completionTokens: completion)
        } else {
            usage = nil
        }

        return ChatCompletionResponse(
            content: ollamaResponse.message.content,
            finishReason: ollamaResponse.done_reason,
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
                    var yieldedAnyContent = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                            continue
                        }

                        // Check for errors
                        if let error = chunk.error {
                            throw mapStreamingError(message: error)
                        }

                        let content = chunk.message.content
                        if !content.isEmpty {
                            yieldedAnyContent = true
                            continuation.yield(content)
                        }

                        // done:true means stream is complete
                        if chunk.done == true {
                            try validateStreamCompletion(
                                providerID: config.id,
                                sawSentinel: true,
                                yieldedAnyContent: yieldedAnyContent
                            )
                            continuation.finish()
                            return
                        }
                    }

                    try validateStreamCompletion(
                        providerID: config.id,
                        sawSentinel: false,
                        yieldedAnyContent: yieldedAnyContent
                    )
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

        return ChatCompletionResponse(
            content: content,
            finishReason: anthropicResponse.stop_reason,
            model: anthropicResponse.model,
            usage: usage
        )
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

                    var sawMessageStop = false
                    var yieldedAnyContent = false
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
                            yieldedAnyContent = true
                            continuation.yield(text)
                        } else if eventType == "message_stop" {
                            sawMessageStop = true
                            try validateStreamCompletion(
                                providerID: config.id,
                                sawSentinel: sawMessageStop,
                                yieldedAnyContent: yieldedAnyContent
                            )
                            continuation.finish()
                            return
                        } else if eventType == "error",
                                  let error = json["error"] as? [String: Any],
                                  let message = error["message"] as? String {
                            throw mapStreamingError(message: message)
                        }
                    }

                    // Anthropic always emits `message_stop` to terminate a
                    // successful stream. Reaching EOF without it means the
                    // HTTP connection dropped mid-response — treat as truncated.
                    try validateStreamCompletion(
                        providerID: config.id,
                        sawSentinel: sawMessageStop,
                        yieldedAnyContent: yieldedAnyContent
                    )
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
        // Anthropic versions are pinned date strings. We track a single
        // constant so chat + listModels stay in sync. Anthropic's public
        // version history still lists 2023-06-01 as the current latest pin.
        request.setValue(LLMClient.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")

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

    public func testConnection(context: LLMExecutionContext) async throws {
        let config = context.providerConfig
        let messages = [ChatMessage(role: .user, content: "Hi")]
        // Models that use reasoning tokens (o1/o3/o4, gpt-5.x) need more budget since
        // max_completion_tokens covers both reasoning and visible output.
        // 128 is enough for a minimal response. Older models can use 1 to minimize cost.
        let needsMoreTokens = config.id == .openai && Self.openAIRequiresMaxCompletionTokens(config.modelName)
        let options = ChatCompletionOptions(maxTokens: needsMoreTokens ? 128 : 1)
        _ = try await chatCompletion(messages: messages, context: context, options: options)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        let config = context.providerConfig
        let endpoint = config.id.modelListEndpoint
        guard endpoint != .none else {
            throw LLMError.connectionFailed("Model listing is not supported for this provider.")
        }
        if endpoint == .ollama {
            do {
                return try await listOllamaModels(config: config)
            } catch {
                // Older Ollama installs exposed only the OpenAI-compatible
                // /v1/models route. Fall through so users with those setups can
                // still refresh models from Settings.
            }
        }

        let url = Self.modelsURL(for: config)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"

        if endpoint == .anthropic {
            // Anthropic uses x-api-key header and anthropic-version
            if let key = config.apiKey {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                // Anthropic versions are pinned date strings. We track a single
                // constant so chat + listModels stay in sync.
                request.setValue(LLMClient.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
            }
        } else if endpoint == .ollama {
            request.setValue("Bearer ollama", forHTTPHeaderField: "Authorization")
        } else if endpoint == .openAICompatible {
            if let key = config.apiKey {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.connectionFailed("Failed to fetch models.")
        }

        if config.id.modelListEndpoint == .gemini,
           let modelsResponse = try? JSONDecoder().decode(GeminiModelsListResponse.self, from: data) {
            return modelsResponse.models
                .filter(Self.isGeminiTextLLMModel)
                .map { entry in
                    entry.name.hasPrefix("models/") ? String(entry.name.dropFirst(7)) : entry.name
                }
                .sorted()
        }

        // Try OpenAI-compatible format: { "data": [{ "id": "..." }] }
        if let modelsResponse = try? JSONDecoder().decode(ModelsListResponse.self, from: data) {
            return Self.filterListedModels(modelsResponse.data, for: config)
                .map(\.id)
                .sorted()
        }

        throw LLMError.invalidResponse
    }

    // MARK: - Private Helpers

    private func listOllamaModels(config: LLMProviderConfig) async throws -> [String] {
        guard let tagsURL = Self.ollamaTagsURL(from: config.baseURL) else {
            throw LLMError.invalidResponse
        }
        var request = URLRequest(url: tagsURL, timeoutInterval: 15)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.connectionFailed("Failed to fetch models.")
        }

        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        let entries = tags.models.map { ModelsListResponse.ModelEntry(id: $0.name) }
        return Self.filterListedModels(entries, for: config)
            .map(\.id)
            .sorted()
    }

    private static func ollamaTagsURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.path
            .split(separator: "/")
            .map(String.init)
        if segments.last == "v1" {
            segments.removeLast()
        }
        segments.append(contentsOf: ["api", "tags"])
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        return components.url
    }

    private static func modelsURL(for config: LLMProviderConfig) -> URL {
        if config.id.modelListEndpoint == .anthropic,
           let url = urlByAppendingQueryItems(
            [URLQueryItem(name: "limit", value: "1000")],
            to: config.baseURL.appendingPathComponent("models")
           ) {
            return url
        }
        if config.id.modelListEndpoint == .gemini,
           let url = geminiModelsURL(from: config.baseURL, apiKey: config.apiKey) {
            return url
        }
        if config.id == .openrouter,
           let url = urlByAppendingQueryItems(
            [URLQueryItem(name: "output_modalities", value: "text")],
            to: config.baseURL.appendingPathComponent("models")
           ) {
            return url
        }
        return config.baseURL.appendingPathComponent("models")
    }

    private static func geminiModelsURL(from baseURL: URL, apiKey: String?) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.path
            .split(separator: "/")
            .map(String.init)
        if segments.last == "openai" {
            segments.removeLast()
        }
        segments.append("models")
        components.path = "/" + segments.joined(separator: "/")
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "pageSize", value: "1000"))
        if let apiKey {
            queryItems.append(URLQueryItem(name: "key", value: apiKey))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func urlByAppendingQueryItems(_ items: [URLQueryItem], to url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url
    }

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

        // OpenAI reasoning models reject temperature AND max_tokens.
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
            response_format: Self.responseFormat(from: options.responseFormat),
            options: ollamaOptions
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// OpenAI reasoning models that reject temperature and max_tokens parameters.
    private static func isOpenAIReasoningModel(_ model: String) -> Bool {
        isOpenAIReasoningModelID(model.lowercased())
    }

    /// OpenAI models that require max_completion_tokens instead of max_tokens.
    /// Includes reasoning models and newer GPT models (5.x+).
    private static func openAIRequiresMaxCompletionTokens(_ model: String) -> Bool {
        let lowered = model.lowercased()
        if isOpenAIReasoningModel(lowered) { return true }
        // GPT-5.x and beyond reject max_tokens
        if lowered.hasPrefix("gpt-"), let digit = lowered.dropFirst(4).first, let version = digit.wholeNumberValue, version >= 5 {
            return true
        }
        return false
    }

    private static func filterListedModels(
        _ models: [ModelsListResponse.ModelEntry],
        for config: LLMProviderConfig
    ) -> [ModelsListResponse.ModelEntry] {
        models
            .map { entry in
                var normalized = entry
                if normalized.id.hasPrefix("models/") {
                    normalized.id = String(normalized.id.dropFirst(7))
                }
                return normalized
            }
            .filter { entry in
                switch config.id {
                case .anthropic:
                    return isAnthropicTextLLMModel(entry)
                case .openai:
                    return isOpenAIStreamingChatModel(entry.id)
                case .openrouter:
                    return isOpenRouterTextLLMModel(entry)
                case .gemini:
                    return isGeminiTextLLMModelID(entry.id)
                case .openaiCompatible, .lmstudio, .ollama:
                    return !isClearlyNonTextModelID(entry.id)
                case .localCLI:
                    return false
                }
            }
    }

    private static func isAnthropicTextLLMModel(_ model: ModelsListResponse.ModelEntry) -> Bool {
        if let type = model.type?.lowercased(), type != "model" { return false }
        return model.id.lowercased().hasPrefix("claude-")
    }

    private static func isOpenRouterTextLLMModel(_ model: ModelsListResponse.ModelEntry) -> Bool {
        if !supportsTextInputOutput(model.architecture) { return false }
        return !isClearlyNonTextModelID(model.id)
    }

    private static func isGeminiTextLLMModel(_ model: GeminiModelsListResponse.ModelEntry) -> Bool {
        if let methods = model.supportedGenerationMethods, !methods.contains("generateContent") {
            return false
        }
        let id = model.name.hasPrefix("models/") ? String(model.name.dropFirst(7)) : model.name
        return isGeminiTextLLMModelID(id)
    }

    private static func isGeminiTextLLMModelID(_ model: String) -> Bool {
        let lowered = model.lowercased()
        guard lowered.hasPrefix("gemini-") || lowered.hasPrefix("gemma-") else { return false }
        return !isClearlyNonTextModelID(model)
    }

    private static func supportsTextInputOutput(_ architecture: ModelsListResponse.ModelArchitecture?) -> Bool {
        guard let architecture else { return true }
        if let inputModalities = architecture.input_modalities?.map({ $0.lowercased() }),
           !inputModalities.contains("text") {
            return false
        }
        if let outputModalities = architecture.output_modalities?.map({ $0.lowercased() }) {
            guard outputModalities.contains("text") else { return false }
            let unsupportedOutputs = ["audio", "embeddings", "image", "video"]
            guard !outputModalities.contains(where: unsupportedOutputs.contains) else { return false }
        }
        return true
    }

    private static func isClearlyNonTextModelID(_ model: String) -> Bool {
        let lowered = model.lowercased()
        let unsupportedSubstrings = [
            "audio",
            "clip",
            "computer-use",
            "dall-e",
            "diffusion",
            "embed",
            "image",
            "imagen",
            "lyria",
            "moderation",
            "nano-banana",
            "realtime",
            "rerank",
            "robotics",
            "sora",
            "speech",
            "transcribe",
            "tts",
            "veo",
            "video",
            "whisper",
        ]
        return unsupportedSubstrings.contains(where: lowered.contains)
    }

    private static func isOpenAIStreamingChatModel(_ model: String) -> Bool {
        let lowered = model.lowercased()
        guard !isClearlyNonTextModelID(model) else { return false }
        guard !lowered.hasSuffix("-pro") else { return false }
        return lowered.hasPrefix("gpt-")
            || lowered.hasPrefix("chatgpt-")
            || isOpenAIReasoningModelID(lowered)
    }

    private static func isOpenAIReasoningModelID(_ model: String) -> Bool {
        guard model.hasPrefix("o") else { return false }
        let suffix = model.dropFirst()
        guard let generation = suffix.first, generation.isNumber else { return false }
        return hasOpenAIModelPrefix(model, prefix: "o\(generation)")
    }

    private static func hasOpenAIModelPrefix(_ model: String, prefix: String) -> Bool {
        guard model.hasPrefix(prefix) else { return false }
        let boundary = model.dropFirst(prefix.count).first
        return boundary == nil || boundary == "-"
    }

    private static func responseFormat(from format: ChatResponseFormat?) -> OpenAIResponseFormat? {
        switch format {
        case .none:
            return nil
        case .jsonSchema(let name, let schema):
            return OpenAIResponseFormat(
                type: "json_schema",
                json_schema: OpenAIJSONSchemaSpec(
                    name: name,
                    schema: schema
                )
            )
        }
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

        // Local/OpenAI-compatible servers can emit provider errors mid-stream
        // instead of returning a non-2xx response. LM Studio, for example,
        // sends `event: error` followed by a `data:` JSON object whose
        // `error` field is an object and whose top-level `message` carries
        // the human-readable context-length failure. Surface those as errors
        // instead of silently dropping the frame and accepting an empty EOF.
        if let streamError = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
           let errorMessage = streamError.error {
            return .error(errorMessage)
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

    /// Whether the provider contractually emits a stream terminator. Strict
    /// providers throw `streamingError` on EOF without the sentinel because
    /// the user is otherwise looking at silently truncated output. Lenient
    /// providers omit the sentinel commonly enough that enforcing it would
    /// produce false positives:
    ///
    /// - **Strict**: OpenAI (`[DONE]`), OpenRouter (`[DONE]`, OpenAI-compat
    ///   aggregator), Anthropic (`message_stop` event).
    /// - **Lenient**: Gemini (no `[DONE]` per spec), OpenAI-Compatible
    ///   (Together/Fireworks/Groq vary), LM Studio (varies), Ollama (uses
    ///   `done:true` field detected separately, not the SSE `[DONE]` line),
    ///   localCLI (subprocess output, not HTTP SSE).
    internal static func providerEnforcesStreamSentinel(_ id: LLMProviderID) -> Bool {
        switch id {
        case .openai, .openrouter, .anthropic:
            return true
        case .openaiCompatible, .gemini, .ollama, .lmstudio, .localCLI:
            return false
        }
    }

    internal func validateStreamCompletion(
        providerID: LLMProviderID,
        sawSentinel: Bool,
        yieldedAnyContent: Bool
    ) throws {
        guard yieldedAnyContent else {
            throw LLMError.streamingError("stream produced no content before EOF")
        }
        guard Self.providerEnforcesStreamSentinel(providerID), !sawSentinel else { return }

        // EOF before the sentinel from a provider that contractually emits one.
        // Some content delivered means the user is otherwise looking at a
        // silently truncated output.
        throw LLMError.streamingError("stream ended before completion sentinel — response is truncated")
    }

    private func mapError(statusCode: Int, data: Data) -> LLMError {
        // Try to extract error message from response body.
        // Providers use different formats:
        //   OpenAI/Anthropic: {"error": {"message": "..."}}
        //   Gemini:           [{"error": {"code": 404, "message": "...", "status": "NOT_FOUND"}}]
        let rawMessage: String
        if let errorBody = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            rawMessage = errorBody.error.message
        } else if let geminiArray = try? JSONDecoder().decode([GeminiErrorWrapper].self, from: data),
                  let first = geminiArray.first {
            rawMessage = first.error.message
        } else {
            rawMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        // Sanitize the message before propagating. Some providers echo the
        // request shape (or fragments of it) in their error responses; if a
        // misconfigured request leaked an Authorization header, sk-... key,
        // or `api-key=...` query param, the message would otherwise carry
        // those tokens into Swift error chains, telemetry, logs, and the
        // user-visible UI.
        let message = LLMClient.scrubAPIKeyArtifacts(from: rawMessage)

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

    private func mapStreamingError(message rawMessage: String) -> LLMError {
        let message = Self.scrubAPIKeyArtifacts(from: rawMessage)
        let lowered = message.lowercased()

        if lowered.contains("context")
            || lowered.contains("tokens to keep")
            || lowered.contains("too many tokens")
            || lowered.contains("maximum number of tokens") {
            return .contextTooLong
        }
        if lowered.contains("rate limit") || lowered.contains("rate_limit") {
            return .rateLimited
        }
        if lowered.contains("unauthorized")
            || lowered.contains("authentication")
            || lowered.contains("api key") {
            return .authenticationFailed(message)
        }
        if lowered.contains("model")
            && (lowered.contains("not found") || lowered.contains("does not exist")) {
            return .modelNotFound(message)
        }
        return .streamingError(message)
    }

    /// Anthropic Messages API version pin. Anthropic dates each API version;
    /// use the latest date listed in the public version history so chat-stream
    /// and listModels stay in lockstep.
    static let anthropicAPIVersion = "2023-06-01"

    /// Strips obvious API-key artifacts from a provider error message before
    /// it propagates into Swift errors / telemetry / logs / UI. Intended to
    /// be idempotent and conservative -- false negatives are acceptable;
    /// false positives that mask the actual error message are not. Patterns:
    /// - `sk-...` and `sk-proj-...` style OpenAI / Anthropic keys
    /// - `Bearer <token>`
    /// - `x-api-key: <token>` and similar header echoes
    /// - `key=<token>` and `api[_-]?key=<token>` query-param echoes
    static func scrubAPIKeyArtifacts(from message: String) -> String {
        let patterns: [(String, String)] = [
            // OpenAI / Anthropic / OpenRouter style keys with `sk-` or `sk-proj-` prefix.
            // (No `%` here: the sk- alphabet never needs URL encoding.)
            (#"\bsk-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),
            // Bearer tokens (Authorization header echoes). `%` covers
            // URL-encoded token echoes (`%2B`, `%3D`, ...) — AUDIT-076.
            (#"\bBearer\s+[A-Za-z0-9._%\-]{8,}"#, "Bearer <token>"),
            // x-api-key header echoes (case-insensitive).
            (#"(?i)\bx-api-key:\s*[A-Za-z0-9._%\-]{8,}"#, "x-api-key: <token>"),
            // Generic api-key / api_key / apikey query params (case-insensitive).
            (#"(?i)\bapi[_-]?key=[A-Za-z0-9._%\-]{8,}"#, "api-key=<token>"),
            // Generic key= query param (must come last so the more specific
            // api-key= rule wins). 16+ chars: long enough to skip innocent
            // `key=<word>` params, short enough to catch real keys the old
            // 20-char floor let through (AUDIT-076).
            (#"(?i)\bkey=[A-Za-z0-9._%\-]{16,}"#, "key=<token>"),
        ]

        var out = message
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return out
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
    let response_format: OpenAIResponseFormat?
    let options: OllamaRequestOptions? // Ollama-specific: num_ctx etc.
}

struct OpenAIResponseFormat: Encodable {
    let type: String
    let json_schema: OpenAIJSONSchemaSpec?
}

struct OpenAIJSONSchemaSpec: Encodable {
    let name: String
    let schema: ChatJSONSchema
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
        let finish_reason: String?
    }

    struct OpenAIChoiceMessage: Decodable {
        let content: String?
        let reasoning_content: String?
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

/// Providers can emit error payloads mid-stream. Shapes observed in practice:
/// - Ollama: `{ "error": "..." }`
/// - LM Studio: `{ "error": { "message": "..." }, "message": "..." }`
struct StreamErrorResponse: Decodable {
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case message
    }

    private struct ErrorObject: Decodable {
        let message: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try? container.decode(String.self, forKey: .message),
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = message
            return
        }
        if let errorMessage = try? container.decode(String.self, forKey: .error),
           !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = errorMessage
            return
        }
        if let errorObject = try? container.decode(ErrorObject.self, forKey: .error),
           let message = errorObject.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = message
            return
        }
        error = nil
    }
}

struct ModelsListResponse: Decodable {
    let data: [ModelEntry]

    struct ModelEntry: Decodable {
        var id: String
        let type: String?
        let architecture: ModelArchitecture?

        init(id: String, type: String? = nil, architecture: ModelArchitecture? = nil) {
            self.id = id
            self.type = type
            self.architecture = architecture
        }
    }

    struct ModelArchitecture: Decodable {
        let input_modalities: [String]?
        let output_modalities: [String]?
    }
}

struct GeminiModelsListResponse: Decodable {
    let models: [ModelEntry]

    struct ModelEntry: Decodable {
        let name: String
        let supportedGenerationMethods: [String]?
    }
}

struct OllamaTagsResponse: Decodable {
    let models: [ModelEntry]

    struct ModelEntry: Decodable {
        let name: String
    }
}

// MARK: - Anthropic Native API Types

struct AnthropicResponse: Decodable {
    let model: String
    let content: [ContentBlock]
    let usage: AnthropicUsage
    let stop_reason: String?

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
    let done_reason: String?
    let error: String?
    let prompt_eval_count: Int?
    let eval_count: Int?

    struct OllamaResponseMessage: Decodable {
        let role: String
        let content: String
    }
}
