import Foundation

// MARK: - Protocol

public protocol LLMConfigStoreProtocol: Sendable {
    func loadConfig() throws -> LLMProviderConfig?
    func saveConfig(_ config: LLMProviderConfig) throws
    func deleteConfig() throws
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

// MARK: - Implementation

// @unchecked Sendable: UserDefaults and Keychain are internally thread-safe
public final class LLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    private static let configKey = "llm_provider_config"
    private static let apiKeyKeychainKey = "llm_api_key"

    private let defaults: UserDefaults
    private let keychain: KeyValueStore

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeyValueStore = KeychainKeyValueStore(service: "com.macparakeet.llm")
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func loadConfig() throws -> LLMProviderConfig? {
        guard let data = defaults.data(forKey: Self.configKey) else { return nil }
        let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: data)
        // Hydrate apiKey from Keychain (excluded from Codable) — construct new value
        let apiKey = try keychain.getString(Self.apiKeyKeychainKey)
        return LLMProviderConfig(
            id: decoded.id,
            baseURL: decoded.baseURL,
            apiKey: apiKey,
            modelName: decoded.modelName,
            isLocal: decoded.isLocal
        )
    }

    public func saveConfig(_ config: LLMProviderConfig) throws {
        // Encode config without apiKey (CodingKeys excludes it)
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: Self.configKey)

        // Save apiKey to Keychain separately
        if let apiKey = config.apiKey {
            try keychain.setString(apiKey, forKey: Self.apiKeyKeychainKey)
        } else {
            try keychain.delete(Self.apiKeyKeychainKey)
        }
    }

    public func deleteConfig() throws {
        defaults.removeObject(forKey: Self.configKey)
        try keychain.delete(Self.apiKeyKeychainKey)
    }

    public func loadAPIKey() throws -> String? {
        try keychain.getString(Self.apiKeyKeychainKey)
    }

    public func saveAPIKey(_ key: String) throws {
        try keychain.setString(key, forKey: Self.apiKeyKeychainKey)
    }

    public func deleteAPIKey() throws {
        try keychain.delete(Self.apiKeyKeychainKey)
    }
}
