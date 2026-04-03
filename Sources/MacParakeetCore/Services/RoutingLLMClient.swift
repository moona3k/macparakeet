import Foundation

/// Routes LLM requests to the appropriate client based on provider ID.
/// HTTP-based providers go to `LLMClient`; `.localCLI` goes to `LocalCLILLMClient`.
public final class RoutingLLMClient: LLMClientProtocol, Sendable {
    private let httpClient: LLMClient
    private let cliClient: LocalCLILLMClient

    public init(
        httpClient: LLMClient = LLMClient(),
        cliClient: LocalCLILLMClient = LocalCLILLMClient()
    ) {
        self.httpClient = httpClient
        self.cliClient = cliClient
    }

    public func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        try await client(for: config).chatCompletion(messages: messages, config: config, options: options)
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        client(for: config).chatCompletionStream(messages: messages, config: config, options: options)
    }

    public func testConnection(config: LLMProviderConfig) async throws {
        try await client(for: config).testConnection(config: config)
    }

    public func listModels(config: LLMProviderConfig) async throws -> [String] {
        try await client(for: config).listModels(config: config)
    }

    private func client(for config: LLMProviderConfig) -> LLMClientProtocol {
        config.id == .localCLI ? cliClient : httpClient
    }
}
