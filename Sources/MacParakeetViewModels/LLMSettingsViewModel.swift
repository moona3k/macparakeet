import Foundation
import MacParakeetCore
import OSLog

@MainActor
@Observable
public final class LLMSettingsViewModel {
    public enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case error(String)
    }

    public enum SaveState: Equatable {
        case idle
        case saved
        case error(String)
    }

    public private(set) var draft = LLMSettingsDraft()
    public var connectionTestState: ConnectionTestState = .idle
    public var saveState: SaveState = .idle

    public var selectedProviderID: LLMProviderID {
        get { draft.providerID }
        set { applyProviderChange(to: newValue) }
    }

    public var apiKeyInput: String {
        get { draft.apiKeyInput }
        set {
            var nextDraft = draft
            nextDraft.apiKeyInput = newValue
            updateDraft(nextDraft)
        }
    }

    public var modelName: String {
        get { draft.suggestedModelName }
        set {
            var nextDraft = draft
            nextDraft.suggestedModelName = newValue
            updateDraft(nextDraft)
        }
    }

    public var baseURLOverride: String {
        get { draft.baseURLOverride }
        set {
            var nextDraft = draft
            nextDraft.baseURLOverride = newValue
            updateDraft(nextDraft)
        }
    }

    public var useCustomModel: Bool {
        get { draft.useCustomModel }
        set {
            var nextDraft = draft
            nextDraft.useCustomModel = newValue
            updateDraft(nextDraft)
        }
    }

    public var customModelName: String {
        get { draft.customModelName }
        set {
            var nextDraft = draft
            nextDraft.customModelName = newValue
            updateDraft(nextDraft)
        }
    }

    public var isConfigured: Bool {
        configStore != nil && (try? configStore?.loadConfig()) != nil
    }

    public var requiresAPIKey: Bool {
        draft.requiresAPIKey
    }

    public var availableModels: [String] {
        Self.suggestedModels(for: draft.providerID)
    }

    public var effectiveModelName: String {
        draft.effectiveModelName
    }

    public var canSave: Bool {
        draft.isValid
    }

    public var canTestConnection: Bool {
        draft.isValid
    }

    public var validationMessage: String? {
        draft.validationError?.localizedDescription
    }

    // Local CLI properties
    public var commandTemplate: String {
        get { draft.commandTemplate }
        set {
            var nextDraft = draft
            nextDraft.commandTemplate = newValue
            // Clear template picker when user manually edits the command
            if let template = nextDraft.selectedCLITemplate,
               newValue != template.defaultCommand {
                nextDraft.selectedCLITemplate = nil
            }
            updateDraft(nextDraft)
        }
    }

    public var selectedCLITemplate: LocalCLITemplate? {
        get { draft.selectedCLITemplate }
        set {
            var nextDraft = draft
            nextDraft.selectedCLITemplate = newValue
            if let template = newValue {
                nextDraft.commandTemplate = template.defaultCommand
                nextDraft.cliTimeoutSeconds = template.defaultConfig.timeoutSeconds
            }
            updateDraft(nextDraft)
        }
    }

    public var cliTimeoutSeconds: Double {
        get { draft.cliTimeoutSeconds }
        set {
            var nextDraft = draft
            nextDraft.cliTimeoutSeconds = max(LocalCLIConfig.minimumTimeout, newValue)
            updateDraft(nextDraft)
        }
    }

    public var onConfigurationChanged: (() -> Void)?

    private var configStore: LLMConfigStoreProtocol?
    private var llmClient: LLMClientProtocol?
    private var cliConfigStore: LocalCLIConfigStore?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "LLMSettingsViewModel")

    public init() {}

    public func configure(
        configStore: LLMConfigStoreProtocol,
        llmClient: LLMClientProtocol,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.configStore = configStore
        self.llmClient = llmClient
        self.cliConfigStore = cliConfigStore
        loadExistingConfig()
    }

    public func saveConfiguration() {
        guard let configStore else { return }
        do {
            let config = try buildConfig(from: draft)
            try configStore.saveConfig(config)

            // Save CLI config separately when using Local CLI
            if draft.providerID == .localCLI {
                let cliConfig = LocalCLIConfig(
                    commandTemplate: draft.trimmedCommandTemplate,
                    timeoutSeconds: draft.cliTimeoutSeconds
                )
                try cliConfigStore?.save(cliConfig)
            }

            saveState = .saved
            onConfigurationChanged?()
        } catch {
            saveState = .error(error.localizedDescription)
        }
    }

    public func testConnection() {
        guard let llmClient else { return }

        let snapshot = draft
        let context: LLMExecutionContext
        do {
            let config = try buildConfig(from: snapshot)
            context = LLMExecutionContext(
                providerConfig: config,
                localCLIConfig: snapshot.providerID == .localCLI ? LocalCLIConfig(
                    commandTemplate: snapshot.trimmedCommandTemplate,
                    timeoutSeconds: snapshot.cliTimeoutSeconds
                ) : nil
            )
        } catch {
            connectionTestState = .error(error.localizedDescription)
            return
        }

        connectionTestState = .testing
        Task {
            do {
                try await llmClient.testConnection(context: context)
                guard draft == snapshot else { return }
                connectionTestState = .success
            } catch {
                guard draft == snapshot else { return }
                connectionTestState = .error(error.localizedDescription)
            }
        }
    }

    public func clearConfiguration() {
        guard let configStore else { return }
        // Use the persisted provider to decide what to delete. The draft may
        // point at an unsaved provider switch in Settings.
        let storedProviderID = (try? configStore.loadConfig())?.id
        let preservedCLIConfig = draft.providerID == .localCLI && storedProviderID != .localCLI
            ? cliConfigStore?.load()
            : nil
        do {
            try configStore.deleteConfig()
        } catch {
            logger.error("Failed to delete LLM configuration error=\(error.localizedDescription, privacy: .public)")
        }
        if storedProviderID == .localCLI {
            cliConfigStore?.delete()
        }
        let apiKey = draft.providerID.requiresAPIKey ? ((try? configStore.loadAPIKey(for: draft.providerID)) ?? "") : ""
        draft = .defaults(
            for: draft.providerID,
            apiKey: apiKey,
            defaultModelName: Self.defaultModelName(for: draft.providerID),
            cliConfig: preservedCLIConfig
        )
        connectionTestState = .idle
        saveState = .idle
        onConfigurationChanged?()
    }

    // MARK: - Private

    private func updateDraft(_ newDraft: LLMSettingsDraft) {
        let didChange = draft != newDraft
        draft = newDraft
        if didChange {
            connectionTestState = .idle
            saveState = .idle
        }
    }

    private func applyProviderChange(to providerID: LLMProviderID) {
        guard draft.providerID != providerID else { return }
        let apiKey = providerID.requiresAPIKey ? ((try? configStore?.loadAPIKey(for: providerID)) ?? "") : ""
        let cliConfig = providerID == .localCLI ? cliConfigStore?.load() : nil
        let nextDraft = LLMSettingsDraft.defaults(
            for: providerID,
            apiKey: apiKey,
            defaultModelName: Self.defaultModelName(for: providerID),
            cliConfig: cliConfig
        )
        updateDraft(nextDraft)
    }

    private func loadExistingConfig() {
        guard let configStore, let config = try? configStore.loadConfig() else { return }
        let cliConfig = config.id == .localCLI ? cliConfigStore?.load() : nil
        draft = .fromStoredConfig(
            config,
            suggestedModels: Self.suggestedModels(for: config.id),
            defaultModelName: Self.defaultModelName(for: config.id),
            defaultBaseURL: Self.defaultBaseURL(for: config.id),
            cliConfig: cliConfig
        )
        connectionTestState = .idle
        saveState = .idle
    }

    private func buildConfig(from draft: LLMSettingsDraft) throws -> LLMProviderConfig {
        try draft.buildConfig(defaultBaseURL: Self.defaultBaseURL(for: draft.providerID))
    }

    /// Popular models for each provider. Empty means free-text input.
    public static func suggestedModels(for provider: LLMProviderID) -> [String] {
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
        case .gemini: return [
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
        case .localCLI: return []
        }
    }

    static func defaultModelName(for provider: LLMProviderID) -> String {
        suggestedModels(for: provider).first ?? ""
    }

    static func defaultBaseURL(for provider: LLMProviderID) -> String {
        switch provider {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .localCLI: return "http://localhost"
        }
    }
}
