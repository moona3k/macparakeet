import Foundation

// MARK: - Protocol

public protocol LLMServiceProtocol: Sendable {
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String
    func transform(text: String, prompt: String) async throws -> String
    func formatTranscript(
        transcript: String,
        promptTemplate: String,
        source: TelemetryFormatterSource,
        defaultPromptUsed: Bool
    ) async throws -> String

    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error>
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error>
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error>

    // MARK: Envelope variants
    //
    // The `*Detailed` calls return the same operation result wrapped in
    // an `LLMResult` envelope (provider, model, usage, stopReason,
    // latencyMs). The CLI uses these for `--json` output; existing
    // `String`-returning callers (the GUI) are unaffected.

    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult
    func formatTranscriptDetailed(
        transcript: String,
        promptTemplate: String,
        source: TelemetryFormatterSource,
        defaultPromptUsed: Bool
    ) async throws -> LLMFormatterResult
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
    private struct MessageAssembly {
        let messages: [ChatMessage]
        let inputTruncated: Bool
    }

    private struct ChatSystemPromptBuild {
        let prompt: String
        let inputTruncated: Bool
    }

    private static let lmStudioFormatterSchema = ChatJSONSchema(
        type: "object",
        properties: [
            "cleaned_text": ChatJSONSchemaProperty(type: "string")
        ],
        required: ["cleaned_text"],
        additionalProperties: false
    )

    // Context budgets (characters). Sized for 2026 model norms: every modern
    // cloud provider ships at least a 200K-token context, and local models on
    // Apple Silicon (Llama 4 / Qwen / Gemma / Mistral) routinely have 32K+
    // tokens. We sit comfortably under those floors so first-token latency and
    // per-turn cost stay reasonable while a multi-hour meeting can fit
    // un-truncated. ~3.5 chars/token in English.
    internal static let cloudContextBudget = 500_000   // ≈140K tokens
    internal static let localContextBudget =  80_000   // ≈ 22K tokens
    internal static let lmStudioContextBudget = 8_000  // ≈2K tokens; LM Studio defaults vary by loaded model

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

    public func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String {
        try await chatDetailed(question: question, transcript: transcript, userNotes: userNotes, history: history, source: source).output
    }

    public func transform(text: String, prompt: String) async throws -> String {
        try await transformDetailed(text: text, prompt: prompt).output
    }

