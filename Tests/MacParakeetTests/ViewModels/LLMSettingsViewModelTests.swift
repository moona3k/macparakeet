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
        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertEqual(viewModel.aiFormatterPrompt, AIFormatter.defaultPromptTemplate)
    }

    // MARK: - Provider Change

    func testProviderChangeUpdatesModelName() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .anthropic
        XCTAssertEqual(viewModel.modelName, "claude-sonnet-4-6")

        viewModel.selectedProviderID = .gemini
        XCTAssertEqual(viewModel.modelName, "gemini-3.1-pro-preview")

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
    }

    func testCloudProviderRequiresAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        XCTAssertTrue(viewModel.requiresAPIKey)
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

    // MARK: - Load Existing

    func testLoadsExistingConfigWithSuggestedModel() {
        mockConfigStore.config = .openai(apiKey: "sk-existing", model: "gpt-4.1")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertEqual(viewModel.selectedProviderID, .openai)
        XCTAssertEqual(viewModel.apiKeyInput, "sk-existing")
        XCTAssertEqual(viewModel.modelName, "gpt-4.1")
        XCTAssertFalse(viewModel.useCustomModel)
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
        XCTAssertEqual(viewModel.modelName, "gpt-5.4")
    }

    func testClearResetsAIFormatterPreferences() {
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey)
        defaults.set("Rewrite:\n\(AIFormatter.transcriptPlaceholder)", forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey)
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.clearConfiguration()

        XCTAssertFalse(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey),
            AIFormatter.defaultPromptTemplate
        )
        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertEqual(viewModel.aiFormatterPrompt, AIFormatter.defaultPromptTemplate)
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
        viewModel.aiFormatterEnabled = true

        viewModel.selectedProviderID = nil

        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertFalse(viewModel.canToggleAIFormatter)
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

    func testLMStudioModelListFailureKeepsCustomMode() async throws {
        mockClient.listModelsError = LLMError.connectionFailed("Failed to fetch models.")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .lmstudio

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(viewModel.availableModels.isEmpty)
        XCTAssertTrue(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.modelListErrorMessage, "Connection failed: Failed to fetch models.")
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

    func testSavePersistsAIFormatterPreferences() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test"
        viewModel.aiFormatterEnabled = true
        viewModel.aiFormatterPrompt = "Rewrite this carefully:\n\(AIFormatter.transcriptPlaceholder)"

        viewModel.saveConfiguration()

        XCTAssertTrue(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey),
            "Rewrite this carefully:\n\(AIFormatter.transcriptPlaceholder)"
        )
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
    }

    func testAIFormatterStaysDisabledUntilProviderIsSaved() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai

        XCTAssertFalse(viewModel.canToggleAIFormatter)

        viewModel.aiFormatterEnabled = true

        XCTAssertFalse(viewModel.aiFormatterEnabled)
        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
    }

    func testAIFormatterTogglePersistsImmediatelyWhenConfigured() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertTrue(viewModel.canToggleAIFormatter)

        viewModel.aiFormatterEnabled = true
        viewModel.aiFormatterPrompt = "Rewrite:\n\(AIFormatter.transcriptPlaceholder)"

        XCTAssertTrue(defaults.bool(forKey: UserDefaultsAppRuntimePreferences.aiFormatterEnabledKey))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.aiFormatterPromptKey),
            "Rewrite:\n\(AIFormatter.transcriptPlaceholder)"
        )
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
        XCTAssertEqual(viewModel.modelName, "anthropic/claude-opus-4-6")
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
}
