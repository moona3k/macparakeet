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
        let url = URL(fileURLWithPath: expandTilde(path))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Inline Options

/// Shared options for CLI commands that call an LLM provider directly (no Keychain).
struct LLMInlineOptions: ParsableArguments {
    @Option(name: .long, help: "Provider: anthropic, openai, openaiCompatible, gemini, openrouter, ollama, lmstudio, cli.")
    var provider: String

    @Option(name: .long, help: "API key literal. Prefer --api-key-env or provider env vars to avoid exposing secrets in process arguments.")
    var apiKey: String?

    @Option(name: .long, help: "Environment variable name containing the API key.")
    var apiKeyEnv: String?

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

    func buildExecutionContext(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> InlineLLMExecutionContext {
        let providerID = try providerID()

        let overrideURL: URL? = if let urlStr = baseURL {
            try validateBaseURL(urlStr)
        } else {
            nil
        }

        let client = RoutingLLMClient()

        var providerConfig: LLMProviderConfig
        var localCLIConfig: LocalCLIConfig?

        switch providerID {
        case .anthropic:
            let key = try requiredAPIKey(
                providerName: "Anthropic",
                defaultEnvNames: ["ANTHROPIC_API_KEY"],
                environment: environment
            )
            providerConfig = .anthropic(apiKey: key, model: model ?? "claude-sonnet-4-6", baseURL: overrideURL)
        case .openai:
            let key = try requiredAPIKey(
                providerName: "OpenAI",
                defaultEnvNames: ["OPENAI_API_KEY"],
                environment: environment
            )
            providerConfig = .openai(apiKey: key, model: model ?? "gpt-4.1", baseURL: overrideURL)
        case .openaiCompatible:
            guard let overrideURL else { throw ValidationError("--base-url is required for OpenAI-Compatible") }
            guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--model is required for OpenAI-Compatible")
            }
            providerConfig = .openaiCompatible(
                apiKey: try optionalAPIKey(defaultEnvNames: [], environment: environment),
                model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: overrideURL
            )
        case .gemini:
            let key = try requiredAPIKey(
                providerName: "Gemini",
                defaultEnvNames: ["GEMINI_API_KEY"],
                environment: environment
            )
            providerConfig = .gemini(apiKey: key, model: model ?? "gemini-2.5-flash", baseURL: overrideURL)
        case .openrouter:
            let key = try requiredAPIKey(
                providerName: "OpenRouter",
                defaultEnvNames: ["OPENROUTER_API_KEY"],
                environment: environment
            )
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

        if local && !providerConfig.isLocal {
            providerConfig = LLMProviderConfig(
                id: providerConfig.id,
                baseURL: providerConfig.baseURL,
                apiKey: providerConfig.apiKey,
                modelName: providerConfig.modelName,
                isLocal: true
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

    private func requiredAPIKey(
        providerName: String,
        defaultEnvNames: [String],
        environment: [String: String]
    ) throws -> String {
        if let key = try optionalAPIKey(defaultEnvNames: defaultEnvNames, environment: environment) {
            return key
        }
        let envHint = defaultEnvNames.isEmpty ? "" : ", --api-key-env, or \(defaultEnvNames.joined(separator: "/"))"
        throw ValidationError("--api-key\(envHint) is required for \(providerName)")
    }

    private func optionalAPIKey(defaultEnvNames: [String], environment: [String: String]) throws -> String? {
        if let apiKey {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ValidationError("--api-key must not be empty")
            }
            return key
        }

        if let apiKeyEnv {
            let envName = apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !envName.isEmpty else {
                throw ValidationError("--api-key-env must not be empty")
            }
            guard let key = environment[envName]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw ValidationError("Environment variable \(envName) is not set or is empty")
            }
            return key
        }

        for envName in defaultEnvNames {
            if let key = environment[envName]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return key
            }
        }

        return nil
    }

    func buildConfig(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LLMProviderConfig {
        try buildExecutionContext(environment: environment).context.providerConfig
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
