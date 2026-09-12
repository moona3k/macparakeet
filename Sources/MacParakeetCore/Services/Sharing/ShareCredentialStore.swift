import Foundation

/// The device's current owner authority: a device token plus the owner and
/// credential generation it authenticates as. Never persisted alongside
/// content, and never written to GRDB or UserDefaults.
public struct ShareDeviceCredential: Sendable, Equatable {
    public var ownerId: String
    public var token: ShareDeviceToken
    public var credentialGeneration: Int

    public init(ownerId: String, token: ShareDeviceToken, credentialGeneration: Int) {
        self.ownerId = ownerId
        self.token = token
        self.credentialGeneration = credentialGeneration
    }
}

/// A recovery-configuration change (install, replace, or remove) the app
/// intends to make, saved before the network request so a lost response can
/// be reconciled by comparing this intended verifier against the verifier
/// `GET /owners/me` actually reports. `intendedVerifier == nil` represents an
/// intended removal.
public struct SharePendingRecoveryConfiguration: Codable, Sendable, Equatable {
    public var intendedVerifier: String?
    public var generatedToken: String?
    public var idempotencyKey: String
    public var isConfirmed: Bool
    public var currentToken: String?
    public var isInitialSetup: Bool

    public init(intendedVerifier: String?, generatedToken: String? = nil, idempotencyKey: String = ShareIdentifiers.generateIdempotencyKey(), isConfirmed: Bool = false, currentToken: String? = nil, isInitialSetup: Bool = true) {
        self.intendedVerifier = intendedVerifier
        self.generatedToken = generatedToken
        self.idempotencyKey = idempotencyKey
        self.isConfirmed = isConfirmed
        self.currentToken = currentToken
        self.isInitialSetup = isInitialSetup
    }
}

public enum ShareCredentialStoreError: Error, Sendable, Equatable {
    case corruptedRecord
}

/// Durable storage for anonymous sharing credentials, separate from every
/// other credential store in the app (KTD3). Storage is injectable so tests
/// never touch the real Keychain.
public protocol ShareCredentialStoring: Sendable {
    func loadDeviceCredential() throws -> ShareDeviceCredential?
    func saveDeviceCredential(_ credential: ShareDeviceCredential) throws
    func clearDeviceCredential() throws

    /// The new device credential a recovery-import request intends to
    /// install, saved before that request so a lost response can be probed
    /// with `GET /owners/me` after restart.
    func loadPendingDeviceCredential() throws -> ShareDeviceCredential?
    func savePendingDeviceCredential(_ credential: ShareDeviceCredential) throws
    func clearPendingDeviceCredential() throws

    func loadPendingRecoveryConfiguration() throws -> SharePendingRecoveryConfiguration?
    func savePendingRecoveryConfiguration(_ configuration: SharePendingRecoveryConfiguration) throws
    func clearPendingRecoveryConfiguration() throws

    func loadContentKey(forRemoteShareId shareId: String) throws -> ShareContentKey?
    func saveContentKey(_ key: ShareContentKey, forRemoteShareId shareId: String) throws
    func removeContentKey(forRemoteShareId shareId: String) throws
}

/// The dedicated, non-synchronizing, device-only Keychain namespace for
/// sharing. This wraps the same primitive `KeychainKeyValueStore` Licensing
/// uses, but under its own service name — sharing identity never shares a
/// namespace with licensing or LLM credentials, and it sets no biometric or
/// application-password access flags.
public final class ShareCredentialStore: ShareCredentialStoring {
    private static let defaultService = "com.macparakeet.sharing"

    private let store: KeyValueStore

    public convenience init() {
        self.init(store: KeychainKeyValueStore(service: Self.defaultService))
    }

    public init(store: KeyValueStore) {
        self.store = store
    }

    // MARK: - Device credential

    public func loadDeviceCredential() throws -> ShareDeviceCredential? {
        try load(StoredDeviceCredential.self, forKey: Key.device).map(Self.credential(from:))
    }

    public func saveDeviceCredential(_ credential: ShareDeviceCredential) throws {
        try save(Self.stored(from: credential), forKey: Key.device)
    }

    public func clearDeviceCredential() throws {
        try store.delete(Key.device)
    }

    // MARK: - Pending device credential (recovery-import in flight)

    public func loadPendingDeviceCredential() throws -> ShareDeviceCredential? {
        try load(StoredDeviceCredential.self, forKey: Key.pendingDevice).map(Self.credential(from:))
    }

    public func savePendingDeviceCredential(_ credential: ShareDeviceCredential) throws {
        try save(Self.stored(from: credential), forKey: Key.pendingDevice)
    }

    public func clearPendingDeviceCredential() throws {
        try store.delete(Key.pendingDevice)
    }

    // MARK: - Pending recovery configuration

    public func loadPendingRecoveryConfiguration() throws -> SharePendingRecoveryConfiguration? {
        try load(SharePendingRecoveryConfiguration.self, forKey: Key.pendingRecoveryConfiguration)
    }

    public func savePendingRecoveryConfiguration(_ configuration: SharePendingRecoveryConfiguration) throws {
        try save(
            configuration,
            forKey: Key.pendingRecoveryConfiguration
        )
    }

    public func clearPendingRecoveryConfiguration() throws {
        try store.delete(Key.pendingRecoveryConfiguration)
    }

    // MARK: - Per-share content keys

    public func loadContentKey(forRemoteShareId shareId: String) throws -> ShareContentKey? {
        guard let raw = try store.getString(Key.contentKey(shareId)) else { return nil }
        return try? ShareContentKey(rawValue: raw)
    }

    public func saveContentKey(_ key: ShareContentKey, forRemoteShareId shareId: String) throws {
        try store.setString(key.rawValue, forKey: Key.contentKey(shareId))
    }

    public func removeContentKey(forRemoteShareId shareId: String) throws {
        try store.delete(Key.contentKey(shareId))
    }

    // MARK: - Serialization helpers

    private enum Key {
        static let device = "device.credential"
        static let pendingDevice = "device.pendingCredential"
        static let pendingRecoveryConfiguration = "device.pendingRecoveryConfiguration"
        static func contentKey(_ remoteShareId: String) -> String { "contentKey.\(remoteShareId)" }
    }

    private struct StoredDeviceCredential: Codable {
        var ownerId: String
        var selector: String
        var secret: String
        var generation: Int
    }

    private static func stored(from credential: ShareDeviceCredential) -> StoredDeviceCredential {
        StoredDeviceCredential(
            ownerId: credential.ownerId,
            selector: credential.token.selectorBase64URL,
            secret: credential.token.secretBase64URL,
            generation: credential.credentialGeneration
        )
    }

    private static func credential(from stored: StoredDeviceCredential) throws -> ShareDeviceCredential {
        guard let selector = ShareBase64URL.decode(stored.selector),
            let secret = ShareBase64URL.decode(stored.secret),
            selector.count == 16, secret.count == 32
        else {
            throw ShareCredentialStoreError.corruptedRecord
        }
        return ShareDeviceCredential(
            ownerId: stored.ownerId,
            token: ShareDeviceToken(selector: selector, secret: secret),
            credentialGeneration: stored.generation
        )
    }

    private func load<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let raw = try store.getString(key), let data = raw.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ShareCredentialStoreError.corruptedRecord
        }
        try store.setString(string, forKey: key)
    }
}
