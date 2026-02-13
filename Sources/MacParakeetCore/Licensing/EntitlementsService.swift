import Foundation

public actor EntitlementsService: EntitlementsChecking {
    private enum Keys {
        static let trialStartISO = "trialStartISO"
        static let installID = "installID"
        static let licenseKey = "licenseKey"
        static let licenseInstanceID = "licenseInstanceID"
        static let lastValidatedISO = "lastValidatedISO"
    }

    private let config: LicensingConfig
    private let store: KeyValueStore
    private let api: LicenseAPI

    /// 7-day full-feature trial.
    private let trialLength: TimeInterval = 7 * 24 * 60 * 60

    /// One-time purchase = yours forever. Once validated, never lock out due to offline use.
    private let validationGrace: TimeInterval = .infinity

    /// Attempt validation at most once per day.
    private let validationMinInterval: TimeInterval = 24 * 60 * 60

    public init(config: LicensingConfig, store: KeyValueStore, api: LicenseAPI) {
        self.config = config
        self.store = store
        self.api = api
    }

    // MARK: - Bootstrapping

    public func bootstrapTrialIfNeeded(now: Date = Date()) {
        do {
            if try store.getString(Keys.trialStartISO) == nil {
                try store.setString(iso(now), forKey: Keys.trialStartISO)
            }
            if try store.getString(Keys.installID) == nil {
                try store.setString(UUID().uuidString, forKey: Keys.installID)
            }
        } catch {
            // Licensing should never prevent core features from running; entitlement checks will fall back to "locked"
            // only when needed.
            _ = error
        }
    }

    // MARK: - Public API

    public func currentState(now: Date = Date()) async -> EntitlementsState {
        let licenseKey = (try? store.getString(Keys.licenseKey)).flatMap { $0.isEmpty ? nil : $0 }
        let masked = licenseKey.map(maskKey(_:))
        let lastValidatedAt = (try? store.getString(Keys.lastValidatedISO)).flatMap(parseISO)

        if await isUnlocked(now: now) {
            return EntitlementsState(access: .unlocked, licenseKeyMasked: masked, lastValidatedAt: lastValidatedAt)
        }

        // Trial logic
        let trialStart = (try? store.getString(Keys.trialStartISO)).flatMap(parseISO) ?? now
        let endsAt = trialStart.addingTimeInterval(trialLength)
        if now < endsAt {
            let days = max(0, daysRemaining(until: endsAt, now: now))
            return EntitlementsState(access: .trialActive(daysRemaining: days, endsAt: endsAt), licenseKeyMasked: masked, lastValidatedAt: lastValidatedAt)
        }
        return EntitlementsState(access: .trialExpired(endedAt: endsAt), licenseKeyMasked: masked, lastValidatedAt: lastValidatedAt)
    }

    public func assertCanTranscribe(now: Date = Date()) async throws {
        let state = await currentState(now: now)
        switch state.access {
        case .unlocked, .trialActive:
            return
        case .trialExpired:
            throw EntitlementsError.trialExpired
        }
    }

    public func activate(licenseKey: String, now: Date = Date()) async throws -> EntitlementsState {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw EntitlementsError.invalidLicense("Please enter a license key.")
        }

        // Production must be configured to prevent activating a key for the wrong product.
        // (Variant IDs are not secrets; they should be embedded in Info.plist by the dist script.)
        guard config.expectedVariantID != nil else {
            throw EntitlementsError.configuration(
                "Licensing is not configured in this build. Please reinstall MacParakeet or contact support."
            )
        }

        let instanceName = try installationInstanceName()
        let activation = try await api.activate(licenseKey: key, instanceName: instanceName)

        if let expected = config.expectedVariantID,
           let actual = activation.variantID,
           expected != actual
        {
            throw EntitlementsError.invalidLicense("That license key doesn’t match this MacParakeet product.")
        }

        try store.setString(activation.licenseKey, forKey: Keys.licenseKey)
        try store.setString(activation.instanceID, forKey: Keys.licenseInstanceID)
        try store.setString(iso(now), forKey: Keys.lastValidatedISO)

        return await currentState(now: now)
    }

    public func deactivate(now: Date = Date()) async throws -> EntitlementsState {
        guard let licenseKey = try store.getString(Keys.licenseKey),
              let instanceID = try store.getString(Keys.licenseInstanceID)
        else {
            // Already deactivated.
            try? store.delete(Keys.licenseKey)
            try? store.delete(Keys.licenseInstanceID)
            try? store.delete(Keys.lastValidatedISO)
            return await currentState(now: now)
        }

        try await api.deactivate(licenseKey: licenseKey, instanceID: instanceID)
        try? store.delete(Keys.licenseKey)
        try? store.delete(Keys.licenseInstanceID)
        try? store.delete(Keys.lastValidatedISO)
        return await currentState(now: now)
    }

    public func refreshValidationIfNeeded(now: Date = Date()) async {
        do {
            guard let licenseKey = try store.getString(Keys.licenseKey),
                  let instanceID = try store.getString(Keys.licenseInstanceID)
            else { return }

            let lastValidatedAt = (try store.getString(Keys.lastValidatedISO)).flatMap(parseISO)
            if let lastValidatedAt, now.timeIntervalSince(lastValidatedAt) < validationMinInterval {
                return
            }

            let validation = try await api.validate(licenseKey: licenseKey, instanceID: instanceID)

            if let expected = config.expectedVariantID,
               let actual = validation.variantID,
               expected != actual
            {
                try? store.delete(Keys.licenseKey)
                try? store.delete(Keys.licenseInstanceID)
                try? store.delete(Keys.lastValidatedISO)
                return
            }

            if validation.valid {
                try store.setString(iso(now), forKey: Keys.lastValidatedISO)
            } else {
                // License no longer valid. Lock the app (trial may still be active).
                try? store.delete(Keys.licenseKey)
                try? store.delete(Keys.licenseInstanceID)
                try? store.delete(Keys.lastValidatedISO)
            }
        } catch {
            // Network failures shouldn't break an already-unlocked app. One-time purchase = yours
            // forever, so validated licenses stay unlocked indefinitely.
            _ = error
        }
    }

    // MARK: - Private

    private func isUnlocked(now: Date) async -> Bool {
        guard let _ = try? store.getString(Keys.licenseKey),
              let _ = try? store.getString(Keys.licenseInstanceID)
        else { return false }

        if let lastValidatedAt = (try? store.getString(Keys.lastValidatedISO)).flatMap(parseISO) {
            return now.timeIntervalSince(lastValidatedAt) <= validationGrace
        }

        // If we have a license but no validation timestamp, allow for now.
        return true
    }

    private func installationInstanceName() throws -> String {
        if let id = try store.getString(Keys.installID), !id.isEmpty {
            return "macparakeet-\(id)"
        }
        let id = UUID().uuidString
        try store.setString(id, forKey: Keys.installID)
        return "macparakeet-\(id)"
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func parseISO(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }

    private func maskKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    private func daysRemaining(until end: Date, now: Date) -> Int {
        let seconds = max(0, end.timeIntervalSince(now))
        return Int(ceil(seconds / (24 * 60 * 60)))
    }
}
