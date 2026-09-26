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
    func updateModelName(_ modelName: String) throws
    func loadTaskOverride(_ task: LLMTaskGroup) throws -> LLMProviderConfig?
    func saveTaskOverride(_ config: LLMProviderConfig?, for task: LLMTaskGroup) throws
    func saveConfiguration(
        _ config: LLMProviderConfig,
        cleanupOverride: LLMProviderConfig?,
        analysisOverride: LLMProviderConfig?
    ) throws
    /// Persisted route metadata without touching Keychain. `apiKey` is always nil.
    func loadConfigMetadata() throws -> LLMProviderConfig?
    /// Persisted task-override metadata without touching Keychain. `apiKey` is always nil.
    func loadTaskOverrideMetadata(_ task: LLMTaskGroup) throws -> LLMProviderConfig?
}

extension LLMConfigStoreProtocol {
    /// Resolve the same inherited task route used by LLM execution.
    public func loadConfig(for task: LLMTaskGroup) throws -> LLMProviderConfig? {
        if task.allowsOverride, let override = try loadTaskOverride(task) {
            return override
        }
        return try loadConfig()
    }

    public func loadConfigMetadata() throws -> LLMProviderConfig? { try loadConfig() }
    public func loadTaskOverrideMetadata(_ task: LLMTaskGroup) throws -> LLMProviderConfig? {
        try loadTaskOverride(task)
    }

    /// Change the selected route without creating an override for an inherited task.
    public func updateModelName(_ modelName: String, for task: LLMTaskGroup) throws {
        guard task.allowsOverride, let existing = try loadTaskOverride(task) else {
            try updateModelName(modelName)
            return
        }
        let updated = LLMProviderConfig(
            id: existing.id,
            baseURL: existing.baseURL,
            apiKey: existing.apiKey,
            modelName: modelName,
            isLocal: existing.isLocal
        )
        try saveTaskOverride(updated, for: task)
    }

    public func loadTaskOverride(_ task: LLMTaskGroup) throws -> LLMProviderConfig? { nil }
    public func saveTaskOverride(_ config: LLMProviderConfig?, for task: LLMTaskGroup) throws {}
    public func saveConfiguration(
        _ config: LLMProviderConfig,
        cleanupOverride: LLMProviderConfig?,
        analysisOverride: LLMProviderConfig?
    ) throws {
        try saveConfig(config)
        try saveTaskOverride(cleanupOverride, for: .cleanup)
        try saveTaskOverride(analysisOverride, for: .analysis)
    }
}

// MARK: - Implementation

// @unchecked Sendable: UserDefaults and Keychain are internally thread-safe
public final class LLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    private enum SaveError: LocalizedError {
        case taskCredentialChanged

