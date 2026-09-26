import CoreFoundation
import Darwin
import Foundation

/// The persisted route a picker displayed. Credentials are deliberately excluded
/// from identity; inheritance and the old model are part of the precondition.
public struct LLMModelSelectionRoute: Equatable, Sendable {
    public let config: LLMProviderConfig
    public let isOverride: Bool

    public init(config: LLMProviderConfig, isOverride: Bool) {
        self.config = LLMProviderConfig(
            id: config.id, baseURL: config.baseURL, apiKey: nil,
            modelName: config.modelName, isLocal: config.isLocal)
        self.isOverride = isOverride
    }
}

public protocol LLMConfigStoreProtocol: Sendable {
    func loadConfig() throws -> LLMProviderConfig?
    func loadConfig(for task: LLMTaskGroup) throws -> LLMProviderConfig?
    func saveConfig(_ config: LLMProviderConfig) throws
    func deleteConfig() throws
    func loadAPIKey() throws -> String?
    func loadAPIKey(for provider: LLMProviderID) throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
    func updateModelName(_ modelName: String) throws
    /// Compare and update the displayed route as one operation. False means no write.
    func updateModelName(_ modelName: String, for task: LLMTaskGroup, expected: LLMModelSelectionRoute) throws -> Bool
    func loadTaskOverride(_ task: LLMTaskGroup) throws -> LLMProviderConfig?
    /// Return the effective metadata captured during publication for a reliable mutation receipt.
    @discardableResult
    func saveTaskOverride(_ config: LLMProviderConfig?, for task: LLMTaskGroup) throws -> LLMModelSelectionRoute?
    func saveConfiguration(
        _ config: LLMProviderConfig,
        cleanupOverride: LLMProviderConfig?,
        analysisOverride: LLMProviderConfig?
    ) throws
    /// Persisted metadata only: no Keychain access and apiKey is nil.
    func loadConfigMetadata() throws -> LLMProviderConfig?
    func loadTaskOverrideMetadata(_ task: LLMTaskGroup) throws -> LLMProviderConfig?
    /// Resolve override/inheritance from one coherent metadata snapshot.
    func loadRouteMetadata(for task: LLMTaskGroup) throws -> LLMModelSelectionRoute?
}

extension LLMConfigStoreProtocol {
    public func updateModelName(_ modelName: String, for task: LLMTaskGroup) throws {
        guard let route = try loadRouteMetadata(for: task) else { return }
        _ = try updateModelName(modelName, for: task, expected: route)
    }

    public func loadTaskOverride(_ task: LLMTaskGroup) throws -> LLMProviderConfig? { nil }
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

// @unchecked Sendable: one nonblocking operation lease serializes mutations
// across instances/processes. Credential mutations retain the lease through
// authorization so a busy rejection cannot change keys. Hydrated reads release
// the lease before Keychain access; other operations fail busy during a mutation.
public final class LLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    enum StoreError: LocalizedError {
        case busy, invalidLock, lockIO(Int32), refreshFailed, publicationUnconfirmed, taskCredentialChanged

        var errorDescription: String? {
            switch self {
            case .busy: return "AI settings are being updated. Try again."
            case .invalidLock: return "The AI settings lock is not a private regular file."
            case .lockIO(let code): return "Could not lock AI settings (errno \(code))."
            case .refreshFailed: return "Could not refresh AI settings. No change was attempted."
            case .publicationUnconfirmed:
                return "AI settings may have changed, but saving could not be confirmed. Refresh before retrying."
            case .taskCredentialChanged:
                return "A task provider's saved API key changed. Reopen AI settings and try again."
            }
        }
    }

    private static let configKey = "llm_provider_config"
    private static func taskOverrideKey(_ task: LLMTaskGroup) -> String { "llm_provider_config_\(task.rawValue)" }
    private static var metadataKeys: [String] { [configKey, taskOverrideKey(.cleanup), taskOverrideKey(.analysis)] }
    private let domain: String
    private let lockURL: URL
    private let keychain: KeyValueStore
    private let synchronizePreferences: @Sendable (String) -> Bool

