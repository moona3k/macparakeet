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
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        try await client(for: context).chatCompletion(messages: messages, context: context, options: options)
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        client(for: context).chatCompletionStream(messages: messages, context: context, options: options)
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        try await client(for: context).testConnection(context: context)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        try await client(for: context).listModels(context: context)
    }

    private func client(for context: LLMExecutionContext) -> LLMClientProtocol {
        context.providerConfig.id == .localCLI ? cliClient : httpClient
    }
}
