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

    public enum AISetupStatus: Equatable {
        case setUpNeeded
        case ready(displayName: String)
        case cannotConnect(displayName: String, message: String)
    }

    public struct AIFormatterProfileDraft: Identifiable, Equatable, Sendable {
        private let draftID: UUID
        public var profileID: UUID?
        public var name: String
        public var isEnabled: Bool
        public var targetKind: AIFormatterProfileTargetKind
        public var bundleIdentifier: String
        public var appDisplayName: String
        public var appCategory: TelemetryAppCategory
        public var promptTemplate: String
        public var origin: AIFormatterProfileOrigin
        public var sortOrder: Int
        public var createdAt: Date

        public var id: UUID {
            profileID ?? draftID
        }

        public init(
            profileID: UUID? = nil,
            name: String,
            isEnabled: Bool = true,
            targetKind: AIFormatterProfileTargetKind,
            bundleIdentifier: String = "",
            appDisplayName: String = "",
            appCategory: TelemetryAppCategory = .messaging,
            promptTemplate: String,
            origin: AIFormatterProfileOrigin = .custom,
            sortOrder: Int = 0,
            createdAt: Date = Date(),
            draftID: UUID = UUID()
        ) {
            self.draftID = draftID
            self.profileID = profileID
            self.name = name
            self.isEnabled = isEnabled
            self.targetKind = targetKind
            self.bundleIdentifier = bundleIdentifier
            self.appDisplayName = appDisplayName
            self.appCategory = appCategory
            self.promptTemplate = promptTemplate
            self.origin = origin
            self.sortOrder = sortOrder
            self.createdAt = createdAt
        }

        public init(profile: AIFormatterProfile) {
            self.init(
                profileID: profile.id,
                name: profile.name,
                isEnabled: profile.isEnabled,
                targetKind: profile.targetKind,
                bundleIdentifier: profile.bundleIdentifier ?? "",
                appDisplayName: profile.appDisplayName ?? "",
                appCategory: profile.appCategory ?? .messaging,
                promptTemplate: profile.promptTemplate,
                origin: profile.origin,
                sortOrder: profile.sortOrder,
                createdAt: profile.createdAt
            )
        }

        public var validationMessage: String? {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Name is required."
            }
            if targetKind == .bundle,
               bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Bundle ID is required for app profiles."
            }
            if promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Prompt template is required."
            }
            return nil
        }

        public var canSave: Bool {
            validationMessage == nil
        }

        func makeProfile(now: Date = Date()) -> AIFormatterProfile {
            AIFormatterProfile(
                id: profileID ?? UUID(),
                name: name,
                isEnabled: isEnabled,
                targetKind: targetKind,
                bundleIdentifier: targetKind == .bundle ? bundleIdentifier : nil,
                appDisplayName: targetKind == .bundle ? appDisplayName : nil,
                appCategory: targetKind == .category ? appCategory : nil,
                promptTemplate: promptTemplate,
                origin: origin,
                sortOrder: sortOrder,
                createdAt: createdAt,
                updatedAt: now
            )
        }
    }

    public private(set) var draft: LLMSettingsDraft
    public var connectionTestState: ConnectionTestState = .idle
    public var saveState: SaveState = .idle
    public private(set) var modelListState: ModelListState = .idle
    public private(set) var aiFormatterProfiles: [AIFormatterProfile] = []
    public var aiFormatterProfileDraft: AIFormatterProfileDraft?
    public var aiFormatterProfileError: String?
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

    public var apiKeyPlaceholder: String {
        switch draft.providerID {
        case .lmstudio:
            return "LM Studio token"
        case .anthropic:
            return "sk-ant-..."
        case .gemini:
            return "Gemini API key"
        case .openrouter:
            return "sk-or-..."
        case .openaiCompatible:
            return "Optional API key"
        case .openai:
            return "sk-..."
        case .ollama, .localCLI, nil:
            return ""
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

    public var setupStatus: AISetupStatus {
        if case .error(let message) = connectionTestState {
            let displayName = draftAIOptionDisplayName ?? savedAIOptionDisplayName ?? "AI"
            return .cannotConnect(displayName: displayName, message: message)
        }
        if isConfigured {
            let displayName = savedAIOptionDisplayName ?? draftAIOptionDisplayName ?? "AI"
            return .ready(displayName: displayName)
        }
        return .setUpNeeded
    }

    public var hasUnsavedChanges: Bool {
        draftConfigurationSnapshot() != savedConfigurationSnapshot()
    }

    public var connectionSuccessMessage: String {
        hasUnsavedChanges ? "Connected. Save to use this AI option." : "Connected"
    }

    public var requiresAPIKey: Bool {
        draft.requiresAPIKey
    }

    public var supportsAPIKey: Bool {
        draft.supportsAPIKey
    }

    public var availableModels: [String] {
        guard let providerID = draft.providerID else { return [] }
        if Self.usesDiscoveredModelList(providerID) {
            return LLMModelAvailability.settingsModels(
                for: providerID,
                discoveredModels: discoveredModels
            )
        }
        return Self.suggestedModels(for: providerID)
    }

    public var canRefreshModelList: Bool {
        draft.providerID.map(Self.usesDiscoveredModelList) ?? false
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

    public var discoveredModelCount: Int {
        discoveredModels.count
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
        isAIFormatterAvailable
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

    /// Whether the AI Formatter also runs on live dictation. Transcript and
    /// meeting formatter availability follows the saved provider config;
    /// dictation is the latency-sensitive opt-in path. The value persists
    /// immediately through the injected `defaults` store. Default `false` keeps
    /// live dictation low-latency unless the user opts in. See issue #408.
    public var aiFormatterEnabledForDictation: Bool {
        didSet {
            guard aiFormatterEnabledForDictation != oldValue else { return }
            defaults.set(
                aiFormatterEnabledForDictation,
                forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey
            )
        }
    }

    public var transcriptAIContextMode: TranscriptAIContextMode {
        didSet {
            guard transcriptAIContextMode != oldValue else { return }
            defaults.set(
                transcriptAIContextMode.rawValue,
                forKey: UserDefaultsAppRuntimePreferences.transcriptAIContextModeKey
            )
        }
    }

    public var isAIFormatterAvailable: Bool {
        draft.providerID != nil && draft.providerID == savedProviderID
    }

    public var aiFormatterPromptModeText: String {
        draft.normalizedAIFormatterPrompt == AIFormatter.defaultPromptTemplate
            ? "Default prompt"
            : "Custom prompt"
    }

    public var aiFormatterUnavailableReason: String? {
        if draft.providerID == nil {
            return "Set up AI to enable the formatter."
        }
        if !isConfigured {
            return "Save your AI setup first."
        }
        if draft.providerID != savedProviderID {
            return "Save this AI option first."
        }
        return nil
    }

    private var savedProviderID: LLMProviderID? {
        guard let configStore else { return nil }
        return (try? configStore.loadConfig())?.id
    }

    private var savedAIOptionDisplayName: String? {
        guard let configStore, let config = try? configStore.loadConfig() else { return nil }
        if config.id == .localCLI {
            return cliConfigStore
                .flatMap { $0.load() }
                .map { LocalCLITemplate.displayName(for: $0.commandTemplate) }
                ?? config.id.displayName
        }
        return config.id.displayName
    }

    private var draftAIOptionDisplayName: String? {
        guard let providerID = draft.providerID else { return nil }
        if providerID == .localCLI {
            return LocalCLITemplate.displayName(for: draft.trimmedCommandTemplate)
        }
        return providerID.displayName
    }

    public var canResetAIFormatterPrompt: Bool {
        draft.aiFormatterPrompt != AIFormatter.defaultPromptTemplate
    }

    public var canManageAIFormatterProfiles: Bool {
        aiFormatterProfileRepo != nil
    }

    public var onConfigurationChanged: (() -> Void)?

    private var configStore: LLMConfigStoreProtocol?
    private var llmClient: LLMClientProtocol?
    private var cliConfigStore: LocalCLIConfigStore?
    private var aiFormatterProfileRepo: AIFormatterProfileRepositoryProtocol?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "LLMSettingsViewModel")

    private enum ConfigurationSnapshot: Equatable {
        case none
        case provider(
            id: LLMProviderID,
            baseURL: String,
            modelName: String,
            apiKey: String?,
            localCLIConfig: LocalCLIConfig?
        )
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.aiFormatterEnabledForDictation = Self.loadStoredAIFormatterEnabledForDictation(from: defaults)
        self.transcriptAIContextMode = TranscriptAIContextMode.current(defaults: defaults)
        self.draft = LLMSettingsDraft(
            aiFormatterPrompt: Self.loadStoredAIFormatterPrompt(from: defaults)
        )
    }

    public func configure(
        configStore: LLMConfigStoreProtocol,
        llmClient: LLMClientProtocol,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore(),
        aiFormatterProfileRepo: AIFormatterProfileRepositoryProtocol? = nil
    ) {
        self.configStore = configStore
        self.llmClient = llmClient
        self.cliConfigStore = cliConfigStore
        self.aiFormatterProfileRepo = aiFormatterProfileRepo
        loadExistingConfig()
        loadAIFormatterProfiles()
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

            let persistedPrompt = persistAIFormatterPreferences(from: draft)
            if draft.aiFormatterPrompt != persistedPrompt {
                var normalizedDraft = draft
                normalizedDraft.aiFormatterPrompt = persistedPrompt
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
        defaults.removeObject(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set(AIFormatter.defaultPromptTemplate, forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        // Restore the dictation routing preference to its default so a config
        // clear returns the formatter to a fully predictable state.
        aiFormatterEnabledForDictation = false
        draft = .defaults(
            for: currentProvider,
            apiKey: apiKey,
            defaultModelName: defaultModelNameAfterClearing(currentProvider),
            cliConfig: preservedCLIConfig,
            aiFormatterPrompt: AIFormatter.defaultPromptTemplate
        )
        if currentProvider == .lmstudio {
            draft.useCustomModel = discoveredModels.isEmpty
        } else if currentProvider == .ollama {
            draft.useCustomModel = false
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

    public func loadAIFormatterProfiles() {
        guard let aiFormatterProfileRepo else {
            aiFormatterProfiles = []
            aiFormatterProfileError = nil
            return
        }
        do {
            aiFormatterProfiles = try aiFormatterProfileRepo.fetchAll()
            aiFormatterProfileError = nil
        } catch {
            aiFormatterProfileError = error.localizedDescription
        }
    }

    public func startCreatingAIFormatterProfile(targetKind: AIFormatterProfileTargetKind) {
        let nextSortOrder = (aiFormatterProfiles.map(\.sortOrder).max() ?? -1) + 1
        let defaultCategory = TelemetryAppCategory.messaging
        let promptTemplate: String
        let name: String
        if targetKind == .category,
           let categoryDefault = AIFormatterSmartDefaults.categoryDefault(for: defaultCategory) {
            name = Self.aiFormatterProfileCategoryName(defaultCategory)
            promptTemplate = categoryDefault.promptTemplate
        } else {
            name = "New app profile"
            promptTemplate = draft.normalizedAIFormatterPrompt
        }

        aiFormatterProfileDraft = AIFormatterProfileDraft(
            name: name,
            targetKind: targetKind,
            appCategory: defaultCategory,
            promptTemplate: promptTemplate,
            sortOrder: nextSortOrder
        )
        aiFormatterProfileError = nil
    }

    public func applyAIFormatterProfileDraftCategory(_ category: TelemetryAppCategory) {
        if aiFormatterProfileDraft == nil {
            startCreatingAIFormatterProfile(targetKind: .category)
        }

        guard var draft = aiFormatterProfileDraft else { return }
        let previousCategory = draft.appCategory
        let previousSmartDefault = AIFormatterSmartDefaults.categoryDefault(for: previousCategory)
        let normalizedPrompt = AIFormatter.normalizedPromptTemplate(draft.promptTemplate)
        let shouldUseSmartDefaultPrompt = isAIFormatterAutoPrompt(
            normalizedPrompt,
            previousCategoryDefault: previousSmartDefault
        )
        let currentName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousAppDisplayName = AppPromptContext.normalizedDisplayName(draft.appDisplayName)
        let previousBundleIdentifier = AppPromptContext.normalizedBundleIdentifier(draft.bundleIdentifier)
        let shouldReplaceName = currentName.isEmpty
            || currentName == "New app profile"
            || currentName == "New category profile"
            || currentName == Self.aiFormatterProfileCategoryName(previousCategory)
            || previousAppDisplayName.map { currentName == $0 } == true
            || previousBundleIdentifier.map { currentName == $0 } == true

        draft.targetKind = .category
        draft.appCategory = category
        if shouldReplaceName {
            draft.name = Self.aiFormatterProfileCategoryName(category)
        }
        if shouldUseSmartDefaultPrompt,
           let categoryDefault = AIFormatterSmartDefaults.categoryDefault(for: category) {
            draft.promptTemplate = categoryDefault.promptTemplate
        }
        aiFormatterProfileDraft = draft
        aiFormatterProfileError = nil
    }

    public func applyAIFormatterProfileDraftTargetKind(_ targetKind: AIFormatterProfileTargetKind) {
        if aiFormatterProfileDraft == nil {
            startCreatingAIFormatterProfile(targetKind: targetKind)
            return
        }

        switch targetKind {
        case .category:
            applyAIFormatterProfileDraftCategory(aiFormatterProfileDraft?.appCategory ?? .messaging)
        case .bundle:
            guard var draft = aiFormatterProfileDraft else { return }
            if AppPromptContext.normalizedBundleIdentifier(draft.bundleIdentifier) != nil {
                applyAIFormatterProfileDraftApp(
                    bundleIdentifier: draft.bundleIdentifier,
                    displayName: draft.appDisplayName
                )
                return
            }

            let previousCategory = draft.appCategory
            let previousSmartDefault = AIFormatterSmartDefaults.categoryDefault(for: previousCategory)
            let normalizedPrompt = AIFormatter.normalizedPromptTemplate(draft.promptTemplate)
            let currentName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldReplaceName = currentName.isEmpty
                || currentName == "New category profile"
                || currentName == Self.aiFormatterProfileCategoryName(previousCategory)

            draft.targetKind = .bundle
            if shouldReplaceName {
                draft.name = "New app profile"
            }
            if isAIFormatterAutoPrompt(normalizedPrompt, previousCategoryDefault: previousSmartDefault) {
                draft.promptTemplate = self.draft.normalizedAIFormatterPrompt
            }
            aiFormatterProfileDraft = draft
            aiFormatterProfileError = nil
        }
    }

    public func applyAIFormatterProfileDraftApp(
        bundleIdentifier: String?,
        displayName: String?
    ) {
        guard let normalizedBundleIdentifier = AppPromptContext.normalizedBundleIdentifier(bundleIdentifier) else {
            aiFormatterProfileError = "Bundle ID is required for app profiles."
            return
        }

        if aiFormatterProfileDraft == nil {
            startCreatingAIFormatterProfile(targetKind: .bundle)
        }

        guard var draft = aiFormatterProfileDraft else { return }
        let normalizedDisplayName = AppPromptContext.normalizedDisplayName(displayName)
        let previousSmartDefault = AIFormatterSmartDefaults.categoryDefault(for: draft.appCategory)
        let normalizedPrompt = AIFormatter.normalizedPromptTemplate(draft.promptTemplate)
        let appCategory = TelemetryAppCategory(bundleIdentifier: normalizedBundleIdentifier)
        let currentName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousAppDisplayName = AppPromptContext.normalizedDisplayName(draft.appDisplayName)
        let previousBundleIdentifier = AppPromptContext.normalizedBundleIdentifier(draft.bundleIdentifier)
        let shouldReplaceName = currentName.isEmpty
            || currentName == "New app profile"
            || currentName == "New category profile"
            || currentName == Self.aiFormatterProfileCategoryName(draft.appCategory)
            || previousAppDisplayName.map { currentName == $0 } == true
            || previousBundleIdentifier.map { currentName == $0 } == true
        let shouldUseSmartDefaultPrompt = isAIFormatterAutoPrompt(
            normalizedPrompt,
            previousCategoryDefault: previousSmartDefault
        )

        draft.targetKind = .bundle
        draft.bundleIdentifier = normalizedBundleIdentifier
        draft.appDisplayName = normalizedDisplayName ?? ""
        draft.appCategory = appCategory
        if shouldReplaceName {
            draft.name = normalizedDisplayName ?? normalizedBundleIdentifier
        }
        if shouldUseSmartDefaultPrompt,
           let categoryDefault = AIFormatterSmartDefaults.categoryDefault(for: appCategory) {
            draft.promptTemplate = categoryDefault.promptTemplate
        } else if shouldUseSmartDefaultPrompt {
            draft.promptTemplate = self.draft.normalizedAIFormatterPrompt
        }
        aiFormatterProfileDraft = draft
        aiFormatterProfileError = nil
    }

    public func aiFormatterPromptPreview(
        for context: AppPromptContext?,
        including draft: AIFormatterProfileDraft? = nil
    ) -> AIFormatterPromptResolution {
        var profiles = aiFormatterProfiles
        if let draft, draft.canSave {
            let draftProfile = draft.makeProfile()
            profiles.removeAll { $0.id == draftProfile.id }
            profiles.append(draftProfile)
        }

        return AIFormatterProfileMatcher.resolve(
            profiles: profiles,
            context: context,
            globalPromptTemplate: self.draft.normalizedAIFormatterPrompt
        )
    }

    public func editAIFormatterProfile(_ profile: AIFormatterProfile) {
        aiFormatterProfileDraft = AIFormatterProfileDraft(profile: profile)
        aiFormatterProfileError = nil
    }

    public func updateAIFormatterProfileDraft<Value>(
        _ keyPath: WritableKeyPath<AIFormatterProfileDraft, Value>,
        to value: Value
    ) {
        guard var draft = aiFormatterProfileDraft else { return }
        draft[keyPath: keyPath] = value
        aiFormatterProfileDraft = draft
        aiFormatterProfileError = nil
    }

    private func isAIFormatterAutoPrompt(
        _ normalizedPrompt: String,
        previousCategoryDefault: AIFormatterSmartDefaults.CategoryDefault?
    ) -> Bool {
        if let previousCategoryDefault,
           normalizedPrompt == AIFormatter.normalizedPromptTemplate(previousCategoryDefault.promptTemplate) {
            return true
        }
        return normalizedPrompt == draft.normalizedAIFormatterPrompt
            || normalizedPrompt == AIFormatter.defaultPromptTemplate
    }

    @discardableResult
    public func saveAIFormatterProfileDraft() -> Bool {
        guard let aiFormatterProfileRepo else {
            aiFormatterProfileError = "Formatter profiles are not available."
            return false
        }
        guard let draft = aiFormatterProfileDraft else { return false }
        if let validationMessage = draft.validationMessage {
            aiFormatterProfileError = validationMessage
            return false
        }
        do {
            try aiFormatterProfileRepo.save(draft.makeProfile())
            aiFormatterProfileDraft = nil
            loadAIFormatterProfiles()
            return true
        } catch {
            aiFormatterProfileError = error.localizedDescription
            return false
        }
    }

    public func cancelAIFormatterProfileEdit() {
        aiFormatterProfileDraft = nil
        aiFormatterProfileError = nil
    }

    public func setAIFormatterProfile(_ profile: AIFormatterProfile, enabled: Bool) {
        guard let aiFormatterProfileRepo else { return }
        var copy = profile
        copy.isEnabled = enabled
        do {
            try aiFormatterProfileRepo.save(copy)
            loadAIFormatterProfiles()
        } catch {
            aiFormatterProfileError = error.localizedDescription
        }
    }

    public func deleteAIFormatterProfile(_ profile: AIFormatterProfile) {
        guard let aiFormatterProfileRepo else { return }
        do {
            _ = try aiFormatterProfileRepo.delete(id: profile.id)
            if aiFormatterProfileDraft?.profileID == profile.id {
                aiFormatterProfileDraft = nil
            }
            loadAIFormatterProfiles()
        } catch {
            aiFormatterProfileError = error.localizedDescription
        }
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
                let models = LLMModelAvailability.normalize(try await llmClient.listModels(context: context))
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
        guard let providerID else {
            resetDiscoveredModels()
            updateDraft(
                LLMSettingsDraft(
                    aiFormatterPrompt: formatterPrompt
                )
            )
            return
        }
        resetDiscoveredModels()
        let apiKey = providerID.supportsAPIKey ? ((try? configStore?.loadAPIKey(for: providerID)) ?? "") : ""
        let cliConfig = providerID == .localCLI ? cliConfigStore?.load() : nil
        var nextDraft = LLMSettingsDraft.defaults(
            for: providerID,
            apiKey: apiKey,
            defaultModelName: Self.defaultModelName(for: providerID),
            cliConfig: cliConfig,
            aiFormatterPrompt: formatterPrompt
        )
        // Auto-switch to custom model input when provider has no fallback list.
        if Self.suggestedModels(for: providerID).isEmpty && providerID != .localCLI {
            nextDraft.useCustomModel = true
        }
        updateDraft(nextDraft)
        if canBuildModelListContext(from: draft) {
            refreshAvailableModels()
        }
    }

    private func loadExistingConfig() {
        guard let configStore, let config = try? configStore.loadConfig() else {
            draft = LLMSettingsDraft(
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
            aiFormatterPrompt: Self.loadStoredAIFormatterPrompt(from: defaults)
        )
        if Self.usesDiscoveredModelList(config.id) {
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
        guard let providerID = draft.providerID, Self.usesDiscoveredModelList(providerID) else { return nil }
        guard let config = try draft.buildConfig(
            defaultBaseURL: Self.defaultBaseURL(for: providerID),
            allowMissingModelName: true
        ) else {
            return nil
        }
        return LLMExecutionContext(providerConfig: config)
    }

    private func canBuildModelListContext(from draft: LLMSettingsDraft) -> Bool {
        (try? buildModelListContext(from: draft)) != nil
    }

    private func shouldApplyModelListResult(for snapshot: LLMSettingsDraft) -> Bool {
        draft.providerID == snapshot.providerID
            && draft.trimmedAPIKey == snapshot.trimmedAPIKey
            && draft.trimmedBaseURLOverride == snapshot.trimmedBaseURLOverride
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
        nextDraft.suggestedModelName = preferredModel(from: models, providerID: snapshot.providerID) ?? models[0]
        updateDraft(nextDraft)
    }

    private func preferredModel(from models: [String], providerID: LLMProviderID?) -> String? {
        guard let providerID else { return nil }
        return Self.suggestedModels(for: providerID).first { models.contains($0) }
    }

    private func resetDiscoveredModels() {
        discoveredModels = []
        modelListState = .idle
    }

    private func defaultModelNameAfterClearing(_ providerID: LLMProviderID?) -> String {
        guard let providerID else { return "" }
        if providerID == .lmstudio {
            return discoveredModels.first ?? ""
        }
        if providerID == .ollama {
            return discoveredModels.first ?? Self.defaultModelName(for: providerID)
        }
        return Self.defaultModelName(for: providerID)
    }

    private func draftConfigurationSnapshot() -> ConfigurationSnapshot {
        guard let providerID = draft.providerID else { return .none }

        if providerID == .localCLI {
            return .provider(
                id: providerID,
                baseURL: Self.defaultBaseURL(for: providerID),
                modelName: "cli",
                apiKey: nil,
                localCLIConfig: LocalCLIConfig(
                    commandTemplate: draft.trimmedCommandTemplate,
                    timeoutSeconds: draft.cliTimeoutSeconds
                )
            )
        }

        return .provider(
            id: providerID,
            baseURL: draftBaseURL(for: providerID),
            modelName: draft.effectiveModelName,
            apiKey: providerID.supportsAPIKey ? draft.trimmedAPIKey : nil,
            localCLIConfig: nil
        )
    }

    private func savedConfigurationSnapshot() -> ConfigurationSnapshot {
        guard let configStore, let config = try? configStore.loadConfig() else { return .none }
        return .provider(
            id: config.id,
            baseURL: config.baseURL.absoluteString,
            modelName: config.modelName,
            apiKey: config.id.supportsAPIKey ? (config.apiKey ?? "") : nil,
            localCLIConfig: config.id == .localCLI ? cliConfigStore?.load() : nil
        )
    }

    private func draftBaseURL(for providerID: LLMProviderID) -> String {
        let override = draft.trimmedBaseURLOverride
        guard !override.isEmpty else {
            return Self.defaultBaseURL(for: providerID)
        }
        return URL(string: override)?.absoluteString ?? override
    }

    private nonisolated static func usesDiscoveredModelList(_ providerID: LLMProviderID) -> Bool {
        providerID.supportsModelListing
    }

    private func persistAIFormatterPreferences(from draft: LLMSettingsDraft) -> String {
        let enabled = draft.providerID != nil
        let normalizedPrompt = draft.normalizedAIFormatterPrompt
        defaults.set(enabled, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set(normalizedPrompt, forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        if defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) == nil {
            defaults.set(
                aiFormatterEnabledForDictation,
                forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey
            )
        }
        return normalizedPrompt
    }

    private func persistAIFormatterDraftIfNeeded() {
        guard isAIFormatterAvailable else { return }
        let persistedPrompt = persistAIFormatterPreferences(from: draft)
        if draft.aiFormatterPrompt != persistedPrompt {
            var normalizedDraft = draft
            normalizedDraft.aiFormatterPrompt = persistedPrompt
            updateDraft(normalizedDraft)
        }
    }

    private static func loadStoredAIFormatterEnabledForDictation(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool ?? false
    }

    private static func loadStoredAIFormatterPrompt(from defaults: UserDefaults) -> String {
        AIFormatter.normalizedPromptTemplate(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey) ?? ""
        )
    }

    private static func aiFormatterProfileCategoryName(_ category: TelemetryAppCategory) -> String {
        switch category {
        case .messaging: return "Messaging"
        case .email: return "Email"
        case .browser: return "Browser"
        case .notes: return "Notes"
        case .docs: return "Documents"
        case .code: return "Code"
        case .terminal: return "Terminal"
        case .other: return "Other"
        }
    }

    public static func suggestedModels(for provider: LLMProviderID) -> [String] {
        provider.fallbackModels
    }

    static func defaultModelName(for provider: LLMProviderID) -> String {
        provider.defaultModelName
    }

    static func defaultBaseURL(for provider: LLMProviderID) -> String {
        provider.defaultBaseURL
    }
}
