import Foundation

public final class VoiceControlCredentialStore {
    private let store = KeychainKeyValueStore(service: "com.macparakeet.voice-control.jev")
    public init() {}
    public func loadAPIKey() throws -> String? { try store.getString("apiKey") }
    public func saveAPIKey(_ value: String) throws {
        if value.isEmpty { try store.delete("apiKey") } else { try store.setString(value, forKey: "apiKey") }
    }
}

public final class VoiceControlConsentStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var hasConsent: Bool {
        get { defaults.bool(forKey: "voiceControl.cloudContextConsent.v1") }
        set { defaults.set(newValue, forKey: "voiceControl.cloudContextConsent.v1") }
    }
}
