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

        guard let openAIResponse = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
              let content = openAIResponse.choices.first?.message.content else {
            throw LLMError.invalidResponse
        }

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

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        switch parseSSELine(line) {
                        case .content(let text):
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .skip:
                            continue
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

    public func testConnection(config: LLMProviderConfig) async throws {
        let messages = [ChatMessage(role: .user, content: "Hi")]
        let options = ChatCompletionOptions(maxTokens: 1)
        _ = try await chatCompletion(messages: messages, config: config, options: options)
    }

    // MARK: - Private Helpers

    private func buildRequest(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions,
        stream: Bool
    ) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
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

        let body = OpenAIRequestBody(
            model: config.modelName,
            messages: messages.map { OpenAIMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            temperature: options.temperature,
            max_tokens: options.maxTokens
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    internal enum SSEResult {
        case content(String)
        case done
        case skip
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

        guard let data = trimmed.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
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

    private func mapError(statusCode: Int, data: Data) -> LLMError {
        // Try to extract error message from response body
        let message: String
        if let errorBody = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            message = errorBody.error.message
        } else {
            message = String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        switch statusCode {
        case 401:
            return .authenticationFailed
        case 429:
            return .rateLimited
        case 404:
            return .modelNotFound(message)
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
        let content: String
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
