import Foundation

/// Routes LLM requests to the appropriate client based on provider ID.
/// HTTP-based providers go to `LLMClient`; `.localCLI` goes to
/// `LocalCLILLMClient`; `.localFormattingModel` goes to
/// `LocalFormattingModelClient`.
public final class RoutingLLMClient: LLMClientProtocol, Sendable {
    private let httpClient: LLMClient
    private let cliClient: LocalCLILLMClient
    private let formattingModelClient: LocalFormattingModelClient

    public init(
        httpClient: LLMClient = LLMClient(),
        cliClient: LocalCLILLMClient = LocalCLILLMClient(),
        formattingModelClient: LocalFormattingModelClient = LocalFormattingModelClient()
    ) {
        self.httpClient = httpClient
        self.cliClient = cliClient
        self.formattingModelClient = formattingModelClient
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

    /// Best-effort pre-warm for providers that benefit from it. Currently
    /// only the bundled cleanup CLI's MLX daemon needs this — other providers
    /// no-op. Errors are swallowed; the caller fires this and forgets.
    public func warmUp(context: LLMExecutionContext) async {
        if context.providerConfig.id == .localFormattingModel {
            await formattingModelClient.warmUp(context: context)
        }
    }

    private func client(for context: LLMExecutionContext) -> LLMClientProtocol {
        switch context.providerConfig.id {
        case .localCLI: return cliClient
        case .localFormattingModel: return formattingModelClient
        default: return httpClient
        }
    }
}
