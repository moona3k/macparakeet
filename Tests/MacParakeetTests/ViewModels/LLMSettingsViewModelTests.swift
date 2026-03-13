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
        XCTAssertEqual(viewModel.modelName, "gpt-4.1")
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
        XCTAssertEqual(viewModel.modelName, "gemini-2.5-flash")

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
        viewModel.modelName = "my-model"
        viewModel.baseURLOverride = "https://my-server.com/v1"

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertEqual(saved?.baseURL.absoluteString, "https://my-server.com/v1")
    }

    // MARK: - Load Existing

    func testLoadsExistingConfigOnConfigure() {
        mockConfigStore.config = .openai(apiKey: "sk-existing", model: "gpt-4")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertEqual(viewModel.selectedProviderID, .openai)
        XCTAssertEqual(viewModel.apiKeyInput, "sk-existing")
        XCTAssertEqual(viewModel.modelName, "gpt-4")
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

    // MARK: - Fetch Models

    func testFetchModelsPopulatesAvailableModels() async throws {
        mockClient.modelsList = ["gpt-5.4", "gpt-5.4-pro", "gpt-5-mini"]
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.fetchModels()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.fetchedModels, ["gpt-5.4", "gpt-5.4-pro", "gpt-5-mini"])
        XCTAssertEqual(viewModel.availableModels, ["gpt-5.4", "gpt-5.4-pro", "gpt-5-mini"])
        XCTAssertFalse(viewModel.isFetchingModels)
    }

    func testAvailableModelsFallsBackToSuggested() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertEqual(viewModel.availableModels, LLMSettingsViewModel.suggestedModels(for: .openai))
    }

    func testProviderChangeClearsFetchedModels() async throws {
        mockClient.modelsList = ["model-a"]
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.fetchModels()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(viewModel.fetchedModels.isEmpty)

        viewModel.selectedProviderID = .anthropic
        XCTAssertTrue(viewModel.fetchedModels.isEmpty)
    }

    // MARK: - OpenRouter

    func testOpenRouterRequiresAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openrouter
        XCTAssertTrue(viewModel.requiresAPIKey)
        XCTAssertEqual(viewModel.modelName, "anthropic/claude-sonnet-4")
    }
}
