import Foundation

// MARK: - Protocol

public protocol LLMConfigStoreProtocol: Sendable {
    func loadConfig() throws -> LLMProviderConfig?
    func saveConfig(_ config: LLMProviderConfig) throws
    func deleteConfig() throws
    func loadAPIKey() throws -> String?
    func loadAPIKey(for provider: LLMProviderID) throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

// MARK: - Implementation

// @unchecked Sendable: UserDefaults and Keychain are internally thread-safe
public final class LLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    private static let configKey = "llm_provider_config"

    private let defaults: UserDefaults
    private let keychain: KeyValueStore

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeyValueStore = KeychainKeyValueStore(service: "com.macparakeet.llm")
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// Per-provider Keychain key so switching providers preserves all saved keys.
    private static func apiKeyKeychainKey(for provider: LLMProviderID) -> String {
        "llm_api_key_\(provider.rawValue)"
    }

    public func loadConfig() throws -> LLMProviderConfig? {
        guard let data = defaults.data(forKey: Self.configKey) else { return nil }
        let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: data)
        let apiKey = try keychain.getString(Self.apiKeyKeychainKey(for: decoded.id))
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

        // Save apiKey to per-provider Keychain key
        let providerKey = Self.apiKeyKeychainKey(for: config.id)
        if let apiKey = config.apiKey {
            try keychain.setString(apiKey, forKey: providerKey)
        } else {
            try keychain.delete(providerKey)
        }
    }

    public func deleteConfig() throws {
        // Only delete the active provider's key, preserving keys for other providers
        if let data = defaults.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(LLMProviderConfig.self, from: data) {
            try keychain.delete(Self.apiKeyKeychainKey(for: decoded.id))
        }
        defaults.removeObject(forKey: Self.configKey)
    }

    public func loadAPIKey() throws -> String? {
        // Load key for the currently saved provider
        guard let data = defaults.data(forKey: Self.configKey),
              let decoded = try? JSONDecoder().decode(LLMProviderConfig.self, from: data) else {
            return nil
        }
        return try loadAPIKey(for: decoded.id)
    }

    public func loadAPIKey(for provider: LLMProviderID) throws -> String? {
        try keychain.getString(Self.apiKeyKeychainKey(for: provider))
    }

    public func saveAPIKey(_ key: String) throws {
        // Save key for the currently saved provider
        guard let data = defaults.data(forKey: Self.configKey),
              let decoded = try? JSONDecoder().decode(LLMProviderConfig.self, from: data) else {
            return
        }
        try keychain.setString(key, forKey: Self.apiKeyKeychainKey(for: decoded.id))
    }

    public func deleteAPIKey() throws {
        guard let data = defaults.data(forKey: Self.configKey),
              let decoded = try? JSONDecoder().decode(LLMProviderConfig.self, from: data) else {
            return
        }
        try keychain.delete(Self.apiKeyKeychainKey(for: decoded.id))
    }
}
