import Foundation
@testable import MacParakeetCore

final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    var getError: Error?
    var readCount = 0
    var setError: Error?
    var deleteError: Error?

    func getString(_ key: String) throws -> String? {
        readCount += 1
        if let getError { throw getError }
        return values[key]
    }

    func setString(_ value: String, forKey key: String) throws {
        if let setError { throw setError }
        values[key] = value
    }

    func delete(_ key: String) throws {
        if let deleteError { throw deleteError }
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
        return LicenseActivation(
            licenseKey: licenseKey, instanceID: activateResult.instanceID, variantID: activateResult.variantID)
    }

    func validate(licenseKey: String, instanceID: String?) async throws -> LicenseValidation {
        if shouldThrow { throw EntitlementsError.network("offline") }
        return validateResult
    }

    func deactivate(licenseKey: String, instanceID: String) async throws {
        if shouldThrow { throw EntitlementsError.network("offline") }
    }
}
