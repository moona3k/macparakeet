import Foundation

// MARK: - Protocol

public protocol LLMServiceProtocol: Sendable {
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String
    func chat(question: String, transcript: String, history: [ChatMessage]) async throws -> String
    func transform(text: String, prompt: String) async throws -> String
    func formatTranscript(
        transcript: String,
        promptTemplate: String,
        source: TelemetryFormatterSource,
        defaultPromptUsed: Bool
    ) async throws -> String

    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error>
    func chatStream(question: String, transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error>

    // MARK: Envelope variants
    //
    // The `*Detailed` calls return the same operation result wrapped in
    // an `LLMResult` envelope (provider, model, usage, stopReason,
    // latencyMs). The CLI uses these for `--json` output; existing
    // `String`-returning callers (the GUI) are unaffected.

    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult
    func chatDetailed(question: String, transcript: String, history: [ChatMessage]) async throws -> LLMResult
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult
}

public extension LLMServiceProtocol {
    func generatePromptResult(transcript: String) async throws -> String {
        try await generatePromptResult(transcript: transcript, systemPrompt: nil)
    }

    func generatePromptResultStream(transcript: String) -> AsyncThrowingStream<String, Error> {
        generatePromptResultStream(transcript: transcript, systemPrompt: nil)
    }

    func summarize(transcript: String) async throws -> String {
        try await generatePromptResult(transcript: transcript, systemPrompt: nil)
    }

    func summarize(transcript: String, systemPrompt: String?) async throws -> String {
        try await generatePromptResult(transcript: transcript, systemPrompt: systemPrompt)
    }

    func summarizeStream(transcript: String) -> AsyncThrowingStream<String, Error> {
        generatePromptResultStream(transcript: transcript, systemPrompt: nil)
    }

    func summarizeStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        generatePromptResultStream(transcript: transcript, systemPrompt: systemPrompt)
    }

    func generatePromptResultDetailed(transcript: String) async throws -> LLMResult {
        try await generatePromptResultDetailed(transcript: transcript, systemPrompt: nil)
    }

    func summarizeDetailed(transcript: String) async throws -> LLMResult {
        try await generatePromptResultDetailed(transcript: transcript, systemPrompt: nil)
    }

    func summarizeDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult {
        try await generatePromptResultDetailed(transcript: transcript, systemPrompt: systemPrompt)
    }
}

// MARK: - Implementation

public final class LLMService: LLMServiceProtocol, Sendable {
    private let client: LLMClientProtocol
    private let contextResolver: any LLMExecutionContextResolving
    private static let lmStudioFormatterSchema = ChatJSONSchema(
        type: "object",
        properties: [
            "cleaned_text": ChatJSONSchemaProperty(type: "string")
        ],
        required: ["cleaned_text"],
        additionalProperties: false
    )

    // Context budgets (characters)
    internal static let cloudContextBudget = 100_000
    internal static let localContextBudget = 24_000

    public init(
        client: LLMClientProtocol = RoutingLLMClient(),
        contextResolver: any LLMExecutionContextResolving = StoredLLMExecutionContextResolver()
    ) {
        self.client = client
        self.contextResolver = contextResolver
    }

