import Foundation

/// LLM client that shells out to the bundled `macparakeet-cleanup` CLI.
///
/// Unlike `LocalCLILLMClient`, this client passes the system prompt verbatim
/// (including any `{{TRANSCRIPT}}` placeholder) to the CLI via `--prompt-file`
/// and pipes the user message on stdin. The cleanup script does the
/// interpolation when LLM mode runs and ignores the prompt entirely on the
/// rules path.
public final class LocalFormattingModelClient: LLMClientProtocol, Sendable {
    private let executor: LocalFormattingModelExecutor

    public init(executor: LocalFormattingModelExecutor = LocalFormattingModelExecutor()) {
        self.executor = executor
    }

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let (system, user) = Self.extractPrompts(from: messages)
        let config = try formattingConfig(from: context)

        do {
            let output = try await executor.execute(
                systemPrompt: system,
                transcript: user,
                config: config
            )
            return ChatCompletionResponse(content: output, model: config.modelID)
        } catch let error as LocalFormattingModelError {
            throw LLMError.cliError(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
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
            try await executor.testConnection(config: try formattingConfig(from: context))
        } catch let error as LocalFormattingModelError {
            throw LLMError.cliError(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.cliError(error.localizedDescription)
        }
    }

    /// Trigger a daemon warm-up so the MLX model is loaded by the time the
    /// user finishes dictating. Errors are swallowed — warm-up is best-effort.
    public func warmUp(context: LLMExecutionContext) async {
        guard let config = context.localFormattingModelConfig else { return }
        try? await executor.warmUp(config: config)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        []
    }

    // MARK: - Private

    private func formattingConfig(from context: LLMExecutionContext) throws -> LocalFormattingModelConfig {
        guard let config = context.localFormattingModelConfig else {
            throw LocalFormattingModelError.notConfigured
        }
        return config
    }

    /// Splits messages into (system prompt, user prompt). System messages are
    /// joined with blank lines; the last user message is treated as the
    /// transcript. Multi-turn isn't expected here (the formatter path sends
    /// one system + one user), but we handle it gracefully.
    static func extractPrompts(from messages: [ChatMessage]) -> (system: String, user: String) {
        let system = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")

        let nonSystem = messages.filter { $0.role != .system }
        let user: String
        if nonSystem.count <= 1 {
            user = nonSystem.first?.content ?? ""
        } else {
            user = nonSystem.map { msg in
                let label = msg.role == .user ? "User" : "Assistant"
                return "\(label): \(msg.content)"
            }.joined(separator: "\n\n")
        }

        return (system, user)
    }
}
