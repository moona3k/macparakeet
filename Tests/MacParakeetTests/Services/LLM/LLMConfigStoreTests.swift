import XCTest
@testable import MacParakeetCore

final class LLMConfigStoreTests: XCTestCase {
    var store: LLMConfigStore!
    var keychain: InMemoryKeyValueStore!
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        keychain = InMemoryKeyValueStore()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        store = LLMConfigStore(defaults: defaults, keychain: keychain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Tests

    func testSaveAndLoadRoundTrip() throws {
        let config = LLMProviderConfig.openai(apiKey: "sk-test-key", model: "gpt-4o")
        try store.saveConfig(config)

        let loaded = try store.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, .openai)
        XCTAssertEqual(loaded?.modelName, "gpt-4o")
        XCTAssertEqual(loaded?.apiKey, "sk-test-key")
        XCTAssertEqual(loaded?.isLocal, false)
    }

    func testAPIKeyStoredInKeychainNotUserDefaults() throws {
        let config = LLMProviderConfig.anthropic(apiKey: "sk-ant-secret")
        try store.saveConfig(config)

        // Verify apiKey is in per-provider Keychain key
        let keychainValue = try keychain.getString("llm_api_key_anthropic")
        XCTAssertEqual(keychainValue, "sk-ant-secret")

        // Verify apiKey is NOT in UserDefaults (CodingKeys excludes it)
        let data = defaults.data(forKey: "llm_provider_config")!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["apiKey"])
    }

    func testLoadReturnsNilWhenEmpty() throws {
        let loaded = try store.loadConfig()
        XCTAssertNil(loaded)
    }

    func testDeleteClearsBothStores() throws {
        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        try store.saveConfig(config)

        try store.deleteConfig()

        XCTAssertNil(try store.loadConfig())
        XCTAssertNil(try keychain.getString("llm_api_key_openai"))
        XCTAssertNil(defaults.data(forKey: "llm_provider_config"))
    }

    func testOllamaConfigWithNoAPIKey() throws {
        let config = LLMProviderConfig.ollama(model: "llama3.2")
        try store.saveConfig(config)

        let loaded = try store.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, .ollama)
        XCTAssertNil(loaded?.apiKey)
        XCTAssertEqual(loaded?.isLocal, true)
    }

    func testOverwriteAPIKey() throws {
        let config1 = LLMProviderConfig.openai(apiKey: "old-key")
        try store.saveConfig(config1)

        let config2 = LLMProviderConfig.openai(apiKey: "new-key")
        try store.saveConfig(config2)

        let loaded = try store.loadConfig()
        XCTAssertEqual(loaded?.apiKey, "new-key")
    }

    func testLoadAPIKeyAndSaveAPIKey() throws {
        // loadAPIKey() requires a saved config to know which provider to look up
        XCTAssertNil(try store.loadAPIKey())

        let config = LLMProviderConfig.openai(apiKey: "sk-initial")
        try store.saveConfig(config)

        try store.saveAPIKey("sk-direct")
        XCTAssertEqual(try store.loadAPIKey(), "sk-direct")
        XCTAssertEqual(try store.loadAPIKey(for: .openai), "sk-direct")

        try store.deleteAPIKey()
        XCTAssertNil(try store.loadAPIKey())
    }

    func testMissingKeychainKeyReturnsConfigWithNilAPIKey() throws {
        // Save config with apiKey, then delete only the Keychain entry
        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        try store.saveConfig(config)
        try keychain.delete("llm_api_key_openai")

        let loaded = try store.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, .openai)
        XCTAssertNil(loaded?.apiKey)
    }

    // MARK: - Per-Provider Key Storage

    func testPerProviderKeysPreservedAcrossSwitch() throws {
        // Save OpenAI config
        let openaiConfig = LLMProviderConfig.openai(apiKey: "sk-openai-key")
        try store.saveConfig(openaiConfig)

        // Save Anthropic config (switches active provider)
        let anthropicConfig = LLMProviderConfig.anthropic(apiKey: "sk-ant-key")
        try store.saveConfig(anthropicConfig)

        // Both keys should be in Keychain
        XCTAssertEqual(try keychain.getString("llm_api_key_openai"), "sk-openai-key")
        XCTAssertEqual(try keychain.getString("llm_api_key_anthropic"), "sk-ant-key")

        // loadAPIKey(for:) returns the right key per provider
        XCTAssertEqual(try store.loadAPIKey(for: .openai), "sk-openai-key")
        XCTAssertEqual(try store.loadAPIKey(for: .anthropic), "sk-ant-key")
    }

    func testDeleteOnlyClearsActiveProviderKey() throws {
        // Save keys for multiple providers
        try store.saveConfig(.openai(apiKey: "sk-openai"))
        try store.saveConfig(.anthropic(apiKey: "sk-ant"))

        // Delete clears only the active provider (anthropic) key
        try store.deleteConfig()

        XCTAssertEqual(try keychain.getString("llm_api_key_openai"), "sk-openai")
        XCTAssertNil(try keychain.getString("llm_api_key_anthropic"))
    }
}
