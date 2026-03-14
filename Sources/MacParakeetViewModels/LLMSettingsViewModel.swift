import Foundation
import MacParakeetCore

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

    public var onConfigurationChanged: (() -> Void)?

    private var configStore: LLMConfigStoreProtocol?
    private var llmClient: LLMClientProtocol?

    public init() {}

    public func configure(
        configStore: LLMConfigStoreProtocol,
        llmClient: LLMClientProtocol
    ) {
        self.configStore = configStore
        self.llmClient = llmClient
        loadExistingConfig()
    }

    public func saveConfiguration() {
        guard let configStore else { return }
        do {
            let config = try buildConfig(from: draft)
            try configStore.saveConfig(config)
            saveState = .saved
            onConfigurationChanged?()
        } catch {
            saveState = .error(error.localizedDescription)
        }
    }

    public func testConnection() {
        guard let llmClient else { return }

        let snapshot = draft
        let config: LLMProviderConfig
        do {
            config = try buildConfig(from: snapshot)
        } catch {
            connectionTestState = .error(error.localizedDescription)
            return
        }

        connectionTestState = .testing
        Task {
            do {
                try await llmClient.testConnection(config: config)
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
        try? configStore.deleteConfig()
        let apiKey = draft.providerID.isLocal ? "" : ((try? configStore.loadAPIKey(for: draft.providerID)) ?? "")
        draft = .defaults(
            for: draft.providerID,
            apiKey: apiKey,
            defaultModelName: Self.defaultModelName(for: draft.providerID)
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
        let apiKey = providerID.isLocal ? "" : ((try? configStore?.loadAPIKey(for: providerID)) ?? "")
        let nextDraft = LLMSettingsDraft.defaults(
            for: providerID,
            apiKey: apiKey,
            defaultModelName: Self.defaultModelName(for: providerID)
        )
        updateDraft(nextDraft)
    }

    private func loadExistingConfig() {
        guard let configStore, let config = try? configStore.loadConfig() else { return }
        draft = .fromStoredConfig(
            config,
            suggestedModels: Self.suggestedModels(for: config.id),
            defaultModelName: Self.defaultModelName(for: config.id),
            defaultBaseURL: Self.defaultBaseURL(for: config.id)
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
        }
    }
}
