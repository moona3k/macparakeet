import Foundation
import GRDB

public enum ShareCoordinatorError: Error, Sendable, Equatable {
    /// A recovery elsewhere invalidated this device's credential. Every
    /// mutating call fails with this until the user recovers or, once every
    /// share is terminal, discards it and enrolls fresh.
    case deviceCredentialSuperseded
    case deviceCredentialMissing
    case shareNotFound
    case contentKeyUnavailable
    case contentUpdateNotEligible
    case shareNotActive
    case invalidExpiry
    case recoverySwitchBlocked
    case sharesNotTerminal
    case corruptedOutboxOperation
    case operationInProgress
    case recoveryPending
}

/// A full link is available only after confirmed creation. Pending results
/// retain durable intent but never advertise a working recipient URL.
public struct SharePublishResult: Sendable {
    public let publication: SharePublication
    public let link: ShareLink?
    public init(publication: SharePublication, link: ShareLink?) {
        self.publication = publication
        self.link = link
    }
}

/// Generated codes remain in Keychain until acknowledged as saved, including
/// across a lost network response or an interrupted presentation.
public struct ShareRecoverySetupResult: Sendable {
    public let recoveryToken: ShareRecoveryToken
    public let ownerMetadata: ShareOwnerMetadata
    public init(recoveryToken: ShareRecoveryToken, ownerMetadata: ShareOwnerMetadata) {
        self.recoveryToken = recoveryToken
        self.ownerMetadata = ownerMetadata
    }
}