    public convenience init(
        client: LLMClientProtocol = RoutingLLMClient(),
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
    //
    // The `String`-returning entry points delegate to their `*Detailed`
    // counterparts and project the `output` field. There's exactly one
    // network-call site per operation; metadata (model, usage, latency)
    // is captured uniformly even for callers that ultimately discard it.

    public func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String {
        try await generatePromptResultDetailed(transcript: transcript, systemPrompt: systemPrompt).output
    }

    public func chat(question: String, transcript: String, history: [ChatMessage]) async throws -> String {
        try await chatDetailed(question: question, transcript: transcript, history: history).output
    }

    public func transform(text: String, prompt: String) async throws -> String {
        try await transformDetailed(text: text, prompt: prompt).output
    }

    // MARK: - Envelope (Detailed) Variants

    public func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult {
        let operationID = Observability.operationID()
        let startedAt = Date()
        let promptDefaultUsed = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let context = try loadContextForLLMOperation(
            operationID: operationID,
            feature: "prompt_result",
            streaming: false,
            startedAt: startedAt,
            inputChars: transcript.count,
            promptDefaultUsed: promptDefaultUsed,
            messageCount: 2
        )
        let config = context.providerConfig
        let budget = contextBudget(for: config)
        let truncated = Self.truncateMiddle(transcript, limit: budget)
        let messages = [
            ChatMessage(role: .system, content: resolveSummaryPrompt(systemPrompt)),
            ChatMessage(role: .user, content: truncated),
        ]
        do {
            let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
            let latencyMs = Self.latencyMs(since: startedAt)
            Telemetry.send(.llmPromptResultUsed(provider: config.id.rawValue))
            sendLLMOperation(
                operationID: operationID,
                feature: "prompt_result",
                provider: config.id.rawValue,
                streaming: false,
                outcome: .success,
                startedAt: startedAt,
                inputChars: transcript.count,
                outputChars: response.content.count,
                inputTruncated: transcript.count > budget,
                promptDefaultUsed: promptDefaultUsed,
                messageCount: messages.count
            )
            return LLMResult(response: response, provider: config.id, latencyMs: latencyMs)
        } catch {
            if error is CancellationError {
                sendLLMOperation(
                    operationID: operationID,
                    feature: "prompt_result",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .cancelled,
                    startedAt: startedAt,
                    inputChars: transcript.count,
                    inputTruncated: transcript.count > budget,
                    promptDefaultUsed: promptDefaultUsed,
                    messageCount: messages.count
                )
            } else {
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                Telemetry.send(.llmPromptResultFailed(provider: config.id.rawValue, errorType: Self.errorType(for: error)))
                sendLLMOperation(
                    operationID: operationID,
                    feature: "prompt_result",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .failure,
                    startedAt: startedAt,
                    inputChars: transcript.count,
                    inputTruncated: transcript.count > budget,
                    promptDefaultUsed: promptDefaultUsed,
                    messageCount: messages.count,
                    errorType: Self.errorType(for: error)
                )
            }
            throw error
        }
    }

    public func chatDetailed(question: String, transcript: String, history: [ChatMessage]) async throws -> LLMResult {
        let operationID = Observability.operationID()
        let startedAt = Date()
        let context = try loadContextForLLMOperation(
            operationID: operationID,
            feature: "chat",
            streaming: false,
            startedAt: startedAt,
            inputChars: question.count + transcript.count,
            messageCount: history.count + 1
        )
        let config = context.providerConfig
        let messages = buildChatMessages(question: question, transcript: transcript, history: history, config: config)
        let budget = contextBudget(for: config)
        do {
            let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
            let latencyMs = Self.latencyMs(since: startedAt)
            Telemetry.send(.llmChatUsed(provider: config.id.rawValue, messageCount: history.count + 1))
            sendLLMOperation(
                operationID: operationID,
                feature: "chat",
                provider: config.id.rawValue,
                streaming: false,
                outcome: .success,
                startedAt: startedAt,
                inputChars: question.count + transcript.count,
                outputChars: response.content.count,
                inputTruncated: transcript.count > budget,
                messageCount: history.count + 1
            )
            return LLMResult(response: response, provider: config.id, latencyMs: latencyMs)
        } catch {
            if error is CancellationError {
                sendLLMOperation(
                    operationID: operationID,
                    feature: "chat",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .cancelled,
                    startedAt: startedAt,
                    inputChars: question.count + transcript.count,
                    inputTruncated: transcript.count > budget,
                    messageCount: history.count + 1
                )
            } else {
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                Telemetry.send(.llmChatFailed(provider: config.id.rawValue, errorType: Self.errorType(for: error)))
                sendLLMOperation(
                    operationID: operationID,
                    feature: "chat",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .failure,
                    startedAt: startedAt,
                    inputChars: question.count + transcript.count,
                    inputTruncated: transcript.count > budget,
                    messageCount: history.count + 1,
                    errorType: Self.errorType(for: error)
                )
            }
            throw error
        }
    }

    public func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        let operationID = Observability.operationID()
        let startedAt = Date()
        let context = try loadContextForLLMOperation(
            operationID: operationID,
            feature: "transform",
            streaming: false,
            startedAt: startedAt,
            inputChars: text.count + prompt.count,
            messageCount: 2
        )
        let config = context.providerConfig
        let budget = contextBudget(for: config)
        let truncated = Self.truncateMiddle(text, limit: budget)
        let messages = [
            ChatMessage(role: .system, content: Prompts.transform),
            ChatMessage(role: .user, content: "Transform the following text according to this instruction: \(prompt)\n\n---\n\n\(truncated)"),
        ]
        do {
            let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
            let latencyMs = Self.latencyMs(since: startedAt)
            Telemetry.send(.llmTransformUsed(provider: config.id.rawValue))
            sendLLMOperation(
                operationID: operationID,
                feature: "transform",
                provider: config.id.rawValue,
                streaming: false,
                outcome: .success,
                startedAt: startedAt,
                inputChars: text.count + prompt.count,
                outputChars: response.content.count,
                inputTruncated: text.count > budget,
                messageCount: messages.count
            )
            return LLMResult(response: response, provider: config.id, latencyMs: latencyMs)
        } catch {
            if error is CancellationError {
                sendLLMOperation(
                    operationID: operationID,
                    feature: "transform",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .cancelled,
                    startedAt: startedAt,
                    inputChars: text.count + prompt.count,
                    inputTruncated: text.count > budget,
                    messageCount: messages.count
                )
            } else {
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                Telemetry.send(.llmTransformFailed(provider: config.id.rawValue, errorType: Self.errorType(for: error)))
                sendLLMOperation(
                    operationID: operationID,
                    feature: "transform",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .failure,
                    startedAt: startedAt,
                    inputChars: text.count + prompt.count,
                    inputTruncated: text.count > budget,
                    messageCount: messages.count,
                    errorType: Self.errorType(for: error)
                )
            }
            throw error
        }
    }

