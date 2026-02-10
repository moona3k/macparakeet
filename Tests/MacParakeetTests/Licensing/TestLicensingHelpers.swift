import Foundation
@testable import MacParakeetCore

final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func getString(_ key: String) throws -> String? {
        values[key]
    }

    func setString(_ value: String, forKey key: String) throws {
        values[key] = value
    }

    func delete(_ key: String) throws {
        values.removeValue(forKey: key)
    }
}

struct StubLicenseAPI: LicenseAPI {
    var activateResult: LicenseActivation
    var validateResult: LicenseValidation
    var shouldThrow: Bool = false

    init() {
        activateResult = LicenseActivation(licenseKey: "TEST-KEY", instanceID: "inst_123", variantID: nil)
        validateResult = LicenseValidation(valid: true, variantID: nil)
    }

    func activate(licenseKey: String, instanceName: String) async throws -> LicenseActivation {
        if shouldThrow { throw EntitlementsError.network("offline") }
        return LicenseActivation(licenseKey: licenseKey, instanceID: activateResult.instanceID, variantID: activateResult.variantID)
    }

    func validate(licenseKey: String, instanceID: String?) async throws -> LicenseValidation {
        if shouldThrow { throw EntitlementsError.network("offline") }
        return validateResult
    }

    func deactivate(licenseKey: String, instanceID: String) async throws {
        if shouldThrow { throw EntitlementsError.network("offline") }
    }
}

