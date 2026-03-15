import ArgumentParser
import Foundation
import MacParakeetCore

// MARK: - Shared Helpers

func validateBaseURL(_ value: String) throws -> URL {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil else {
        throw ValidationError("--base-url must be an absolute http:// or https:// URL")
    }
    return url
}

func readInput(_ path: String) throws -> String {
    if path == "-" {
        var lines: [String] = []
        while let line = readLine(strippingNewline: false) {
            lines.append(line)
        }
        return lines.joined()
    } else {
        let url = URL(fileURLWithPath: path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class InlineLLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    private let config: LLMProviderConfig

    init(config: LLMProviderConfig) {
        self.config = config
    }

    func loadConfig() throws -> LLMProviderConfig? { config }
    func saveConfig(_ config: LLMProviderConfig) throws { throw KeyValueStoreError.unsupported }
    func deleteConfig() throws { throw KeyValueStoreError.unsupported }
    func loadAPIKey() throws -> String? { config.apiKey }
    func loadAPIKey(for provider: LLMProviderID) throws -> String? { config.id == provider ? config.apiKey : nil }
    func saveAPIKey(_ key: String) throws { throw KeyValueStoreError.unsupported }
    func deleteAPIKey() throws { throw KeyValueStoreError.unsupported }
    func updateModelName(_ modelName: String) throws { throw KeyValueStoreError.unsupported }
}

// MARK: - Inline Options

/// Shared options for CLI commands that call an LLM provider directly (no Keychain).
struct LLMInlineOptions: ParsableArguments {
    @Option(name: .long, help: "Provider: anthropic, openai, gemini, openrouter, ollama.")
    var provider: String

    @Option(name: .long, help: "API key.")
    var apiKey: String?

    @Option(name: .long, help: "Model name (e.g. gpt-4o, claude-sonnet-4-20250514, gemini-2.0-flash).")
    var model: String?

    @Option(name: .long, help: "Base URL override (e.g. https://us.api.openai.com/v1).")
    var baseURL: String?

    @Flag(name: .long, help: "Mark provider as local (smaller context budget).")
    var local: Bool = false

    func buildConfig() throws -> LLMProviderConfig {
        guard let providerID = LLMProviderID(rawValue: provider) else {
            throw ValidationError("Unknown provider '\(provider)'. Options: anthropic, openai, gemini, openrouter, ollama")
        }

        let overrideURL: URL? = if let urlStr = baseURL {
            try validateBaseURL(urlStr)
        } else {
            nil
        }

        switch providerID {
        case .anthropic:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Anthropic") }
            return .anthropic(apiKey: key, model: model ?? "claude-sonnet-4-6", baseURL: overrideURL)
        case .openai:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenAI") }
            return .openai(apiKey: key, model: model ?? "gpt-4.1", baseURL: overrideURL)
        case .gemini:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Gemini") }
            return .gemini(apiKey: key, model: model ?? "gemini-2.5-flash", baseURL: overrideURL)
        case .openrouter:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenRouter") }
            return .openrouter(apiKey: key, model: model ?? "anthropic/claude-sonnet-4", baseURL: overrideURL)
        case .ollama:
            return .ollama(model: model ?? "qwen3.5:4b", baseURL: overrideURL)
        }
    }
}
