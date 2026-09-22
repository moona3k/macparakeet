import Foundation

/// Chat Completions families whose sampling or thinking wire shape differs
/// from generic OpenAI. Detection is by canonical model ID so native labs,
/// OpenRouter prefixes (`moonshotai/kimi-k2.6`), and custom endpoints share
/// one sampling omit. Thinking objects stay on first-class lab providers.
enum ChatCompletionsModelFamily: Equatable, Sendable {
    case kimi
    case deepseek
    case qwen
    case glm
    case minimax
    case generic
}

/// Wire encoding for an explicit thinking-mode request. `omit` means the
/// adapter must not send a thinking field (provider default applies, or the
/// model rejects the field).
enum ChatCompletionsThinkingEncoding: Equatable, Sendable {
    case omit
    case thinkingType(String)
    case enableThinking(Bool)
    case llamaCpp(enableThinking: Bool, reasoningEffort: String?)
}

/// Shared Chat Completions request policy.
enum ChatCompletionsModelPolicy {
    static func canonicalModelID(_ model: String) -> String {
        OpenAIModelPolicy.canonicalModelID(model)
    }

    static func family(for model: String) -> ChatCompletionsModelFamily {
        let id = canonicalModelID(model)
        if isKimi(id) { return .kimi }
        if id.hasPrefix("deepseek-") { return .deepseek }
        if id.hasPrefix("glm-") { return .glm }
        if id.hasPrefix("minimax-") { return .minimax }
        if id.hasPrefix("qwen") { return .qwen }
        return .generic
    }

    /// Kimi K2.5+ / K3 fix temperature and `top_p`; any other value 400s.
    /// GPT-5 / o-series omission stays in `OpenAIModelPolicy`.
    static func shouldOmitSampling(model: String) -> Bool {
        OpenAIModelPolicy.shouldOmitSampling(model: model) || isKimi(canonicalModelID(model))
    }

    /// Prompt-settings thinking toggle. K2.7-code and K3 always think;
    /// an explicit `disabled` 400s.
    static func supportsThinkingToggle(model: String) -> Bool {
        let id = canonicalModelID(model)
        if kimiOmitsThinkingField(id) { return false }
        switch family(for: model) {
        case .kimi, .deepseek, .qwen, .glm, .minimax:
            return true
        case .generic:
            return false
        }
    }

    static func thinkingEncoding(
        provider: LLMProviderID,
        model: String,
        thinkingMode: PromptInferenceSettings.ThinkingMode,
        reasoningEffort: PromptInferenceSettings.ReasoningEffort?,
        usesPromptInferenceSettings: Bool
    ) -> ChatCompletionsThinkingEncoding {
        if provider == .lmstudio || provider == .openrouter {
            return .omit
        }
        if provider.isChinaLabCloud {
            return labThinkingEncoding(model: model, thinkingMode: thinkingMode)
        }

        let usesLlamaCppKwargs =
            provider == .openaiCompatible
            && usesPromptInferenceSettings
            && !OpenAIModelPolicy.requiresMaxCompletionTokens(model: model)
        guard usesLlamaCppKwargs else { return .omit }
        switch thinkingMode {
        case .providerDefault:
            return .omit
        case .enabled:
            return .llamaCpp(enableThinking: true, reasoningEffort: reasoningEffort?.rawValue)
        case .disabled:
            return .llamaCpp(enableThinking: false, reasoningEffort: nil)
        }
    }

    private static func labThinkingEncoding(
        model: String,
        thinkingMode: PromptInferenceSettings.ThinkingMode
    ) -> ChatCompletionsThinkingEncoding {
        let id = canonicalModelID(model)
        if kimiOmitsThinkingField(id) { return .omit }

        switch family(for: model) {
        case .generic:
            return .omit
        case .kimi, .deepseek, .glm:
            switch thinkingMode {
            case .providerDefault:
                return .omit
            case .enabled:
                return .thinkingType("enabled")
            case .disabled:
                return .thinkingType("disabled")
            }
        case .minimax:
            switch thinkingMode {
            case .providerDefault:
                return .omit
            case .enabled:
                return .thinkingType("adaptive")
            case .disabled:
                return .thinkingType("disabled")
            }
        case .qwen:
            switch thinkingMode {
            case .providerDefault:
                return .omit
            case .enabled:
                return .enableThinking(true)
            case .disabled:
                return .enableThinking(false)
            }
        }
    }

    private static func isKimi(_ id: String) -> Bool {
        id.hasPrefix("kimi-k2.5") || id.hasPrefix("kimi-k2.6") || id.hasPrefix("kimi-k2.7")
            || id.hasPrefix("kimi-k3")
    }

    private static func kimiOmitsThinkingField(_ id: String) -> Bool {
        id.hasPrefix("kimi-k2.7") || id.hasPrefix("kimi-k3")
    }
}
