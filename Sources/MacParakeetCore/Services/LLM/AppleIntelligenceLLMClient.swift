import Foundation

/// On-device Apple Intelligence client. Foundation Models is isolated behind
/// `AppleIntelligenceGenerating` so Xcode 16.1 CI can compile without the
/// framework, and tests can inject a fake generator.
public final class AppleIntelligenceLLMClient: LLMClientProtocol, Sendable {
    private let generator: any AppleIntelligenceGenerating

    public convenience init() {
        self.init(generator: AppleIntelligenceRuntime.makeGenerator())
    }

    public init(generator: any AppleIntelligenceGenerating) {
        self.generator = generator
    }

    public func structuredOutputCapability(
        context: LLMExecutionContext
    ) -> LLMStructuredOutputCapability {
        .promptEmbeddedJSONSchema
    }

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let content = try await generate(
            messages: messages,
            context: context,
            options: options,
            onPartial: nil
        )
        return ChatCompletionResponse(
            content: content,
            model: context.providerConfig.modelName,
            effectiveInferenceSettings: options.effectiveInferenceSettings
        )
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.generate(
                        messages: messages,
                        context: context,
                        options: options,
                        onPartial: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        _ = try await generate(
            messages: [ChatMessage(role: .user, content: "Reply with OK.")],
            context: context,
            options: ChatCompletionOptions(maxTokens: 16),
            onPartial: nil
        )
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        try ensureProvider(context)
        let availability = generator.currentAvailability()
        guard availability.canGenerate else {
            throw LLMError.connectionFailed(availability.userMessage)
        }
        return [context.providerConfig.modelName]
    }

    private func generate(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        try ensureProvider(context)
        try options.validateInferenceSettings(for: context.providerConfig)
        try Task.checkCancellation()

        let availability = generator.currentAvailability()
        guard availability.canGenerate else {
            throw LLMError.connectionFailed(availability.userMessage)
        }

        let split = AppleIntelligencePromptBuilder.split(messages: messages)
        guard !split.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.invalidResponse
        }

        let content = try await generator.generate(
            request: AppleIntelligenceGenerationRequest(
                instructions: split.instructions,
                prompt: split.prompt,
                temperature: options.temperature,
                maximumResponseTokens: options.maxTokens
            ),
            onPartial: onPartial
        )
        // A generator can return after cancellation. Do not treat that text as success.
        try Task.checkCancellation()
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.invalidResponse
        }
        return content
    }

    private func ensureProvider(_ context: LLMExecutionContext) throws {
        guard context.providerConfig.id == .appleIntelligence else {
            throw LLMError.providerError(
                "AppleIntelligenceLLMClient received \(context.providerConfig.id.rawValue)."
            )
        }
    }
}
