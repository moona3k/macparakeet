import Foundation

struct OllamaLLMHTTPAdapter: LLMHTTPAdapter {
    static let contextWindowTokens = 8192

    private let transport: LLMHTTPTransport
    private let openAICompatibleFallbackAdapter: OpenAICompatibleLLMHTTPAdapter

    init(transport: LLMHTTPTransport) {
        self.transport = transport
        openAICompatibleFallbackAdapter = OpenAICompatibleLLMHTTPAdapter(transport: transport)
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

        if let envelope = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
            let error = envelope.error
        {
            throw LLMHTTPErrorMapper.mapStreamingError(message: error)
        }

        guard let ollamaResponse = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
            throw LLMError.invalidResponse
        }

        // Emit usage only when both halves are present. Defaulting missing
        // counts to 0 (the previous `?? 0` behavior) is misleading for any
        // downstream consumer that has to distinguish "really 0 tokens"
        // from "Ollama didn't report it" - most acutely the public
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
            usage: usage,
            effectiveInferenceSettings: options.effectiveInferenceSettings
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
                    let request = try buildRequest(
                        messages: messages,
                        config: config,
                        options: options,
                        stream: true
                    )

                    let (bytes, response) = try await transport.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.connectionFailed("Invalid response.")
                    }

                    guard (200...299).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: errorData)
                    }

                    // Ollama streams NDJSON: one JSON object per line
                    var yieldedAnyContent = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        if let envelope = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
                            let error = envelope.error
                        {
                            throw LLMHTTPErrorMapper.mapStreamingError(message: error)
                        }
                        guard let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                            continue
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

    func chatCompletionDetailedStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(
                        messages: messages,
                        config: config,
                        options: options,
                        stream: true
                    )
                    let (bytes, response) = try await transport.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.connectionFailed("Invalid response.")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: errorData)
                    }

                    var yieldedAnyContent = false
                    var lastChunk: OllamaChatResponse?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        if let envelope = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
                            let error = envelope.error
                        {
                            throw LLMHTTPErrorMapper.mapStreamingError(message: error)
                        }
                        guard let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                            continue
                        }
                        lastChunk = chunk
                        if !chunk.message.content.isEmpty {
                            yieldedAnyContent = true
                            continuation.yield(.text(chunk.message.content))
                        }
                        if chunk.done == true {
                            try validateStreamCompletion(
                                providerID: config.id,
                                sawSentinel: true,
                                yieldedAnyContent: yieldedAnyContent
                            )
                            continuation.yield(.completed(Self.terminalReceipt(
                                for: chunk, config: config, options: options
                            )))
                            continuation.finish()
                            return
                        }
                    }
                    try validateStreamCompletion(
                        providerID: config.id,
                        sawSentinel: false,
                        yieldedAnyContent: yieldedAnyContent
                    )
                    // Match the legacy Ollama EOF policy. Content has already
                    // passed validation; retain observed metadata without
                    // inventing a stop reason or usage for the missing sentinel.
                    if let lastChunk {
                        continuation.yield(.completed(Self.terminalReceipt(
                            for: lastChunk, config: config, options: options
                        )))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func terminalReceipt(
        for chunk: OllamaChatResponse,
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> LLMStreamTerminal {
        let usage: LLMUsage?
        if chunk.prompt_eval_count != nil || chunk.eval_count != nil {
            usage = LLMUsage(
                promptTokens: chunk.prompt_eval_count,
                completionTokens: chunk.eval_count,
                totalTokens: LLMUsage.derivedTotal(
                    promptTokens: chunk.prompt_eval_count, completionTokens: chunk.eval_count
                )
            )
        } else {
            usage = nil
        }
        return LLMStreamTerminal(
            provider: config.id.rawValue, model: chunk.model, usage: usage,
            stopReason: chunk.done_reason, effectiveSettings: options.effectiveInferenceSettings
        )
    }

    func listModels(config: LLMProviderConfig) async throws -> [String] {
        do {
            return try await listNativeModels(config: config)
        } catch {
            // Older Ollama installs exposed only the OpenAI-compatible
            // /v1/models route. Fall through so users with those setups can
            // still refresh models from Settings.
            return try await openAICompatibleFallbackAdapter.listModels(config: config)
        }
    }

    func buildRequest(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions,
        stream: Bool
    ) throws -> URLRequest {
        try options.validateInferenceSettings(for: config)
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

        let usesPromptInferenceSettings = options.usesPromptInferenceSettings
        let body = OllamaChatRequest(
            model: config.modelName,
            messages: messages.map { OllamaMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            think: usesPromptInferenceSettings && options.thinkingMode == .enabled,
            options: OllamaRequestOptions(
                num_ctx: Self.contextWindowTokens,
                temperature: usesPromptInferenceSettings ? options.temperature : nil,
                top_p: usesPromptInferenceSettings ? options.topP : nil,
                top_k: usesPromptInferenceSettings ? options.topK : nil,
                num_predict: usesPromptInferenceSettings ? options.maxTokens : nil
            )
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
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

    private func listNativeModels(config: LLMProviderConfig) async throws -> [String] {
        guard let tagsURL = LLMHTTPModelCatalog.ollamaTagsURL(from: config.baseURL) else {
            throw LLMError.invalidResponse
        }
        var request = URLRequest(url: tagsURL, timeoutInterval: 15)
        request.httpMethod = "GET"

        let (data, response) = try await transport.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.connectionFailed("Failed to fetch models.")
        }

        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        let entries = tags.models.map { ModelsListResponse.ModelEntry(id: $0.name) }
        return LLMHTTPModelCatalog.filterListedModels(entries, for: config)
            .map(\.id)
            .sorted()
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
    let prompt_eval_count: Int?
    let eval_count: Int?

    struct OllamaResponseMessage: Decodable {
        let role: String
        let content: String
    }
}

struct OllamaTagsResponse: Decodable {
    let models: [ModelEntry]

    struct ModelEntry: Decodable {
        let name: String
    }
}
