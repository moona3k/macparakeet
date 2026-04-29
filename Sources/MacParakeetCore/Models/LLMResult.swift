import Foundation

// MARK: - Public Result Envelope
//
// `LLMResult` is the public, JSON-stable shape returned by the
// `*Detailed` variants on `LLMService` and emitted on stdout when the
// CLI is invoked with `--json`. Internal wire types (`ChatCompletionResponse`,
// `TokenUsage`) stay concerned with provider parsing; this type is the
// contract for downstream consumers.

/// Structured result envelope for LLM operations.
///
/// Token field names match OpenAI's convention (`promptTokens`/
/// `completionTokens`/`totalTokens`) so agent authors building on top of
/// existing OpenAI/Anthropic SDK shapes don't have to remap.
///
/// `stopReason` is intentionally pass-through — each provider's native
/// vocabulary (`end_turn`, `length`, `STOP`, `done_reason`, etc.) is
/// surfaced verbatim. Agents that want a normalized taxonomy can map
/// downstream.
public struct LLMResult: Sendable, Codable, Equatable {
    public let output: String
    public let provider: String
    public let model: String
    public let usage: LLMUsage?
    public let stopReason: String?
    public let latencyMs: Int

    public init(
        output: String,
        provider: String,
        model: String,
        usage: LLMUsage? = nil,
        stopReason: String? = nil,
        latencyMs: Int
    ) {
        self.output = output
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.latencyMs = latencyMs
    }
}

/// Token usage. All fields optional because:
/// - `localCLI` provider has no concept of tokens.
/// - Some `openaiCompatible` servers return responses without a usage block.
/// - Some providers (Ollama) report only one of prompt/completion counts in
///   certain configurations.
public struct LLMUsage: Sendable, Codable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

// MARK: - Internal Conversion

extension LLMUsage {
    /// Build an `LLMUsage` from the internal wire-shaped `TokenUsage`.
    /// Computes `totalTokens` when both halves are present.
    init(_ tokenUsage: TokenUsage) {
        self.init(
            promptTokens: tokenUsage.promptTokens,
            completionTokens: tokenUsage.completionTokens,
            totalTokens: tokenUsage.promptTokens + tokenUsage.completionTokens
        )
    }
}

extension LLMResult {
    /// Build an `LLMResult` from a non-streaming `ChatCompletionResponse`,
    /// stamping the provider id and measured latency the caller captured.
    init(
        response: ChatCompletionResponse,
        provider: LLMProviderID,
        latencyMs: Int
    ) {
        self.init(
            output: response.content,
            provider: provider.rawValue,
            model: response.model,
            usage: response.usage.map(LLMUsage.init),
            stopReason: response.finishReason,
            latencyMs: latencyMs
        )
    }
}
