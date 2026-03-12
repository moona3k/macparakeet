import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Configure or clear the LLM provider."
    )

    @Option(name: .long, help: "Provider: anthropic, openai, gemini, ollama, lmstudio, custom.")
    var provider: String?

    @Option(name: .long, help: "API key (stored in Keychain, not on disk).")
    var apiKey: String?

    @Option(name: .long, help: "Model name (e.g. gpt-4o, claude-sonnet-4-20250514, llama3.2).")
    var model: String?

    @Option(name: .long, help: "Base URL (required for custom provider, optional for others).")
    var baseURL: String?

    @Flag(name: .long, help: "Mark custom provider as local (uses smaller context budget).")
    var local: Bool = false

    @Flag(name: .long, help: "Clear the current provider configuration.")
    var clear: Bool = false

    func run() async throws {
        let store = LLMConfigStore()

        if clear {
            try store.deleteConfig()
            print("LLM provider configuration cleared.")
            return
        }

        guard let providerName = provider else {
            throw ValidationError("--provider is required. Options: anthropic, openai, gemini, ollama, lmstudio, custom")
        }

        guard let providerID = LLMProviderID(rawValue: providerName) else {
            throw ValidationError("Unknown provider '\(providerName)'. Options: anthropic, openai, gemini, ollama, lmstudio, custom")
        }

        let config: LLMProviderConfig
        switch providerID {
        case .anthropic:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Anthropic") }
            config = .anthropic(apiKey: key, model: model ?? "claude-sonnet-4-20250514")
        case .openai:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenAI") }
            config = .openai(apiKey: key, model: model ?? "gpt-4o")
        case .gemini:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Gemini") }
            config = .gemini(apiKey: key, model: model ?? "gemini-2.0-flash")
        case .ollama:
            config = .ollama(model: model ?? "llama3.2")
        case .lmstudio:
            guard let modelName = model else { throw ValidationError("--model is required for LM Studio") }
            config = .lmstudio(model: modelName, apiKey: apiKey)
        case .custom:
            guard let urlStr = baseURL, let url = URL(string: urlStr) else {
                throw ValidationError("--base-url is required for custom provider")
            }
            guard let modelName = model else { throw ValidationError("--model is required for custom provider") }
            config = .custom(baseURL: url, model: modelName, apiKey: apiKey, isLocal: local)
        }

        try store.saveConfig(config)
        print("LLM provider configured: \(config.id.displayName) (\(config.modelName))")
    }
}
