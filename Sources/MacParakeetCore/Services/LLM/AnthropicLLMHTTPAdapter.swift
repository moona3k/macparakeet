import Foundation

struct AnthropicLLMHTTPAdapter: LLMHTTPAdapter {
    /// Anthropic Messages API version pin. Anthropic dates each API version;
    /// use the latest date listed in the public version history so chat-stream
    /// and listModels stay in lockstep.
    static let apiVersion = "2023-06-01"

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
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: errorData)
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
                            throw LLMHTTPErrorMapper.mapStreamingError(message: message)
                        }
                    }

                    // Anthropic always emits `message_stop` to terminate a
                    // successful stream. Reaching EOF without it means the
                    // HTTP connection dropped mid-response - treat as truncated.
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

    func listModels(config: LLMProviderConfig) async throws -> [String] {
        let url = LLMHTTPModelCatalog.modelsURL(for: config)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"

        // Anthropic uses x-api-key header and anthropic-version
        if let key = config.apiKey {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            // Anthropic versions are pinned date strings. We track a single
            // constant so chat + listModels stay in sync.
            request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        }

        let (data, response) = try await transport.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.connectionFailed("Failed to fetch models.")
        }

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
        let url = config.baseURL.appendingPathComponent("messages")

        var request = URLRequest(url: url, timeoutInterval: stream ? 120 : 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic versions are pinned date strings. We track a single
        // constant so chat + listModels stay in sync. Anthropic's public
        // version history still lists 2023-06-01 as the current latest pin.
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

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
