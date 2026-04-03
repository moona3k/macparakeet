import Foundation

/// LLM client that executes CLI tools (e.g. `claude -p`, `codex exec`)
/// instead of making HTTP requests. Conforms to `LLMClientProtocol` so it
/// plugs transparently into `LLMService` via `RoutingLLMClient`.
public final class LocalCLILLMClient: LLMClientProtocol, Sendable {
    private let executor: LocalCLIExecutor

    public init(executor: LocalCLIExecutor = LocalCLIExecutor()) {
        self.executor = executor
    }

    public func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let (system, user) = Self.extractPrompts(from: messages)

        do {
            let output = try await executor.execute(systemPrompt: system, userPrompt: user)
            return ChatCompletionResponse(content: output, model: "cli")
        } catch let error as LocalCLIError {
            throw LLMError.cliError(error.errorDescription ?? error.localizedDescription)
        }
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.chatCompletion(
                        messages: messages, config: config, options: options
                    )
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection(config: LLMProviderConfig) async throws {
        do {
            try await executor.testConnection()
        } catch let error as LocalCLIError {
            throw LLMError.cliError(error.errorDescription ?? error.localizedDescription)
        }
    }

    public func listModels(config: LLMProviderConfig) async throws -> [String] {
        []
    }

    // MARK: - Private

    /// Splits a message array into (system prompt, user prompt) strings.
    static func extractPrompts(from messages: [ChatMessage]) -> (system: String, user: String) {
        let system = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")

        let user = messages
            .filter { $0.role != .system }
            .map(\.content)
            .joined(separator: "\n\n")

        return (system, user)
    }
}