    /// App, dev app and CLI deliberately share this preferences domain and lock,
    /// independent of the dev app's isolated database/audio directory.
    public convenience init(keychain: KeyValueStore = KeychainKeyValueStore(service: "com.macparakeet.llm")) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(
            preferencesDomain: AppPaths.preferencesSuiteName,
            lockURL: support.appendingPathComponent(AppPaths.preferencesSuiteName).appendingPathComponent(
                "llm-routes.lock"),
            keychain: keychain)
    }

    /// Explicit domain and lock injection prevents opaque UserDefaults objects
    /// from accidentally routing tests or helpers into production preferences.
    public convenience init(
        preferencesDomain: String, lockURL: URL,
        keychain: KeyValueStore = KeychainKeyValueStore(service: "com.macparakeet.llm")
    ) {
        self.init(
            preferencesDomain: preferencesDomain, lockURL: lockURL, keychain: keychain,
            synchronizePreferences: { CFPreferencesAppSynchronize($0 as CFString) })
    }

    // Internal seam for deterministic refresh/publication I/O failure tests.
    init(
        preferencesDomain: String, lockURL: URL, keychain: KeyValueStore,
        synchronizePreferences: @escaping @Sendable (String) -> Bool
    ) {
        self.domain = preferencesDomain
        self.lockURL = lockURL
        self.keychain = keychain
        self.synchronizePreferences = synchronizePreferences
    }

    private static func apiKeyKeychainKey(for provider: LLMProviderID) -> String { "llm_api_key_\(provider.rawValue)" }

    private func withOperationLease<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw StoreError.lockIO(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw StoreError.lockIO(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            throw StoreError.invalidLock
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw StoreError.busy }
            throw StoreError.lockIO(errno)
        }
        // Refresh before any precondition or credential mutation. The publisher
        // explicitly confirms metadata before close releases the lease.
        // Do not unlink the shared lock file.
        guard synchronizePreferences(domain) else { throw StoreError.refreshFailed }
        return try body()
    }

    private func publish() throws {
        // An I/O failure here is indeterminate, not a rejected/no-change write.
        // Do not retry or roll back shared credentials over an external rotation.
        guard synchronizePreferences(domain) else { throw StoreError.publicationUnconfirmed }
    }

    private func data(for key: String) -> Data? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Data
    }

    private func write(_ data: Data?, for key: String) {
        CFPreferencesSetAppValue(key as CFString, data as CFData?, domain as CFString)
    }

    private func metadata(for key: String) throws -> LLMProviderConfig? {
        try data(for: key).map { try JSONDecoder().decode(LLMProviderConfig.self, from: $0) }
    }

    private func route(for task: LLMTaskGroup) throws -> LLMModelSelectionRoute? {
        if task.allowsOverride, let config = try metadata(for: Self.taskOverrideKey(task)) {
            return LLMModelSelectionRoute(config: config, isOverride: true)
        }
        return try metadata(for: Self.configKey).map { LLMModelSelectionRoute(config: $0, isOverride: false) }
    }

    private func hydrated(_ metadata: LLMProviderConfig?) throws -> LLMProviderConfig? {
        guard let metadata else { return nil }
        return LLMProviderConfig(
            id: metadata.id, baseURL: metadata.baseURL, apiKey: try loadAPIKey(for: metadata.id),
            modelName: metadata.modelName, isLocal: metadata.isLocal)
    }

    public func loadConfig() throws -> LLMProviderConfig? { try hydrated(loadConfigMetadata()) }
    public func loadConfig(for task: LLMTaskGroup) throws -> LLMProviderConfig? {
        try hydrated(loadRouteMetadata(for: task)?.config)
    }
    public func loadTaskOverride(_ task: LLMTaskGroup) throws -> LLMProviderConfig? {
        try hydrated(loadTaskOverrideMetadata(task))
    }
    public func loadConfigMetadata() throws -> LLMProviderConfig? {
        try withOperationLease { try metadata(for: Self.configKey) }
    }
    public func loadTaskOverrideMetadata(_ task: LLMTaskGroup) throws -> LLMProviderConfig? {
        guard task.allowsOverride else { return nil }
        return try withOperationLease { try metadata(for: Self.taskOverrideKey(task)) }
    }
    public func loadRouteMetadata(for task: LLMTaskGroup) throws -> LLMModelSelectionRoute? {
        try withOperationLease { try route(for: task) }
    }

    public func saveConfig(_ config: LLMProviderConfig) throws {
        let data = try JSONEncoder().encode(config)
        try withOperationLease {
            if config.id != .localCLI {
                let key = Self.apiKeyKeychainKey(for: config.id)
                if let value = config.apiKey {
                    try keychain.setString(value, forKey: key)
                } else {
                    try keychain.delete(key)
                }
            }
            write(data, for: Self.configKey)
            try publish()
        }
    }

    public func deleteConfig() throws {
        try withOperationLease {
            // Corrupt metadata remains clearable, without guessing its provider.
            if let data = data(for: Self.configKey),
                let config = try? JSONDecoder().decode(LLMProviderConfig.self, from: data)
            {
                try keychain.delete(Self.apiKeyKeychainKey(for: config.id))
            }
            Self.metadataKeys.forEach { write(nil, for: $0) }
            try publish()
        }
    }

    public func loadAPIKey() throws -> String? {
        guard let config = try loadConfigMetadata() else { return nil }
        return try loadAPIKey(for: config.id)
    }
    public func loadAPIKey(for provider: LLMProviderID) throws -> String? {
        try keychain.getString(Self.apiKeyKeychainKey(for: provider))
    }
    public func saveAPIKey(_ key: String) throws {
        try withOperationLease {
            guard let config = try metadata(for: Self.configKey) else { return }
            try keychain.setString(key, forKey: Self.apiKeyKeychainKey(for: config.id))
        }
    }
    public func deleteAPIKey() throws {
        try withOperationLease {
            guard let config = try metadata(for: Self.configKey) else { return }
            try keychain.delete(Self.apiKeyKeychainKey(for: config.id))
        }
    }

    private func replaceModel(_ modelName: String, in config: LLMProviderConfig, key: String) throws {
        let updated = LLMProviderConfig(
            id: config.id, baseURL: config.baseURL, apiKey: nil, modelName: modelName, isLocal: config.isLocal)
        write(try JSONEncoder().encode(updated), for: key)
    }

    public func updateModelName(_ modelName: String) throws {
        try withOperationLease {
            guard let config = try metadata(for: Self.configKey) else { return }
            try replaceModel(modelName, in: config, key: Self.configKey)
            try publish()
        }
    }
    public func updateModelName(_ modelName: String, for task: LLMTaskGroup, expected: LLMModelSelectionRoute) throws
        -> Bool
    {
        try withOperationLease {
            guard try route(for: task) == expected else { return false }
            let key = expected.isOverride ? Self.taskOverrideKey(task) : Self.configKey
            try replaceModel(modelName, in: expected.config, key: key)
            try publish()
            return true
        }
    }

    @discardableResult
    public func saveTaskOverride(_ config: LLMProviderConfig?, for task: LLMTaskGroup) throws -> LLMModelSelectionRoute?
    {
        guard task.allowsOverride else { return try loadRouteMetadata(for: task) }
        let encoded = try config.map { try JSONEncoder().encode($0) }
        return try withOperationLease {
            let inherited = try config == nil ? metadata(for: Self.configKey) : nil
            if let config, config.id != .localCLI, let key = config.apiKey {
                try keychain.setString(key, forKey: Self.apiKeyKeychainKey(for: config.id))
            }
            write(encoded, for: Self.taskOverrideKey(task))
            try publish()
            return (config ?? inherited).map { LLMModelSelectionRoute(config: $0, isOverride: config != nil) }
        }
    }

    public func saveConfiguration(
        _ config: LLMProviderConfig, cleanupOverride: LLMProviderConfig?, analysisOverride: LLMProviderConfig?
    ) throws {
        let encoder = JSONEncoder()
        let values = try [Optional(config), cleanupOverride, analysisOverride].map {
            try $0.map { try encoder.encode($0) }
        }
        try withOperationLease {
            for override in [cleanupOverride, analysisOverride].compactMap({ $0 }) {
                guard override.id != .localCLI, override.id != config.id, let key = override.apiKey else { continue }
                if try loadAPIKey(for: override.id) != key { throw StoreError.taskCredentialChanged }
            }
            if config.id != .localCLI, try loadAPIKey(for: config.id) != config.apiKey {
                let key = Self.apiKeyKeychainKey(for: config.id)
                if let value = config.apiKey {
                    try keychain.setString(value, forKey: key)
                } else {
                    try keychain.delete(key)
                }
            }
            for (key, value) in zip(Self.metadataKeys, values) { write(value, for: key) }
            try publish()
        }
    }
}
