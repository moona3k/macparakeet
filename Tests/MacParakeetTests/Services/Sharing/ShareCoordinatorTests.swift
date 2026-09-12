import XCTest
@testable import MacParakeetCore

final class ShareCoordinatorTests: XCTestCase {
    var manager: DatabaseManager!
    var repository: SharePublicationRepository!
    var credentialBacking: InMemoryKeyValueStore!
    var credentialStore: ShareCredentialStore!
    var remoteClient: FakeShareRemoteClient!
    var coordinator: ShareCoordinator!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repository = SharePublicationRepository(dbQueue: manager.dbQueue)
        credentialBacking = InMemoryKeyValueStore()
        credentialStore = ShareCredentialStore(store: credentialBacking)
        remoteClient = FakeShareRemoteClient()
        coordinator = ShareCoordinator(
            repository: repository, credentialStore: credentialStore, remoteClient: remoteClient)

        // Enrollment succeeds by default; individual tests override only
        // what they need to script differently.
        remoteClient.enrollOwnerHandler = { ownerId, _, _, _, _ in
            ShareOwnerMetadata(ownerId: ownerId, credentialGeneration: 1, recoveryVerifier: nil)
        }
    }

    private func succeedingCreateHandler()
        -> (ShareDeviceToken, String, String, Int, Date, ShareEnvelope, String) async throws -> ShareResource
    {
        { _, shareId, locator, contentRevision, expiresAt, _, _ in
            makeConfirmedResource(
                shareId: shareId,
                locatorCommitment: ShareVerifier.locator(try ShareLocator(rawValue: locator)),
                contentRevision: contentRevision,
                version: 1,
                expiresAt: expiresAt,
                maxExpiresAt: expiresAt.addingTimeInterval(5_184_000)
            )
        }
    }

    // MARK: - First publish and enrollment

    func testFirstPublishGeneratesOneOwnerCredentialAndStoresNoSecretOutsideKeychainStore() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()

        let result = try await coordinator.publish(bundle: try makeNotesBundle())

        XCTAssertTrue(result.publication.isConfirmed)
        XCTAssertEqual(result.publication.accessState, .active)

        let credential = try XCTUnwrap(credentialStore.loadDeviceCredential())
        XCTAssertEqual(credential.credentialGeneration, 1)

        // The link's content key must never appear anywhere in the persisted
        // ledger row — it lives only in the dedicated Keychain-backed store.
        let contentKeyRaw = try XCTUnwrap(result.link).contentKey.rawValue
        let persisted = try XCTUnwrap(repository.fetch(id: result.publication.id))
        XCTAssertFalse(persisted.remoteShareId.contains(contentKeyRaw))
        XCTAssertFalse(persisted.locator?.contains(contentKeyRaw) ?? false)
        XCTAssertFalse(persisted.locatorCommitment.contains(contentKeyRaw))
        XCTAssertFalse(persisted.ownerId.contains(contentKeyRaw))
    }

    func testEnrollmentConflictOnRetryReconcilesWithOwnerMetadataInsteadOfFailing() async throws {
        remoteClient.enrollOwnerHandler = { _, _, _, _, _ in
            throw ShareClientError.api(ShareAPIError(code: .enrollmentConflict, retryable: false, requestId: nil))
        }
        remoteClient.fetchOwnerMetadataHandler = { token in
            ShareOwnerMetadata(ownerId: "reconciled-owner", credentialGeneration: 1, recoveryVerifier: nil)
        }
        remoteClient.createShareHandler = succeedingCreateHandler()

        let result = try await coordinator.publish(bundle: try makeNotesBundle())
        XCTAssertTrue(result.publication.isConfirmed)

        let credential = try XCTUnwrap(credentialStore.loadDeviceCredential())
        XCTAssertEqual(credential.ownerId, "reconciled-owner")
    }

    // MARK: - Expiry defaults and boundaries

    func testDefaultExpiryIsThirtyDaysAndRequestedValueIsSentToTheService() async throws {
        var capturedExpiresAt: Date?
        remoteClient.createShareHandler = { _, shareId, locator, contentRevision, expiresAt, _, _ in
            capturedExpiresAt = expiresAt
            return makeConfirmedResource(
                shareId: shareId, locatorCommitment: ShareVerifier.locator(try ShareLocator(rawValue: locator)),
                contentRevision: contentRevision, version: 1,
                expiresAt: expiresAt, maxExpiresAt: expiresAt.addingTimeInterval(5_184_000)
            )
        }

        let before = Date()
        _ = try await coordinator.publish(bundle: try makeNotesBundle())
        let after = Date()

        let expiresAt = try XCTUnwrap(capturedExpiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince(before), 2_592_000, accuracy: after.timeIntervalSince(before) + 1)
    }

    func testExactNinetyDayExpiryIsAcceptedButOneSecondBeyondIsRejectedLocally() async throws {
        var createCallCount = 0
        remoteClient.createShareHandler = { _, shareId, locator, contentRevision, expiresAt, _, _ in
            createCallCount += 1
            return makeConfirmedResource(
                shareId: shareId, locatorCommitment: ShareVerifier.locator(try ShareLocator(rawValue: locator)),
                contentRevision: contentRevision, version: 1,
                expiresAt: expiresAt, maxExpiresAt: expiresAt.addingTimeInterval(5_184_000)
            )
        }

        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        coordinator = ShareCoordinator(
            repository: repository, credentialStore: credentialStore, remoteClient: remoteClient, now: { now })
        let atBoundary = try await coordinator.publish(
            bundle: try makeNotesBundle(), expiresAt: now.addingTimeInterval(7_776_000)
        )
        XCTAssertTrue(atBoundary.publication.isConfirmed)
        XCTAssertEqual(createCallCount, 1)

        do {
            _ = try await coordinator.publish(
                bundle: try makeNotesBundle(), expiresAt: now.addingTimeInterval(7_776_001))
            XCTFail("expected invalidExpiry")
        } catch ShareCoordinatorError.invalidExpiry {
            // expected — rejected before any network call
        }
        XCTAssertEqual(createCallCount, 1, "an invalid expiry must never reach the network")
    }

    // MARK: - Restart resumes a pending create with the same idempotency key

    func testRestartRetriesAPendingCreateWithTheSameIdempotencyKey() async throws {
        var seenIdempotencyKeys: [String] = []
        var shouldFail = true
        remoteClient.createShareHandler = { _, shareId, locator, contentRevision, expiresAt, _, idempotencyKey in
            seenIdempotencyKeys.append(idempotencyKey)
            if shouldFail {
                throw ShareClientError.network
            }
            return makeConfirmedResource(
                shareId: shareId, locatorCommitment: ShareVerifier.locator(try ShareLocator(rawValue: locator)),
                contentRevision: contentRevision, version: 1,
                expiresAt: expiresAt, maxExpiresAt: expiresAt.addingTimeInterval(5_184_000)
            )
        }

        let result = try await coordinator.publish(bundle: try makeNotesBundle())
        XCTAssertFalse(result.publication.isConfirmed, "a network failure must leave the share pending, not thrown")
        XCTAssertNil(result.link, "unconfirmed creation never exposes a recipient URL")

        shouldFail = false
        await coordinator.resumePendingWork()

        let publications = try await coordinator.listPublications()
        let confirmed = try XCTUnwrap(publications.first { $0.id == result.publication.id })
        XCTAssertTrue(confirmed.isConfirmed)
        let recoveredLink = try await coordinator.confirmedLink(shareId: confirmed.id)
        XCTAssertNotNil(recoveredLink)
        XCTAssertEqual(seenIdempotencyKeys.count, 2)
        XCTAssertEqual(
            seenIdempotencyKeys[0], seenIdempotencyKeys[1], "retry must reuse the exact same idempotency key")
    }

    // MARK: - Lost create response reconciles instead of double-creating

    func testVersionConflictOnCreateReconciliesViaOwnerListingInsteadOfCreatingASecondShare() async throws {
        var capturedShareId: String?
        var capturedCommitment: String?
        remoteClient.createShareHandler = { _, shareId, locator, _, _, _, _ in
            capturedShareId = shareId
            capturedCommitment = ShareVerifier.locator(try ShareLocator(rawValue: locator))
            throw ShareClientError.api(ShareAPIError(code: .versionConflict, retryable: false, requestId: nil))
        }
        remoteClient.listSharesHandler = { _, _, _ in
            let shareId = capturedShareId ?? ""
            let now = Date(timeIntervalSince1970: 1_789_084_800)
            return ShareListPage(
                shares: [
                    makeConfirmedResource(
                        shareId: shareId, locatorCommitment: try XCTUnwrap(capturedCommitment), contentRevision: 1,
                        version: 1,
                        expiresAt: now.addingTimeInterval(2_592_000), maxExpiresAt: now.addingTimeInterval(7_776_000)
                    )
                ],
                nextCursor: nil
            )
        }

        let result = try await coordinator.publish(bundle: try makeNotesBundle())
        XCTAssertTrue(result.publication.isConfirmed)
        XCTAssertEqual(result.publication.locatorCommitment, capturedCommitment)
        XCTAssertEqual(try repository.fetchAll().count, 1, "reconciliation must never leave a second row")
    }

    // MARK: - Content update eligibility

    func testMismatchedCreateCommitmentPreservesUncertainOutboxAndKey() async throws {
        remoteClient.createShareHandler = { _, shareId, _, revision, expiresAt, _, _ in
            makeConfirmedResource(
                shareId: shareId, locatorCommitment: ShareVerifier.locator(.generate()),
                contentRevision: revision, version: 1,
                expiresAt: expiresAt, maxExpiresAt: expiresAt.addingTimeInterval(3600))
        }
        let result = try await coordinator.publish(bundle: makeNotesBundle())
        XCTAssertFalse(result.publication.isConfirmed)
        XCTAssertNil(result.link)
        let pending = try XCTUnwrap(repository.fetchPendingOperations(forShareId: result.publication.id).first)
        XCTAssertEqual(pending.kind, .create)
        XCTAssertNotNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))

        remoteClient.createShareHandler = { _, _, _, _, _, _, _ in
            throw ShareClientError.api(ShareAPIError(code: .versionConflict, retryable: false, requestId: nil))
        }
        remoteClient.listSharesHandler = { _, _, _ in
            ShareListPage(
                shares: [
                    makeConfirmedResource(
                        shareId: result.publication.remoteShareId,
                        locatorCommitment: ShareVerifier.locator(.generate()),
                        contentRevision: 1, version: 1, expiresAt: result.publication.expiresAt,
                        maxExpiresAt: result.publication.maxExpiresAt)
                ], nextCursor: nil)
        }
        await coordinator.resumePendingWork()
        let persisted = try XCTUnwrap(repository.fetch(id: result.publication.id))
        XCTAssertFalse(persisted.isConfirmed)
        XCTAssertEqual(persisted.locatorCommitment, result.publication.locatorCommitment)
        let retried = try XCTUnwrap(repository.fetchPendingOperations(forShareId: persisted.id).first)
        XCTAssertEqual(retried.id, pending.id)
        XCTAssertEqual(retried.idempotencyKey, pending.idempotencyKey)
        XCTAssertEqual(retried.requestBody, pending.requestBody)
        XCTAssertNotNil(try credentialStore.loadContentKey(forRemoteShareId: persisted.remoteShareId))

        remoteClient.createShareHandler = succeedingCreateHandler()
        await coordinator.resumePendingWork()
        XCTAssertTrue(try XCTUnwrap(repository.fetch(id: persisted.id)).isConfirmed)
        XCTAssertTrue(try repository.fetchPendingOperations(forShareId: persisted.id).isEmpty)
    }

    func testRefreshRejectsMismatchedCommitmentWithoutOverwritingLocalAuthority() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let result = try await coordinator.publish(bundle: makeNotesBundle())
        remoteClient.listSharesHandler = { _, _, _ in
            ShareListPage(
                shares: [
                    makeConfirmedResource(
                        shareId: result.publication.remoteShareId,
                        locatorCommitment: ShareVerifier.locator(.generate()),
                        contentRevision: 1, version: 2, expiresAt: result.publication.expiresAt,
                        maxExpiresAt: result.publication.maxExpiresAt)
                ], nextCursor: nil)
        }
        do {
            _ = try await coordinator.refreshPublications()
            XCTFail("a mismatched receipt cannot replace local revocation authority")
        } catch ShareClientError.unexpectedResponse {}
        let persisted = try XCTUnwrap(repository.fetch(id: result.publication.id))
        XCTAssertEqual(persisted.locatorCommitment, result.publication.locatorCommitment)
        XCTAssertEqual(persisted.version, result.publication.version)
    }

    func testContentUpdateIsRejectedLocallyWhenTheGenerationCannotWriteWithoutHittingTheNetwork() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let result = try await coordinator.publish(bundle: try makeNotesBundle())

        // Simulate a receipt that marks this share management-only, as a
        // recovered old-generation share would be.
        var notWritable = try XCTUnwrap(repository.fetch(id: result.publication.id))
        notWritable.contentWritable = false
        let updatedPublication = notWritable
        try await manager.dbQueue.write { db in try updatedPublication.update(db) }

        remoteClient.updateShareContentHandler = { _, _, _, _, _, _, _ in
            XCTFail("must not reach the network for an ineligible update")
            throw FakeShareRemoteClient.Unconfigured(method: "updateShareContent")
        }

        do {
            _ = try await coordinator.updateContent(shareId: result.publication.id, bundle: try makeNotesBundle("v2"))
            XCTFail("expected contentUpdateNotEligible")
        } catch ShareCoordinatorError.contentUpdateNotEligible {
            // expected
        }
    }

    // MARK: - Stop / delete lifecycle

    func testStopConfirmsButPendingCleanupRotatesTheIdempotencyKeyForTheNextCheck() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let result = try await coordinator.publish(bundle: try makeNotesBundle())

        var seenKeys: [String] = []
        remoteClient.deleteShareHandler = { _, shareId, locatorCommitment, idempotencyKey in
            seenKeys.append(idempotencyKey)
            return ShareDeletionReceipt(
                id: shareId, locatorCommitment: locatorCommitment, accessState: .stopped, deletionState: .pending
            )
        }

        let stopped = try await coordinator.stop(shareId: result.publication.id)
        XCTAssertEqual(stopped.accessState, .stopped)
        XCTAssertEqual(stopped.deletionState, .pending)

        let ops = try repository.fetchPendingOperations(forShareId: result.publication.id)
        XCTAssertEqual(ops.count, 1)
        XCTAssertNotEqual(ops.first?.idempotencyKey, seenKeys.first, "a pending cleanup receipt must rotate the key")
    }

    func testStopCompletionRemovesTheOutboxOperationAndTheContentKey() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let result = try await coordinator.publish(bundle: try makeNotesBundle())
        XCTAssertNotNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))

        remoteClient.deleteShareHandler = { _, shareId, locatorCommitment, _ in
            ShareDeletionReceipt(
                id: shareId, locatorCommitment: locatorCommitment, accessState: .stopped, deletionState: .complete
            )
        }

        _ = try await coordinator.stop(shareId: result.publication.id)

        XCTAssertTrue(try repository.fetchPendingOperations(forShareId: result.publication.id).isEmpty)
        XCTAssertNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))
    }

    func testDeleteNeverFalselyFinishesOnAnUnknownLocator() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let result = try await coordinator.publish(bundle: try makeNotesBundle())

        remoteClient.deleteShareHandler = { _, _, _, _ in
            throw ShareClientError.api(ShareAPIError(code: .notFound, retryable: false, requestId: nil))
        }

        do {
            _ = try await coordinator.stop(shareId: result.publication.id)
            XCTFail("expected the notFound error to surface")
        } catch ShareClientError.api(let apiError) {
            XCTAssertEqual(apiError.code, .notFound)
        }

        // Never falsely completed: the terminal operation is still queued.
        let ops = try repository.fetchPendingOperations(forShareId: result.publication.id)
        XCTAssertEqual(ops.map(\.kind), [.delete])
    }

    func testMismatchedCompleteDeleteReceiptPreservesKeyAndOutboxUntilValidRetry() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let result = try await coordinator.publish(bundle: makeNotesBundle())
        remoteClient.deleteShareHandler = { _, id, _, _ in
            ShareDeletionReceipt(
                id: id, locatorCommitment: ShareVerifier.locator(.generate()),
                accessState: .stopped, deletionState: .complete)
        }
        _ = try await coordinator.stop(shareId: result.publication.id)
        let pending = try XCTUnwrap(repository.fetchPendingOperations(forShareId: result.publication.id).first)
        XCTAssertEqual(pending.kind, .delete)
        XCTAssertNotNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))
        let unchanged = try XCTUnwrap(repository.fetch(id: result.publication.id))
        XCTAssertEqual(unchanged.locatorCommitment, result.publication.locatorCommitment)
        XCTAssertNotEqual(unchanged.deletionState, .complete)

        remoteClient.deleteShareHandler = { _, _, commitment, _ in
            ShareDeletionReceipt(
                id: ShareIdentifiers.generate16ByteIdentifier(), locatorCommitment: commitment,
                accessState: .stopped, deletionState: .complete)
        }
        await coordinator.resumePendingWork()
        let retried = try XCTUnwrap(repository.fetchPendingOperations(forShareId: result.publication.id).first)
        XCTAssertEqual(retried.id, pending.id)
        XCTAssertEqual(retried.idempotencyKey, pending.idempotencyKey)
        XCTAssertEqual(retried.requestBody, pending.requestBody)
        XCTAssertNotNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))

        remoteClient.deleteShareHandler = { _, id, commitment, _ in
            ShareDeletionReceipt(id: id, locatorCommitment: commitment, accessState: .stopped, deletionState: .complete)
        }
        await coordinator.resumePendingWork()
        XCTAssertTrue(try repository.fetchPendingOperations(forShareId: result.publication.id).isEmpty)
        XCTAssertEqual(try repository.fetch(id: result.publication.id)?.deletionState, .complete)
        XCTAssertNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))
    }

    // MARK: - Superseded credential stops retrying

    func testUnauthorizedResponseMarksTheCredentialSupersededAndStopsFurtherNetworkCalls() async throws {
        var createCallCount = 0
        remoteClient.createShareHandler = { _, _, _, _, _, _, _ in
            createCallCount += 1
            throw ShareClientError.api(ShareAPIError(code: .unauthorized, retryable: false, requestId: nil))
        }

        do {
            _ = try await coordinator.publish(bundle: try makeNotesBundle())
            XCTFail("expected deviceCredentialSuperseded")
        } catch ShareCoordinatorError.deviceCredentialSuperseded {
            // expected
        }
        XCTAssertEqual(createCallCount, 1)

        do {
            _ = try await coordinator.publish(bundle: try makeNotesBundle())
            XCTFail("expected deviceCredentialSuperseded without a second network attempt")
        } catch ShareCoordinatorError.deviceCredentialSuperseded {
            // expected
        }
        XCTAssertEqual(createCallCount, 1, "a superseded credential must halt retries, not loop forever")
    }

    // MARK: - Recovery switch guard

    func testForgottenCompletedShareDoesNotReappearOnRefresh() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let published = try await coordinator.publish(bundle: makeNotesBundle())
        var completed = makeConfirmedResource(
            shareId: published.publication.remoteShareId,
            locatorCommitment: published.publication.locatorCommitment, contentRevision: 1, version: 2,
            expiresAt: published.publication.expiresAt, maxExpiresAt: published.publication.maxExpiresAt)
        completed.accessState = .stopped
        completed.deletionState = .complete
        completed.contentWritable = false
        completed.terminalAt = Date()
        let remoteCompleted = completed
        var listCalls = 0
        remoteClient.listSharesHandler = { _, _, _ in
            listCalls += 1
            return ShareListPage(shares: [remoteCompleted], nextCursor: nil)
        }

        // Known rows still receive terminal receipts during reconciliation.
        let reconciled = try await coordinator.refreshPublications()
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.version, 2)
        XCTAssertEqual(reconciled.first?.deletionState, .complete)

        try await coordinator.forgetCompletedPublication(shareId: published.publication.id)
        let afterRefresh = try await coordinator.refreshPublications()
        XCTAssertTrue(afterRefresh.isEmpty, "remote retention tombstones must not recreate a forgotten local row")
        XCTAssertEqual(listCalls, 2)
        XCTAssertNil(try credentialStore.loadContentKey(forRemoteShareId: published.publication.remoteShareId))
    }

    func testFractionalExpiryRejectsBeforeEnrollment() async throws {
        var enrolled = false
        remoteClient.enrollOwnerHandler = { _, _, _, _, _ in
            enrolled = true
            throw ShareClientError.network
        }
        do {
            _ = try await coordinator.publish(
                bundle: makeNotesBundle(),
                expiresAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3600.5))
            XCTFail("fractional expiry must be rejected")
        } catch ShareCoordinatorError.invalidExpiry {}
        XCTAssertFalse(enrolled)
        XCTAssertNil(try credentialStore.loadDeviceCredential())
    }

    func testFailedCreateReconciliationPreservesOutboxAndKey() async throws {
        remoteClient.createShareHandler = { _, _, _, _, _, _, _ in
            throw ShareClientError.api(ShareAPIError(code: .versionConflict, retryable: false, requestId: nil))
        }
        remoteClient.listSharesHandler = { _, _, _ in throw ShareClientError.network }
        let result = try await coordinator.publish(bundle: makeNotesBundle())
        XCTAssertNil(result.link)
        XCTAssertNotNil(try repository.fetch(id: result.publication.id))
        XCTAssertEqual(try repository.fetchPendingOperations(forShareId: result.publication.id).count, 1)
        XCTAssertNotNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))
    }

    func testRecoveryCodeSurvivesLostConfigurationResponseAndRestart() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        _ = try await coordinator.publish(bundle: makeNotesBundle())
        var installedVerifier: String?
        remoteClient.configureRecoveryHandler = { _, verifier, _, _, _ in
            installedVerifier = verifier
            throw ShareClientError.network
        }
        do { _ = try await coordinator.setUpRecovery(); XCTFail("expected lost response") } catch ShareClientError
            .network
        {}
        let unconfirmedCode = try await coordinator.pendingRecoveryCode()
        XCTAssertNil(unconfirmedCode)
        let credential = try XCTUnwrap(credentialStore.loadDeviceCredential())
        remoteClient.fetchOwnerMetadataHandler = { _ in
            ShareOwnerMetadata(
                ownerId: credential.ownerId, credentialGeneration: 1, recoveryVerifier: installedVerifier)
        }
        let restarted = ShareCoordinator(
            repository: repository, credentialStore: credentialStore, remoteClient: remoteClient)
        _ = try await restarted.reconcileLostRecoveryConfiguration()
        let code = try await restarted.pendingRecoveryCode()
        XCTAssertEqual(code?.verifier, installedVerifier)
        try await restarted.acknowledgeRecoveryCodeSaved()
        XCTAssertNil(try credentialStore.loadPendingRecoveryConfiguration())
    }

    func testOverlappingRecoveryConfigurationCannotOverwritePendingSecret() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        _ = try await coordinator.publish(bundle: makeNotesBundle())
        let coordinator = try XCTUnwrap(coordinator)
        var rejected = false
        remoteClient.configureRecoveryHandler = { _, _, _, _, _ in
            do { _ = try await coordinator.setUpRecovery() } catch ShareCoordinatorError.operationInProgress {
                rejected = true
            }
            throw ShareClientError.network
        }
        do { _ = try await coordinator.setUpRecovery() } catch ShareClientError.network {}
        XCTAssertTrue(rejected)
        XCTAssertNotNil(try credentialStore.loadPendingRecoveryConfiguration()?.generatedToken)
    }

    func testNegativeRecoveryProbeKeepsPendingDeviceAuthority() async throws {
        let pending = ShareDeviceCredential(
            ownerId: ShareIdentifiers.generate16ByteIdentifier(), token: .generate(), credentialGeneration: 0)
        try credentialStore.savePendingDeviceCredential(pending)
        remoteClient.fetchOwnerMetadataHandler = { _ in
            throw ShareClientError.api(ShareAPIError(code: .unauthorized, retryable: false, requestId: nil))
        }
        let confirmed = try await coordinator.reconcileLostRecoveryImport()
        XCTAssertFalse(confirmed)
        XCTAssertEqual(try credentialStore.loadPendingDeviceCredential(), pending)
    }

    func testNeverSentRecoveryCanRetrySameDurableDeviceAfterRestart() async throws {
        let code = ShareRecoveryToken.generate(ownerId: ShareRandom.bytes(16))
        let ownerId = ShareBase64URL.encode(code.ownerId)
        let replacement = ShareRecoveryToken.generate(ownerId: code.ownerId).verifier
        var attempts: [(String, String, String?, String)] = []
        remoteClient.recoverOwnerHandler = { _, selector, verifier, replacement, key in
            attempts.append((selector, verifier, replacement, key))
            if attempts.count == 1 { throw ShareClientError.network }
            return ShareOwnerMetadata(ownerId: ownerId, credentialGeneration: 2, recoveryVerifier: replacement)
        }
        remoteClient.fetchOwnerMetadataHandler = { _ in
            throw ShareClientError.api(ShareAPIError(code: .unauthorized, retryable: false, requestId: nil))
        }
        do {
            _ = try await coordinator.recoverOwnership(recoveryToken: code, replacementRecoveryVerifier: replacement)
        } catch ShareClientError.network {}
        let pending = try XCTUnwrap(credentialStore.loadPendingDeviceCredential())
        let restarted = ShareCoordinator(
            repository: repository, credentialStore: credentialStore, remoteClient: remoteClient)
        _ = try await restarted.recoverOwnership(recoveryToken: code, replacementRecoveryVerifier: replacement)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].0, attempts[1].0)
        XCTAssertEqual(attempts[0].1, attempts[1].1)
        XCTAssertEqual(attempts[0].2, attempts[1].2)
        XCTAssertEqual(attempts[0].3, attempts[1].3)
        XCTAssertEqual(try credentialStore.loadDeviceCredential()?.token, pending.token)
        XCTAssertNil(try credentialStore.loadPendingDeviceCredential())
    }

    func testPendingRecoveryRejectsChangedOwnerOrReplacementWithoutChangingAuthority() async throws {
        let code = ShareRecoveryToken.generate(ownerId: ShareRandom.bytes(16))
        remoteClient.recoverOwnerHandler = { _, _, _, _, _ in throw ShareClientError.network }
        do { _ = try await coordinator.recoverOwnership(recoveryToken: code) } catch ShareClientError.network {}
        let pending = try credentialStore.loadPendingDeviceCredential()
        do {
            _ = try await coordinator.recoverOwnership(recoveryToken: code, replacementRecoveryVerifier: "different")
            XCTFail("replacement changes the pending request")
        } catch ShareCoordinatorError.recoveryPending {}
        do {
            _ = try await coordinator.recoverOwnership(recoveryToken: .generate(ownerId: ShareRandom.bytes(16)))
            XCTFail("owner changes the pending request")
        } catch ShareCoordinatorError.recoveryPending {}
        XCTAssertEqual(try credentialStore.loadPendingDeviceCredential(), pending)
    }

    func testLateRecoveryCommitDuringRetryIsConfirmedWithOriginalDevice() async throws {
        let code = ShareRecoveryToken.generate(ownerId: ShareRandom.bytes(16))
        let ownerId = ShareBase64URL.encode(code.ownerId)
        var attempts = 0
        var committed = false
        remoteClient.recoverOwnerHandler = { _, _, _, _, _ in
            attempts += 1
            if attempts == 1 { throw ShareClientError.network }
            // The first request finishes after the retry's negative probe.
            committed = true
            throw ShareClientError.api(ShareAPIError(code: .unauthorized, retryable: false, requestId: nil))
        }
        remoteClient.fetchOwnerMetadataHandler = { _ in
            if committed { return ShareOwnerMetadata(ownerId: ownerId, credentialGeneration: 2, recoveryVerifier: nil) }
            throw ShareClientError.api(ShareAPIError(code: .unauthorized, retryable: false, requestId: nil))
        }
        do { _ = try await coordinator.recoverOwnership(recoveryToken: code) } catch ShareClientError.network {}
        let pending = try XCTUnwrap(credentialStore.loadPendingDeviceCredential())
        let result = try await coordinator.recoverOwnership(recoveryToken: code)
        XCTAssertEqual(result.credentialGeneration, 2)
        XCTAssertEqual(try credentialStore.loadDeviceCredential()?.token, pending.token)
    }

    func testDefinitiveFirstCreateRejectionDoesNotLeavePermanentPendingWork() async throws {
        var shareId: String?
        remoteClient.createShareHandler = { _, id, _, _, _, _, _ in
            shareId = id
            throw ShareClientError.api(ShareAPIError(code: .payloadTooLarge, retryable: false, requestId: nil))
        }
        do {
            _ = try await coordinator.publish(bundle: makeNotesBundle()); XCTFail("expected rejection")
        } catch ShareClientError.api(let error) { XCTAssertEqual(error.code, .payloadTooLarge) }
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertTrue(try repository.fetchShareIdsWithPendingOperations().isEmpty)
        XCTAssertNil(try credentialStore.loadContentKey(forRemoteShareId: XCTUnwrap(shareId)))
    }

    func testValidationErrorAfterLostCreateStillPreservesUncertainAuthority() async throws {
        var attempts = 0
        remoteClient.createShareHandler = { _, _, _, _, _, _, _ in
            attempts += 1
            if attempts == 1 { throw ShareClientError.network }
            throw ShareClientError.api(ShareAPIError(code: .invalidExpiry, retryable: false, requestId: nil))
        }
        let result = try await coordinator.publish(bundle: makeNotesBundle())
        await coordinator.resumePendingWork()
        XCTAssertNotNil(try repository.fetch(id: result.publication.id))
        XCTAssertEqual(try repository.fetchPendingOperations(forShareId: result.publication.id).map(\.kind), [.create])
        XCTAssertNotNil(try credentialStore.loadContentKey(forRemoteShareId: result.publication.remoteShareId))
    }

    func testDifferentOwnerSwitchExhaustsRemotePagesBeforeAllowingSwitch() async throws {
        let old = ShareDeviceCredential(
            ownerId: ShareIdentifiers.generate16ByteIdentifier(), token: .generate(), credentialGeneration: 1)
        try credentialStore.saveDeviceCredential(old)
        var pages = 0
        remoteClient.listSharesHandler = { _, cursor, _ in
            pages += 1
            if cursor == nil { return ShareListPage(shares: [], nextCursor: "page&two") }
            XCTAssertEqual(cursor, "page&two")
            return ShareListPage(
                shares: [
                    makeConfirmedResource(
                        shareId: ShareIdentifiers.generate16ByteIdentifier(),
                        locatorCommitment: ShareIdentifiers.generate16ByteIdentifier(), contentRevision: 1, version: 1,
                        expiresAt: Date().addingTimeInterval(3600), maxExpiresAt: Date().addingTimeInterval(7200))
                ], nextCursor: nil)
        }
        do {
            _ = try await coordinator.recoverOwnership(recoveryToken: .generate(ownerId: ShareRandom.bytes(16)))
            XCTFail("must block")
        } catch ShareCoordinatorError.recoverySwitchBlocked {}
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(try credentialStore.loadDeviceCredential(), old)
        let imported = try XCTUnwrap(repository.fetchAll().first)
        XCTAssertNil(imported.locator)
        XCTAssertFalse(imported.isContentUpdateEligibleLocally)
    }

    func testLostUpdateResponseReconcilesRevisionAfterReceiptExpires() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        let published = try await coordinator.publish(bundle: makeNotesBundle())
        var attempts = 0
        var tags: [String] = []
        remoteClient.updateShareContentHandler = { _, _, _, _, _, tag, _ in
            attempts += 1
            tags.append(tag)
            if attempts == 1 { throw ShareClientError.network }
            throw ShareClientError.api(ShareAPIError(code: .versionConflict, retryable: false, requestId: nil))
        }
        let updatedBundle = try makeNotesBundle("updated")
        _ = try await coordinator.updateContent(
            shareId: published.publication.id, bundle: updatedBundle, projectionManifest: Data("selection".utf8))
        remoteClient.listSharesHandler = { _, _, _ in
            ShareListPage(
                shares: [
                    makeConfirmedResource(
                        shareId: published.publication.remoteShareId,
                        locatorCommitment: published.publication.locatorCommitment, contentRevision: 2, version: 2,
                        expiresAt: published.publication.expiresAt, maxExpiresAt: published.publication.maxExpiresAt)
                ], nextCursor: nil)
        }
        await coordinator.resumePendingWork()
        let updated = try XCTUnwrap(repository.fetch(id: published.publication.id))
        XCTAssertEqual(updated.contentRevision, 2)
        XCTAssertEqual(updated.contentDigest, try updatedBundle.contentDigest())
        XCTAssertEqual(updated.projectionManifest, Data("selection".utf8))
        XCTAssertEqual(tags, ["\"v1\"", "\"v1\""])
        XCTAssertTrue(try repository.fetchPendingOperations(forShareId: updated.id).isEmpty)
    }

    func testRecoveringADifferentOwnerIsBlockedWhileAShareIsStillNonTerminal() async throws {
        remoteClient.listSharesHandler = { _, _, _ in ShareListPage(shares: [], nextCursor: nil) }
        remoteClient.createShareHandler = succeedingCreateHandler()
        _ = try await coordinator.publish(bundle: try makeNotesBundle())

        var recoverOwnerCalled = false
        remoteClient.recoverOwnerHandler = { _, _, _, _, _ in
            recoverOwnerCalled = true
            return ShareOwnerMetadata(ownerId: "other-owner", credentialGeneration: 1, recoveryVerifier: nil)
        }

        let foreignToken = ShareRecoveryToken.generate(ownerId: ShareRandom.bytes(16))
        do {
            _ = try await coordinator.recoverOwnership(recoveryToken: foreignToken, replacementRecoveryVerifier: nil)
            XCTFail("expected recoverySwitchBlocked")
        } catch ShareCoordinatorError.recoverySwitchBlocked {
            // expected
        }
        XCTAssertFalse(recoverOwnerCalled, "the switch guard must reject before any network call")
    }

    func testRejectedFirstCreateDiscardsOnlyNeverPublishedIntentAndQueuedCancellation() async throws {
        let repository = try XCTUnwrap(repository)
        var deleteCalls = 0
        var remoteID: String?
        remoteClient.createShareHandler = { _, _, _, _, _, _, _ in
            let share = try XCTUnwrap(repository.fetchAll().first)
            remoteID = share.remoteShareId
            try await repository.enqueueTerminalDelete(shareId: share.id)
            throw ShareClientError.api(ShareAPIError(code: .invalidExpiry, retryable: false, requestId: nil))
        }
        remoteClient.deleteShareHandler = { _, id, commitment, _ in
            deleteCalls += 1
            return ShareDeletionReceipt(
                id: id, locatorCommitment: commitment,
                accessState: .stopped, deletionState: deleteCalls == 1 ? .pending : .complete)
        }
        do {
            _ = try await coordinator.publish(bundle: makeNotesBundle()); XCTFail("expected rejection")
        } catch ShareClientError.api(let error) { XCTAssertEqual(error.code, .invalidExpiry) }
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertTrue(try repository.fetchShareIdsWithPendingOperations().isEmpty)
        XCTAssertNil(try credentialStore.loadContentKey(forRemoteShareId: XCTUnwrap(remoteID)))
        await coordinator.resumePendingWork()
        XCTAssertEqual(deleteCalls, 0, "no remote deletion receipt is fabricated for a never-published intent")
    }

    func testEmptyListingRequiresDeleteReceiptForTerminalLocalRecord() async throws {
        remoteClient.listSharesHandler = { _, _, _ in ShareListPage(shares: [], nextCursor: nil) }
        remoteClient.createShareHandler = succeedingCreateHandler()
        let result = try await coordinator.publish(bundle: makeNotesBundle())
        _ = try await repository.applyDeletionReceipt(
            shareId: result.publication.id,
            receipt: ShareDeletionReceipt(
                id: result.publication.remoteShareId,
                locatorCommitment: result.publication.locatorCommitment, accessState: .expired, deletionState: .pending)
        )
        var acceptsDelete = false
        remoteClient.deleteShareHandler = { _, id, commitment, _ in
            if !acceptsDelete { throw ShareClientError.network }
            return ShareDeletionReceipt(
                id: id, locatorCommitment: commitment, accessState: .stopped, deletionState: .complete)
        }
        let pending = try await coordinator.refreshPublications()
        XCTAssertEqual(pending.first?.deletionState, .pending, "absence never proves cleanup")
        XCTAssertEqual(try repository.fetchPendingOperations(forShareId: result.publication.id).map(\.kind), [.delete])
        acceptsDelete = true
        let complete = try await coordinator.refreshPublications()
        XCTAssertEqual(complete.first?.deletionState, .complete)
        XCTAssertTrue(try repository.fetchPendingOperations(forShareId: result.publication.id).isEmpty)
    }

    func testValidationRejectionAfterUncertainCreatePreservesQueuedStop() async throws {
        var attempts = 0
        remoteClient.createShareHandler = { _, _, _, _, _, _, _ in
            attempts += 1
            if attempts == 1 { throw ShareClientError.network }
            throw ShareClientError.api(ShareAPIError(code: .invalidExpiry, retryable: false, requestId: nil))
        }
        let result = try await coordinator.publish(bundle: makeNotesBundle())
        try await repository.enqueueTerminalDelete(shareId: result.publication.id)
        await coordinator.resumePendingWork()
        XCTAssertNotNil(try repository.fetch(id: result.publication.id))
        XCTAssertEqual(
            try repository.fetchPendingOperations(forShareId: result.publication.id).map(\.kind), [.create, .delete])
    }

    func testWrongRecoveryProofCanBeCorrectedForReplacementAndRemoval() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        _ = try await coordinator.publish(bundle: makeNotesBundle())
        let credential = try XCTUnwrap(credentialStore.loadDeviceCredential())
        let ownerBytes = try XCTUnwrap(ShareBase64URL.decode(credential.ownerId))
        let wrong = ShareRecoveryToken.generate(ownerId: ownerBytes)
        let correct = ShareRecoveryToken.generate(ownerId: ownerBytes)
        remoteClient.configureRecoveryHandler = { _, verifier, _, proof, _ in
            guard proof == correct else {
                throw ShareClientError.api(ShareAPIError(code: .unauthorized, retryable: false, requestId: nil))
            }
            return ShareOwnerMetadata(ownerId: credential.ownerId, credentialGeneration: 1, recoveryVerifier: verifier)
        }
        do {
            _ = try await coordinator.replaceRecovery(currentRecoveryToken: wrong); XCTFail("expected rejection")
        } catch ShareClientError.api(let error) { XCTAssertEqual(error.code, .unauthorized) }
        XCTAssertNil(try credentialStore.loadPendingRecoveryConfiguration())
        _ = try await coordinator.replaceRecovery(currentRecoveryToken: correct)
        XCTAssertTrue(try XCTUnwrap(credentialStore.loadPendingRecoveryConfiguration()).isConfirmed)
        try await coordinator.acknowledgeRecoveryCodeSaved()
        do {
            _ = try await coordinator.removeRecovery(currentRecoveryToken: wrong); XCTFail("expected rejection")
        } catch ShareClientError.api(let error) { XCTAssertEqual(error.code, .unauthorized) }
        XCTAssertNil(try credentialStore.loadPendingRecoveryConfiguration())
        _ = try await coordinator.removeRecovery(currentRecoveryToken: correct)
        XCTAssertNil(try credentialStore.loadPendingRecoveryConfiguration())
    }

    func testRejectedRecoveryReconciliationRetainsEarlierUncertainRequest() async throws {
        remoteClient.createShareHandler = succeedingCreateHandler()
        _ = try await coordinator.publish(bundle: makeNotesBundle())
        let credential = try XCTUnwrap(credentialStore.loadDeviceCredential())
        remoteClient.configureRecoveryHandler = { _, _, _, _, _ in throw ShareClientError.network }
        do { _ = try await coordinator.setUpRecovery() } catch ShareClientError.network {}
        let pending = try XCTUnwrap(credentialStore.loadPendingRecoveryConfiguration())
        remoteClient.fetchOwnerMetadataHandler = { _ in
            ShareOwnerMetadata(ownerId: credential.ownerId, credentialGeneration: 1, recoveryVerifier: nil)
        }
        remoteClient.configureRecoveryHandler = { _, _, _, _, _ in
            throw ShareClientError.api(ShareAPIError(code: .versionConflict, retryable: false, requestId: nil))
        }
        do {
            _ = try await coordinator.reconcileLostRecoveryConfiguration(); XCTFail("expected rejection")
        } catch ShareClientError.api {}
        XCTAssertEqual(try credentialStore.loadPendingRecoveryConfiguration(), pending)
    }

    // MARK: - Discard after recovery loss requires terminal shares

    func testDiscardCredentialAfterRecoveryLossRequiresEveryShareToBeTerminal() async throws {
        remoteClient.listSharesHandler = { _, _, _ in ShareListPage(shares: [], nextCursor: nil) }
        remoteClient.createShareHandler = succeedingCreateHandler()
        _ = try await coordinator.publish(bundle: try makeNotesBundle())

        do {
            try await coordinator.discardCredentialAfterRecoveryLoss()
            XCTFail("expected sharesNotTerminal")
        } catch ShareCoordinatorError.sharesNotTerminal {
            // expected
        }
        XCTAssertNotNil(try credentialStore.loadDeviceCredential(), "a blocked discard must not clear management")
    }
}
