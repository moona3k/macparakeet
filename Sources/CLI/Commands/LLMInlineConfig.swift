import ArgumentParser
import Foundation
import MacParakeetCore

// MARK: - Shared Helpers

struct InlineLLMExecutionContext {
    let context: LLMExecutionContext
    let client: any LLMClientProtocol
}

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
    @Option(name: .long, help: "Provider: anthropic, openai, gemini, openrouter, ollama, localCLI.")
    var provider: String

    @Option(name: .long, help: "API key.")
    var apiKey: String?

    @Option(name: .long, help: "Model name (e.g. gpt-4o, claude-sonnet-4-20250514, gemini-2.0-flash).")
    var model: String?

    @Option(name: .long, help: "Base URL override (e.g. https://us.api.openai.com/v1).")
    var baseURL: String?

    @Option(name: .long, help: "CLI command for localCLI provider (e.g. 'claude -p').")
    var command: String?

    @Flag(name: .long, help: "Mark provider as local (smaller context budget).")
    var local: Bool = false

    private func providerID() throws -> LLMProviderID {
        guard let providerID = LLMProviderID(rawValue: provider) else {
            throw ValidationError("Unknown provider '\(provider)'. Options: anthropic, openai, gemini, openrouter, ollama, localCLI")
        }
        return providerID
    }

    func buildExecutionContext() throws -> InlineLLMExecutionContext {
        let providerID = try providerID()

        let overrideURL: URL? = if let urlStr = baseURL {
            try validateBaseURL(urlStr)
        } else {
            nil
        }

        switch providerID {
        case .anthropic:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Anthropic") }
            return InlineLLMExecutionContext(
                context: LLMExecutionContext(
                    providerConfig: .anthropic(apiKey: key, model: model ?? "claude-sonnet-4-6", baseURL: overrideURL)
                ),
                client: RoutingLLMClient()
            )
        case .openai:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenAI") }
            return InlineLLMExecutionContext(
                context: LLMExecutionContext(
                    providerConfig: .openai(apiKey: key, model: model ?? "gpt-4.1", baseURL: overrideURL)
                ),
                client: RoutingLLMClient()
            )
        case .gemini:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Gemini") }
            return InlineLLMExecutionContext(
                context: LLMExecutionContext(
                    providerConfig: .gemini(apiKey: key, model: model ?? "gemini-2.5-flash", baseURL: overrideURL)
                ),
                client: RoutingLLMClient()
            )
        case .openrouter:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenRouter") }
            return InlineLLMExecutionContext(
                context: LLMExecutionContext(
                    providerConfig: .openrouter(apiKey: key, model: model ?? "anthropic/claude-sonnet-4", baseURL: overrideURL)
                ),
                client: RoutingLLMClient()
            )
        case .ollama:
            return InlineLLMExecutionContext(
                context: LLMExecutionContext(
                    providerConfig: .ollama(model: model ?? "qwen3.5:4b", baseURL: overrideURL)
                ),
                client: RoutingLLMClient()
            )
        case .localCLI:
            guard let rawCommand = command,
                  !rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--command is required for localCLI provider (e.g. 'claude -p')")
            }
            let cliConfig = LocalCLIConfig(
                commandTemplate: rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return InlineLLMExecutionContext(
                context: LLMExecutionContext(
                    providerConfig: .localCLI(),
                    localCLIConfig: cliConfig
                ),
                client: RoutingLLMClient()
            )
        }
    }

    func buildConfig() throws -> LLMProviderConfig {
        try buildExecutionContext().context.providerConfig
    }
}
