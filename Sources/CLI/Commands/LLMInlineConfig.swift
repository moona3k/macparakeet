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
    @Option(name: .long, help: "Provider: anthropic, openai, openaiCompatible, gemini, openrouter, ollama, lmstudio, cli.")
    var provider: String

    @Option(name: .long, help: "API key.")
    var apiKey: String?

    @Option(name: .long, help: "Model name (e.g. gpt-4o, claude-sonnet-4-20250514, gemini-2.0-flash).")
    var model: String?

    @Option(name: .long, help: "Base URL override (e.g. https://us.api.openai.com/v1).")
    var baseURL: String?

    @Option(name: .long, help: "CLI command for cli provider (e.g. 'claude -p').")
    var command: String?

    @Flag(name: .long, help: "Mark provider as local (smaller context budget).")
    var local: Bool = false

    private func providerID() throws -> LLMProviderID {
        // Accept simple aliases for provider names used in docs and terminals.
        let normalized: String
        switch provider.lowercased() {
        case "cli":
            normalized = "localCLI"
        case "openaicompatible", "openai-compatible":
            normalized = "openaiCompatible"
        default:
            normalized = provider
        }
        guard let providerID = LLMProviderID(rawValue: normalized) else {
            throw ValidationError(
                "Unknown provider '\(provider)'. Options: anthropic, openai, openaiCompatible, gemini, openrouter, ollama, lmstudio, cli"
            )
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

        let client = RoutingLLMClient()

        let providerConfig: LLMProviderConfig
        var localCLIConfig: LocalCLIConfig?

        switch providerID {
        case .anthropic:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Anthropic") }
            providerConfig = .anthropic(apiKey: key, model: model ?? "claude-sonnet-4-6", baseURL: overrideURL)
        case .openai:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenAI") }
            providerConfig = .openai(apiKey: key, model: model ?? "gpt-4.1", baseURL: overrideURL)
        case .openaiCompatible:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenAI-Compatible") }
            guard let overrideURL else { throw ValidationError("--base-url is required for OpenAI-Compatible") }
            guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--model is required for OpenAI-Compatible")
            }
            providerConfig = .openaiCompatible(
                apiKey: key,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: overrideURL
            )
        case .gemini:
            guard let key = apiKey else { throw ValidationError("--api-key is required for Gemini") }
            providerConfig = .gemini(apiKey: key, model: model ?? "gemini-2.5-flash", baseURL: overrideURL)
        case .openrouter:
            guard let key = apiKey else { throw ValidationError("--api-key is required for OpenRouter") }
            providerConfig = .openrouter(apiKey: key, model: model ?? "anthropic/claude-sonnet-4", baseURL: overrideURL)
        case .ollama:
            providerConfig = .ollama(model: model ?? "qwen3.5:4b", baseURL: overrideURL)
        case .lmstudio:
            guard let rawModel = model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawModel.isEmpty else {
                throw ValidationError("--model is required for LM Studio")
            }
            providerConfig = .lmstudio(model: rawModel, baseURL: overrideURL)
        case .localCLI:
            guard let rawCommand = command,
                  !rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--command is required for cli provider (e.g. 'claude -p')")
            }
            providerConfig = .localCLI()
            localCLIConfig = LocalCLIConfig(
                commandTemplate: rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return InlineLLMExecutionContext(
            context: LLMExecutionContext(
                providerConfig: providerConfig,
                localCLIConfig: localCLIConfig
            ),
            client: client
        )
    }

    func buildConfig() throws -> LLMProviderConfig {
        try buildExecutionContext().context.providerConfig
    }
}
