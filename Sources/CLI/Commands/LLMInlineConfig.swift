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

// MARK: - Inline Options

/// Shared options for CLI commands that call an LLM provider directly (no Keychain).
struct LLMInlineOptions: ParsableArguments {
    @Option(name: .long, help: "Provider: anthropic, openai, gemini, ollama, lmstudio, custom.")
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
            throw ValidationError("Unknown provider '\(provider)'. Options: anthropic, openai, gemini, ollama, lmstudio, custom")
        }

        let overrideURL: URL? = if let urlStr = baseURL {
            try validateBaseURL(urlStr)
        } else {
            nil
        }

        switch providerID {
        case .anthropic:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Anthropic") }
            return .anthropic(apiKey: key, model: model ?? "claude-sonnet-4-20250514", baseURL: overrideURL)
        case .openai:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenAI") }
            return .openai(apiKey: key, model: model ?? "gpt-4o", baseURL: overrideURL)
        case .gemini:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Gemini") }
            return .gemini(apiKey: key, model: model ?? "gemini-2.0-flash", baseURL: overrideURL)
        case .ollama:
            return .ollama(model: model ?? "llama3.2")
        case .lmstudio:
            guard let modelName = model else { throw ValidationError("--model is required for LM Studio") }
            return .lmstudio(model: modelName, apiKey: apiKey)
        case .custom:
            guard let url = overrideURL else { throw ValidationError("--base-url is required for custom provider") }
            guard let modelName = model else { throw ValidationError("--model is required for custom provider") }
            return .custom(baseURL: url, model: modelName, apiKey: apiKey, isLocal: local)
        }
    }
}
