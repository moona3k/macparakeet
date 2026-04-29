import Foundation

public struct LLMExecutionContext: Sendable, Equatable {
    public let providerConfig: LLMProviderConfig
    public let localCLIConfig: LocalCLIConfig?
    public let localFormattingModelConfig: LocalFormattingModelConfig?

    public init(
        providerConfig: LLMProviderConfig,
        localCLIConfig: LocalCLIConfig? = nil,
        localFormattingModelConfig: LocalFormattingModelConfig? = nil
    ) {
        self.providerConfig = providerConfig
        self.localCLIConfig = localCLIConfig
        self.localFormattingModelConfig = localFormattingModelConfig
    }
}

public protocol LLMExecutionContextResolving: Sendable {
    func resolveContext() throws -> LLMExecutionContext?
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
    private let formattingModelConfigStore: LocalFormattingModelConfigStore

    public init(
        configStore: LLMConfigStoreProtocol = LLMConfigStore(),
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore(),
        formattingModelConfigStore: LocalFormattingModelConfigStore = LocalFormattingModelConfigStore()
    ) {
        self.configStore = configStore
        self.cliConfigStore = cliConfigStore
        self.formattingModelConfigStore = formattingModelConfigStore
    }

    public func resolveContext() throws -> LLMExecutionContext? {
        guard let providerConfig = try configStore.loadConfig() else {
            return nil
        }

        let localCLIConfig: LocalCLIConfig?
        if providerConfig.id == .localCLI {
            localCLIConfig = cliConfigStore.load()
        } else {
            localCLIConfig = nil
        }

        let formattingModelConfig: LocalFormattingModelConfig?
        if providerConfig.id == .localFormattingModel {
            formattingModelConfig = formattingModelConfigStore.load() ?? LocalFormattingModelConfig()
        } else {
            formattingModelConfig = nil
        }

        return LLMExecutionContext(
            providerConfig: providerConfig,
            localCLIConfig: localCLIConfig,
            localFormattingModelConfig: formattingModelConfig
        )
    }
}