/// Owns anonymous credential lifecycle, the local publication ledger, and
/// per-share outbox processing. An explicit mutation guard spans suspension
/// points; actor isolation alone does not serialize an async operation.
public actor ShareCoordinator {
    private static let defaultLifetimeSeconds: TimeInterval = 2_592_000
    private static let maxLifetimeSeconds: TimeInterval = 7_776_000

    private let repository: SharePublicationRepositoryProtocol
    private let credentialStore: ShareCredentialStoring
    private let remoteClient: ShareRemoteClientProtocol
    private let now: @Sendable () -> Date

    private var isDeviceCredentialSuperseded = false
    private var activeShareIds: Set<UUID> = []
    private var mutationInProgress = false
    private var pendingResumeRequested = false

    init(
        repository: SharePublicationRepositoryProtocol,
        credentialStore: ShareCredentialStoring,
        remoteClient: ShareRemoteClientProtocol,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.remoteClient = remoteClient
        self.now = now
    }

    public init(dbQueue: DatabaseQueue, origin: ShareServiceOrigin) {
        self.init(
            repository: SharePublicationRepository(dbQueue: dbQueue),
            credentialStore: ShareCredentialStore(),
            remoteClient: ShareRemoteClient(origin: origin)
        )
    }

    // MARK: - Reads

    public func listPublications() throws -> [SharePublication] {
        try repository.fetchAll()
    }

    public func pendingOperations(shareId: UUID) throws -> [ShareOutboxOperation] {
        try repository.fetchPendingOperations(forShareId: shareId)
    }

    public func forgetCompletedPublication(shareId: UUID) async throws {
        try beginMutation()
        defer { finishMutation() }
        guard let share = try repository.fetch(id: shareId), share.deletionState == .complete else {
            throw ShareCoordinatorError.sharesNotTerminal
        }
        try credentialStore.removeContentKey(forRemoteShareId: share.remoteShareId)
        try await repository.forgetCompletedPublication(id: shareId)
    }

    public func fetchCapabilities() async throws -> ShareCapabilities {
        try await remoteClient.capabilities()
    }

    public func confirmedLink(shareId: UUID) throws -> ShareLink? {
        guard let share = try repository.fetch(id: shareId), share.isConfirmed,
            share.accessState == .active, share.deletionState == .retained,
            !share.isDetached, share.expiresAt > now(), let rawLocator = share.locator,
            let key = try credentialStore.loadContentKey(forRemoteShareId: share.remoteShareId)
        else { return nil }
        return ShareLink(locator: try ShareLocator(rawValue: rawLocator), contentKey: key)
    }

    public func refreshPublications() async throws -> [SharePublication] {
        try beginMutation()
        defer { finishMutation() }
        guard let credential = try requireConfirmedDeviceCredential() else { return try repository.fetchAll() }
        let resources = try await allRemoteShares(credential: credential)
        try await repository.reconcileResources(resources, ownerId: credential.ownerId)
        for share in try repository.fetchAll()
        where share.ownerId == credential.ownerId && share.isConfirmed && share.isTerminal
            && share.deletionState != .complete
        {
            try await repository.enqueueTerminalDelete(shareId: share.id)
            _ = try await processPendingOperations(forShareId: share.id)
        }
        return try repository.fetchAll()
    }

    private func beginMutation(allowPendingRecovery: Bool = false) throws {
        guard !mutationInProgress, activeShareIds.isEmpty else { throw ShareCoordinatorError.operationInProgress }
        if !allowPendingRecovery, try credentialStore.loadPendingDeviceCredential() != nil {
            throw ShareCoordinatorError.recoveryPending
        }
        mutationInProgress = true
    }

    private func finishMutation() {
        mutationInProgress = false
        guard pendingResumeRequested else { return }
        pendingResumeRequested = false
        Task { await resumePendingWork() }
    }

    private func allRemoteShares(credential: ShareDeviceCredential) async throws -> [ShareResource] {
        var resources: [ShareResource] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            let page = try await remoteClient.listShares(deviceToken: credential.token, cursor: cursor, limit: 50)
            for resource in page.shares {
                if let local = try repository.fetch(remoteShareId: resource.id) {
                    try validateLocatorCommitment(resource, for: local)
                }
            }
            resources.append(contentsOf: page.shares)
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw ShareClientError.unexpectedResponse }
        } while cursor != nil
        return resources
    }

    private func validateLocatorCommitment(_ resource: ShareResource, for share: SharePublication) throws {
        try validateReceiptIdentity(id: resource.id, locatorCommitment: resource.locatorCommitment, for: share)
    }

    private func validateReceiptIdentity(id: String, locatorCommitment: String, for share: SharePublication) throws {
        let expected =
            try share.locator.map { ShareVerifier.locator(try ShareLocator(rawValue: $0)) }
            ?? share.locatorCommitment
        guard id == share.remoteShareId, locatorCommitment == expected else {
            throw ShareClientError.unexpectedResponse
        }
    }

    private static func validExpiry(_ date: Date, after now: Date, maximum: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds.rounded(.down) == seconds && date > now && date <= maximum
    }

    // MARK: - Publish, update, expire, stop

    public func publish(
        bundle: ShareBundle,
        transcriptionId: UUID? = nil,
        expiresAt: Date? = nil,
        projectionManifest: Data? = nil,
        contentDigest: String? = nil
    ) async throws -> SharePublishResult {
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        try beginMutation()
        defer { finishMutation() }

        let instant = self.now()
        let now = Date(timeIntervalSince1970: instant.timeIntervalSince1970.rounded(.down))
        let resolvedExpiresAt = expiresAt ?? now.addingTimeInterval(Self.defaultLifetimeSeconds)
        let maxExpiresAt = now.addingTimeInterval(Self.maxLifetimeSeconds)
        guard Self.validExpiry(resolvedExpiresAt, after: instant, maximum: maxExpiresAt) else {
            throw ShareCoordinatorError.invalidExpiry
        }

        let link = ShareLink.generate()
        let plaintext = try bundle.encodedJSON()
        let envelope = try ShareCryptography.seal(
            plaintext: plaintext,
            contentKey: link.contentKey,
            locator: link.locator,
            contentRevision: 1
        )
        let remoteShareId = ShareIdentifiers.generate16ByteIdentifier()
        let locatorCommitment = ShareVerifier.locator(link.locator)
        let credential = try await ensureEnrolled()

        // The content key is durable before any network call, matching the
        // create outbox operation itself.
        try credentialStore.saveContentKey(link.contentKey, forRemoteShareId: remoteShareId)

        let publication = SharePublication(
            remoteShareId: remoteShareId,
            locator: link.locator.rawValue,
            locatorCommitment: locatorCommitment,
            ownerId: credential.ownerId,
            createdCredentialGeneration: credential.credentialGeneration,
            contentRevision: 1,
            createdAt: now,
            updatedAt: now,
            expiresAt: resolvedExpiresAt,
            maxExpiresAt: maxExpiresAt,
            transcriptionId: transcriptionId
        )
        let requestPayload = ShareCreateOrUpdateRequestBody(
            locator: link.locator.rawValue,
            contentRevision: 1,
            expiresAt: resolvedExpiresAt,
            envelope: envelope
        )
        let operation = ShareOutboxOperation(
            sharePublicationId: publication.id,
            sequence: 0,
            kind: .create,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(requestPayload),
            projectionManifest: projectionManifest,
            contentDigest: try contentDigest ?? bundle.contentDigest()
        )
        do {
            try await repository.createPublication(publication, initialOperation: operation)
        } catch {
            try? credentialStore.removeContentKey(forRemoteShareId: remoteShareId)
            throw error
        }

        let result = try await processPendingOperations(forShareId: publication.id) ?? publication
        return SharePublishResult(publication: result, link: try confirmedLink(shareId: publication.id))
    }

    public func updateContent(
        shareId: UUID, bundle: ShareBundle, projectionManifest: Data? = nil, contentDigest: String? = nil
    ) async throws -> SharePublication {
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        try beginMutation()
        defer { finishMutation() }
        guard let share = try repository.fetch(id: shareId) else {
            throw ShareCoordinatorError.shareNotFound
        }
        guard share.isContentUpdateEligibleLocally else {
            throw ShareCoordinatorError.contentUpdateNotEligible
        }
        guard let contentKey = try credentialStore.loadContentKey(forRemoteShareId: share.remoteShareId) else {
            throw ShareCoordinatorError.contentKeyUnavailable
        }

        guard let rawLocator = share.locator, let version = share.version else {
            throw ShareCoordinatorError.contentUpdateNotEligible
        }
        let locator = try ShareLocator(rawValue: rawLocator)
        let nextRevision = share.contentRevision + 1
        let plaintext = try bundle.encodedJSON()
        let envelope = try ShareCryptography.seal(
            plaintext: plaintext,
            contentKey: contentKey,
            locator: locator,
            contentRevision: nextRevision
        )
        let payload = ShareCreateOrUpdateRequestBody(
            locator: rawLocator,
            contentRevision: nextRevision,
            expiresAt: nil,
            envelope: envelope
        )
        let operation = ShareOutboxOperation(
            sharePublicationId: share.id,
            sequence: 0,
            kind: .contentUpdate,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(payload),
            ifMatch: "\"v\(version)\"",
            projectionManifest: projectionManifest,
            contentDigest: try contentDigest ?? bundle.contentDigest()
        )
        try await repository.enqueueOperation(operation)
        guard let updated = try await processPendingOperations(forShareId: share.id) else {
            throw ShareCoordinatorError.shareNotFound
        }
        return updated
    }

    public func changeExpiry(shareId: UUID, newExpiresAt: Date) async throws -> SharePublication {
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        try beginMutation()
        defer { finishMutation() }
        guard let share = try repository.fetch(id: shareId) else {
            throw ShareCoordinatorError.shareNotFound
        }
        let now = self.now()
        guard share.accessState == .active, now < share.expiresAt else {
            throw ShareCoordinatorError.shareNotActive
        }
        guard let version = share.version, Self.validExpiry(newExpiresAt, after: now, maximum: share.maxExpiresAt)
        else {
            throw ShareCoordinatorError.invalidExpiry
        }

        let payload = ShareExpiryChangeRequestBody(expiresAt: newExpiresAt)
        let operation = ShareOutboxOperation(
            sharePublicationId: share.id,
            sequence: 0,
            kind: .expiryChange,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(payload),
            ifMatch: "\"v\(version)\""
        )
        try await repository.enqueueOperation(operation)
        guard let updated = try await processPendingOperations(forShareId: share.id) else {
            throw ShareCoordinatorError.shareNotFound
        }
        return updated
    }

    public func stop(shareId: UUID) async throws -> SharePublication {
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        try beginMutation()
        defer { finishMutation() }
        guard try repository.fetch(id: shareId) != nil else {
            throw ShareCoordinatorError.shareNotFound
        }
        try await repository.enqueueTerminalDelete(shareId: shareId)
        guard let updated = try await processPendingOperations(forShareId: shareId) else {
            throw ShareCoordinatorError.shareNotFound
        }
        return updated
    }

    /// Best-effort restart sweep: resumes every share with queued work and
    /// retries any interrupted detach content-key cleanup. Swallows errors —
    /// this is a background sweep, not a direct user action.
    public func resumePendingWork() async {
        guard !isDeviceCredentialSuperseded else { return }
        if mutationInProgress {
            pendingResumeRequested = true
            return
        }
        do { try beginMutation() } catch { return }
        defer { finishMutation() }
        if let shareIds = try? repository.fetchShareIdsWithPendingOperations() {
            for shareId in shareIds {
                _ = try? await processPendingOperations(forShareId: shareId)
            }
        }
        await retryDetachedContentKeyCleanup()
    }

    public func retryDetachedContentKeyCleanup() async {
        guard let detached = try? repository.fetchDetachedNeedingKeyCleanup() else { return }
        for share in detached {
            try? credentialStore.removeContentKey(forRemoteShareId: share.remoteShareId)
        }
    }

    // MARK: - Recovery configuration (this device's own verifier)

    public func setUpRecovery() async throws -> ShareRecoverySetupResult {
        try beginMutation()
        defer { finishMutation() }
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        guard let credential = try requireConfirmedDeviceCredential() else {
            throw ShareCoordinatorError.deviceCredentialMissing
        }
        return try await installRecoveryVerifier(
            credential: credential, isInitialSetup: true, currentRecoveryToken: nil)
    }

    public func replaceRecovery(currentRecoveryToken: ShareRecoveryToken) async throws -> ShareRecoverySetupResult {
        try beginMutation()
        defer { finishMutation() }
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        guard let credential = try requireConfirmedDeviceCredential() else {
            throw ShareCoordinatorError.deviceCredentialMissing
        }
        return try await installRecoveryVerifier(
            credential: credential,
            isInitialSetup: false,
            currentRecoveryToken: currentRecoveryToken
        )
    }

    public func removeRecovery(currentRecoveryToken: ShareRecoveryToken) async throws -> ShareOwnerMetadata {
        try beginMutation()
        defer { finishMutation() }
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        guard let credential = try requireConfirmedDeviceCredential() else {
            throw ShareCoordinatorError.deviceCredentialMissing
        }

        // Save the intended (absent) verifier before the network call so a
        // lost response can be reconciled against `GET /owners/me`.
        guard try credentialStore.loadPendingRecoveryConfiguration() == nil else {
            throw ShareCoordinatorError.recoveryPending
        }
        let pending = SharePendingRecoveryConfiguration(
            intendedVerifier: nil, currentToken: currentRecoveryToken.rawValue, isInitialSetup: false)
        try credentialStore.savePendingRecoveryConfiguration(pending)
        let metadata = try await sendInitialRecoveryConfiguration(
            deviceToken: credential.token,
            recoveryVerifier: nil,
            isInitialSetup: false,
            currentRecoveryToken: currentRecoveryToken,
            idempotencyKey: pending.idempotencyKey
        )
        try credentialStore.clearPendingRecoveryConfiguration()
        return metadata
    }

    private func installRecoveryVerifier(
        credential: ShareDeviceCredential,
        isInitialSetup: Bool,
        currentRecoveryToken: ShareRecoveryToken?
    ) async throws -> ShareRecoverySetupResult {
        guard try credentialStore.loadPendingRecoveryConfiguration() == nil else {
            throw ShareCoordinatorError.recoveryPending
        }
        guard let ownerIdBytes = ShareBase64URL.decode(credential.ownerId) else {
            throw ShareCoordinatorError.deviceCredentialMissing
        }
        let newRecoveryToken = ShareRecoveryToken.generate(ownerId: ownerIdBytes)
        let verifier = newRecoveryToken.verifier

        // Save the intended verifier before the network call so a lost
        // response can be reconciled by comparing it to what
        // `GET /owners/me` actually reports.
        var pending = SharePendingRecoveryConfiguration(
            intendedVerifier: verifier, generatedToken: newRecoveryToken.rawValue,
            currentToken: currentRecoveryToken?.rawValue, isInitialSetup: isInitialSetup)
        try credentialStore.savePendingRecoveryConfiguration(pending)

        let metadata = try await sendInitialRecoveryConfiguration(
            deviceToken: credential.token,
            recoveryVerifier: verifier,
            isInitialSetup: isInitialSetup,
            currentRecoveryToken: currentRecoveryToken,
            idempotencyKey: pending.idempotencyKey
        )
        pending.isConfirmed = true
        pending.currentToken = nil
        try credentialStore.savePendingRecoveryConfiguration(pending)
        return ShareRecoverySetupResult(recoveryToken: newRecoveryToken, ownerMetadata: metadata)
    }

    /// Only the initial call can prove non-acceptance. Reconciliation retries
    /// retain their durable authority even when a later request is rejected.
    private func sendInitialRecoveryConfiguration(
        deviceToken: ShareDeviceToken, recoveryVerifier: String?, isInitialSetup: Bool,
        currentRecoveryToken: ShareRecoveryToken?, idempotencyKey: String
    ) async throws -> ShareOwnerMetadata {
        do {
            return try await remoteClient.configureRecovery(
                deviceToken: deviceToken, recoveryVerifier: recoveryVerifier, isInitialSetup: isInitialSetup,
                currentRecoveryToken: currentRecoveryToken, idempotencyKey: idempotencyKey)
        } catch {
            if case ShareClientError.api(let api) = error, !api.retryable,
                [
                    .invalidRequest, .unauthorized, .versionConflict, .preconditionRequired,
                    .unsupportedVersion, .payloadTooLarge,
                ].contains(api.code)
            {
                try credentialStore.clearPendingRecoveryConfiguration()
            }
            throw error
        }
    }

    public func pendingRecoveryCode() throws -> ShareRecoveryToken? {
        guard let pending = try credentialStore.loadPendingRecoveryConfiguration(), pending.isConfirmed,
            let raw = pending.generatedToken
        else { return nil }
        return try ShareRecoveryToken(rawValue: raw)
    }

    public func acknowledgeRecoveryCodeSaved() throws {
        guard !mutationInProgress else { throw ShareCoordinatorError.operationInProgress }
        guard let pending = try credentialStore.loadPendingRecoveryConfiguration(), pending.isConfirmed else {
            throw ShareCoordinatorError.recoveryPending
        }
        try credentialStore.clearPendingRecoveryConfiguration()
    }

    public func reconcileLostRecoveryConfiguration() async throws -> ShareOwnerMetadata? {
        try beginMutation()
        defer { finishMutation() }
        guard var pending = try credentialStore.loadPendingRecoveryConfiguration() else { return nil }
        guard let credential = try requireConfirmedDeviceCredential() else { return nil }
        var metadata = try await remoteClient.fetchOwnerMetadata(deviceToken: credential.token)
        if metadata.recoveryVerifier != pending.intendedVerifier {
            metadata = try await remoteClient.configureRecovery(
                deviceToken: credential.token,
                recoveryVerifier: pending.intendedVerifier, isInitialSetup: pending.isInitialSetup,
                currentRecoveryToken: try pending.currentToken.map(ShareRecoveryToken.init(rawValue:)),
                idempotencyKey: pending.idempotencyKey)
        }
        if metadata.recoveryVerifier == pending.intendedVerifier {
            if pending.generatedToken == nil {
                try credentialStore.clearPendingRecoveryConfiguration()
            } else {
                pending.isConfirmed = true
                pending.currentToken = nil
                try credentialStore.savePendingRecoveryConfiguration(pending)
            }
        }
        return metadata
    }

    // MARK: - Recovery import (this device becomes the owner via a saved code)

    /// Resubmitting the same-owner code resumes a pending import. A retry
    /// first probes the previously generated device, then sends the exact
    /// same replacement if it does not yet authenticate. A late first request
    /// therefore installs a secret that this Mac still holds.
    public func recoverOwnership(
        recoveryToken: ShareRecoveryToken,
        replacementRecoveryVerifier: String? = nil
    ) async throws -> ShareOwnerMetadata {
        try beginMutation(allowPendingRecovery: true)
        defer { finishMutation() }
        guard try credentialStore.loadPendingRecoveryConfiguration() == nil else {
            throw ShareCoordinatorError.recoveryPending
        }
        let recoveryOwnerId = ShareBase64URL.encode(recoveryToken.ownerId)
        let pending: ShareDeviceCredential
        let isRetry: Bool
        if let existing = try credentialStore.loadPendingDeviceCredential() {
            guard existing.ownerId == recoveryOwnerId,
                existing.pendingRecoveryReplacementVerifier == replacementRecoveryVerifier,
                existing.pendingRecoveryIdempotencyKey != nil
            else {
                throw ShareCoordinatorError.recoveryPending
            }
            pending = existing
            isRetry = true
            if let metadata = try await probePendingRecovery(existing) {
                return metadata
            }
        } else {
            if let current = try credentialStore.loadDeviceCredential(), current.ownerId != recoveryOwnerId {
                try await requireCurrentOwnerFullyReconciledForSwitch()
            }
            pending = ShareDeviceCredential(
                ownerId: recoveryOwnerId, token: .generate(), credentialGeneration: 0,
                pendingRecoveryIdempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
                pendingRecoveryReplacementVerifier: replacementRecoveryVerifier)
            isRetry = false
            try credentialStore.savePendingDeviceCredential(pending)
        }
        guard let idempotencyKey = pending.pendingRecoveryIdempotencyKey else {
            throw ShareCoordinatorError.recoveryPending
        }
        do {
            let metadata = try await remoteClient.recoverOwner(
                recoveryToken: recoveryToken,
                deviceSelector: pending.token.selectorBase64URL,
                deviceVerifier: pending.token.verifier,
                recoveryVerifier: pending.pendingRecoveryReplacementVerifier,
                idempotencyKey: idempotencyKey
            )
            try confirmRecovery(pending, metadata: metadata)
            return metadata
        } catch ShareClientError.api(let error) where !error.retryable {
            if isRetry {
                // The first request may have committed after our probe.
                // Never erase its new device merely because the imported
                // one-time code is now rejected.
                if let metadata = try await probePendingRecovery(pending) { return metadata }
            } else {
                // This first request was explicitly rejected, not lost.
                try credentialStore.clearPendingDeviceCredential()
            }
            throw ShareClientError.api(error)
        }
    }

    @discardableResult
    public func reconcileLostRecoveryImport() async throws -> Bool {
        try beginMutation(allowPendingRecovery: true)
        defer { finishMutation() }
        guard let pending = try credentialStore.loadPendingDeviceCredential() else { return false }
        return try await probePendingRecovery(pending) != nil
    }

    private func probePendingRecovery(_ pending: ShareDeviceCredential) async throws -> ShareOwnerMetadata? {
        do {
            let metadata = try await remoteClient.fetchOwnerMetadata(deviceToken: pending.token)
            try confirmRecovery(pending, metadata: metadata)
            return metadata
        } catch ShareClientError.api(let error) where error.code == .unauthorized {
            // Absence may be transient. Keep pending authority for a later
            // probe or an exact retry with the user-supplied recovery code.
            return nil
        }
    }

    private func confirmRecovery(_ pending: ShareDeviceCredential, metadata: ShareOwnerMetadata) throws {
        guard metadata.ownerId == pending.ownerId, metadata.credentialGeneration > 0 else {
            throw ShareClientError.unexpectedResponse
        }
        try credentialStore.saveDeviceCredential(
            ShareDeviceCredential(
                ownerId: metadata.ownerId,
                token: pending.token, credentialGeneration: metadata.credentialGeneration))
        try credentialStore.clearPendingDeviceCredential()
        isDeviceCredentialSuperseded = false
    }

    private func requireCurrentOwnerFullyReconciledForSwitch() async throws {
        guard let credential = try requireConfirmedDeviceCredential() else { return }
        let resources = try await allRemoteShares(credential: credential)
        try await repository.reconcileResources(resources, ownerId: credential.ownerId)
        guard resources.allSatisfy({ $0.accessState != .active && $0.deletionState == .complete }),
            try repository.fetchAll().filter({ $0.ownerId == credential.ownerId }).allSatisfy({
                $0.isTerminal && $0.deletionState == .complete
            })
        else {
            throw ShareCoordinatorError.recoverySwitchBlocked
        }
        guard try repository.fetchShareIdsWithPendingOperations().isEmpty else {
            throw ShareCoordinatorError.recoverySwitchBlocked
        }
    }

    /// Available only once every share is terminal and no work is pending —
    /// this permanently forgets the current owner. It never migrates shares
    /// and does not invalidate a recovery token the user may have saved.
    public func discardCredentialAfterRecoveryLoss() async throws {
        try beginMutation()
        defer { finishMutation() }
        do { try await requireCurrentOwnerFullyReconciledForSwitch() } catch ShareCoordinatorError.recoverySwitchBlocked
        { throw ShareCoordinatorError.sharesNotTerminal }
        try credentialStore.clearDeviceCredential()
        try credentialStore.clearPendingDeviceCredential()
        try credentialStore.clearPendingRecoveryConfiguration()
        isDeviceCredentialSuperseded = false
    }

    // MARK: - Enrollment

    private func requireConfirmedDeviceCredential() throws -> ShareDeviceCredential? {
        guard let credential = try credentialStore.loadDeviceCredential(), credential.credentialGeneration > 0 else {
            return nil
        }
        return credential
    }

    @discardableResult
    private func ensureEnrolled() async throws -> ShareDeviceCredential {
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }

        if let credential = try requireConfirmedDeviceCredential() {
            return credential
        }

        let pendingCredential: ShareDeviceCredential
        if let existing = try credentialStore.loadDeviceCredential() {
            pendingCredential = existing
        } else {
            let ownerId = ShareIdentifiers.generate16ByteIdentifier()
            let token = ShareDeviceToken.generate()
            let unconfirmed = ShareDeviceCredential(ownerId: ownerId, token: token, credentialGeneration: 0)
            // Durable before the network call: a restart before a response
            // ever arrives must retry the exact same generated identity.
            try credentialStore.saveDeviceCredential(unconfirmed)
            pendingCredential = unconfirmed
        }

        let idempotencyKey = ShareIdentifiers.deriveEnrollmentIdempotencyKey(ownerId: pendingCredential.ownerId)
        do {
            let metadata = try await remoteClient.enrollOwner(
                ownerId: pendingCredential.ownerId,
                deviceSelector: pendingCredential.token.selectorBase64URL,
                deviceVerifier: pendingCredential.token.verifier,
                recoveryVerifier: nil,
                idempotencyKey: idempotencyKey
            )
            return try confirmEnrollment(pendingCredential: pendingCredential, metadata: metadata)
        } catch ShareClientError.api(let apiError) where apiError.code == .enrollmentConflict {
            // A genuine collision on 16 random bytes is cryptographically
            // negligible, so a conflict here overwhelmingly means our own
            // earlier attempt already succeeded and the idempotency receipt
            // has since expired. Confirm with the credential we already
            // generated instead of guessing.
            let metadata = try await remoteClient.fetchOwnerMetadata(deviceToken: pendingCredential.token)
            return try confirmEnrollment(pendingCredential: pendingCredential, metadata: metadata)
        }
    }

    private func confirmEnrollment(
        pendingCredential: ShareDeviceCredential,
        metadata: ShareOwnerMetadata
    ) throws -> ShareDeviceCredential {
        let confirmed = ShareDeviceCredential(
            ownerId: metadata.ownerId,
            token: pendingCredential.token,
            credentialGeneration: metadata.credentialGeneration
        )
        try credentialStore.saveDeviceCredential(confirmed)
        return confirmed
    }

    // MARK: - Outbox processing

    private enum ExecutionOutcome {
        case advanced
        case stop
        case stopAndThrow(Error)
    }

    private enum ErrorClassification {
        case retry
        case superseded
        case definitive(ShareAPIError)
    }

    private func classify(_ error: Error) -> ErrorClassification {
        switch error {
        case ShareClientError.api(let apiError):
            if apiError.code == .unauthorized { return .superseded }
            return apiError.retryable ? .retry : .definitive(apiError)
        case ShareClientError.network, ShareClientError.unapprovedOrigin, ShareClientError.unexpectedResponse:
            return .retry
        default:
            return .retry
        }
    }

    @discardableResult
    private func processPendingOperations(forShareId shareId: UUID) async throws -> SharePublication? {
        guard !isDeviceCredentialSuperseded else { throw ShareCoordinatorError.deviceCredentialSuperseded }
        guard !activeShareIds.contains(shareId) else {
            return try repository.fetch(id: shareId)
        }
        activeShareIds.insert(shareId)
        defer { activeShareIds.remove(shareId) }

        let credential = try await ensureEnrolled()

        while true {
            guard let operation = try repository.fetchNextPendingOperation(forShareId: shareId) else { break }
            switch await execute(operation, deviceToken: credential.token) {
            case .advanced:
                continue
            case .stop:
                return try repository.fetch(id: shareId)
            case .stopAndThrow(let error):
                throw error
            }
        }
        return try repository.fetch(id: shareId)
    }

    private func execute(_ operation: ShareOutboxOperation, deviceToken: ShareDeviceToken) async -> ExecutionOutcome {
        guard let share = (try? repository.fetch(id: operation.sharePublicationId)) ?? nil else {
            return .stop
        }
        let isFirstAttempt: Bool
        do { isFirstAttempt = try await repository.recordAttempt(operationId: operation.id) } catch {
            return .stopAndThrow(error)
        }

        switch operation.kind {
        case .create:
            return await executeCreate(
                operation, share: share, deviceToken: deviceToken, isFirstAttempt: isFirstAttempt)
        case .contentUpdate, .expiryChange:
            return await executeMutation(operation, share: share, deviceToken: deviceToken)
        case .delete:
            return await executeDelete(operation, share: share, deviceToken: deviceToken)
        }
    }

    private func executeCreate(
        _ operation: ShareOutboxOperation,
        share: SharePublication,
        deviceToken: ShareDeviceToken,
        isFirstAttempt: Bool
    ) async -> ExecutionOutcome {
        do {
            guard
                case .resource(let resource) = try await remoteClient.sendPersistedOperation(
                    operation,
                    shareId: share.remoteShareId, deviceToken: deviceToken)
            else {
                throw ShareCoordinatorError.corruptedOutboxOperation
            }
            try validateLocatorCommitment(resource, for: share)
            try await repository.confirmOperation(operation, resource: resource)
            return .advanced
        } catch {
            switch classify(error) {
            case .retry: return .stop
            case .superseded:
                isDeviceCredentialSuperseded = true
                return .stopAndThrow(ShareCoordinatorError.deviceCredentialSuperseded)
            case .definitive(let apiError):
                // A validation rejection of the very first request proves
                // this freshly generated share was never accepted. This is
                // not true after any uncertain attempt or a conflict.
                // A queued stop then cancels only a never-published intent;
                // discarding it is not a remote deletion-complete receipt.
                let rejectsBeforeAcceptance: [ShareServiceErrorCode] = [
                    .invalidRequest, .invalidExpiry, .payloadTooLarge, .unsupportedVersion, .preconditionRequired,
                ]
                if isFirstAttempt && rejectsBeforeAcceptance.contains(apiError.code) {
                    do {
                        if try await repository.discardRejectedInitialPublication(operation) {
                            try? credentialStore.removeContentKey(forRemoteShareId: share.remoteShareId)
                            return .stopAndThrow(ShareClientError.api(apiError))
                        }
                    } catch { return .stopAndThrow(error) }
                }
                // Any conflict can follow an earlier successful request whose
                // receipt expired. A failed/absent listing is not permission
                // to erase uncertain creation or its queued revocation.
                do {
                    if let resource = try await reconcileCreateViaList(
                        remoteShareId: share.remoteShareId, deviceToken: deviceToken)
                    {
                        try await repository.confirmOperation(operation, resource: resource)
                        return .advanced
                    }
                } catch { return .stop }
                return .stopAndThrow(ShareClientError.api(apiError))
            }
        }
    }

    private func executeMutation(
        _ operation: ShareOutboxOperation,
        share: SharePublication,
        deviceToken: ShareDeviceToken
    ) async -> ExecutionOutcome {
        do {
            guard
                case .resource(let resource) = try await remoteClient.sendPersistedOperation(
                    operation,
                    shareId: share.remoteShareId, deviceToken: deviceToken)
            else {
                throw ShareCoordinatorError.corruptedOutboxOperation
            }
            try validateLocatorCommitment(resource, for: share)
            try await repository.confirmOperation(operation, resource: resource)
            return .advanced
        } catch {
            switch classify(error) {
            case .retry: return .stop
            case .superseded:
                isDeviceCredentialSuperseded = true
                return .stopAndThrow(ShareCoordinatorError.deviceCredentialSuperseded)
            case .definitive(let apiError):
                // Reconcile before dropping a stale request: the original
                // mutation may have succeeded outside the receipt window.
                do {
                    guard
                        let resource = try await reconcileCreateViaList(
                            remoteShareId: share.remoteShareId, deviceToken: deviceToken)
                    else {
                        return .stopAndThrow(ShareClientError.api(apiError))
                    }
                    var reconciled = operation
                    let expectedRevision = try? ShareServiceJSON.makeDecoder()
                        .decode(ShareCreateOrUpdateRequestBody.self, from: operation.requestBody).contentRevision
                    if operation.kind == .contentUpdate && resource.contentRevision != expectedRevision {
                        // Never attribute our selection to someone else's revision.
                        reconciled.projectionManifest = share.projectionManifest
                        reconciled.contentDigest = share.contentDigest
                    }
                    try await repository.confirmOperation(reconciled, resource: resource)
                    if operation.kind == .contentUpdate && resource.contentRevision == expectedRevision {
                        return .advanced
                    }
                    if operation.kind == .expiryChange,
                        let requested = try? ShareServiceJSON.makeDecoder().decode(
                            ShareExpiryChangeRequestBody.self, from: operation.requestBody),
                        requested.expiresAt == resource.expiresAt
                    {
                        return .advanced
                    }
                } catch { return .stop }
                return .stopAndThrow(ShareClientError.api(apiError))
            }
        }
    }

    private func executeDelete(
        _ operation: ShareOutboxOperation,
        share: SharePublication,
        deviceToken: ShareDeviceToken
    ) async -> ExecutionOutcome {
        do {
            guard
                case .deletion(let receipt) = try await remoteClient.sendPersistedOperation(
                    operation,
                    shareId: share.remoteShareId, deviceToken: deviceToken)
            else {
                throw ShareCoordinatorError.corruptedOutboxOperation
            }
            try validateReceiptIdentity(id: receipt.id, locatorCommitment: receipt.locatorCommitment, for: share)
            try await repository.confirmDelete(
                operation, receipt: receipt, nextKey: ShareIdentifiers.generateIdempotencyKey())
            if receipt.deletionState == .complete {
                try? credentialStore.removeContentKey(forRemoteShareId: share.remoteShareId)
                return .advanced
            }
            return .stop
        } catch {
            switch classify(error) {
            case .retry: return .stop
            case .superseded:
                isDeviceCredentialSuperseded = true
                return .stopAndThrow(ShareCoordinatorError.deviceCredentialSuperseded)
            case .definitive(let apiError):
                return .stopAndThrow(ShareClientError.api(apiError))
            }
        }
    }

    private func reconcileCreateViaList(
        remoteShareId: String,
        deviceToken: ShareDeviceToken
    ) async throws -> ShareResource? {
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            let page = try await remoteClient.listShares(deviceToken: deviceToken, cursor: cursor, limit: 50)
            if let match = page.shares.first(where: { $0.id == remoteShareId }) {
                if let local = try repository.fetch(remoteShareId: remoteShareId) {
                    try validateLocatorCommitment(match, for: local)
                }
                return match
            }
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw ShareClientError.unexpectedResponse }
        } while cursor != nil
        return nil
    }
}