        var errorDescription: String? {
            "A task provider's saved API key changed. Reopen AI settings and try again."
        }
    }

    private static let configKey = "llm_provider_config"

    private static func taskOverrideKey(_ task: LLMTaskGroup) -> String {
        "llm_provider_config_\(task.rawValue)"
    }

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
        guard let decoded = try loadConfigMetadata() else { return nil }
        let apiKey = try keychain.getString(Self.apiKeyKeychainKey(for: decoded.id))
        return LLMProviderConfig(
            id: decoded.id,
            baseURL: decoded.baseURL,
            apiKey: apiKey,
            modelName: decoded.modelName,
            isLocal: decoded.isLocal
        )
    }

    public func loadConfigMetadata() throws -> LLMProviderConfig? {
        guard let data = defaults.data(forKey: Self.configKey) else { return nil }
        return try JSONDecoder().decode(LLMProviderConfig.self, from: data)
    }

    public func saveConfig(_ config: LLMProviderConfig) throws {
        // Encode config without apiKey (CodingKeys excludes it)
        let data = try JSONEncoder().encode(config)

        // Keychain updates/deletes are atomic. Complete the throwing operation
        // before replacing the working provider metadata in UserDefaults.
        if config.id != .localCLI {
            let providerKey = Self.apiKeyKeychainKey(for: config.id)
            if let apiKey = config.apiKey {
                try keychain.setString(apiKey, forKey: providerKey)
            } else {
                try keychain.delete(providerKey)
            }
        }
        defaults.set(data, forKey: Self.configKey)
    }

    public func deleteConfig() throws {
        // Only delete the active provider's key, preserving keys for other providers
        if let data = defaults.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(LLMProviderConfig.self, from: data) {
            try keychain.delete(Self.apiKeyKeychainKey(for: decoded.id))
        }
        defaults.removeObject(forKey: Self.configKey)
        defaults.removeObject(forKey: Self.taskOverrideKey(.cleanup))
        defaults.removeObject(forKey: Self.taskOverrideKey(.analysis))
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

    public func updateModelName(_ modelName: String) throws {
        guard let existing = try loadConfig() else { return }
        let updated = LLMProviderConfig(
            id: existing.id,
            baseURL: existing.baseURL,
            apiKey: existing.apiKey,
            modelName: modelName,
            isLocal: existing.isLocal
        )
        try saveConfig(updated)
    }

    public func loadTaskOverride(_ task: LLMTaskGroup) throws -> LLMProviderConfig? {
        guard let decoded = try loadTaskOverrideMetadata(task) else { return nil }
        let apiKey = try keychain.getString(Self.apiKeyKeychainKey(for: decoded.id))
        return LLMProviderConfig(
            id: decoded.id,
            baseURL: decoded.baseURL,
            apiKey: apiKey,
            modelName: decoded.modelName,
            isLocal: decoded.isLocal
        )
    }

    public func loadTaskOverrideMetadata(_ task: LLMTaskGroup) throws -> LLMProviderConfig? {
        guard task.allowsOverride else { return nil }
        guard let data = defaults.data(forKey: Self.taskOverrideKey(task)) else { return nil }
        return try JSONDecoder().decode(LLMProviderConfig.self, from: data)
    }

    public func saveTaskOverride(_ config: LLMProviderConfig?, for task: LLMTaskGroup) throws {
        guard task.allowsOverride else { return }
        let key = Self.taskOverrideKey(task)
        guard let config else {
            defaults.removeObject(forKey: key)
            return
        }
        if config.id != .localCLI, let apiKey = config.apiKey {
            try keychain.setString(apiKey, forKey: Self.apiKeyKeychainKey(for: config.id))
        }
        defaults.set(try JSONEncoder().encode(config), forKey: key)
    }

    public func saveConfiguration(
        _ config: LLMProviderConfig,
        cleanupOverride: LLMProviderConfig?,
        analysisOverride: LLMProviderConfig?
    ) throws {
        let encoder = JSONEncoder()
        let defaultData = try encoder.encode(config)
        let cleanupData = try cleanupOverride.map { try encoder.encode($0) }
        let analysisData = try analysisOverride.map { try encoder.encode($0) }

        // Alternate task providers must use credentials already in Keychain.
        // The active default's credential is the only new value from Settings.
        // Finish every throwing operation before publishing route metadata.
        for override in [cleanupOverride, analysisOverride].compactMap({ $0 }) {
            guard override.id != .localCLI, override.id != config.id,
                let key = override.apiKey
            else { continue }
            let keychainKey = Self.apiKeyKeychainKey(for: override.id)
            if try keychain.getString(keychainKey) != key {
                throw SaveError.taskCredentialChanged
            }
        }
        if config.id != .localCLI {
            let keychainKey = Self.apiKeyKeychainKey(for: config.id)
            if try keychain.getString(keychainKey) != config.apiKey {
                if let key = config.apiKey {
                    try keychain.setString(key, forKey: keychainKey)
                } else {
                    try keychain.delete(keychainKey)
                }
            }
        }

        defaults.set(defaultData, forKey: Self.configKey)
        for (task, data) in [(LLMTaskGroup.cleanup, cleanupData), (.analysis, analysisData)] {
            let key = Self.taskOverrideKey(task)
            if let data {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
