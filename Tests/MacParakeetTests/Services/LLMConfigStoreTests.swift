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

        // Verify apiKey is in Keychain
        let keychainValue = try keychain.getString("llm_api_key")
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
        XCTAssertNil(try keychain.getString("llm_api_key"))
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
        XCTAssertNil(try store.loadAPIKey())

        try store.saveAPIKey("sk-direct")
        XCTAssertEqual(try store.loadAPIKey(), "sk-direct")

        try store.deleteAPIKey()
        XCTAssertNil(try store.loadAPIKey())
    }

    func testMissingKeychainKeyReturnsConfigWithNilAPIKey() throws {
        // Save config with apiKey, then delete only the Keychain entry
        let config = LLMProviderConfig.openai(apiKey: "sk-test")
        try store.saveConfig(config)
        try keychain.delete("llm_api_key")

        let loaded = try store.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, .openai)
        XCTAssertNil(loaded?.apiKey)
    }
}
