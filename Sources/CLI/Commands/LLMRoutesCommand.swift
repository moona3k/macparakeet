import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMRoutesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "routes",
        abstract: "Inspect or configure shared app AI task routes without contacting a provider.",
        discussion: """
            Cleanup and analysis may override Default AI. Transforms always inherit Default AI.
            Changes use the app's preferences and Keychain; a running app may need to reload settings.
            API keys are shared by provider: supplying a replacement updates every route using that provider.
            Explicit --api-key/--api-key-env wins, then the saved provider key, then provider environment variables.
            The cli provider reuses the existing shared command configured in the app. --command may only
            repeat that command; this command never replaces it. Default AI is configured in the app.
            List output shows endpoint origins only, omitting credentials, paths, queries, and fragments.
            """,
        subcommands: [LLMRoutesListCommand.self, LLMRoutesSetCommand.self, LLMRoutesResetCommand.self]
    )
}

struct LLMRoutesListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List configured and inherited AI routes.")
    @Flag(name: .long, help: "Emit a structured JSON envelope.") var json = false

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            let routes = try listLLMRoutes(store: LLMConfigStore(defaults: macParakeetAppDefaults()))
            if json {
                try printJSON(LLMRoutesListResult(ok: true, routes: routes))
            } else {
                for route in routes { printLLMRoute(route) }
            }
        }
    }
}

struct LLMRoutesSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a cleanup or analysis override.")
    @Argument(help: "Task route: cleanup or analysis.") var task: String
    @OptionGroup var llm: LLMInlineOptions
    @Flag(name: .long, help: "Emit a structured JSON envelope.") var json = false

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            let defaults = macParakeetAppDefaults()
            let store = LLMConfigStore(defaults: defaults)
            try setLLMRoute(task, options: llm, store: store, cliStore: LocalCLIConfigStore(defaults: defaults))
            let route = try describeLLMRoute(task, store: store)
            if json { try printJSON(LLMRouteMutationResult(ok: true, route: route)) } else { printLLMRoute(route) }
        }
    }
}

struct LLMRoutesResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset", abstract: "Restore inheritance from Default AI; retain saved credentials.")
    @Argument(help: "Task route: cleanup or analysis.") var task: String
    @Flag(name: .long, help: "Emit a structured JSON envelope.") var json = false

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            let store = LLMConfigStore(defaults: macParakeetAppDefaults())
            try resetLLMRoute(task, store: store)
            let route = try describeLLMRoute(task, store: store)
            if json { try printJSON(LLMRouteMutationResult(ok: true, route: route)) } else { printLLMRoute(route) }
        }
    }
}

struct LLMRouteDescription: Encodable {
    let task: String
    let inherited: Bool
    let configured: Bool
    let provider: String?
    let model: String?
    let isLocal: Bool?
    let endpoint: String?
}

private struct LLMRoutesListResult: Encodable {
    let ok: Bool
    let routes: [LLMRouteDescription]
}

private struct LLMRouteMutationResult: Encodable {
    let ok: Bool
    let route: LLMRouteDescription
}

private func overridableLLMTask(_ task: String) throws -> LLMTaskGroup {
    guard let group = LLMTaskGroup(rawValue: task), group.allowsOverride else {
        throw ValidationError("Task route must be cleanup or analysis.")
    }
    return group
}

func setLLMRoute(
    _ task: String,
    options: LLMInlineOptions,
    store: any LLMConfigStoreProtocol,
    cliStore: LocalCLIConfigStore,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    let group = try overridableLLMTask(task)
    var options = options
    let provider = try options.providerID()
    if let model = options.model {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError("--model must not be empty") }
        options.model = trimmed
    }
    if provider == .localCLI {
        guard let existing = cliStore.load(), !existing.commandTemplate.isEmpty else {
            throw ValidationError("Configure the shared CLI command in the app before selecting the cli route.")
        }
        if let command = options.command,
            command.trimmingCharacters(in: .whitespacesAndNewlines) != existing.commandTemplate
        {
            throw ValidationError(
                "--command must match the existing shared CLI command. Change it in the app's AI settings.")
        }
        options.command = existing.commandTemplate
    } else if options.command != nil {
        throw ValidationError("--command is only supported for the cli provider.")
    }
    if options.apiKey == nil, options.apiKeyEnv == nil,
        provider != .appleIntelligence, provider != .localCLI
    {
        options.apiKey = try store.loadAPIKey(for: provider)
    }
    // Building the configuration does not execute the client. Suppress the inline
    // HTTP warning because it includes the raw URL, which may contain credentials.
    let config = try options.buildConfig(environment: environment, emitWarnings: false)
    try store.saveTaskOverride(config, for: group)
}

func resetLLMRoute(_ task: String, store: any LLMConfigStoreProtocol) throws {
    try store.saveTaskOverride(nil, for: overridableLLMTask(task))
}

func listLLMRoutes(store: any LLMConfigStoreProtocol) throws -> [LLMRouteDescription] {
    try (["default"] + LLMTaskGroup.allCases.map(\.rawValue)).map {
        try describeLLMRoute($0, store: store)
    }
}

private func describeLLMRoute(_ task: String, store: any LLMConfigStoreProtocol) throws -> LLMRouteDescription {
    let override = try LLMTaskGroup(rawValue: task).flatMap { try store.loadTaskOverride($0) }
    let config = try override ?? store.loadConfig()
    return LLMRouteDescription(
        task: task,
        inherited: task != "default" && override == nil,
        configured: config != nil,
        provider: config?.id.rawValue,
        model: config?.modelName,
        isLocal: config?.isLocal,
        endpoint: config.flatMap { endpointOrigin($0.baseURL) }
    )
}

private func endpointOrigin(_ url: URL) -> String? {
    guard let source = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    var origin = URLComponents()
    origin.scheme = source.scheme
    origin.host = source.host
    origin.port = source.port
    return origin.string
}

private func printLLMRoute(_ route: LLMRouteDescription) {
    let inheritance = route.inherited ? " (inherits default)" : ""
    if let provider = route.provider, let model = route.model {
        print("\(route.task): \(provider) / \(model)\(inheritance)")
    } else {
        print("\(route.task): unconfigured\(inheritance)")
    }
}
