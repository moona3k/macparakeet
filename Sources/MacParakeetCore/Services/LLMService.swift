import Foundation

// MARK: - Protocol

public protocol LLMServiceProtocol: Sendable {
    func summarize(transcript: String) async throws -> String
    func chat(question: String, transcript: String, history: [ChatMessage]) async throws -> String
    func transform(text: String, prompt: String) async throws -> String

    func summarizeStream(transcript: String) -> AsyncThrowingStream<String, Error>
    func chatStream(question: String, transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error>
}

// MARK: - Implementation

public final class LLMService: LLMServiceProtocol, Sendable {
    private let client: LLMClientProtocol
    private let contextResolver: any LLMExecutionContextResolving

    // Context budgets (characters)
    internal static let cloudContextBudget = 100_000
    internal static let localContextBudget = 24_000

    public init(
        client: LLMClientProtocol = LLMClient(),
        contextResolver: any LLMExecutionContextResolving = StoredLLMExecutionContextResolver()
    ) {
        self.client = client
        self.contextResolver = contextResolver
    }

    public convenience init(
        client: LLMClientProtocol = LLMClient(),
        configStore: LLMConfigStoreProtocol = LLMConfigStore(),
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.init(
            client: client,
            contextResolver: StoredLLMExecutionContextResolver(
                configStore: configStore,
                cliConfigStore: cliConfigStore
            )
        )
    }

    // MARK: - Sync Variants

    public func summarize(transcript: String) async throws -> String {
        let context = try loadContext()
        let config = context.providerConfig
        let truncated = Self.truncateMiddle(transcript, limit: contextBudget(for: config))
        let messages = [
            ChatMessage(role: .system, content: Prompts.summary),
            ChatMessage(role: .user, content: truncated),
        ]
        do {
            let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
            Telemetry.send(.llmSummaryUsed(provider: config.id.rawValue))
            return response.content
        } catch {
            if !(error is CancellationError) {
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                Telemetry.send(.llmSummaryFailed(provider: config.id.rawValue, errorType: Self.errorType(for: error)))
            }
            throw error
        }
    }

    public func chat(question: String, transcript: String, history: [ChatMessage]) async throws -> String {
        let context = try loadContext()
        let config = context.providerConfig
        let messages = buildChatMessages(question: question, transcript: transcript, history: history, config: config)
        do {
            let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
            Telemetry.send(.llmChatUsed(provider: config.id.rawValue, messageCount: history.count + 1))
            return response.content
        } catch {
            if !(error is CancellationError) {
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                Telemetry.send(.llmChatFailed(provider: config.id.rawValue, errorType: Self.errorType(for: error)))
            }
            throw error
        }
    }

    public func transform(text: String, prompt: String) async throws -> String {
        let context = try loadContext()
        let config = context.providerConfig
        let truncated = Self.truncateMiddle(text, limit: contextBudget(for: config))
        let messages = [
            ChatMessage(role: .system, content: Prompts.transform),
            ChatMessage(role: .user, content: "Transform the following text according to this instruction: \(prompt)\n\n---\n\n\(truncated)"),
        ]
        let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
        return response.content
    }

    // MARK: - Streaming Variants

