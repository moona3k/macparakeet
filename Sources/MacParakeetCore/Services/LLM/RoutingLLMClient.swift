import Foundation

/// Routes LLM requests to the appropriate client based on provider ID.
/// HTTP-based providers go to `LLMClient`; `.localCLI` goes to
/// `LocalCLILLMClient`; `.inProcessLocal` goes to `InProcessLLMClient`.
public final class RoutingLLMClient: LLMClientProtocol, Sendable {
    private let httpClient: any LLMClientProtocol
    private let cliClient: any LLMClientProtocol
    private let inProcessClient: any LLMClientProtocol

    public init(
        httpClient: any LLMClientProtocol = LLMClient(),
        cliClient: any LLMClientProtocol = LocalCLILLMClient(),
        inProcessClient: any LLMClientProtocol = InProcessLLMClient()
    ) {
        self.httpClient = httpClient
        self.cliClient = cliClient
        self.inProcessClient = inProcessClient
    }

    public var supportsInProcessLocalLLM: Bool {
        inProcessClient.supportsInProcessLocalLLM
    }

    public func structuredOutputCapability(
        context: LLMExecutionContext
    ) -> LLMStructuredOutputCapability {
        client(for: context).structuredOutputCapability(context: context)
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

    public func withInProcessLocalModelRemoval(_ operation: @Sendable () async throws -> Void) async throws {
        try await inProcessClient.withInProcessLocalModelRemoval(operation)
    }

    private func client(for context: LLMExecutionContext) -> any LLMClientProtocol {
        switch context.providerConfig.id {
        case .localCLI:
            return cliClient
        case .inProcessLocal:
            return inProcessClient
        case .anthropic, .openai, .openaiCompatible, .gemini, .openrouter, .ollama, .lmstudio:
            return httpClient
        }
    }
}
