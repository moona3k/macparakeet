import Foundation

public enum LLMTaskGroup: String, Sendable, Codable, CaseIterable {
    case cleanup
    case analysis
    case transform

    public var allowsOverride: Bool {
        self != .transform
    }
}

public struct LLMExecutionContext: Sendable, Equatable {
    public let providerConfig: LLMProviderConfig
    public let localCLIConfig: LocalCLIConfig?

    public init(providerConfig: LLMProviderConfig, localCLIConfig: LocalCLIConfig? = nil) {
        self.providerConfig = providerConfig
        self.localCLIConfig = localCLIConfig
    }
}

public protocol LLMExecutionContextResolving: Sendable {
    func resolveContext() throws -> LLMExecutionContext?
    func resolveContext(for task: LLMTaskGroup) throws -> LLMExecutionContext?
}

extension LLMExecutionContextResolving {
    public func resolveContext(for task: LLMTaskGroup) throws -> LLMExecutionContext? {
        try resolveContext()
    }
}

public struct StaticLLMExecutionContextResolver: LLMExecutionContextResolving, Sendable {
    private let context: LLMExecutionContext?

    public init(context: LLMExecutionContext?) {
        self.context = context
    }

    public func resolveContext() throws -> LLMExecutionContext? {
        context
    }
}

public final class StoredLLMExecutionContextResolver: LLMExecutionContextResolving, @unchecked Sendable {
    private let configStore: LLMConfigStoreProtocol
    private let cliConfigStore: LocalCLIConfigStore

    public init(
        configStore: LLMConfigStoreProtocol = LLMConfigStore(),
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.configStore = configStore
        self.cliConfigStore = cliConfigStore
    }

    public func resolveContext() throws -> LLMExecutionContext? {
        try makeContext(from: configStore.loadConfig())
    }

    public func resolveContext(for task: LLMTaskGroup) throws -> LLMExecutionContext? {
        try makeContext(from: configStore.loadConfig(for: task))
    }

    private func makeContext(from providerConfig: LLMProviderConfig?) throws -> LLMExecutionContext? {
        guard let providerConfig else { return nil }

        let localCLIConfig: LocalCLIConfig?
        if providerConfig.id == .localCLI {
            localCLIConfig = cliConfigStore.load()
        } else {
            localCLIConfig = nil
        }

        return LLMExecutionContext(
            providerConfig: providerConfig,
            localCLIConfig: localCLIConfig
        )
    }
}
