import XCTest
@testable import MacParakeetCore

final class ShareCredentialStoreTests: XCTestCase {
    var backing: InMemoryKeyValueStore!
    var store: ShareCredentialStore!

    override func setUp() {
        backing = InMemoryKeyValueStore()
        store = ShareCredentialStore(store: backing)
    }

    private func makeCredential(generation: Int = 1) -> ShareDeviceCredential {
        ShareDeviceCredential(
            ownerId: ShareIdentifiers.generate16ByteIdentifier(),
            token: .generate(),
            credentialGeneration: generation
        )
    }

    // MARK: - Device credential

    func testDeviceCredentialIsAbsentUntilSaved() throws {
        XCTAssertNil(try store.loadDeviceCredential())
    }

    func testDeviceCredentialRoundTripsExactly() throws {
        let credential = makeCredential()
        try store.saveDeviceCredential(credential)

        let loaded = try XCTUnwrap(store.loadDeviceCredential())
        XCTAssertEqual(loaded.ownerId, credential.ownerId)
        XCTAssertEqual(loaded.token, credential.token)
        XCTAssertEqual(loaded.credentialGeneration, credential.credentialGeneration)
    }

    func testDeviceCredentialSurvivesAFreshStoreInstanceOverTheSameBacking() throws {
        // Simulates a restart: a new `ShareCredentialStore` wraps the same
        // durable backing store.
        let credential = makeCredential()
        try store.saveDeviceCredential(credential)

        let afterRestart = ShareCredentialStore(store: backing)
        XCTAssertEqual(try afterRestart.loadDeviceCredential(), try store.loadDeviceCredential())
    }

    func testClearDeviceCredentialRemovesIt() throws {
        try store.saveDeviceCredential(makeCredential())
        try store.clearDeviceCredential()
        XCTAssertNil(try store.loadDeviceCredential())
    }

    func testCorruptedDeviceCredentialRecordThrowsRatherThanSilentlyDroppingIt() throws {
        try backing.setString("{not valid json", forKey: "device.credential")
        XCTAssertThrowsError(try store.loadDeviceCredential())
    }

    // MARK: - Pending device credential is a separate slot

    func testPendingDeviceCredentialDoesNotAffectCurrentDeviceCredential() throws {
        let current = makeCredential(generation: 1)
        try store.saveDeviceCredential(current)

        let pending = makeCredential(generation: 0)
        try store.savePendingDeviceCredential(pending)

        XCTAssertEqual(try store.loadDeviceCredential(), current)
        XCTAssertEqual(try store.loadPendingDeviceCredential(), pending)

        try store.clearPendingDeviceCredential()
        XCTAssertNil(try store.loadPendingDeviceCredential())
        XCTAssertEqual(try store.loadDeviceCredential(), current, "clearing pending must never touch current")
    }

    // MARK: - Pending recovery configuration distinguishes "no change" from "intended removal"

    func testNoPendingRecoveryConfigurationByDefault() throws {
        XCTAssertNil(try store.loadPendingRecoveryConfiguration())
    }

    func testPendingRecoveryConfigurationCanRepresentAnIntendedInstall() throws {
        try store.savePendingRecoveryConfiguration(SharePendingRecoveryConfiguration(intendedVerifier: "verifier-value"))
        let loaded = try XCTUnwrap(store.loadPendingRecoveryConfiguration())
        XCTAssertEqual(loaded.intendedVerifier, "verifier-value")
    }

    func testPendingRecoveryConfigurationCanRepresentAnIntendedRemoval() throws {
        try store.savePendingRecoveryConfiguration(SharePendingRecoveryConfiguration(intendedVerifier: nil))
        // The outer Optional must be non-nil (a change IS pending) even
        // though the intended verifier itself is nil.
        let loaded = try store.loadPendingRecoveryConfiguration()
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.intendedVerifier)
    }

    func testClearingPendingRecoveryConfigurationReturnsToNoPendingChange() throws {
        try store.savePendingRecoveryConfiguration(SharePendingRecoveryConfiguration(intendedVerifier: "v"))
        try store.clearPendingRecoveryConfiguration()
        XCTAssertNil(try store.loadPendingRecoveryConfiguration())
    }

    // MARK: - Per-share content keys

    func testContentKeyRoundTripsPerShareAndRemovesIndependently() throws {
        let keyA = ShareContentKey.generate()
        let keyB = ShareContentKey.generate()
        try store.saveContentKey(keyA, forRemoteShareId: "share-a")
        try store.saveContentKey(keyB, forRemoteShareId: "share-b")

        XCTAssertEqual(try store.loadContentKey(forRemoteShareId: "share-a"), keyA)
        XCTAssertEqual(try store.loadContentKey(forRemoteShareId: "share-b"), keyB)

        try store.removeContentKey(forRemoteShareId: "share-a")
        XCTAssertNil(try store.loadContentKey(forRemoteShareId: "share-a"))
        XCTAssertEqual(try store.loadContentKey(forRemoteShareId: "share-b"), keyB, "removal must be per-share")
    }

    func testRemovingAnAlreadyAbsentContentKeyIsIdempotent() throws {
        XCTAssertNoThrow(try store.removeContentKey(forRemoteShareId: "never-existed"))
    }

    func testCorruptedContentKeyRecordFailsClosedToNilRatherThanThrowing() throws {
        try backing.setString("not-a-valid-content-key", forKey: "contentKey.share-a")
        XCTAssertNil(try store.loadContentKey(forRemoteShareId: "share-a"))
    }
}
