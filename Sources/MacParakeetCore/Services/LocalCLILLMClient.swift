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
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let (system, user) = Self.extractPrompts(from: messages)

        do {
            let config = try localCLIConfig(from: context)
            let output = try await executor.execute(
                systemPrompt: system,
                userPrompt: user,
                config: config
            )
            return ChatCompletionResponse(content: output, model: "cli")
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.cliError(error.localizedDescription)
        }
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.chatCompletion(
                        messages: messages, context: context, options: options
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

    public func testConnection(context: LLMExecutionContext) async throws {
        do {
            try await executor.testConnection(config: try localCLIConfig(from: context))
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.cliError(error.localizedDescription)
        }
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        []
    }

    // MARK: - Private

    private func localCLIConfig(from context: LLMExecutionContext) throws -> LocalCLIConfig {
        guard let config = context.localCLIConfig else {
            throw LocalCLIError.commandNotConfigured
        }
        return config
    }

    /// Splits a message array into (system prompt, user prompt) strings.
    /// Non-system messages preserve role labels for multi-turn context.
    static func extractPrompts(from messages: [ChatMessage]) -> (system: String, user: String) {
        let system = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")

        let nonSystem = messages.filter { $0.role != .system }
        let user: String
        if nonSystem.count == 1 {
            // Single message — no role prefix needed
            user = nonSystem[0].content
        } else {
            // Multi-turn: prefix each message with its role
            user = nonSystem.map { msg in
                let label = msg.role == .user ? "User" : "Assistant"
                return "\(label): \(msg.content)"
            }.joined(separator: "\n\n")
        }

        return (system, user)
    }
}