    private static func latencyMs(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    public func formatTranscript(
        transcript: String,
        promptTemplate: String,
        source: TelemetryFormatterSource,
        defaultPromptUsed: Bool
    ) async throws -> String {
        let operationID = Observability.operationID()
        let startedAt = Date()
        let inputChars = transcript.count
        let context = try loadContextForLLMOperation(
            operationID: operationID,
            feature: "formatter_\(source.rawValue)",
            streaming: false,
            startedAt: startedAt,
            inputChars: inputChars,
            promptDefaultUsed: defaultPromptUsed,
            messageCount: 2
        )
        let config = context.providerConfig
        let budget = contextBudget(for: config)
        // Compare original transcript length against budget rather than the
        // output of `truncateMiddle`, which can be longer than the original
        // (the truncation marker adds ~32 chars) for inputs that only
        // slightly exceed the budget. What we actually care about is "did
        // we have to drop content to fit," which this expresses directly.
        let inputTruncated = transcript.count > budget
        let truncated = Self.truncateMiddle(transcript, limit: budget)

        do {
            let renderedPrompt = AIFormatter.renderPrompt(template: promptTemplate, transcript: truncated)
            let messages = [
                ChatMessage(role: .system, content: Prompts.formatter),
                ChatMessage(role: .user, content: renderedPrompt),
            ]

            let output: String
            if config.id == .lmstudio {
                let response = try await client.chatCompletion(
                    messages: messages,
                    context: context,
                    options: ChatCompletionOptions(
                        temperature: 0.2,
                        responseFormat: .jsonSchema(
                            name: "formatter_output",
                            schema: Self.lmStudioFormatterSchema
                        )
                    )
                )
                if response.finishReason?.lowercased() == "length" {
                    throw LLMError.formatterTruncated
                }
                let formatted = parseLMStudioFormattedTranscript(response) ?? response.content
                output = AIFormatter.normalizedFormattedOutput(formatted)
            } else {
                let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
                output = AIFormatter.normalizedFormattedOutput(response.content)
            }

            // An empty or whitespace-only response is a failure, not a
            // success: the caller will fall back to the deterministic
            // cleanup, and counting this as a successful formatter run
            // inflates the success-rate metric with runs that produced
            // nothing usable. Throw into the failure path so the
            // `.llmFormatterFailed` event is emitted with a meaningful
            // error_type bucket.
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw LLMError.formatterEmptyResponse
            }

            Telemetry.send(.llmFormatterUsed(
                provider: config.id.rawValue,
                source: source,
                durationSeconds: Date().timeIntervalSince(startedAt),
                inputChars: inputChars,
                outputChars: output.count,
                defaultPromptUsed: defaultPromptUsed,
                inputTruncated: inputTruncated
            ))
            sendLLMOperation(
                operationID: operationID,
                feature: "formatter_\(source.rawValue)",
                provider: config.id.rawValue,
                streaming: false,
                outcome: .success,
                startedAt: startedAt,
                inputChars: inputChars,
                outputChars: output.count,
                inputTruncated: inputTruncated,
                promptDefaultUsed: defaultPromptUsed,
                messageCount: 2
            )
            return output
        } catch {
            if error is CancellationError {
                sendLLMOperation(
                    operationID: operationID,
                    feature: "formatter_\(source.rawValue)",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .cancelled,
                    startedAt: startedAt,
                    inputChars: inputChars,
                    inputTruncated: inputTruncated,
                    promptDefaultUsed: defaultPromptUsed,
                    messageCount: 2
                )
            } else {
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                Telemetry.send(.llmFormatterFailed(
                    provider: config.id.rawValue,
                    source: source,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    errorType: Self.errorType(for: error),
                    defaultPromptUsed: defaultPromptUsed,
                    inputTruncated: inputTruncated
                ))
                sendLLMOperation(
                    operationID: operationID,
                    feature: "formatter_\(source.rawValue)",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .failure,
                    startedAt: startedAt,
                    inputChars: inputChars,
                    inputTruncated: inputTruncated,
                    promptDefaultUsed: defaultPromptUsed,
                    messageCount: 2,
                    errorType: Self.errorType(for: error)
                )
            }
            throw error
        }
    }

