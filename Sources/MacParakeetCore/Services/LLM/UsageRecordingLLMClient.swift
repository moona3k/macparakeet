import Foundation

/// Wraps the real AI client and records one usage event per completed
/// request, so every feature (summary, chat, translation, cleanup,
/// transforms) is counted in one place. Failed and cancelled requests are
/// not counted.
public final class UsageRecordingLLMClient: LLMClientProtocol, Sendable {
    private let base: LLMClientProtocol
    private let ledger: UsageLedger

    public init(base: LLMClientProtocol, ledger: UsageLedger = .shared) {
        self.base = base
        self.ledger = ledger
    }

    public var supportsInProcessLocalLLM: Bool { base.supportsInProcessLocalLLM }

    public func structuredOutputCapability(context: LLMExecutionContext) -> LLMStructuredOutputCapability {
        base.structuredOutputCapability(context: context)
    }

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let response = try await base.chatCompletion(messages: messages, context: context, options: options)
        record(
            context: context,
            model: response.model,
            promptTokens: response.usage?.promptTokens,
            completionTokens: response.usage?.completionTokens,
            promptCharacters: Self.characters(in: messages),
            completionCharacters: response.content.count
        )
        return response
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        let stream = base.chatCompletionStream(messages: messages, context: context, options: options)
        let promptCharacters = Self.characters(in: messages)
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                var completionCharacters = 0
                do {
                    for try await token in stream {
                        completionCharacters += token.count
                        continuation.yield(token)
                    }
                    // Plain text streams carry no token counts.
                    record(
                        context: context, model: nil, promptTokens: nil, completionTokens: nil,
                        promptCharacters: promptCharacters, completionCharacters: completionCharacters)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func chatCompletionDetailedStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let stream = base.chatCompletionDetailedStream(messages: messages, context: context, options: options)
        let promptCharacters = Self.characters(in: messages)
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                var completionCharacters = 0
                var terminal: LLMStreamTerminal?
                do {
                    for try await event in stream {
                        switch event {
                        case .text(let text): completionCharacters += text.count
                        case .completed(let value): terminal = value
                        }
                        continuation.yield(event)
                    }
                    record(
                        context: context,
                        model: terminal?.model,
                        promptTokens: terminal?.usage?.promptTokens,
                        completionTokens: terminal?.usage?.completionTokens,
                        promptCharacters: promptCharacters,
                        completionCharacters: completionCharacters)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        try await base.testConnection(context: context)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        try await base.listModels(context: context)
    }

    public func withInProcessLocalModelRemoval(_ operation: @Sendable () async throws -> Void) async throws {
        try await base.withInProcessLocalModelRemoval(operation)
    }

    private func record(
        context: LLMExecutionContext,
        model: String?,
        promptTokens: Int?,
        completionTokens: Int?,
        promptCharacters: Int,
        completionCharacters: Int
    ) {
        let config = context.providerConfig
        let reported = promptTokens != nil && completionTokens != nil
        let resolvedModel = model.flatMap { $0.isEmpty ? nil : $0 } ?? config.modelName
        ledger.record(
            UsageEvent(
                kind: .llm,
                provider: config.id.rawValue,
                model: resolvedModel.isEmpty ? "unknown" : resolvedModel,
                isLocal: config.isLocal,
                promptTokens: promptTokens ?? UsageLedger.estimatedTokens(forCharacters: promptCharacters),
                completionTokens: completionTokens
                    ?? UsageLedger.estimatedTokens(forCharacters: completionCharacters),
                tokensEstimated: !reported
            ))
    }

    private static func characters(in messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count }
    }
}
