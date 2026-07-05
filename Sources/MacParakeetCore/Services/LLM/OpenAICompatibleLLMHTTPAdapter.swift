import Foundation

struct OpenAICompatibleLLMHTTPAdapter: LLMHTTPAdapter {
    private let transport: LLMHTTPTransport

    init(transport: LLMHTTPTransport) {
        self.transport = transport
    }

    func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let request = try buildRequest(messages: messages, config: config, options: options, stream: false)

        let (data, response) = try await transport.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.connectionFailed("Invalid response.")
        }

        guard (200...299).contains(http.statusCode) else {
            throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: data)
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

    func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(messages: messages, config: config, options: options, stream: true)

                    let (bytes, response) = try await transport.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.connectionFailed("Invalid response.")
                    }

                    guard (200...299).contains(http.statusCode) else {
                        // Collect error body from stream
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: errorData)
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
                            throw LLMHTTPErrorMapper.mapStreamingError(message: message)
                        case .skip:
                            break
                        }
                    }

                    // Stream ended without `[DONE]`. For strict providers
                    // (OpenAI, OpenRouter - both contractually emit `[DONE]`),
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

    func testConnection(config: LLMProviderConfig) async throws {
        let messages = [ChatMessage(role: .user, content: "Hi")]
        // Models that use reasoning tokens (o1/o3/o4, gpt-5.x) need more budget since
        // max_completion_tokens covers both reasoning and visible output.
        // 128 is enough for a minimal response. Older models can use 1 to minimize cost.
        let needsMoreTokens = config.id == .openai && Self.openAIRequiresMaxCompletionTokens(config.modelName)
        let options = ChatCompletionOptions(maxTokens: needsMoreTokens ? 128 : 1)
        _ = try await chatCompletion(messages: messages, config: config, options: options)
    }

    func listModels(config: LLMProviderConfig) async throws -> [String] {
        let endpoint = config.id.modelListEndpoint
        let url = LLMHTTPModelCatalog.modelsURL(for: config)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"

        if endpoint == .ollama {
            request.setValue("Bearer ollama", forHTTPHeaderField: "Authorization")
        } else if endpoint == .openAICompatible {
            if let key = config.apiKey {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await transport.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.connectionFailed("Failed to fetch models.")
        }

        if config.id.modelListEndpoint == .gemini,
           let modelsResponse = try? JSONDecoder().decode(GeminiModelsListResponse.self, from: data) {
            return modelsResponse.models
                .filter(LLMHTTPModelCatalog.isGeminiTextLLMModel)
                .map { entry in
                    entry.name.hasPrefix("models/") ? String(entry.name.dropFirst(7)) : entry.name
                }
                .sorted()
        }

        // Try OpenAI-compatible format: { "data": [{ "id": "..." }] }
        if let modelsResponse = try? JSONDecoder().decode(ModelsListResponse.self, from: data) {
            return LLMHTTPModelCatalog.filterListedModels(modelsResponse.data, for: config)
                .map(\.id)
                .sorted()
        }

        throw LLMError.invalidResponse
    }

    func buildRequest(
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
    static func isOpenAIReasoningModel(_ model: String) -> Bool {
        isOpenAIReasoningModelID(model.lowercased())
    }

    /// OpenAI models that require max_completion_tokens instead of max_tokens.
    /// Includes reasoning models and newer GPT models (5.x+).
    static func openAIRequiresMaxCompletionTokens(_ model: String) -> Bool {
        let lowered = model.lowercased()
        if isOpenAIReasoningModel(lowered) { return true }
        // GPT-5.x and beyond reject max_tokens
        if lowered.hasPrefix("gpt-"), let digit = lowered.dropFirst(4).first, let version = digit.wholeNumberValue, version >= 5 {
            return true
        }
        return false
    }

    static func isOpenAIReasoningModelID(_ model: String) -> Bool {
        guard model.hasPrefix("o") else { return false }
        let suffix = model.dropFirst()
        guard let generation = suffix.first, generation.isNumber else { return false }
        return hasOpenAIModelPrefix(model, prefix: "o\(generation)")
    }

    static func hasOpenAIModelPrefix(_ model: String, prefix: String) -> Bool {
        guard model.hasPrefix(prefix) else { return false }
        let boundary = model.dropFirst(prefix.count).first
        return boundary == nil || boundary == "-"
    }

    static func responseFormat(from format: ChatResponseFormat?) -> OpenAIResponseFormat? {
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

    enum SSEResult {
        case content(String)
        case done
        case skip
        case error(String)
    }

    func parseSSELine(_ line: String) -> SSEResult {
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

    func parseSSEEvent(_ lines: [String]) -> SSEResult {
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

    func validateStreamCompletion(
        providerID: LLMProviderID,
        sawSentinel: Bool,
        yieldedAnyContent: Bool
    ) throws {
        try LLMHTTPStreamCompletionPolicy.validateStreamCompletion(
            providerID: providerID,
            sawSentinel: sawSentinel,
            yieldedAnyContent: yieldedAnyContent
        )
    }
}

// MARK: - OpenAI-Compatible Wire Types

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
