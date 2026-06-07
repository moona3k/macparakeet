import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LLMSettingsViewModelTests: XCTestCase {
    var viewModel: LLMSettingsViewModel!
    var mockConfigStore: MockLLMConfigStore!
    var mockClient: MockLLMClient!
    var defaults: UserDefaults!
    var defaultsSuiteName: String!

    override func setUp() {
        defaultsSuiteName = "test.llmsettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        viewModel = LLMSettingsViewModel(defaults: defaults)
        mockConfigStore = MockLLMConfigStore()
        mockClient = MockLLMClient()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        viewModel = nil
        mockConfigStore = nil
        mockClient = nil
    }

    // MARK: - Defaults

    func testDefaultValuesAfterInit() {
        XCTAssertNil(viewModel.selectedProviderID)
        XCTAssertEqual(viewModel.apiKeyInput, "")
        XCTAssertEqual(viewModel.modelName, "")
        XCTAssertEqual(viewModel.baseURLOverride, "")
        XCTAssertEqual(viewModel.connectionTestState, .idle)
        XCTAssertFalse(viewModel.isConfigured)
        XCTAssertFalse(viewModel.requiresAPIKey)
        XCTAssertEqual(viewModel.setupStatus, .setUpNeeded)
        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertEqual(viewModel.aiFormatterPrompt, AIFormatter.defaultPromptTemplate)
        XCTAssertEqual(viewModel.aiFormatterPromptModeText, "Default prompt")
        XCTAssertEqual(viewModel.transcriptAIContextMode, .richTranscript)
    }

    // MARK: - AI Formatter: dictation routing toggle (#408)

    func testAIFormatterEnabledForDictationDefaultsToFalse() {
        XCTAssertFalse(viewModel.aiFormatterEnabledForDictation)
    }

    func testAIFormatterEnabledForDictationPersistsThroughInjectedDefaults() {
        let key = UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey

        viewModel.aiFormatterEnabledForDictation = true

        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
        XCTAssertTrue(LLMSettingsViewModel(defaults: defaults).aiFormatterEnabledForDictation)
    }

    func testAIFormatterEnabledForDictationLoadsStoredValueOnInit() {
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey)
        let reloaded = LLMSettingsViewModel(defaults: defaults)
        XCTAssertTrue(reloaded.aiFormatterEnabledForDictation)
    }

    func testTranscriptAIContextModePersistsThroughInjectedDefaults() {
        let key = UserDefaultsAppRuntimePreferences.transcriptAIContextModeKey

        viewModel.transcriptAIContextMode = .plainTranscript

        XCTAssertEqual(defaults.string(forKey: key), TranscriptAIContextMode.plainTranscript.rawValue)
        XCTAssertEqual(LLMSettingsViewModel(defaults: defaults).transcriptAIContextMode, .plainTranscript)
    }

    func testClearConfigurationRestoresDictationRoutingDefault() {
        mockConfigStore.config = .lmstudio(model: "local-model")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.aiFormatterEnabledForDictation = true

        viewModel.clearConfiguration()

        XCTAssertFalse(viewModel.aiFormatterEnabledForDictation)
        XCTAssertEqual(
            defaults.object(
                forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey
            ) as? Bool,
            false
        )
    }

    func testSetupStatusReadyUsesSavedProviderDisplayName() {
        mockConfigStore.config = .lmstudio(model: "local-model")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertEqual(viewModel.setupStatus, .ready(displayName: "LM Studio"))
    }

    func testSetupStatusCannotConnectUsesConnectionError() {
        mockConfigStore.config = .ollama(model: "qwen3.5:4b")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.connectionTestState = .error("Connection failed")

        XCTAssertEqual(
            viewModel.setupStatus,
            .cannotConnect(displayName: "Ollama", message: "Connection failed")
        )
    }

    func testSetupStatusCannotConnectUsesDraftProviderDisplayName() {
        mockConfigStore.config = .lmstudio(model: "local-model")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .ollama
        viewModel.connectionTestState = .error("Connection failed")

        XCTAssertEqual(
            viewModel.setupStatus,
            .cannotConnect(displayName: "Ollama", message: "Connection failed")
        )
    }

    // MARK: - Provider Change

    func testProviderChangeUpdatesModelName() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .anthropic
        XCTAssertEqual(viewModel.modelName, "claude-sonnet-4-6")

        viewModel.selectedProviderID = .gemini
        XCTAssertEqual(viewModel.modelName, "gemini-3.5-flash")

        viewModel.selectedProviderID = .ollama
        XCTAssertEqual(viewModel.modelName, "qwen3.5:4b")
    }

    func testOllamaDoesNotRequireAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .ollama
        XCTAssertFalse(viewModel.requiresAPIKey)
    }

    func testLMStudioDoesNotRequireAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .lmstudio
        XCTAssertFalse(viewModel.requiresAPIKey)
        XCTAssertTrue(viewModel.supportsAPIKey)
    }

    func testCloudProviderRequiresAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        XCTAssertTrue(viewModel.requiresAPIKey)
    }

    func testAPIKeyPlaceholderIsProviderSpecific() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .lmstudio
        XCTAssertEqual(viewModel.apiKeyPlaceholder, "LM Studio token")

        viewModel.selectedProviderID = .anthropic
        XCTAssertEqual(viewModel.apiKeyPlaceholder, "sk-ant-...")

        viewModel.selectedProviderID = .openrouter
        XCTAssertEqual(viewModel.apiKeyPlaceholder, "sk-or-...")

        viewModel.selectedProviderID = .gemini
        XCTAssertEqual(viewModel.apiKeyPlaceholder, "Gemini API key")

        viewModel.selectedProviderID = .openaiCompatible
        XCTAssertEqual(viewModel.apiKeyPlaceholder, "Optional API key")
    }

    func testOpenAICompatibleProviderStartsInCustomModelMode() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openaiCompatible

        XCTAssertFalse(viewModel.requiresAPIKey)
        XCTAssertTrue(viewModel.supportsAPIKey)
        XCTAssertTrue(viewModel.useCustomModel)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
    }

    // MARK: - Save

    func testSavePersistsToStore() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test-123"
        viewModel.modelName = "gpt-4o-mini"

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.id, .openai)
        XCTAssertEqual(saved?.apiKey, "sk-test-123")
        XCTAssertEqual(saved?.modelName, "gpt-4o-mini")
    }

    func testSaveWithBaseURLOverride() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test-123"
        viewModel.modelName = "my-model"
        viewModel.baseURLOverride = "https://my-server.com/v1"

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertEqual(saved?.baseURL.absoluteString, "https://my-server.com/v1")
    }

    func testOpenAICompatibleProviderRequiresEndpointBeforeSave() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openaiCompatible
        viewModel.customModelName = "third-party-model"

        XCTAssertFalse(viewModel.canSave)
        XCTAssertEqual(viewModel.validationMessage, "Enter a valid base URL. Remote endpoints must use https.")

        viewModel.baseURLOverride = "https://api.example.com/v1"

        XCTAssertTrue(viewModel.canSave)
    }

    // MARK: - Load Existing

    func testLoadsExistingConfigWithSuggestedModel() {
        mockConfigStore.config = .openai(apiKey: "sk-existing", model: "gpt-4.1")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertEqual(viewModel.selectedProviderID, .openai)
        XCTAssertEqual(viewModel.apiKeyInput, "sk-existing")
        XCTAssertEqual(viewModel.modelName, "gpt-4.1")
        XCTAssertFalse(viewModel.useCustomModel)
    }

    func testLoadsExistingConfigEnablesAIFormatterByDefaultWhenPreferenceUnset() {
        mockConfigStore.config = .openai(apiKey: "sk-existing", model: "gpt-4.1")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertTrue(viewModel.aiFormatterEnabled)
        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
    }

    func testLoadsExistingConfigWithCustomModel() {
        mockConfigStore.config = .openai(apiKey: "sk-existing", model: "gpt-4")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertEqual(viewModel.selectedProviderID, .openai)
        XCTAssertEqual(viewModel.apiKeyInput, "sk-existing")
        XCTAssertTrue(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.customModelName, "gpt-4")
        XCTAssertEqual(viewModel.effectiveModelName, "gpt-4")
    }

    // MARK: - isConfigured

    func testIsConfiguredWhenStoreHasConfig() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertTrue(viewModel.isConfigured)
    }

    func testIsConfiguredFalseWhenStoreEmpty() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertFalse(viewModel.isConfigured)
    }

    // MARK: - Clear

    func testClearResetsState() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.clearConfiguration()

        XCTAssertNil(mockConfigStore.config)
        XCTAssertEqual(viewModel.apiKeyInput, "")
        XCTAssertEqual(viewModel.connectionTestState, .idle)
        XCTAssertFalse(viewModel.isConfigured)
    }

    func testClearResetsCustomModelDraft() {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "custom-model")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.clearConfiguration()

        XCTAssertFalse(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.customModelName, "")
        XCTAssertEqual(viewModel.modelName, "gpt-5.5")
    }

    func testClearResetsAIFormatterPreferences() {
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set("Rewrite:\n\(AIFormatter.transcriptPlaceholder)", forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.clearConfiguration()

        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).aiFormatterEnabled)
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey),
            AIFormatter.defaultPromptTemplate
        )
        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertEqual(viewModel.aiFormatterPrompt, AIFormatter.defaultPromptTemplate)
    }

    // MARK: - AI Formatter Profiles

    func testConfigureLoadsAIFormatterProfiles() throws {
        let dbManager = try DatabaseManager()
        let repo = AIFormatterProfileRepository(dbQueue: dbManager.dbQueue)
        let profile = AIFormatterProfile.category(
            name: "Messaging",
            appCategory: .messaging,
            promptTemplate: "Messaging prompt"
        )
        try repo.save(profile)

        viewModel.configure(
            configStore: mockConfigStore,
            llmClient: mockClient,
            aiFormatterProfileRepo: repo
        )

        XCTAssertEqual(viewModel.aiFormatterProfiles.map(\.id), [profile.id])
        XCTAssertNil(viewModel.aiFormatterProfileError)
    }

    func testSaveAIFormatterExactAppProfile() throws {
        let dbManager = try DatabaseManager()
        let repo = AIFormatterProfileRepository(dbQueue: dbManager.dbQueue)
        viewModel.configure(
            configStore: mockConfigStore,
            llmClient: mockClient,
            aiFormatterProfileRepo: repo
        )

        viewModel.startCreatingAIFormatterProfile(targetKind: .bundle)
        viewModel.updateAIFormatterProfileDraft(\.name, to: "Slack")
        viewModel.updateAIFormatterProfileDraft(\.bundleIdentifier, to: " COM.TINYSPECK.SLACKMACGAP ")
        viewModel.updateAIFormatterProfileDraft(\.appDisplayName, to: "Slack")
        viewModel.updateAIFormatterProfileDraft(\.promptTemplate, to: "Slack prompt")

        XCTAssertTrue(viewModel.saveAIFormatterProfileDraft())

        let saved = try XCTUnwrap(repo.fetchAll().first)
        XCTAssertEqual(saved.name, "Slack")
        XCTAssertEqual(saved.targetKind, .bundle)
        XCTAssertEqual(saved.bundleIdentifier, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(saved.appDisplayName, "Slack")
        XCTAssertEqual(saved.promptTemplate, "Slack prompt")
        XCTAssertNil(saved.appCategory)
        XCTAssertNil(viewModel.aiFormatterProfileDraft)
        XCTAssertEqual(viewModel.aiFormatterProfiles.map(\.id), [saved.id])
    }

    func testApplyAIFormatterProfileDraftAppNormalizesBundleAndUsesDisplayName() {
        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: " COM.TINYSPECK.SLACKMACGAP ",
            displayName: " Slack "
        )

        let draft = viewModel.aiFormatterProfileDraft
        let messagingDefault = AIFormatterSmartDefaults.categoryDefault(for: .messaging)
        XCTAssertEqual(draft?.targetKind, .bundle)
        XCTAssertEqual(draft?.bundleIdentifier, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(draft?.appDisplayName, "Slack")
        XCTAssertEqual(draft?.appCategory, .messaging)
        XCTAssertEqual(draft?.name, "Slack")
        XCTAssertEqual(draft?.promptTemplate, messagingDefault?.promptTemplate)
        XCTAssertNil(viewModel.aiFormatterProfileError)
    }

    func testCategoryProfileStartsFromSmartDefaultPrompt() {
        viewModel.startCreatingAIFormatterProfile(targetKind: .category)

        let messagingDefault = AIFormatterSmartDefaults.categoryDefault(for: .messaging)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .messaging)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "Messaging")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.promptTemplate, messagingDefault?.promptTemplate)
    }

    func testChangingCategoryProfileDraftUpdatesSmartDefaultPrompt() {
        viewModel.startCreatingAIFormatterProfile(targetKind: .category)
        viewModel.applyAIFormatterProfileDraftCategory(.email)

        let emailDefault = AIFormatterSmartDefaults.categoryDefault(for: .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "Email")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.promptTemplate, emailDefault?.promptTemplate)
    }

    func testChangingCategoryProfileDraftTreatsNormalizedSmartDefaultAsAutoPrompt() {
        viewModel.startCreatingAIFormatterProfile(targetKind: .category)
        let messagingDefault = AIFormatterSmartDefaults.categoryDefault(for: .messaging)
        viewModel.updateAIFormatterProfileDraft(
            \.promptTemplate,
            to: "\n\(messagingDefault?.promptTemplate ?? "")\n"
        )

        viewModel.applyAIFormatterProfileDraftCategory(.email)

        let emailDefault = AIFormatterSmartDefaults.categoryDefault(for: .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.promptTemplate, emailDefault?.promptTemplate)
    }

    func testChangingCategoryProfileDraftPreservesCustomNameAndPrompt() {
        viewModel.startCreatingAIFormatterProfile(targetKind: .category)
        viewModel.updateAIFormatterProfileDraft(\.name, to: "My Messages")
        viewModel.updateAIFormatterProfileDraft(\.promptTemplate, to: "Custom prompt \(AIFormatter.transcriptPlaceholder)")

        viewModel.applyAIFormatterProfileDraftCategory(.email)

        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "My Messages")
        XCTAssertEqual(
            viewModel.aiFormatterProfileDraft?.promptTemplate,
            "Custom prompt \(AIFormatter.transcriptPlaceholder)"
        )
    }

    func testChangingEditedCategoryProfilePreservesCustomNameAndPrompt() {
        let profile = AIFormatterProfile.category(
            name: "My Messages",
            appCategory: .messaging,
            promptTemplate: "Custom prompt \(AIFormatter.transcriptPlaceholder)"
        )
        viewModel.editAIFormatterProfile(profile)

        viewModel.applyAIFormatterProfileDraftCategory(.email)

        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.profileID, profile.id)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "My Messages")
        XCTAssertEqual(
            viewModel.aiFormatterProfileDraft?.promptTemplate,
            "Custom prompt \(AIFormatter.transcriptPlaceholder)"
        )
    }

    func testApplyingBlankAppBundleSetsErrorAndPreservesDraft() {
        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )
        let originalDraft = viewModel.aiFormatterProfileDraft

        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: "   ",
            displayName: "Blank"
        )

        XCTAssertEqual(viewModel.aiFormatterProfileError, "Bundle ID is required for app profiles.")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft, originalDraft)
    }

    func testUnknownAppProfileUsesFallbackPrompt() {
        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: "com.example.privateapp",
            displayName: "Private App"
        )

        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.targetKind, .bundle)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.bundleIdentifier, "com.example.privateapp")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .other)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "Private App")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.promptTemplate, AIFormatter.defaultPromptTemplate)
    }

    func testChangingSelectedAppReplacesPreviousSmartDefaultPrompt() {
        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )
        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: "com.apple.mail",
            displayName: "Mail"
        )

        let emailDefault = AIFormatterSmartDefaults.categoryDefault(for: .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.bundleIdentifier, "com.apple.mail")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "Mail")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.promptTemplate, emailDefault?.promptTemplate)
    }

    func testProfileTargetKindSwitchNormalizesCategoryAndAppDrafts() {
        viewModel.startCreatingAIFormatterProfile(targetKind: .category)
        viewModel.applyAIFormatterProfileDraftTargetKind(.bundle)

        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.targetKind, .bundle)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "New app profile")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.promptTemplate, AIFormatter.defaultPromptTemplate)

        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: "com.apple.mail",
            displayName: "Mail"
        )
        viewModel.applyAIFormatterProfileDraftTargetKind(.category)

        let emailDefault = AIFormatterSmartDefaults.categoryDefault(for: .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.targetKind, .category)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.appCategory, .email)
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.name, "Email")
        XCTAssertEqual(viewModel.aiFormatterProfileDraft?.promptTemplate, emailDefault?.promptTemplate)
    }

    func testAIFormatterPromptPreviewUsesBuiltInCategoryDefault() {
        let context = AppPromptContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )

        let resolution = viewModel.aiFormatterPromptPreview(for: context)

        XCTAssertEqual(resolution.matchKind, .category)
        XCTAssertEqual(resolution.profileName, "Messaging")
        XCTAssertEqual(resolution.profileOrigin, .template)
        XCTAssertNil(resolution.profileID)
    }

    func testAIFormatterPromptPreviewIncludesUnsavedDraft() throws {
        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: "com.apple.mail",
            displayName: "Mail"
        )
        viewModel.updateAIFormatterProfileDraft(\.name, to: "Mail Formal")
        viewModel.updateAIFormatterProfileDraft(
            \.promptTemplate,
            to: "Formal mail prompt \(AIFormatter.transcriptPlaceholder)"
        )
        let draft = try XCTUnwrap(viewModel.aiFormatterProfileDraft)

        let resolution = viewModel.aiFormatterPromptPreview(
            for: AppPromptContext(bundleIdentifier: "com.apple.mail", displayName: "Mail"),
            including: draft
        )

        XCTAssertEqual(resolution.matchKind, .exactApp)
        XCTAssertEqual(resolution.profileName, "Mail Formal")
        XCTAssertEqual(resolution.profileOrigin, .custom)
        XCTAssertEqual(resolution.promptTemplate, "Formal mail prompt \(AIFormatter.transcriptPlaceholder)")
    }

    func testBlankAIFormatterProfilePromptIsRejected() throws {
        let dbManager = try DatabaseManager()
        let repo = AIFormatterProfileRepository(dbQueue: dbManager.dbQueue)
        viewModel.configure(
            configStore: mockConfigStore,
            llmClient: mockClient,
            aiFormatterProfileRepo: repo
        )

        viewModel.startCreatingAIFormatterProfile(targetKind: .category)
        viewModel.updateAIFormatterProfileDraft(\.name, to: "Email")
        viewModel.updateAIFormatterProfileDraft(\.appCategory, to: TelemetryAppCategory.email)
        viewModel.updateAIFormatterProfileDraft(\.promptTemplate, to: "   ")

        XCTAssertFalse(viewModel.saveAIFormatterProfileDraft())
        XCTAssertEqual(viewModel.aiFormatterProfileError, "Prompt template is required.")
        XCTAssertEqual(try repo.fetchAll().count, 0)
        XCTAssertNotNil(viewModel.aiFormatterProfileDraft)
    }

    func testDuplicateAIFormatterProfileSurfacesErrorAndKeepsDraft() throws {
        let dbManager = try DatabaseManager()
        let repo = AIFormatterProfileRepository(dbQueue: dbManager.dbQueue)
        try repo.save(AIFormatterProfile.category(
            name: "Email",
            appCategory: .email,
            promptTemplate: "Email prompt"
        ))
        viewModel.configure(
            configStore: mockConfigStore,
            llmClient: mockClient,
            aiFormatterProfileRepo: repo
        )

        viewModel.startCreatingAIFormatterProfile(targetKind: .category)
        viewModel.updateAIFormatterProfileDraft(\.name, to: "Email 2")
        viewModel.updateAIFormatterProfileDraft(\.appCategory, to: TelemetryAppCategory.email)

        XCTAssertFalse(viewModel.saveAIFormatterProfileDraft())
        XCTAssertEqual(viewModel.aiFormatterProfileError, "A profile already exists for email.")
        XCTAssertNotNil(viewModel.aiFormatterProfileDraft)
        XCTAssertEqual(try repo.fetchAll().count, 1)
    }

    func testToggleAndDeleteAIFormatterProfile() throws {
        let dbManager = try DatabaseManager()
        let repo = AIFormatterProfileRepository(dbQueue: dbManager.dbQueue)
        let profile = AIFormatterProfile.category(
            name: "Terminal",
            appCategory: .terminal,
            promptTemplate: "Terminal prompt"
        )
        try repo.save(profile)
        viewModel.configure(
            configStore: mockConfigStore,
            llmClient: mockClient,
            aiFormatterProfileRepo: repo
        )

        let loaded = try XCTUnwrap(viewModel.aiFormatterProfiles.first)
        viewModel.setAIFormatterProfile(loaded, enabled: false)
        XCTAssertEqual(viewModel.aiFormatterProfiles.first?.isEnabled, false)

        let disabled = try XCTUnwrap(viewModel.aiFormatterProfiles.first)
        viewModel.deleteAIFormatterProfile(disabled)

        XCTAssertTrue(viewModel.aiFormatterProfiles.isEmpty)
        XCTAssertTrue(try repo.fetchAll().isEmpty)
    }

    // MARK: - Test Connection

    func testConnectionSuccess() async throws {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"

        viewModel.testConnection()

        // Wait for async task
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.connectionTestState, .success)
    }

    func testConnectionSuccessMessagePromptsSaveForUnsavedDraft() async throws {
        mockConfigStore.config = .gemini(
            apiKey: "gemini-key",
            model: "gemini-3.1-pro-preview"
        )
        mockClient.modelsList = ["gemini-3.1-pro-preview", "gemini-3-flash-preview"]
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        try await Task.sleep(nanoseconds: 100_000_000)
        mockClient.capturedContext = nil

        viewModel.modelName = "gemini-3-flash-preview"
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.testConnection()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.connectionTestState, .success)
        XCTAssertEqual(viewModel.connectionSuccessMessage, "Connected. Save to use this AI option.")
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.modelName, "gemini-3-flash-preview")
        XCTAssertEqual(mockConfigStore.config?.modelName, "gemini-3.1-pro-preview")

        viewModel.saveConfiguration()

        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertEqual(viewModel.connectionSuccessMessage, "Connected")
        XCTAssertEqual(mockConfigStore.config?.modelName, "gemini-3-flash-preview")
    }

    func testConnectionFailure() async throws {
        mockClient.testConnectionError = LLMError.authenticationFailed(nil)
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-bad"

        viewModel.testConnection()

        try await Task.sleep(nanoseconds: 100_000_000)
        if case .error = viewModel.connectionTestState {
            // Expected
        } else {
            XCTFail("Expected error state, got \(viewModel.connectionTestState)")
        }
    }

    func testStaleConnectionSuccessIsIgnoredAfterFieldChange() async throws {
        mockClient.testConnectionDelayNs = 200_000_000
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"

        viewModel.testConnection()
        viewModel.apiKeyInput = "sk-updated"

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(viewModel.connectionTestState, .idle)
    }

    func testStaleConnectionResultIsIgnoredAfterProviderChange() async throws {
        mockClient.testConnectionDelayNs = 200_000_000
        mockClient.testConnectionError = LLMError.authenticationFailed(nil)
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"

        viewModel.testConnection()
        viewModel.selectedProviderID = .anthropic
        viewModel.apiKeyInput = "sk-anthropic"

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(viewModel.connectionTestState, .idle)
    }

    // MARK: - Configuration Changed Callback

    func testSaveCallsOnConfigurationChanged() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        var callbackCalled = false
        viewModel.onConfigurationChanged = { callbackCalled = true }
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"
        viewModel.saveConfiguration()
        XCTAssertTrue(callbackCalled)
    }

    func testClearCallsOnConfigurationChanged() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        var callbackCalled = false
        viewModel.onConfigurationChanged = { callbackCalled = true }
        viewModel.clearConfiguration()
        XCTAssertTrue(callbackCalled)
    }

    // MARK: - Provider switch preserves per-provider keys

    func testSelectingNoneDisablesTestConnection() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertFalse(viewModel.canTestConnection)
    }

    func testSelectingNoneCanSaveOnlyWhenConfigured() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertFalse(viewModel.canSave)

        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"
        viewModel.saveConfiguration()
        XCTAssertTrue(viewModel.isConfigured)

        viewModel.selectedProviderID = nil
        XCTAssertTrue(viewModel.canSave)
    }

    func testSavingNoneClearsExistingConfig() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertTrue(viewModel.isConfigured)

        viewModel.selectedProviderID = nil
        viewModel.saveConfiguration()

        XCTAssertNil(mockConfigStore.config)
        XCTAssertFalse(viewModel.isConfigured)
    }

    func testSelectingNoneDisablesAIFormatter() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai

        viewModel.selectedProviderID = nil

        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertFalse(viewModel.isAIFormatterAvailable)
    }

    func testNoneProviderReturnsEmptyModels() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
    }

    func testSwitchingToLocalClearsAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.apiKeyInput = "sk-test"

        viewModel.selectedProviderID = .ollama
        XCTAssertEqual(viewModel.apiKeyInput, "")
    }

    func testLMStudioLoadsAvailableModelsAndDefaultsToFirstResult() async throws {
        mockClient.modelsList = ["llama-3.2", "qwen2.5"]
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .lmstudio

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.availableModels, ["llama-3.2", "qwen2.5"])
        XCTAssertFalse(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.modelName, "llama-3.2")
        XCTAssertNil(viewModel.modelListErrorMessage)
    }

    func testLMStudioSavesOptionalAPIKey() async throws {
        mockClient.modelsList = ["local-model"]
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .lmstudio
        try await Task.sleep(nanoseconds: 100_000_000)
        viewModel.apiKeyInput = "lm-token"
        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertEqual(saved?.id, .lmstudio)
        XCTAssertEqual(saved?.apiKey, "lm-token")
        XCTAssertEqual(saved?.modelName, "local-model")
    }

    func testOllamaLoadsAvailableModelsAndDefaultsToFirstResult() async throws {
        mockClient.modelsList = ["qwen3.5:9b", "gemma3:4b"]
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .ollama

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.availableModels, ["qwen3.5:9b", "gemma3:4b"])
        XCTAssertEqual(viewModel.modelName, "qwen3.5:9b")
        XCTAssertEqual(viewModel.discoveredModelCount, 2)
        XCTAssertNil(viewModel.modelListErrorMessage)
    }

    func testLMStudioModelListFailureKeepsCustomMode() async throws {
        mockClient.listModelsError = LLMError.connectionFailed("Failed to fetch models.")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .lmstudio

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(viewModel.availableModels.isEmpty)
        XCTAssertTrue(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.modelListErrorMessage, "Connection failed: Failed to fetch models.")
    }

    func testOllamaModelListFailureKeepsRecommendedModels() async throws {
        mockClient.listModelsError = LLMError.connectionFailed("Failed to fetch models.")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .ollama

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.availableModels, LLMSettingsViewModel.suggestedModels(for: .ollama))
        XCTAssertFalse(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.modelName, "qwen3.5:4b")
        XCTAssertEqual(viewModel.modelListErrorMessage, "Connection failed: Failed to fetch models.")
    }

    func testOpenAILoadsAvailableModelsWhenConfigured() async throws {
        mockClient.modelsList = ["gpt-5.2", "gpt-4.1", "gpt-5-mini"]
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "gpt-4.1")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.availableModels, ["gpt-5.2", "gpt-4.1", "gpt-5-mini"])
        XCTAssertEqual(viewModel.modelName, "gpt-4.1")
        XCTAssertEqual(viewModel.discoveredModelCount, 3)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.id, .openai)
        XCTAssertNil(viewModel.modelListErrorMessage)
    }

    func testSwitchingBetweenDiscoveryProvidersClearsPreviousDiscoveredModels() async throws {
        mockClient.modelsList = ["qwen3.5:9b", "gemma3:4b"]
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .ollama
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.availableModels, ["qwen3.5:9b", "gemma3:4b"])

        viewModel.selectedProviderID = .openai

        XCTAssertEqual(viewModel.discoveredModelCount, 0)
        XCTAssertEqual(viewModel.availableModels, LLMSettingsViewModel.suggestedModels(for: .openai))
        XCTAssertFalse(viewModel.availableModels.contains("qwen3.5:9b"))
    }

    func testSwitchingProviderLoadsStoredKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        // Save OpenAI config (stores key in mock)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-openai-key"
        viewModel.saveConfiguration()

        // Switch to Anthropic, save a different key
        viewModel.selectedProviderID = .anthropic
        viewModel.apiKeyInput = "sk-ant-key"
        viewModel.saveConfiguration()

        // Switch back to OpenAI — should restore the OpenAI key
        viewModel.selectedProviderID = .openai
        XCTAssertEqual(viewModel.apiKeyInput, "sk-openai-key")

        // Switch back to Anthropic — should restore the Anthropic key
        viewModel.selectedProviderID = .anthropic
        XCTAssertEqual(viewModel.apiKeyInput, "sk-ant-key")
    }

    func testSwitchingProviderResetsConnectionTestState() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.connectionTestState = .success

        viewModel.selectedProviderID = .anthropic
        XCTAssertEqual(viewModel.connectionTestState, .idle)
    }

    // MARK: - Save State

    func testSaveShowsSavedState() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"
        viewModel.saveConfiguration()
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testHasUnsavedChangesTracksSavedGeminiModelDraft() {
        mockConfigStore.config = .gemini(
            apiKey: "gemini-key",
            model: "gemini-3.1-pro-preview"
        )
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.modelName = "gemini-3-flash-preview"

        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.saveConfiguration()

        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertEqual(mockConfigStore.config?.modelName, "gemini-3-flash-preview")
    }

    func testHasUnsavedChangesTracksClearingSavedConfiguration() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.selectedProviderID = nil

        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.saveConfiguration()

        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertNil(mockConfigStore.config)
    }

    func testHasUnsavedChangesTracksLocalCLIConfigDraft() throws {
        let defaults = UserDefaults(suiteName: "test.vm.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(
            LocalCLIConfig(commandTemplate: "claude -p --model haiku", timeoutSeconds: 45)
        )
        mockConfigStore.config = .localCLI()
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient, cliConfigStore: cliStore)

        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.commandTemplate = "codex exec --skip-git-repo-check --model gpt-5.4-mini"

        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.saveConfiguration()

        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertEqual(
            cliStore.load()?.commandTemplate,
            "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )
    }

    func testSavePersistsAIFormatterPreferences() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"
        viewModel.aiFormatterPrompt = "Rewrite this carefully:\n\(AIFormatter.transcriptPlaceholder)"

        viewModel.saveConfiguration()

        XCTAssertTrue(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey),
            "Rewrite this carefully:\n\(AIFormatter.transcriptPlaceholder)"
        )
    }

    func testSaveEnablesAIFormatterByDefaultForNewProviderConfiguration() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"

        viewModel.saveConfiguration()

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
        XCTAssertTrue(viewModel.aiFormatterEnabled)
    }

    func testSaveEnablesAIFormatterWhenLegacyPreferenceWasFalse() {
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"

        viewModel.saveConfiguration()

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledForDictationKey) as? Bool,
            false
        )
        XCTAssertTrue(viewModel.aiFormatterEnabled)
    }

    func testFieldChangeResetsSaveState() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"
        viewModel.saveConfiguration()
        XCTAssertEqual(viewModel.saveState, .saved)

        viewModel.apiKeyInput = "sk-different"
        XCTAssertEqual(viewModel.saveState, .idle)
    }

    func testFieldChangeResetsConnectionTestState() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.connectionTestState = .success

        viewModel.apiKeyInput = "sk-changed"
        XCTAssertEqual(viewModel.connectionTestState, .idle)
    }

    func testLoadsStoredAIFormatterPreferences() {
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set("Rewrite:\n\(AIFormatter.transcriptPlaceholder)", forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        mockConfigStore.config = .openai(apiKey: "sk-test")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertTrue(viewModel.aiFormatterEnabled)
        XCTAssertEqual(viewModel.aiFormatterPrompt, "Rewrite:\n\(AIFormatter.transcriptPlaceholder)")
        XCTAssertEqual(viewModel.aiFormatterPromptModeText, "Custom prompt")
    }

    func testLoadsLegacyDefaultAIFormatterPromptAsUpdatedDefault() {
        defaults.set(AIFormatter.legacyDefaultPromptTemplateV1, forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        mockConfigStore.config = .openai(apiKey: "sk-test")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertEqual(viewModel.aiFormatterPrompt, AIFormatter.defaultPromptTemplate)
    }

    func testAIFormatterUnavailableUntilProviderIsSaved() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai

        XCTAssertFalse(viewModel.isAIFormatterAvailable)
        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
    }

    func testAIFormatterPromptPersistsImmediatelyWhenConfigured() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertTrue(viewModel.isAIFormatterAvailable)

        viewModel.aiFormatterPrompt = "Rewrite:\n\(AIFormatter.transcriptPlaceholder)"

        XCTAssertTrue(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey),
            "Rewrite:\n\(AIFormatter.transcriptPlaceholder)"
        )
    }

    func testResetAIFormatterPromptRestoresDefaultInDraft() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.aiFormatterPrompt = "Rewrite:\n\(AIFormatter.transcriptPlaceholder)"

        XCTAssertTrue(viewModel.canResetAIFormatterPrompt)

        viewModel.resetAIFormatterPrompt()

        XCTAssertEqual(viewModel.aiFormatterPrompt, AIFormatter.defaultPromptTemplate)
        XCTAssertFalse(viewModel.canResetAIFormatterPrompt)
    }

    func testResetAIFormatterPromptPersistsDefaultWhenConfigured() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.aiFormatterPrompt = "Rewrite:\n\(AIFormatter.transcriptPlaceholder)"

        viewModel.resetAIFormatterPrompt()

        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey),
            AIFormatter.defaultPromptTemplate
        )
        XCTAssertEqual(viewModel.aiFormatterPrompt, AIFormatter.defaultPromptTemplate)
    }

    // MARK: - Model Selection

    func testAvailableModelsReturnsSuggestedModels() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        XCTAssertEqual(viewModel.availableModels, LLMSettingsViewModel.suggestedModels(for: .openai))
    }

    func testCustomModelUsesCustomModelName() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.useCustomModel = true
        viewModel.customModelName = "my-fine-tuned-model"
        XCTAssertEqual(viewModel.effectiveModelName, "my-fine-tuned-model")
    }

    func testPickerModelUsesModelName() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.useCustomModel = false
        viewModel.modelName = "gpt-4o"
        XCTAssertEqual(viewModel.effectiveModelName, "gpt-4o")
    }

    func testProviderChangeResetsCustomModel() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.useCustomModel = true
        viewModel.customModelName = "custom-model"

        viewModel.selectedProviderID = .anthropic
        XCTAssertFalse(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.customModelName, "")
    }

    func testEmptyCustomModelIsInvalid() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"
        viewModel.useCustomModel = true
        viewModel.customModelName = "   "

        XCTAssertFalse(viewModel.canSave)
        XCTAssertEqual(viewModel.validationMessage, "Enter a custom model ID.")

        viewModel.saveConfiguration()

        XCTAssertNil(mockConfigStore.config)
        if case .error(let message) = viewModel.saveState {
            XCTAssertEqual(message, "Enter a custom model ID.")
        } else {
            XCTFail("Expected save error for invalid custom model")
        }
    }

    func testLoadExistingConfigDetectsCustomModel() {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "ft:gpt-4o:my-org:custom:id")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertTrue(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.customModelName, "ft:gpt-4o:my-org:custom:id")
    }

    func testLoadExistingConfigDetectsSuggestedModel() {
        mockConfigStore.config = .openai(apiKey: "sk-test", model: "gpt-4.1")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertFalse(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.modelName, "gpt-4.1")
    }

    // MARK: - OpenRouter

    func testOpenRouterRequiresAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openrouter
        XCTAssertTrue(viewModel.requiresAPIKey)
        XCTAssertEqual(viewModel.modelName, "anthropic/claude-sonnet-4.6")
    }

    // MARK: - Local CLI

    func testLocalCLIDoesNotRequireAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .localCLI
        XCTAssertFalse(viewModel.requiresAPIKey)
    }

    func testLocalCLIConnectionUsesInjectedClient() async throws {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .localCLI
        viewModel.commandTemplate = "echo OK"

        viewModel.testConnection()

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.connectionTestState, .success)
        XCTAssertEqual(mockClient.capturedContext?.providerConfig.id, .localCLI)
        XCTAssertEqual(mockClient.capturedContext?.localCLIConfig?.commandTemplate, "echo OK")
    }

    func testLocalCLITemplatePopulatesCommand() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .localCLI

        viewModel.selectedCLITemplate = .claudeCode
        XCTAssertEqual(viewModel.commandTemplate, "claude -p --model haiku")

        viewModel.selectedCLITemplate = .codex
        XCTAssertEqual(
            viewModel.commandTemplate,
            "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )
    }

    func testLoadsExistingLocalCLIConfigRehydratesPresetSelection() throws {
        let defaults = UserDefaults(suiteName: "test.vm.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(
            LocalCLIConfig(
                commandTemplate: "claude -p --model haiku",
                timeoutSeconds: 45
            )
        )
        mockConfigStore.config = .localCLI()

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient, cliConfigStore: cliStore)

        XCTAssertEqual(viewModel.selectedProviderID, .localCLI)
        XCTAssertEqual(viewModel.commandTemplate, "claude -p --model haiku")
        XCTAssertEqual(viewModel.selectedCLITemplate, .claudeCode)
        XCTAssertEqual(viewModel.cliTimeoutSeconds, 45)
    }

    func testLocalCLICanSaveWithCommand() {
        let cliStore = LocalCLIConfigStore(defaults: UserDefaults(suiteName: "test.vm.\(UUID().uuidString)")!)
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient, cliConfigStore: cliStore)
        viewModel.selectedProviderID = .localCLI
        viewModel.commandTemplate = "claude -p --model haiku"

        XCTAssertTrue(viewModel.canSave)
        viewModel.saveConfiguration()
        XCTAssertEqual(viewModel.saveState, .saved)

        // Verify CLI config was persisted
        let saved = cliStore.load()
        XCTAssertEqual(saved?.commandTemplate, "claude -p --model haiku")
    }

    func testLocalCLITimeoutClampsToMinimum() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .localCLI

        viewModel.cliTimeoutSeconds = 1

        XCTAssertEqual(viewModel.cliTimeoutSeconds, LocalCLIConfig.minimumTimeout)
    }

    func testLocalCLISaveDuringConnectionTestDoesNotRestoreStaleCommand() async throws {
        let defaults = UserDefaults(suiteName: "test.vm.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(LocalCLIConfig(commandTemplate: "echo OLD", timeoutSeconds: 10))

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient, cliConfigStore: cliStore)
        viewModel.selectedProviderID = .localCLI
        viewModel.commandTemplate = "sleep 0.2; cat >/dev/null; echo OK"
        viewModel.cliTimeoutSeconds = 10

        viewModel.testConnection()
        viewModel.commandTemplate = "echo SAVED"
        viewModel.saveConfiguration()

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(cliStore.load()?.commandTemplate, "echo SAVED")
        XCTAssertEqual(viewModel.connectionTestState, .idle)
    }

    func testClearKeepsSavedLocalCLIConfigAfterUnsavedProviderSwitch() throws {
        let defaults = UserDefaults(suiteName: "test.vm.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(
            LocalCLIConfig(
                commandTemplate: "codex exec --skip-git-repo-check --model gpt-5.4-mini",
                timeoutSeconds: 15
            )
        )
        mockConfigStore.config = .openai(apiKey: "sk-test")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient, cliConfigStore: cliStore)
        viewModel.selectedProviderID = .localCLI
        XCTAssertEqual(
            viewModel.commandTemplate,
            "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )

        viewModel.clearConfiguration()

        XCTAssertNil(mockConfigStore.config)
        XCTAssertEqual(
            cliStore.load()?.commandTemplate,
            "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )
        XCTAssertEqual(viewModel.selectedProviderID, .localCLI)
        XCTAssertEqual(
            viewModel.commandTemplate,
            "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )
        XCTAssertEqual(viewModel.cliTimeoutSeconds, 15)
    }

    func testLocalCLICannotSaveWithoutCommand() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .localCLI
        viewModel.commandTemplate = ""

        XCTAssertFalse(viewModel.canSave)
    }

    func testLocalCLITemplateClears_onManualEdit() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .localCLI

        viewModel.selectedCLITemplate = .claudeCode
        XCTAssertEqual(viewModel.commandTemplate, "claude -p --model haiku")
        XCTAssertEqual(viewModel.selectedCLITemplate, .claudeCode)

        // Manually editing clears the template selection
        viewModel.commandTemplate = "my-custom-tool"
        XCTAssertNil(viewModel.selectedCLITemplate)
    }

    func testSwitchToLocalCLIAndBack() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .localCLI
        XCTAssertFalse(viewModel.requiresAPIKey)
        XCTAssertTrue(viewModel.availableModels.isEmpty)

        viewModel.selectedProviderID = .openai
        XCTAssertTrue(viewModel.requiresAPIKey)
        XCTAssertFalse(viewModel.availableModels.isEmpty)
    }

    func testSaveOpenAICompatibleProviderPersistsCustomEndpoint() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openaiCompatible
        viewModel.apiKeyInput = "sk-third-party"
        viewModel.customModelName = "vendor/model"
        viewModel.baseURLOverride = "https://api.example.com/v1"

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertEqual(saved?.id, .openaiCompatible)
        XCTAssertEqual(saved?.apiKey, "sk-third-party")
        XCTAssertEqual(saved?.modelName, "vendor/model")
        XCTAssertEqual(saved?.baseURL.absoluteString, "https://api.example.com/v1")
        XCTAssertEqual(saved?.isLocal, false)
    }

    func testSaveOpenAICompatibleProviderAllowsEmptyAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openaiCompatible
        viewModel.customModelName = "vendor/model"
        viewModel.baseURLOverride = "https://api.example.com/v1"

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertEqual(saved?.id, .openaiCompatible)
        XCTAssertNil(saved?.apiKey)
    }

    func testOpenAICompatibleLoopbackEndpointIsTreatedAsLocal() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openaiCompatible
        viewModel.customModelName = "local-model"
        viewModel.baseURLOverride = "http://localhost:8000/v1"

        XCTAssertTrue(viewModel.isLocalConfiguration)

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertEqual(saved?.id, .openaiCompatible)
        XCTAssertEqual(saved?.isLocal, true)
    }
}
