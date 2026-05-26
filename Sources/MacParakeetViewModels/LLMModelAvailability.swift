import Foundation
import MacParakeetCore

enum LLMModelAvailability {
    static func supportsModelListing(_ providerID: LLMProviderID) -> Bool {
        switch providerID {
        case .anthropic, .openai, .openaiCompatible, .gemini, .openrouter, .ollama, .lmstudio:
            return true
        case .localCLI:
            return false
        }
    }

    static func pickerModels(for config: LLMProviderConfig, discoveredModels: [String]) -> [String] {
        let discovered = normalize(discoveredModels)
        let baseModels = discovered.isEmpty ? suggestedModels(for: config.id) : discovered
        return includingCurrentModel(config.modelName, in: baseModels)
    }

    static func settingsModels(for providerID: LLMProviderID, discoveredModels: [String]) -> [String] {
        let discovered = normalize(discoveredModels)
        return discovered.isEmpty ? suggestedModels(for: providerID) : discovered
    }

    static func normalize(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    /// Popular models for each provider. Used only as a fallback when live
    /// discovery is unavailable, or before a saved provider's list request returns.
    static func suggestedModels(for provider: LLMProviderID) -> [String] {
        switch provider {
        case .anthropic: return [
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "claude-haiku-4-5-20251001",
        ]
        case .openai: return [
            "gpt-5.4",
            "gpt-5.4-pro",
            "gpt-5.3-chat-latest",
            "gpt-5-mini",
            "gpt-5-nano",
            "gpt-4.1",
            "gpt-4.1-mini",
        ]
        case .openaiCompatible: return []
        case .gemini: return [
            "gemini-3.5-flash",
            "gemini-3.1-pro-preview",
            "gemini-3-flash-preview",
            "gemini-3.1-flash-lite-preview",
            "gemini-2.5-pro",
            "gemini-2.5-flash",
        ]
        case .openrouter: return [
            "anthropic/claude-opus-4-6",
            "anthropic/claude-sonnet-4-6",
            "anthropic/claude-haiku-4-5",
            "openai/gpt-5.4",
            "openai/gpt-5.4-pro",
            "openai/gpt-5-mini",
            "openai/gpt-5-nano",
            "openai/gpt-4.1",
            "openai/gpt-4.1-mini",
            "google/gemini-3.5-flash",
            "google/gemini-3.1-pro-preview",
            "google/gemini-3-flash-preview",
            "google/gemini-2.5-flash",
            "deepseek/deepseek-v3.2",
            "meta-llama/llama-4-scout",
            "qwen/qwen3.5-72b",
        ]
        case .ollama: return [
            "qwen3.5:4b",
            "qwen3.5:9b",
            "llama4:8b",
            "gemma3:4b",
            "deepseek-v3.2",
            "qwen3:8b",
            "mistral",
        ]
        case .lmstudio, .localCLI: return []
        }
    }

    private static func includingCurrentModel(_ modelName: String, in models: [String]) -> [String] {
        let current = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !models.contains(current) else { return models }
        return [current] + models
    }
}