    public func summarizeStream(transcript: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var provider = "unknown"
                do {
                    let context = try self.loadContext()
                    let config = context.providerConfig
                    provider = config.id.rawValue
                    let truncated = Self.truncateMiddle(transcript, limit: self.contextBudget(for: config))
                    let messages = [
                        ChatMessage(role: .system, content: Prompts.summary),
                        ChatMessage(role: .user, content: truncated),
                    ]
                    let stream = self.client.chatCompletionStream(messages: messages, context: context, options: .default)
                    for try await token in stream {
                        continuation.yield(token)
                    }
                    Telemetry.send(.llmSummaryUsed(provider: config.id.rawValue))
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        Telemetry.send(.llmSummaryFailed(
                            provider: provider,
                            errorType: Self.errorType(for: error)
                        ))
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func chatStream(question: String, transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var provider = "unknown"
                do {
                    let context = try self.loadContext()
                    let config = context.providerConfig
                    provider = config.id.rawValue
                    let messages = self.buildChatMessages(question: question, transcript: transcript, history: history, config: config)
                    let stream = self.client.chatCompletionStream(messages: messages, context: context, options: .default)
                    for try await token in stream {
                        continuation.yield(token)
                    }
                    Telemetry.send(.llmChatUsed(provider: config.id.rawValue, messageCount: history.count + 1))
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        Telemetry.send(.llmChatFailed(
                            provider: provider,
                            errorType: Self.errorType(for: error)
                        ))
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let context = try self.loadContext()
                    let config = context.providerConfig
                    let truncated = Self.truncateMiddle(text, limit: self.contextBudget(for: config))
                    let messages = [
                        ChatMessage(role: .system, content: Prompts.transform),
                        ChatMessage(role: .user, content: "Transform the following text according to this instruction: \(prompt)\n\n---\n\n\(truncated)"),
                    ]
                    let stream = self.client.chatCompletionStream(messages: messages, context: context, options: .default)
                    for try await token in stream {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private Helpers

    private func loadContext() throws -> LLMExecutionContext {
        guard let context = try contextResolver.resolveContext() else {
            throw LLMError.notConfigured
        }
        return context
    }

    private func contextBudget(for config: LLMProviderConfig) -> Int {
        config.isLocal ? Self.localContextBudget : Self.cloudContextBudget
    }

    private static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    private func buildChatMessages(
        question: String,
        transcript: String,
        history: [ChatMessage],
        config: LLMProviderConfig
    ) -> [ChatMessage] {
        let budget = contextBudget(for: config)
        let truncated = Self.truncateMiddle(transcript, limit: budget)

        let systemPrompt = Prompts.chat + "\n\n---\nTranscript:\n" + truncated

        var messages = [ChatMessage(role: .system, content: systemPrompt)]

        // Add history, dropping oldest turns if total exceeds budget.
        // Trim at turn boundaries (user+assistant pairs) to avoid orphaned messages.
        let historyBudget = max(0, budget - systemPrompt.count - question.count)
        var historyChars = 0
        var keptTurns: [[ChatMessage]] = []

        // Group history into turns (pairs of consecutive messages) from newest to oldest
        var i = history.count
        while i > 0 {
            // Walk backwards: take assistant then user (or single message if unpaired)
            let end = i
            i -= 1
            // If this is an assistant message preceded by a user message, take both as a turn
            if i > 0 && history[i].role == .assistant && history[i - 1].role == .user {
                let turnChars = history[i - 1].content.count + history[i].content.count
                if historyChars + turnChars > historyBudget { break }
                historyChars += turnChars
                keptTurns.insert([history[i - 1], history[i]], at: 0)
                i -= 1
            } else {
                let turnChars = history[end - 1].content.count
                if historyChars + turnChars > historyBudget { break }
                historyChars += turnChars
                keptTurns.insert([history[end - 1]], at: 0)
            }
        }
        messages.append(contentsOf: keptTurns.flatMap { $0 })

        messages.append(ChatMessage(role: .user, content: question))
        return messages
    }

    /// Truncate text from the middle, keeping first 45% and last 45% of the budget.
    /// Snaps to word boundaries to avoid slicing multi-byte Unicode characters.
    internal static func truncateMiddle(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }

        let headBudget = Int(Double(limit) * 0.45)
        let tailBudget = Int(Double(limit) * 0.45)

        let head = snapToWordBoundary(text, fromStart: true, budget: headBudget)
        let tail = snapToWordBoundary(text, fromStart: false, budget: tailBudget)

        return head + "\n\n[... content truncated ...]\n\n" + tail
    }

    private static func snapToWordBoundary(_ text: String, fromStart: Bool, budget: Int) -> String {
        if fromStart {
            let endIndex = text.index(text.startIndex, offsetBy: min(budget, text.count))
            let substring = text[text.startIndex..<endIndex]
            // Find last space to snap to word boundary
            if let lastSpace = substring.lastIndex(of: " ") {
                return String(text[text.startIndex...lastSpace])
            }
            return String(substring)
        } else {
            let startIndex = text.index(text.endIndex, offsetBy: -min(budget, text.count))
            let substring = text[startIndex..<text.endIndex]
            // Find first space to snap to word boundary
            if let firstSpace = substring.firstIndex(of: " ") {
                return String(text[firstSpace..<text.endIndex])
            }
            return String(substring)
        }
    }

    // MARK: - Prompt Templates

    private enum Prompts {
        static let summary = """
            You are a helpful assistant that summarizes transcripts. Provide a clear, \
            concise summary that captures the key points, decisions, and action items. \
            Use bullet points for clarity. Keep the summary under 500 words.
            """

        static let chat = """
            You are a helpful assistant. The user will ask questions about the following \
            transcript. Answer based on the transcript content. If the answer isn't in \
            the transcript, say so.
            """

        static let transform = """
            You are a helpful assistant that transforms text according to user instructions. \
            Apply the requested transformation to the provided text. Return only the \
            transformed text without explanation.
            """
    }
}