    public func formatTranscript(
        transcript: String,
        promptTemplate: String,
        source: TelemetryFormatterSource,
        defaultPromptUsed: Bool
    ) async throws -> String {
        try await formatTranscriptDetailed(
            transcript: transcript,
            promptTemplate: promptTemplate,
            source: source,
            defaultPromptUsed: defaultPromptUsed
        ).output
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
        let assembly = buildPromptResultMessages(transcript: transcript, systemPrompt: systemPrompt, config: config)
        let messages = assembly.messages
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
                inputTruncated: assembly.inputTruncated,
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
                    inputTruncated: assembly.inputTruncated,
                    promptDefaultUsed: promptDefaultUsed,
                    messageCount: messages.count
                )
            } else {
                let kind = Self.errorType(for: error)
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                if Self.isProviderUnavailable(error) {
                    Telemetry.send(.llmProviderUnavailable(
                        provider: config.id.rawValue,
                        errorType: kind,
                        feature: .promptResult
                    ))
                } else {
                    Telemetry.send(.llmPromptResultFailed(provider: config.id.rawValue, errorType: kind))
                }
                sendLLMOperation(
                    operationID: operationID,
                    feature: "prompt_result",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .failure,
                    startedAt: startedAt,
                    inputChars: transcript.count,
                    inputTruncated: assembly.inputTruncated,
                    promptDefaultUsed: promptDefaultUsed,
                    messageCount: messages.count,
                    errorType: kind
                )
            }
            throw error
        }
    }

    public func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult {
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
        let assembly = buildChatMessages(
            question: question,
            transcript: transcript,
            userNotes: userNotes,
            history: history,
            config: config
        )
        let messages = assembly.messages
        do {
            let response = try await client.chatCompletion(messages: messages, context: context, options: .default)
            let latencyMs = Self.latencyMs(since: startedAt)
            Telemetry.send(.llmChatUsed(provider: config.id.rawValue, source: source, messageCount: history.count + 1))
            sendLLMOperation(
                operationID: operationID,
                feature: "chat",
                provider: config.id.rawValue,
                streaming: false,
                outcome: .success,
                startedAt: startedAt,
                inputChars: question.count + transcript.count,
                outputChars: response.content.count,
                inputTruncated: assembly.inputTruncated,
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
                    inputTruncated: assembly.inputTruncated,
                    messageCount: history.count + 1
                )
            } else {
                let kind = Self.errorType(for: error)
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                if Self.isProviderUnavailable(error) {
                    Telemetry.send(.llmProviderUnavailable(
                        provider: config.id.rawValue,
                        errorType: kind,
                        feature: .chat
                    ))
                } else {
                    Telemetry.send(.llmChatFailed(provider: config.id.rawValue, source: source, errorType: kind))
                }
                sendLLMOperation(
                    operationID: operationID,
                    feature: "chat",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .failure,
                    startedAt: startedAt,
                    inputChars: question.count + transcript.count,
                    inputTruncated: assembly.inputTruncated,
                    messageCount: history.count + 1,
                    errorType: kind
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
        let assembly = buildTransformMessages(text: text, prompt: prompt, config: config)
        let messages = assembly.messages
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
                inputTruncated: assembly.inputTruncated,
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
                    inputTruncated: assembly.inputTruncated,
                    messageCount: messages.count
                )
            } else {
                let kind = Self.errorType(for: error)
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                if Self.isProviderUnavailable(error) {
                    Telemetry.send(.llmProviderUnavailable(
                        provider: config.id.rawValue,
                        errorType: kind,
                        feature: .transform
                    ))
                } else {
                    Telemetry.send(.llmTransformFailed(provider: config.id.rawValue, errorType: kind))
                }
                sendLLMOperation(
                    operationID: operationID,
                    feature: "transform",
                    provider: config.id.rawValue,
                    streaming: false,
                    outcome: .failure,
                    startedAt: startedAt,
                    inputChars: text.count + prompt.count,
                    inputTruncated: assembly.inputTruncated,
                    messageCount: messages.count,
                    errorType: kind
                )
            }
            throw error
        }
    }

    private static func latencyMs(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    public func formatTranscriptDetailed(
        transcript: String,
        promptTemplate: String,
        source: TelemetryFormatterSource,
        defaultPromptUsed: Bool
    ) async throws -> LLMFormatterResult {
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
        let promptOverhead = Prompts.formatter.count
            + AIFormatter.renderPrompt(template: promptTemplate, transcript: "").count
        let transcriptBudget = max(0, budget - promptOverhead)
        // Compare original transcript length against the transcript-specific
        // budget. The request also includes formatter instructions and the
        // rendered template, so the transcript cannot consume the whole model
        // context by itself.
        let inputTruncated = transcript.count > transcriptBudget
        let truncated = Self.truncateMiddle(transcript, limit: transcriptBudget)
        let renderedPrompt = AIFormatter.renderPrompt(template: promptTemplate, transcript: truncated)
        let messages = [
            ChatMessage(role: .system, content: Prompts.formatter),
            ChatMessage(role: .user, content: renderedPrompt),
        ]

        do {
            let response: ChatCompletionResponse
            let output: String
            if config.id == .lmstudio {
                response = try await client.chatCompletion(
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
                response = try await client.chatCompletion(messages: messages, context: context, options: .default)
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
            let llmResult = LLMResult(
                output: output,
                provider: config.id.rawValue,
                model: response.model,
                usage: response.usage.map(LLMUsage.init),
                stopReason: response.finishReason,
                latencyMs: Self.latencyMs(since: startedAt)
            )
            return LLMFormatterResult(
                result: llmResult,
                operationID: operationID,
                inputChars: inputChars,
                outputChars: output.count,
                inputTruncated: inputTruncated,
                defaultPromptUsed: defaultPromptUsed,
                messageCount: messages.count
            )
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
                let kind = Self.errorType(for: error)
                // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                if Self.isProviderUnavailable(error) {
                    Telemetry.send(.llmProviderUnavailable(
                        provider: config.id.rawValue,
                        errorType: kind,
                        feature: .formatter,
                        source: source
                    ))
                } else {
                    Telemetry.send(.llmFormatterFailed(
                        provider: config.id.rawValue,
                        source: source,
                        durationSeconds: Date().timeIntervalSince(startedAt),
                        errorType: kind,
                        defaultPromptUsed: defaultPromptUsed,
                        inputTruncated: inputTruncated
                    ))
                }
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
                    errorType: kind
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
                    let assembly = self.buildPromptResultMessages(
                        transcript: transcript,
                        systemPrompt: systemPrompt,
                        config: config
                    )
                    inputTruncated = assembly.inputTruncated
                    let messages = assembly.messages
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
                        let kind = Self.errorType(for: error)
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        if Self.isProviderUnavailable(error) {
                            Telemetry.send(.llmProviderUnavailable(
                                provider: provider,
                                errorType: kind,
                                feature: .promptResult
                            ))
                        } else {
                            Telemetry.send(.llmPromptResultFailed(
                                provider: provider,
                                errorType: kind
                            ))
                        }
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

    public func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> {
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
                    let assembly = self.buildChatMessages(
                        question: question,
                        transcript: transcript,
                        userNotes: userNotes,
                        history: history,
                        config: config
                    )
                    inputTruncated = assembly.inputTruncated
                    let messages = assembly.messages
                    let stream = self.client.chatCompletionStream(messages: messages, context: context, options: .default)
                    for try await token in stream {
                        outputChars += token.count
                        continuation.yield(token)
                    }
                    Telemetry.send(.llmChatUsed(provider: config.id.rawValue, source: source, messageCount: history.count + 1))
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
                        let kind = Self.errorType(for: error)
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        if Self.isProviderUnavailable(error) {
                            Telemetry.send(.llmProviderUnavailable(
                                provider: provider,
                                errorType: kind,
                                feature: .chat
                            ))
                        } else {
                            Telemetry.send(.llmChatFailed(
                                provider: provider,
                                source: source,
                                errorType: kind
                            ))
                        }
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
                    let assembly = self.buildTransformMessages(text: text, prompt: prompt, config: config)
                    inputTruncated = assembly.inputTruncated
                    let messages = assembly.messages
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
                        let kind = Self.errorType(for: error)
                        // No errorDetail for LLM errors — API responses may echo user transcript/prompt content
                        if Self.isProviderUnavailable(error) {
                            Telemetry.send(.llmProviderUnavailable(
                                provider: provider,
                                errorType: kind,
                                feature: .transform
                            ))
                        } else {
                            Telemetry.send(.llmTransformFailed(
                                provider: provider,
                                errorType: kind
                            ))
                        }
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
        if config.id == .lmstudio {
            return Self.lmStudioContextBudget
        }
        return config.isLocal ? Self.localContextBudget : Self.cloudContextBudget
    }

    private func transcriptBudget(totalBudget: Int, systemPrompt: String) -> Int {
        max(0, totalBudget - systemPrompt.count)
    }

    private func buildPromptResultMessages(
        transcript: String,
        systemPrompt: String?,
        config: LLMProviderConfig
    ) -> MessageAssembly {
        let budget = contextBudget(for: config)
        let resolvedPrompt = resolveSummaryPrompt(systemPrompt)
        let promptWasTruncated = resolvedPrompt.count > budget
        let boundedPrompt = promptWasTruncated
            ? Self.truncateMiddle(resolvedPrompt, limit: budget)
            : resolvedPrompt
        let transcriptBudget = transcriptBudget(totalBudget: budget, systemPrompt: boundedPrompt)
        let truncated = Self.truncateMiddle(transcript, limit: transcriptBudget)
        return MessageAssembly(
            messages: [
                ChatMessage(role: .system, content: boundedPrompt),
                ChatMessage(role: .user, content: truncated),
            ],
            inputTruncated: promptWasTruncated || transcript.count > transcriptBudget
        )
    }

    private func buildTransformMessages(
        text: String,
        prompt: String,
        config: LLMProviderConfig
    ) -> MessageAssembly {
        let systemPrompt = Prompts.transform
        let instructionPrefix = "Transform the following text according to this instruction: "
        let separator = "\n\n---\n\n"
        let available = max(
            0,
            contextBudget(for: config) - systemPrompt.count - instructionPrefix.count - separator.count
        )
        let promptBudget = prompt.count <= available ? prompt.count : available / 2
        let boundedPrompt = Self.truncateMiddle(prompt, limit: promptBudget)
        let textBudget = max(0, available - boundedPrompt.count)
        let truncated = Self.truncateMiddle(text, limit: textBudget)
        return MessageAssembly(
            messages: [
                ChatMessage(role: .system, content: systemPrompt),
                ChatMessage(role: .user, content: "\(instructionPrefix)\(boundedPrompt)\(separator)\(truncated)"),
            ],
            inputTruncated: prompt.count > promptBudget || text.count > textBudget
        )
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

    /// True if `error` represents a drifted user environment rather than an
    /// app/provider failure: the local LLM stopped running, the configured
    /// model name no longer exists, a CLI tool is missing, or an API key is
    /// invalid. These should be tagged as `llm_provider_unavailable` so the
    /// `llm_*_failed` dashboards reflect failures actually worth
    /// investigating, not "your Ollama isn't running."
    private static func isProviderUnavailable(_ error: Error) -> Bool {
        guard let llmError = error as? LLMError else { return false }
        switch llmError {
        case .connectionFailed, .modelNotFound, .cliError, .authenticationFailed:
            return true
        case .notConfigured, .rateLimited, .contextTooLong, .formatterTruncated,
             .formatterEmptyResponse, .providerError, .streamingError, .invalidResponse:
            return false
        }
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
        userNotes: String?,
        history: [ChatMessage],
        config: LLMProviderConfig
    ) -> MessageAssembly {
        let budget = contextBudget(for: config)
        let systemPromptBuild = Self.buildChatSystemPrompt(
            transcript: transcript,
            userNotes: userNotes,
            question: question,
            budget: budget
        )
        let systemPrompt = systemPromptBuild.prompt

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
                let userMessage = Self.requestMessage(from: history[i - 1])
                let assistantMessage = Self.requestMessage(from: history[i])
                let turnChars = userMessage.content.count + assistantMessage.content.count
                if historyChars + turnChars > historyBudget { break }
                historyChars += turnChars
                keptTurns.insert([userMessage, assistantMessage], at: 0)
                i -= 1
            } else {
                let message = Self.requestMessage(from: history[end - 1])
                let turnChars = message.content.count
                if historyChars + turnChars > historyBudget { break }
                historyChars += turnChars
                keptTurns.insert([message], at: 0)
            }
        }
        let keptHistory = keptTurns.flatMap { $0 }
        messages.append(contentsOf: keptHistory)

        messages.append(ChatMessage(role: .user, content: question))
        return MessageAssembly(
            messages: messages,
            inputTruncated: systemPromptBuild.inputTruncated || keptHistory.count < history.count
        )
    }

    private static func requestMessage(from message: ChatMessage) -> ChatMessage {
        ChatMessage(role: message.role, content: message.modelContent)
    }

    private static func buildChatSystemPrompt(
        transcript: String,
        userNotes: String?,
        question: String,
        budget: Int
    ) -> ChatSystemPromptBuild {
        let trimmedNotes = userNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transcriptHeader = "\n\n---\nTranscript:\n"
        let notesHeader = "\n\n---\nUser's notes from the meeting (treat these as what the user thinks matters; the transcript is the source of truth for facts):\n"
        let historyReserve = min(8_000, max(0, budget / 10))
        let contextBudget = max(0, budget - Prompts.chat.count - question.count - historyReserve)

        let notesBlock: String
        let notesWasTruncated: Bool
        if trimmedNotes.isEmpty {
            notesBlock = ""
            notesWasTruncated = false
        } else {
            let notesTextBudget = max(0, min(trimmedNotes.count, contextBudget / 4))
            notesBlock = notesHeader + truncateMiddle(trimmedNotes, limit: notesTextBudget)
            notesWasTruncated = trimmedNotes.count > notesTextBudget
        }

        let transcriptBudget = max(0, contextBudget - notesBlock.count - transcriptHeader.count)
        let transcriptBlock = transcriptHeader + truncateMiddle(transcript, limit: transcriptBudget)
        let context = notesBlock + transcriptBlock
        let boundedContext = context.count > contextBudget
            ? truncateMiddle(context, limit: contextBudget)
            : context

        return ChatSystemPromptBuild(
            prompt: Prompts.chat + boundedContext,
            inputTruncated: notesWasTruncated || transcript.count > transcriptBudget || context.count > contextBudget
        )
    }

    /// Truncate text from the middle, keeping the head and tail within the limit.
    /// Snaps to word boundaries to avoid slicing multi-byte Unicode characters.
    internal static func truncateMiddle(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }

        let marker = "\n\n[... content truncated ...]\n\n"
        guard limit > marker.count else {
            return String(text.prefix(limit))
        }

        let contentBudget = limit - marker.count
        let headBudget = contentBudget / 2
        let tailBudget = contentBudget - headBudget

        let head = snapToWordBoundary(text, fromStart: true, budget: headBudget)
        let tail = snapToWordBoundary(text, fromStart: false, budget: tailBudget)

        return head + marker + tail
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
