import Foundation

// MARK: - Protocol

public protocol LLMClientProtocol: Sendable {
    var supportsInProcessLocalLLM: Bool { get }

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
    var supportsInProcessLocalLLM: Bool { false }

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
    private let openAICompatibleAdapter: OpenAICompatibleLLMHTTPAdapter
    private let anthropicAdapter: AnthropicLLMHTTPAdapter
    private let ollamaAdapter: OllamaLLMHTTPAdapter

    public init(session: URLSession = .shared) {
        let transport = LLMHTTPTransport(session: session)
        openAICompatibleAdapter = OpenAICompatibleLLMHTTPAdapter(transport: transport)
        anthropicAdapter = AnthropicLLMHTTPAdapter(transport: transport)
        ollamaAdapter = OllamaLLMHTTPAdapter(transport: transport)
    }

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let config = context.providerConfig
        return try await adapter(for: config.id)
            .chatCompletion(messages: messages, config: config, options: options)
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        do {
            let config = context.providerConfig
            return try adapter(for: config.id)
                .chatCompletionStream(messages: messages, config: config, options: options)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        let config = context.providerConfig
        try await adapter(for: config.id).testConnection(config: config)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        let config = context.providerConfig
        guard config.id.modelListEndpoint != .none else {
            throw LLMError.connectionFailed("Model listing is not supported for this provider.")
        }
        return try await adapter(for: config.id).listModels(config: config)
    }

    // MARK: - Internal Test Shims

    internal func parseSSELine(_ line: String) -> OpenAICompatibleLLMHTTPAdapter.SSEResult {
        openAICompatibleAdapter.parseSSELine(line)
    }

    internal func parseSSEEvent(_ lines: [String]) -> OpenAICompatibleLLMHTTPAdapter.SSEResult {
        openAICompatibleAdapter.parseSSEEvent(lines)
    }

    internal static func providerEnforcesStreamSentinel(_ id: LLMProviderID) -> Bool {
        LLMHTTPStreamCompletionPolicy.providerEnforcesStreamSentinel(id)
    }

    internal func validateStreamCompletion(
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

    /// Anthropic Messages API version pin. Anthropic dates each API version;
    /// use the latest date listed in the public version history so chat-stream
    /// and listModels stay in lockstep.
    static let anthropicAPIVersion = AnthropicLLMHTTPAdapter.apiVersion

    static func scrubAPIKeyArtifacts(from message: String) -> String {
        LLMHTTPErrorMapper.scrubAPIKeyArtifacts(from: message)
    }

    private func adapter(for id: LLMProviderID) throws -> any LLMHTTPAdapter {
        switch id {
        case .anthropic:
            return anthropicAdapter
        case .ollama:
            return ollamaAdapter
        case .openai, .openaiCompatible, .gemini, .openrouter, .lmstudio:
            return openAICompatibleAdapter
        case .localCLI:
            throw LLMError.connectionFailed("HTTP LLM client does not support Local CLI provider.")
        case .inProcessLocal:
            throw LLMError.connectionFailed("HTTP LLM client does not support Local MLX provider.")
        }
    }
}
