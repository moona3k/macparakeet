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

    public enum ModelListState: Equatable {
        case idle
        case loading
        case error(String)
    }

    public private(set) var draft: LLMSettingsDraft
    public var connectionTestState: ConnectionTestState = .idle
    public var saveState: SaveState = .idle
    public private(set) var modelListState: ModelListState = .idle
    private var discoveredModels: [String] = []

    public var selectedProviderID: LLMProviderID? {
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

    public var baseURLPlaceholder: String {
        guard let providerID = draft.providerID else { return "https://..." }
        let fallback = providerID == .openaiCompatible ? "https://api.example.com/v1" : "https://..."
        let defaultURL = Self.defaultBaseURL(for: providerID)
        return defaultURL.isEmpty ? fallback : defaultURL
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

    public var supportsAPIKey: Bool {
        draft.supportsAPIKey
    }

    public var availableModels: [String] {
        guard let providerID = draft.providerID else { return [] }
        if providerID == .lmstudio {
            return discoveredModels
        }
        return Self.suggestedModels(for: providerID)
    }

    public var canRefreshModelList: Bool {
        draft.providerID == .lmstudio
    }

    public var canChooseModelFromList: Bool {
        !availableModels.isEmpty
    }

    public var isLoadingModelList: Bool {
        if case .loading = modelListState {
            return true
        }
        return false
    }

    public var modelListErrorMessage: String? {
        if case .error(let message) = modelListState {
            return message
        }
        return nil
    }

    public var effectiveModelName: String {
        draft.effectiveModelName
    }

    public var canSave: Bool {
        if draft.providerID == nil { return isConfigured }
        return draft.isValid
    }

    public var canTestConnection: Bool {
        draft.providerID != nil && draft.isValid
    }

    public var isLocalConfiguration: Bool {
        draft.isLocalConfiguration
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

    public var aiFormatterEnabled: Bool {
        get { draft.providerID != nil && draft.aiFormatterEnabled }
        set {
            var nextDraft = draft
            nextDraft.aiFormatterEnabled = canToggleAIFormatter ? newValue : false
            updateDraft(nextDraft)
            persistAIFormatterDraftIfNeeded()
        }
    }

    public var aiFormatterPrompt: String {
        get { draft.aiFormatterPrompt }
        set {
            var nextDraft = draft
            nextDraft.aiFormatterPrompt = newValue
            updateDraft(nextDraft)
            persistAIFormatterDraftIfNeeded()
        }
    }

    public var canToggleAIFormatter: Bool {
        draft.providerID != nil && draft.providerID == savedProviderID
    }

    public var aiFormatterStatusText: String {
        aiFormatterEnabled ? "Enabled" : "Disabled"
    }

    public var aiFormatterDisabledReason: String? {
        if draft.providerID == nil {
            return "Set an AI provider to enable the formatter."
        }
        if !isConfigured {
            return "Save your AI provider first. Formatter changes apply immediately after that."
        }
        if draft.providerID != savedProviderID {
            return "Save this provider first. Formatter changes apply immediately after that."
        }
        return nil
    }

    private var savedProviderID: LLMProviderID? {
        guard let configStore else { return nil }
        return (try? configStore.loadConfig())?.id
    }

    public var canResetAIFormatterPrompt: Bool {
        draft.aiFormatterPrompt != AIFormatter.defaultPromptTemplate
    }

    public var onConfigurationChanged: (() -> Void)?

    private var configStore: LLMConfigStoreProtocol?
    private var llmClient: LLMClientProtocol?
    private var cliConfigStore: LocalCLIConfigStore?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "LLMSettingsViewModel")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.draft = LLMSettingsDraft(
            aiFormatterEnabled: false,
            aiFormatterPrompt: Self.loadStoredAIFormatterPrompt(from: defaults)
        )
    }

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
        guard draft.providerID != nil else {
            clearConfiguration()
            saveState = .saved
            return
        }
        do {
            guard let config = try buildConfig(from: draft) else { return }
            try configStore.saveConfig(config)

            // Save CLI config separately when using Local CLI
            if draft.providerID == .localCLI {
                let cliConfig = LocalCLIConfig(
                    commandTemplate: draft.trimmedCommandTemplate,
                    timeoutSeconds: draft.cliTimeoutSeconds
                )
                try cliConfigStore?.save(cliConfig)
            }

            let normalizedFormatterPrompt = persistAIFormatterPreferences(from: draft)
            if draft.aiFormatterPrompt != normalizedFormatterPrompt || draft.aiFormatterEnabled != aiFormatterEnabled {
                var normalizedDraft = draft
                normalizedDraft.aiFormatterEnabled = aiFormatterEnabled
                normalizedDraft.aiFormatterPrompt = normalizedFormatterPrompt
                draft = normalizedDraft
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
            guard let config = try buildConfig(from: snapshot) else { return }
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
        let currentProvider = draft.providerID
        let apiKey: String
        if let currentProvider, currentProvider.supportsAPIKey {
            apiKey = (try? configStore.loadAPIKey(for: currentProvider)) ?? ""
        } else {
            apiKey = ""
        }
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set(AIFormatter.defaultPromptTemplate, forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        draft = .defaults(
            for: currentProvider,
            apiKey: apiKey,
            defaultModelName: currentProvider == .lmstudio
                ? discoveredModels.first ?? ""
                : currentProvider.map { Self.defaultModelName(for: $0) } ?? "",
            cliConfig: preservedCLIConfig,
            aiFormatterEnabled: false,
            aiFormatterPrompt: AIFormatter.defaultPromptTemplate
        )
        if currentProvider == .lmstudio {
            draft.useCustomModel = discoveredModels.isEmpty
        } else {
            resetDiscoveredModels()
        }
        connectionTestState = .idle
        saveState = .idle
        onConfigurationChanged?()
    }

    public func resetAIFormatterPrompt() {
        aiFormatterPrompt = AIFormatter.defaultPromptTemplate
    }

    public func refreshAvailableModels() {
        guard let llmClient, canRefreshModelList else { return }

        let snapshot = draft
        let context: LLMExecutionContext
        do {
            guard let builtContext = try buildModelListContext(from: snapshot) else { return }
            context = builtContext
        } catch {
            modelListState = .error(error.localizedDescription)
            return
        }

        modelListState = .loading
        Task {
            do {
                let models = normalizeDiscoveredModels(try await llmClient.listModels(context: context))
                guard shouldApplyModelListResult(for: snapshot) else { return }
                discoveredModels = models
                modelListState = .idle
                reconcileModelSelection(with: models, snapshot: snapshot)
            } catch {
                guard shouldApplyModelListResult(for: snapshot) else { return }
                discoveredModels = []
                modelListState = .error(error.localizedDescription)
            }
        }
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

    private func applyProviderChange(to providerID: LLMProviderID?) {
        guard draft.providerID != providerID else { return }
        let formatterPrompt = draft.aiFormatterPrompt
        let formatterEnabled = providerID == nil ? false : draft.aiFormatterEnabled
        guard let providerID else {
            resetDiscoveredModels()
            updateDraft(
                LLMSettingsDraft(
                    aiFormatterEnabled: false,
                    aiFormatterPrompt: formatterPrompt
                )
            )
            return
        }
        if providerID != .lmstudio {
            resetDiscoveredModels()
        }
        let apiKey = providerID.supportsAPIKey ? ((try? configStore?.loadAPIKey(for: providerID)) ?? "") : ""
        let cliConfig = providerID == .localCLI ? cliConfigStore?.load() : nil
        var nextDraft = LLMSettingsDraft.defaults(
            for: providerID,
            apiKey: apiKey,
            defaultModelName: Self.defaultModelName(for: providerID),
            cliConfig: cliConfig,
            aiFormatterEnabled: formatterEnabled,
            aiFormatterPrompt: formatterPrompt
        )
        // Auto-switch to custom model input when provider has no suggested models
        if Self.suggestedModels(for: providerID).isEmpty && providerID != .localCLI {
            nextDraft.useCustomModel = true
        }
        updateDraft(nextDraft)
        if providerID == .lmstudio {
            refreshAvailableModels()
        }
    }

    private func loadExistingConfig() {
        guard let configStore, let config = try? configStore.loadConfig() else {
            draft = LLMSettingsDraft(
                aiFormatterEnabled: false,
                aiFormatterPrompt: Self.loadStoredAIFormatterPrompt(from: defaults)
            )
            resetDiscoveredModels()
            connectionTestState = .idle
            saveState = .idle
            return
        }
        let cliConfig = config.id == .localCLI ? cliConfigStore?.load() : nil
        draft = .fromStoredConfig(
            config,
            suggestedModels: Self.suggestedModels(for: config.id),
            defaultModelName: Self.defaultModelName(for: config.id),
            defaultBaseURL: Self.defaultBaseURL(for: config.id),
            cliConfig: cliConfig,
            aiFormatterEnabled: Self.loadStoredAIFormatterEnabled(from: defaults),
            aiFormatterPrompt: Self.loadStoredAIFormatterPrompt(from: defaults)
        )
        if config.id == .lmstudio {
            refreshAvailableModels()
        } else {
            resetDiscoveredModels()
        }
        connectionTestState = .idle
        saveState = .idle
    }

    private func buildConfig(from draft: LLMSettingsDraft) throws -> LLMProviderConfig? {
        guard let providerID = draft.providerID else { return nil }
        return try draft.buildConfig(defaultBaseURL: Self.defaultBaseURL(for: providerID))
    }

    private func buildModelListContext(from draft: LLMSettingsDraft) throws -> LLMExecutionContext? {
        guard let providerID = draft.providerID, providerID == .lmstudio else { return nil }
        guard let config = try draft.buildConfig(
            defaultBaseURL: Self.defaultBaseURL(for: providerID),
            allowMissingModelName: true
        ) else {
            return nil
        }
        return LLMExecutionContext(providerConfig: config)
    }

    private func shouldApplyModelListResult(for snapshot: LLMSettingsDraft) -> Bool {
        draft.providerID == snapshot.providerID
            && draft.trimmedAPIKey == snapshot.trimmedAPIKey
            && draft.trimmedBaseURLOverride == snapshot.trimmedBaseURLOverride
    }

    private func normalizeDiscoveredModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func reconcileModelSelection(with models: [String], snapshot: LLMSettingsDraft) {
        guard !models.isEmpty else { return }
        guard draft.providerID == snapshot.providerID else { return }
        guard draft.useCustomModel == snapshot.useCustomModel,
              draft.customModelName == snapshot.customModelName,
              draft.suggestedModelName == snapshot.suggestedModelName else {
            return
        }

        var nextDraft = draft
        let currentSuggestedModel = draft.suggestedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentCustomModel = draft.trimmedCustomModelName

        if draft.useCustomModel {
            guard currentCustomModel.isEmpty || models.contains(currentCustomModel) else { return }
            nextDraft.useCustomModel = false
            nextDraft.suggestedModelName = currentCustomModel.isEmpty ? models[0] : currentCustomModel
            nextDraft.customModelName = ""
            updateDraft(nextDraft)
            return
        }

        guard currentSuggestedModel.isEmpty || !models.contains(currentSuggestedModel) else { return }
        nextDraft.suggestedModelName = models[0]
        updateDraft(nextDraft)
    }

    private func resetDiscoveredModels() {
        discoveredModels = []
        modelListState = .idle
    }

    private func persistAIFormatterPreferences(from draft: LLMSettingsDraft) -> String {
        let enabled = draft.providerID != nil && draft.aiFormatterEnabled
        let normalizedPrompt = draft.normalizedAIFormatterPrompt
        defaults.set(enabled, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set(normalizedPrompt, forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        return normalizedPrompt
    }

    private func persistAIFormatterDraftIfNeeded() {
        guard canToggleAIFormatter else { return }
        let normalizedPrompt = persistAIFormatterPreferences(from: draft)
        if draft.aiFormatterPrompt != normalizedPrompt {
            var normalizedDraft = draft
            normalizedDraft.aiFormatterPrompt = normalizedPrompt
            updateDraft(normalizedDraft)
        }
    }

    private static func loadStoredAIFormatterEnabled(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool ?? false
    }

    private static func loadStoredAIFormatterPrompt(from defaults: UserDefaults) -> String {
        AIFormatter.normalizedPromptTemplate(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey) ?? ""
        )
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
        case .openaiCompatible: return []
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
        case .lmstudio: return []
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
        case .openaiCompatible: return ""
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .localCLI: return "http://localhost"
        }
    }
}