    // MARK: - Streaming Variants

    public func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let operationID = Observability.operationID()
            let startedAt = Date()
            let promptDefaultUsed = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let task = Task {
                var provider = "unknown"
                var outputChars = 0
                var inputTruncated: Bool?
                do {
                    let context: LLMExecutionContext
                    do {
                        context = try self.loadContext()
                    } catch {
                        self.sendLLMOperation(
                            operationID: operationID,
                            feature: "prompt_result",
                            provider: provider,
                            streaming: true,
                            outcome: Self.outcomeForLLMSetupError(error),
                            startedAt: startedAt,
                            inputChars: transcript.count,
                            promptDefaultUsed: promptDefaultUsed,
                            messageCount: 2,
                            errorType: Self.operationErrorType(for: error)
                        )
                        throw error
                    }
                    let config = context.providerConfig
                    provider = config.id.rawValue
                    let budget = self.contextBudget(for: config)
                    inputTruncated = transcript.count > budget
                    let truncated = Self.truncateMiddle(transcript, limit: budget)
                    let messages = [
                        ChatMessage(role: .system, content: self.resolveSummaryPrompt(systemPrompt)),
                        ChatMessage(role: .user, content: truncated),
                    ]
                    let stream = self.client.chatCompletionStream(messages: messages, context: context, options: .default)
                    for try await token in stream {
                        outputChars += token.count
                        continuation.yield(token)
                    }
                    Telemetry.send(.llmPromptResultUsed(provider: config.id.rawValue))
                    self.sendLLMOperation(
                        operationID: operationID,
                        feature: "prompt_result",
                        provider: provider,
                        streaming: true,
                        outcome: .success,
                        startedAt: startedAt,
                        inputChars: transcript.count,
                        outputChars: outputChars,
                        inputTruncated: inputTruncated,
                        promptDefaultUsed: promptDefaultUsed,
                        messageCount: messages.count
                    )
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        Telemetry.send(.llmPromptResultFailed(
                            provider: provider,
                            errorType: Self.errorType(for: error)
                        ))
                    }
                    if provider != "unknown" {
                        self.sendLLMOperation(
                            operationID: operationID,
                            feature: "prompt_result",
                            provider: provider,
                            streaming: true,
                            outcome: error is CancellationError ? .cancelled : .failure,
                            startedAt: startedAt,
                            inputChars: transcript.count,
                            outputChars: outputChars,
                            inputTruncated: inputTruncated,
                            promptDefaultUsed: promptDefaultUsed,
                            messageCount: 2,
                            errorType: error is CancellationError ? nil : Self.errorType(for: error)
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func chatStream(question: String, transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let operationID = Observability.operationID()
            let startedAt = Date()
            let messageCount = history.count + 1
            let task = Task {
                var provider = "unknown"
                var outputChars = 0
                var inputTruncated: Bool?
                do {
                    let context: LLMExecutionContext
                    do {
                        context = try self.loadContext()
                    } catch {
                        self.sendLLMOperation(
                            operationID: operationID,
                            feature: "chat",
                            provider: provider,
                            streaming: true,
                            outcome: Self.outcomeForLLMSetupError(error),
                            startedAt: startedAt,
                            inputChars: question.count + transcript.count,
                            messageCount: messageCount,
                            errorType: Self.operationErrorType(for: error)
                        )
                        throw error
                    }
                    let config = context.providerConfig
                    provider = config.id.rawValue
                    inputTruncated = transcript.count > self.contextBudget(for: config)
                    let messages = self.buildChatMessages(question: question, transcript: transcript, history: history, config: config)
                    let stream = self.client.chatCompletionStream(messages: messages, context: context, options: .default)
                    for try await token in stream {
                        outputChars += token.count
                        continuation.yield(token)
                    }
                    Telemetry.send(.llmChatUsed(provider: config.id.rawValue, messageCount: history.count + 1))
                    self.sendLLMOperation(
                        operationID: operationID,
                        feature: "chat",
                        provider: provider,
                        streaming: true,
                        outcome: .success,
                        startedAt: startedAt,
                        inputChars: question.count + transcript.count,
                        outputChars: outputChars,
                        inputTruncated: inputTruncated,
                        messageCount: messageCount
                    )
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        Telemetry.send(.llmChatFailed(
                            provider: provider,
                            errorType: Self.errorType(for: error)
                        ))
                    }
                    if provider != "unknown" {
                        self.sendLLMOperation(
                            operationID: operationID,
                            feature: "chat",
                            provider: provider,
                            streaming: true,
                            outcome: error is CancellationError ? .cancelled : .failure,
                            startedAt: startedAt,
                            inputChars: question.count + transcript.count,
                            outputChars: outputChars,
                            inputTruncated: inputTruncated,
                            messageCount: messageCount,
                            errorType: error is CancellationError ? nil : Self.errorType(for: error)
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let operationID = Observability.operationID()
            let startedAt = Date()
            let task = Task {
                var provider = "unknown"
                var outputChars = 0
                var inputTruncated: Bool?
                do {
                    let context: LLMExecutionContext
                    do {
                        context = try self.loadContext()
                    } catch {
                        self.sendLLMOperation(
                            operationID: operationID,
                            feature: "transform",
                            provider: provider,
                            streaming: true,
                            outcome: Self.outcomeForLLMSetupError(error),
                            startedAt: startedAt,
                            inputChars: text.count + prompt.count,
                            messageCount: 2,
                            errorType: Self.operationErrorType(for: error)
                        )
                        throw error
                    }
                    let config = context.providerConfig
                    provider = config.id.rawValue
                    let budget = self.contextBudget(for: config)
                    inputTruncated = text.count > budget
                    let truncated = Self.truncateMiddle(text, limit: budget)
                    let messages = [
                        ChatMessage(role: .system, content: Prompts.transform),
                        ChatMessage(role: .user, content: "Transform the following text according to this instruction: \(prompt)\n\n---\n\n\(truncated)"),
                    ]
                    let stream = self.client.chatCompletionStream(messages: messages, context: context, options: .default)
                    for try await token in stream {
                        outputChars += token.count
                        continuation.yield(token)
                    }
                    Telemetry.send(.llmTransformUsed(provider: config.id.rawValue))
                    self.sendLLMOperation(
                        operationID: operationID,
                        feature: "transform",
                        provider: provider,
                        streaming: true,
                        outcome: .success,
                        startedAt: startedAt,
                        inputChars: text.count + prompt.count,
                        outputChars: outputChars,
                        inputTruncated: inputTruncated,
                        messageCount: messages.count
                    )
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        Telemetry.send(.llmTransformFailed(
                            provider: provider,
                            errorType: Self.errorType(for: error)
                        ))
                    }
                    if provider != "unknown" {
                        self.sendLLMOperation(
                            operationID: operationID,
                            feature: "transform",
                            provider: provider,
                            streaming: true,
                            outcome: error is CancellationError ? .cancelled : .failure,
                            startedAt: startedAt,
                            inputChars: text.count + prompt.count,
                            outputChars: outputChars,
                            inputTruncated: inputTruncated,
                            messageCount: 2,
                            errorType: error is CancellationError ? nil : Self.errorType(for: error)
                        )
                    }
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

    private func loadContextForLLMOperation(
        operationID: String,
        feature: String,
        streaming: Bool,
        startedAt: Date,
        inputChars: Int?,
        promptDefaultUsed: Bool? = nil,
        messageCount: Int? = nil
    ) throws -> LLMExecutionContext {
        do {
            return try loadContext()
        } catch {
            sendLLMOperation(
                operationID: operationID,
                feature: feature,
                provider: "unknown",
                streaming: streaming,
                outcome: Self.outcomeForLLMSetupError(error),
                startedAt: startedAt,
                inputChars: inputChars,
                promptDefaultUsed: promptDefaultUsed,
                messageCount: messageCount,
                errorType: Self.operationErrorType(for: error)
            )
            throw error
        }
    }

    private func contextBudget(for config: LLMProviderConfig) -> Int {
        config.isLocal ? Self.localContextBudget : Self.cloudContextBudget
    }

    private func resolveSummaryPrompt(_ systemPrompt: String?) -> String {
        let trimmed = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? Prompts.summary
    }

    private func parseLMStudioFormattedTranscript(_ response: ChatCompletionResponse) -> String? {
        let candidates = [
            response.content,
            response.reasoningContent ?? "",
        ].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter {
            !$0.isEmpty
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(FormatterStructuredOutput.self, from: data) else {
                continue
            }
            let cleaned = payload.cleaned_text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return nil
    }

    private static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    private static func operationErrorType(for error: Error) -> String? {
        error is CancellationError ? nil : errorType(for: error)
    }

    private static func outcomeForLLMSetupError(_ error: Error) -> ObservabilityOutcome {
        if error is CancellationError {
            return .cancelled
        }
        if let llmError = error as? LLMError, case .notConfigured = llmError {
            return .unavailable
        }
        return .failure
    }

    private func sendLLMOperation(
        operationID: String,
        feature: String,
        provider: String,
        streaming: Bool,
        outcome: ObservabilityOutcome,
        startedAt: Date,
        inputChars: Int?,
        outputChars: Int? = nil,
        inputTruncated: Bool? = nil,
        promptDefaultUsed: Bool? = nil,
        messageCount: Int? = nil,
        errorType: String? = nil
    ) {
        let operationContext = Observability.operationContext(operationID: operationID, startedAt: startedAt)
        Telemetry.send(.llmOperation(
            operationID: operationID,
            operationContext: operationContext,
            feature: feature,
            provider: provider,
            streaming: streaming,
            outcome: outcome,
            durationSeconds: Observability.durationSeconds(since: startedAt),
            inputChars: inputChars,
            outputChars: outputChars,
            inputTruncated: inputTruncated,
            promptDefaultUsed: promptDefaultUsed,
            messageCount: messageCount,
            errorType: errorType
        ))
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
            Summarize this transcript clearly and concisely. Capture the key points, \
            decisions, and action items. Use bullet points for clarity. Keep it under \
            500 words.
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

        static let formatter = """
            You are a transcription formatting assistant. Follow the user's formatting \
            instructions exactly and return only the final formatted transcript.
            """
    }

    private struct FormatterStructuredOutput: Decodable {
        let cleaned_text: String
    }
}
