import Foundation

protocol LLMHTTPAdapter: Sendable {
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
    func listModels(config: LLMProviderConfig) async throws -> [String]
}

extension LLMHTTPAdapter {
    func testConnection(config: LLMProviderConfig) async throws {
        let messages = [ChatMessage(role: .user, content: "Hi")]
        let options = ChatCompletionOptions(maxTokens: 1)
        _ = try await chatCompletion(messages: messages, config: config, options: options)
    }
}

struct LLMHTTPTransport: Sendable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }
    }
}

enum LLMHTTPErrorMapper {
    static func mapError(statusCode: Int, data: Data) -> LLMError {
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
        let message = scrubAPIKeyArtifacts(from: rawMessage)

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

    static func mapStreamingError(message rawMessage: String) -> LLMError {
        let message = scrubAPIKeyArtifacts(from: rawMessage)
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
            // URL-encoded token echoes (`%2B`, `%3D`, ...); `+/=` covers raw
            // Base64 tokens, whose pre-`+` prefix could otherwise dodge the
            // length floor or leak a suffix - AUDIT-076 + PR #477 review.
            (#"\bBearer\s+[A-Za-z0-9._%\-+=/]{8,}"#, "Bearer <token>"),
            // x-api-key header echoes (case-insensitive).
            (#"(?i)\bx-api-key:\s*[A-Za-z0-9._%\-+=/]{8,}"#, "x-api-key: <token>"),
            // Generic api-key / api_key / apikey query params (case-insensitive).
            (#"(?i)\bapi[_-]?key=[A-Za-z0-9._%\-+=/]{8,}"#, "api-key=<token>"),
            // Generic key= query param (must come last so the more specific
            // api-key= rule wins). 16+ chars: long enough to skip innocent
            // `key=<word>` params, short enough to catch real keys the old
            // 20-char floor let through (AUDIT-076).
            (#"(?i)\bkey=[A-Za-z0-9._%\-+=/]{16,}"#, "key=<token>"),
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

enum LLMHTTPStreamCompletionPolicy {
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
    static func providerEnforcesStreamSentinel(_ id: LLMProviderID) -> Bool {
        switch id {
        case .openai, .openrouter, .anthropic:
            return true
        case .openaiCompatible, .gemini, .ollama, .lmstudio, .localCLI, .inProcessLocal:
            return false
        }
    }

    static func validateStreamCompletion(
        providerID: LLMProviderID,
        sawSentinel: Bool,
        yieldedAnyContent: Bool
    ) throws {
        guard yieldedAnyContent else {
            throw LLMError.streamingError("stream produced no content before EOF")
        }
        guard providerEnforcesStreamSentinel(providerID), !sawSentinel else { return }

        // EOF before the sentinel from a provider that contractually emits one.
        // Some content delivered means the user is otherwise looking at a
        // silently truncated output.
        throw LLMError.streamingError("stream ended before completion sentinel — response is truncated")
    }
}

enum LLMHTTPModelCatalog {
    static func modelsURL(for config: LLMProviderConfig) -> URL {
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

    static func ollamaTagsURL(from baseURL: URL) -> URL? {
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

    static func filterListedModels(
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
                case .localCLI, .inProcessLocal:
                    return false
                }
            }
    }

    static func isGeminiTextLLMModel(_ model: GeminiModelsListResponse.ModelEntry) -> Bool {
        if let methods = model.supportedGenerationMethods, !methods.contains("generateContent") {
            return false
        }
        let id = model.name.hasPrefix("models/") ? String(model.name.dropFirst(7)) : model.name
        return isGeminiTextLLMModelID(id)
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

    private static func isAnthropicTextLLMModel(_ model: ModelsListResponse.ModelEntry) -> Bool {
        if let type = model.type?.lowercased(), type != "model" { return false }
        return model.id.lowercased().hasPrefix("claude-")
    }

    private static func isOpenRouterTextLLMModel(_ model: ModelsListResponse.ModelEntry) -> Bool {
        if !supportsTextInputOutput(model.architecture) { return false }
        return !isClearlyNonTextModelID(model.id)
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
            || OpenAICompatibleLLMHTTPAdapter.isOpenAIReasoningModelID(lowered)
    }
}

// MARK: - Shared Wire Types

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

/// Ollama-specific request options to override defaults (e.g., context window size).
struct OllamaRequestOptions: Encodable {
    let num_ctx: Int
}
