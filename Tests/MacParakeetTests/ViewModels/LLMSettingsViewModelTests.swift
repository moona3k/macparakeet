import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LLMSettingsViewModelTests: XCTestCase {
    var viewModel: LLMSettingsViewModel!
    var mockConfigStore: MockLLMConfigStore!
    var mockClient: MockLLMClient!

    override func setUp() {
        viewModel = LLMSettingsViewModel()
        mockConfigStore = MockLLMConfigStore()
        mockClient = MockLLMClient()
    }

    // MARK: - Defaults

    func testDefaultValuesAfterInit() {
        XCTAssertEqual(viewModel.selectedProviderID, .openai)
        XCTAssertEqual(viewModel.apiKeyInput, "")
        XCTAssertEqual(viewModel.modelName, "gpt-5.4")
        XCTAssertEqual(viewModel.baseURLOverride, "")
        XCTAssertEqual(viewModel.connectionTestState, .idle)
        XCTAssertFalse(viewModel.isConfigured)
        XCTAssertTrue(viewModel.requiresAPIKey)
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

    // MARK: - Test Connection

    func testConnectionSuccess() async throws {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.apiKeyInput = "sk-test"

        viewModel.testConnection()

        // Wait for async task
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.connectionTestState, .success)
    }

    func testConnectionFailure() async throws {
        mockClient.testConnectionError = LLMError.authenticationFailed(nil)
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
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

    func testSwitchingToLocalClearsAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.apiKeyInput = "sk-test"

        viewModel.selectedProviderID = .ollama
        XCTAssertEqual(viewModel.apiKeyInput, "")
    }

    func testSwitchingProviderLoadsStoredKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        // Save OpenAI config (stores key in mock)
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
        viewModel.apiKeyInput = "sk-test"
        viewModel.saveConfiguration()
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFieldChangeResetsSaveState() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.apiKeyInput = "sk-test"
        viewModel.saveConfiguration()
        XCTAssertEqual(viewModel.saveState, .saved)

        viewModel.apiKeyInput = "sk-different"
        XCTAssertEqual(viewModel.saveState, .idle)
    }

    func testFieldChangeResetsConnectionTestState() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.connectionTestState = .success

        viewModel.apiKeyInput = "sk-changed"
        XCTAssertEqual(viewModel.connectionTestState, .idle)
    }

    // MARK: - Model Selection

    func testAvailableModelsReturnsSuggestedModels() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertEqual(viewModel.availableModels, LLMSettingsViewModel.suggestedModels(for: .openai))
    }

    func testCustomModelUsesCustomModelName() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.useCustomModel = true
        viewModel.customModelName = "my-fine-tuned-model"
        XCTAssertEqual(viewModel.effectiveModelName, "my-fine-tuned-model")
    }

    func testPickerModelUsesModelName() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.useCustomModel = false
        viewModel.modelName = "gpt-4o"
        XCTAssertEqual(viewModel.effectiveModelName, "gpt-4o")
    }

    func testProviderChangeResetsCustomModel() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.useCustomModel = true
        viewModel.customModelName = "custom-model"

        viewModel.selectedProviderID = .anthropic
        XCTAssertFalse(viewModel.useCustomModel)
        XCTAssertEqual(viewModel.customModelName, "")
    }

    func testEmptyCustomModelIsInvalid() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
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
}
