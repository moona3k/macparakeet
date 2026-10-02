import XCTest
import Security
@testable import MacParakeetCore

final class KeychainInteractionTests: XCTestCase {
    func testInteractionIsDisabledDuringAccessAndRestoredAfterSuccess() throws {
        let before = try interactionAllowed()
        let result = try KeychainKeyValueStore.withoutUserInteraction {
            XCTAssertFalse(try interactionAllowed())
            return "result"
        }
        XCTAssertEqual(result, "result")
        XCTAssertEqual(try interactionAllowed(), before)
    }

    func testInteractionIsRestoredAfterFailure() throws {
        let before = try interactionAllowed()
        XCTAssertThrowsError(
            try KeychainKeyValueStore.withoutUserInteraction {
                XCTAssertFalse(try interactionAllowed())
                throw KeyValueStoreError.unsupported
            })
        XCTAssertEqual(try interactionAllowed(), before)
    }

    func testDeniedAccessHasActionableErrorAndRetainsStatus() {
        let error = KeychainError(status: errSecInteractionNotAllowed)
        XCTAssertEqual(error.status, errSecInteractionNotAllowed)
        XCTAssertTrue(error.localizedDescription.contains("Keychain Access"))
    }

    func testLockedPrivateKeychainFailsWithoutAuthenticationUI() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-keychain-test-" + UUID().uuidString + ".keychain-db").path
        var keychain: SecKeychain?
        let password = "synthetic-test-password"
        let created = try KeychainKeyValueStore.withoutUserInteraction {
            password.withCString {
                SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain)
            }
        }
        guard created == errSecSuccess, let keychain else {
            throw XCTSkip("Private test Keychain unavailable: \(created)")
        }
        defer { SecKeychainDelete(keychain) }
        let service = "com.macparakeet.test." + UUID().uuidString
        let added = try KeychainKeyValueStore.withoutUserInteraction {
            SecItemAdd(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "fixture",
                    kSecValueData as String: Data("synthetic-value".utf8),
                    kSecUseKeychain as String: keychain,
                ] as CFDictionary, nil)
        }
        XCTAssertEqual(added, errSecSuccess)
        XCTAssertEqual(SecKeychainLock(keychain), errSecSuccess)
        let status = try KeychainKeyValueStore.withoutUserInteraction {
            var result: CFTypeRef?
            return SecItemCopyMatching(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "fixture",
                    kSecMatchSearchList as String: [keychain],
                    kSecReturnData as String: true,
                ] as CFDictionary, &result)
        }
        XCTAssertTrue([errSecInteractionNotAllowed, errSecAuthFailed].contains(status), "Status: \(status)")
    }

    private func interactionAllowed() throws -> Bool {
        var allowed = DarwinBoolean(false)
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return allowed.boolValue
    }
}
