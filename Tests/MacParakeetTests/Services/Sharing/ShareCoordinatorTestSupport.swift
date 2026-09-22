import Foundation
@testable import MacParakeetCore

/// A fully scriptable `ShareRemoteClientProtocol` fake. Every method defaults
/// to throwing `.unconfigured` so an un-scripted call fails loudly instead of
/// silently returning a guessed value.
final class FakeShareRemoteClient: ShareRemoteClientProtocol, @unchecked Sendable {
    struct Unconfigured: Error { let method: String }

    var capabilitiesHandler: () async throws -> ShareCapabilities = {
        throw Unconfigured(method: "capabilities")
    }
    var enrollOwnerHandler: (String, String, String, String?, String) async throws -> ShareOwnerMetadata = {
        _, _, _, _, _ in
        throw Unconfigured(method: "enrollOwner")
    }
    var fetchOwnerMetadataHandler: (ShareDeviceToken) async throws -> ShareOwnerMetadata = { _ in
        throw Unconfigured(method: "fetchOwnerMetadata")
    }
    var recoverOwnerHandler: (ShareRecoveryToken, String, String, String?, String) async throws -> ShareOwnerMetadata =
        {
            _, _, _, _, _ in
            throw Unconfigured(method: "recoverOwner")
        }
    var configureRecoveryHandler:
        (ShareDeviceToken, String?, Bool, ShareRecoveryToken?, String) async throws -> ShareOwnerMetadata = {
            _, _, _, _, _ in
            throw Unconfigured(method: "configureRecovery")
        }
    var listSharesHandler: (ShareDeviceToken, String?, Int) async throws -> ShareListPage = { _, _, _ in
        throw Unconfigured(method: "listShares")
    }
    var createShareHandler:
        (ShareDeviceToken, String, String, Int, Date, ShareEnvelope, String) async throws ->
            ShareResource = { _, _, _, _, _, _, _ in
                throw Unconfigured(method: "createShare")
            }
    var updateShareContentHandler:
        (ShareDeviceToken, String, String, Int, ShareEnvelope, String, String) async throws -> ShareResource = {
            _, _, _, _, _, _, _ in
            throw Unconfigured(method: "updateShareContent")
        }
    var changeExpiryHandler: (ShareDeviceToken, String, Date, String, String) async throws -> ShareResource = {
        _, _, _, _, _ in
        throw Unconfigured(method: "changeExpiry")
    }
    var deleteShareHandler: (ShareDeviceToken, String, String, String) async throws -> ShareDeletionReceipt = {
        _, _, _, _ in
        throw Unconfigured(method: "deleteShare")
    }

    func capabilities() async throws -> ShareCapabilities {
        try await capabilitiesHandler()
    }

    func enrollOwner(
        ownerId: String,
        deviceSelector: String,
        deviceVerifier: String,
        recoveryVerifier: String?,
        idempotencyKey: String
    ) async throws -> ShareOwnerMetadata {
        try await enrollOwnerHandler(ownerId, deviceSelector, deviceVerifier, recoveryVerifier, idempotencyKey)
    }

    func fetchOwnerMetadata(deviceToken: ShareDeviceToken) async throws -> ShareOwnerMetadata {
        try await fetchOwnerMetadataHandler(deviceToken)
    }

    func recoverOwner(
        recoveryToken: ShareRecoveryToken,
        deviceSelector: String,
        deviceVerifier: String,
        recoveryVerifier: String?,
        idempotencyKey: String
    ) async throws -> ShareOwnerMetadata {
        try await recoverOwnerHandler(recoveryToken, deviceSelector, deviceVerifier, recoveryVerifier, idempotencyKey)
    }

    func configureRecovery(
        deviceToken: ShareDeviceToken,
        recoveryVerifier: String?,
        isInitialSetup: Bool,
        currentRecoveryToken: ShareRecoveryToken?,
        idempotencyKey: String
    ) async throws -> ShareOwnerMetadata {
        try await configureRecoveryHandler(
            deviceToken, recoveryVerifier, isInitialSetup, currentRecoveryToken, idempotencyKey
        )
    }

    func listShares(deviceToken: ShareDeviceToken, cursor: String?, limit: Int) async throws -> ShareListPage {
        try await listSharesHandler(deviceToken, cursor, limit)
    }

    func createShare(
        deviceToken: ShareDeviceToken,
        shareId: String,
        locator: String,
        contentRevision: Int,
        expiresAt: Date,
        envelope: ShareEnvelope,
        idempotencyKey: String
    ) async throws -> ShareResource {
        try await createShareHandler(
            deviceToken, shareId, locator, contentRevision, expiresAt, envelope, idempotencyKey)
    }

    func updateShareContent(
        deviceToken: ShareDeviceToken,
        shareId: String,
        locator: String,
        contentRevision: Int,
        envelope: ShareEnvelope,
        ifMatch: String,
        idempotencyKey: String
    ) async throws -> ShareResource {
        try await updateShareContentHandler(
            deviceToken, shareId, locator, contentRevision, envelope, ifMatch, idempotencyKey
        )
    }

    func changeExpiry(
        deviceToken: ShareDeviceToken,
        shareId: String,
        expiresAt: Date,
        ifMatch: String,
        idempotencyKey: String
    ) async throws -> ShareResource {
        try await changeExpiryHandler(deviceToken, shareId, expiresAt, ifMatch, idempotencyKey)
    }

    func deleteShare(
        deviceToken: ShareDeviceToken,
        shareId: String,
        locatorCommitment: String,
        idempotencyKey: String
    ) async throws -> ShareDeletionReceipt {
        try await deleteShareHandler(deviceToken, shareId, locatorCommitment, idempotencyKey)
    }
}

/// Builds a `ShareResource` success response that mirrors what a real
/// service would return for the given request, keeping coordinator tests
/// focused on coordinator behavior instead of hand-rolled fixture plumbing.
func makeConfirmedResource(
    shareId: String,
    locatorCommitment: String,
    contentRevision: Int,
    version: Int,
    contentWritable: Bool = true,
    accessState: SharePublication.AccessState = .active,
    deletionState: SharePublication.DeletionState = .retained,
    expiresAt: Date,
    maxExpiresAt: Date,
    terminalAt: Date? = nil
) -> ShareResource {
    ShareResource(
        id: shareId,
        locatorCommitment: locatorCommitment,
        contentRevision: contentRevision,
        version: version,
        contentWritable: contentWritable,
        accessState: accessState,
        deletionState: deletionState,
        ciphertextBytes: 128,
        createdAt: Date(timeIntervalSince1970: 1_789_084_800),
        updatedAt: Date(timeIntervalSince1970: 1_789_084_800),
        expiresAt: expiresAt,
        maxExpiresAt: maxExpiresAt,
        terminalAt: terminalAt
    )
}

func makeNotesBundle(_ markdown: String = "Owner-authored notes.") throws -> ShareBundle {
    try ShareBundle(
        publishedAt: Date(timeIntervalSince1970: 1_789_084_800),
        sections: [.notes(title: "Notes", markdown: markdown)]
    )
}
