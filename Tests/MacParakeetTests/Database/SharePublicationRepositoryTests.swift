import XCTest
@testable import MacParakeetCore

final class SharePublicationRepositoryTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: SharePublicationRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = SharePublicationRepository(dbQueue: manager.dbQueue)
    }

    private func makePublication(
        remoteShareId: String = ShareIdentifiers.generate16ByteIdentifier(),
        transcriptionId: UUID? = nil
    ) -> SharePublication {
        let now = Date(timeIntervalSince1970: 1_789_084_800)
        return SharePublication(
            remoteShareId: remoteShareId,
            locator: ShareLocator.generate().rawValue,
            locatorCommitment: ShareVerifier.locator(.generate()),
            ownerId: ShareIdentifiers.generate16ByteIdentifier(),
            createdCredentialGeneration: 1,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(2_592_000),
            maxExpiresAt: now.addingTimeInterval(7_776_000),
            transcriptionId: transcriptionId
        )
    }

    private func makeCreateOperation(for publication: SharePublication) throws -> ShareOutboxOperation {
        let bundle = try ShareBundle(
            publishedAt: publication.createdAt,
            sections: [.notes(title: "Notes", markdown: "Owner-authored notes.")]
        )
        let locator = try ShareLocator(rawValue: XCTUnwrap(publication.locator))
        let envelope = try ShareCryptography.seal(
            plaintext: bundle.encodedJSON(),
            contentKey: .generate(),
            locator: locator,
            contentRevision: 1
        )
        let payload = ShareCreateOrUpdateRequestBody(
            locator: try XCTUnwrap(publication.locator),
            contentRevision: 1,
            expiresAt: publication.expiresAt,
            envelope: envelope
        )
        return ShareOutboxOperation(
            sharePublicationId: publication.id,
            sequence: 0,
            kind: .create,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(payload)
        )
    }

    // MARK: - Create persists ledger + outbox atomically

    func testCreatePublicationPersistsLedgerRowAndCreateOperationTogether() async throws {
        let publication = makePublication()
        let operation = try makeCreateOperation(for: publication)

        try await repo.createPublication(publication, initialOperation: operation)

        let fetched = try XCTUnwrap(repo.fetch(id: publication.id))
        XCTAssertEqual(fetched.remoteShareId, publication.remoteShareId)
        XCTAssertNil(fetched.version, "unconfirmed until a receipt arrives")

        let pending = try repo.fetchPendingOperations(forShareId: publication.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, .create)
    }

    // MARK: - Outbox ordering

    func testStaleDraftCannotCreateAfterSourceDisappears() async throws {
        let publication = makePublication(transcriptionId: UUID())
        do {
            try await repo.createPublication(publication, initialOperation: makeCreateOperation(for: publication))
            XCTFail("a deleted source must fence publication")
        } catch SharePublicationRepositoryError.sourceMissing {}
        XCTAssertNil(try repo.fetch(id: publication.id))
        XCTAssertTrue(try repo.fetchShareIdsWithPendingOperations().isEmpty)
    }

    func testConfirmedReceiptAndOutboxCompletionAreOneTransaction() async throws {
        let publication = makePublication()
        var operation = try makeCreateOperation(for: publication)
        operation.projectionManifest = Data("selected".utf8)
        operation.contentDigest = "digest"
        try await repo.createPublication(publication, initialOperation: operation)
        let receipt = makeConfirmedResource(shareId: publication.remoteShareId, locatorCommitment: publication.locatorCommitment,
            contentRevision: 1, version: 1, expiresAt: publication.expiresAt, maxExpiresAt: publication.maxExpiresAt)
        try await repo.confirmOperation(operation, resource: receipt)
        let confirmed = try XCTUnwrap(repo.fetch(id: publication.id))
        XCTAssertEqual(confirmed.version, 1)
        XCTAssertEqual(confirmed.projectionManifest, operation.projectionManifest)
        XCTAssertEqual(confirmed.contentDigest, "digest")
        XCTAssertTrue(try repo.fetchPendingOperations(forShareId: publication.id).isEmpty)
    }

    func testCreateReceiptCannotUndoQueuedTerminalIntent() async throws {
        let publication = makePublication()
        let operation = try makeCreateOperation(for: publication)
        try await repo.createPublication(publication, initialOperation: operation)
        try await repo.enqueueTerminalDelete(shareId: publication.id)
        let receipt = makeConfirmedResource(shareId: publication.remoteShareId, locatorCommitment: publication.locatorCommitment,
            contentRevision: 1, version: 1, expiresAt: publication.expiresAt, maxExpiresAt: publication.maxExpiresAt)
        try await repo.confirmOperation(operation, resource: receipt)
        XCTAssertEqual(try repo.fetch(id: publication.id)?.deletionState, .pending)
        XCTAssertEqual(try repo.fetchPendingOperations(forShareId: publication.id).map(\.kind), [.delete])
    }

    func testOutboxOperationsProcessInEnqueueOrder() async throws {
        let publication = makePublication()
        try await repo.createPublication(publication, initialOperation: try makeCreateOperation(for: publication))

        // Confirm the create first so a nonterminal mutation is legal to enqueue.
        try await confirmActive(publication)

        let expiryOp = ShareOutboxOperation(
            sharePublicationId: publication.id,
            sequence: 0,
            kind: .expiryChange,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(
                ShareExpiryChangeRequestBody(expiresAt: publication.expiresAt.addingTimeInterval(60))
            )
        )
        try await repo.enqueueOperation(expiryOp)

        let ordered = try repo.fetchPendingOperations(forShareId: publication.id)
        XCTAssertEqual(ordered.map(\.kind), [.create, .expiryChange])
        XCTAssertEqual(try repo.fetchNextPendingOperation(forShareId: publication.id)?.kind, .create)
    }

    // MARK: - Enqueue guards

    func testEnqueueingASecondNonterminalOperationIsRejected() async throws {
        let publication = makePublication()
        try await repo.createPublication(publication, initialOperation: try makeCreateOperation(for: publication))
        try await confirmActive(publication)

        let firstUpdate = ShareOutboxOperation(
            sharePublicationId: publication.id,
            sequence: 0,
            kind: .expiryChange,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(
                ShareExpiryChangeRequestBody(expiresAt: publication.expiresAt.addingTimeInterval(60))
            )
        )
        try await repo.enqueueOperation(firstUpdate)

        let secondUpdate = ShareOutboxOperation(
            sharePublicationId: publication.id,
            sequence: 0,
            kind: .expiryChange,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(
                ShareExpiryChangeRequestBody(expiresAt: publication.expiresAt.addingTimeInterval(120))
            )
        )
        do {
            try await repo.enqueueOperation(secondUpdate)
            XCTFail("expected operationAlreadyPending")
        } catch SharePublicationRepositoryError.operationAlreadyPending {
            // expected
        }
    }

    func testTerminalDeletePreemptsQueuedNonterminalWorkButKeepsAnUncertainCreate() async throws {
        let publication = makePublication()
        try await repo.createPublication(publication, initialOperation: try makeCreateOperation(for: publication))
        // Do NOT confirm — the create is still uncertain.

        try await repo.enqueueTerminalDelete(shareId: publication.id)

        let ordered = try repo.fetchPendingOperations(forShareId: publication.id)
        XCTAssertEqual(ordered.map(\.kind), [.create, .delete], "the uncertain create must survive for reconciliation")

        // Idempotent: enqueueing again does not create a second delete row.
        try await repo.enqueueTerminalDelete(shareId: publication.id)
        let orderedAgain = try repo.fetchPendingOperations(forShareId: publication.id)
        XCTAssertEqual(orderedAgain.map(\.kind), [.create, .delete])

        let share = try XCTUnwrap(repo.fetch(id: publication.id))
        XCTAssertEqual(share.deletionState, .pending)
    }

    func testEnqueueingNonterminalWorkAfterATerminalDeleteIsRejected() async throws {
        let publication = makePublication()
        try await repo.createPublication(publication, initialOperation: try makeCreateOperation(for: publication))
        try await confirmActive(publication)
        try await repo.enqueueTerminalDelete(shareId: publication.id)

        let update = ShareOutboxOperation(
            sharePublicationId: publication.id,
            sequence: 0,
            kind: .expiryChange,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(
                ShareExpiryChangeRequestBody(expiresAt: publication.expiresAt.addingTimeInterval(60))
            )
        )
        do {
            try await repo.enqueueOperation(update)
            XCTFail("expected shareIsTerminating")
        } catch SharePublicationRepositoryError.shareIsTerminating {
            // expected
        }
    }

    // MARK: - Receipts and dequeue

    func testApplyConfirmedReceiptAndDequeueOperation() async throws {
        let publication = makePublication()
        let operation = try makeCreateOperation(for: publication)
        try await repo.createPublication(publication, initialOperation: operation)

        try await confirmActive(publication)
        try await repo.dequeueOperation(id: operation.id)

        let fetched = try XCTUnwrap(repo.fetch(id: publication.id))
        XCTAssertEqual(fetched.accessState, .active)
        XCTAssertNotNil(fetched.version)
        XCTAssertTrue(try repo.fetchPendingOperations(forShareId: publication.id).isEmpty)
    }

    // MARK: - Unconfirmed deletion

    func testDeleteUnconfirmedPublicationRefusesAConfirmedRow() async throws {
        let publication = makePublication()
        try await repo.createPublication(publication, initialOperation: try makeCreateOperation(for: publication))
        try await confirmActive(publication)

        let deleted = try await repo.deleteUnconfirmedPublication(id: publication.id)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(try repo.fetch(id: publication.id))
    }

    func testDeleteUnconfirmedPublicationRemovesRowAndCascadesOutbox() async throws {
        let publication = makePublication()
        let operation = try makeCreateOperation(for: publication)
        try await repo.createPublication(publication, initialOperation: operation)

        let deleted = try await repo.deleteUnconfirmedPublication(id: publication.id)
        XCTAssertTrue(deleted)
        XCTAssertNil(try repo.fetch(id: publication.id))
        XCTAssertTrue(try repo.fetchPendingOperations(forShareId: publication.id).isEmpty)
    }

    // MARK: - Detach does not cascade from the source

    func testDetachClearsContentDerivedFieldsAndQueuesExactlyOneTerminalDelete() async throws {
        let transcription = Transcription(fileName: "meeting.wav", status: .completed, sourceType: .meeting)
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let transcriptionId = transcription.id
        let publication = makePublication(transcriptionId: transcriptionId)
        var withManifest = publication
        withManifest.projectionManifest = Data("manifest".utf8)
        withManifest.contentDigest = "digest"
        try await manager.dbQueue.write { db in try withManifest.insert(db) }

        try await manager.dbQueue.write { db in
            _ = try SharePublicationRepository.detachAndEnqueueTerminalOperations(transcriptionId: transcriptionId, in: db)
        }

        let detached = try XCTUnwrap(repo.fetch(id: publication.id))
        XCTAssertNil(detached.transcriptionId)
        XCTAssertNil(detached.projectionManifest)
        XCTAssertNil(detached.contentDigest)
        XCTAssertTrue(detached.isDetached)
        XCTAssertEqual(detached.deletionState, .pending)

        let ops = try repo.fetchPendingOperations(forShareId: publication.id)
        XCTAssertEqual(ops.map(\.kind), [.delete])
    }

    func testDetachHelperIsIdempotentAcrossRepeatedCalls() async throws {
        let transcription = Transcription(fileName: "meeting.wav", status: .completed, sourceType: .meeting)
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let transcriptionId = transcription.id
        let publication = makePublication(transcriptionId: transcriptionId)
        try await manager.dbQueue.write { db in try publication.insert(db) }

        try await manager.dbQueue.write { db in
            _ = try SharePublicationRepository.detachAndEnqueueTerminalOperations(transcriptionId: transcriptionId, in: db)
        }
        // A second detach pass for the same (now-detached) transcriptionId finds nothing to do.
        let secondPass = try await manager.dbQueue.write { db in
            try SharePublicationRepository.detachAndEnqueueTerminalOperations(transcriptionId: transcriptionId, in: db)
        }
        XCTAssertTrue(secondPass.isEmpty)

        let ops = try repo.fetchPendingOperations(forShareId: publication.id)
        XCTAssertEqual(ops.count, 1, "detach must never queue a second terminal delete")
    }

    func testShareRowDoesNotCascadeWhenTranscriptionIsDeletedDirectly() async throws {
        // Exercises the schema invariant directly: a transcription deletion
        // that bypasses the detach helper must not cascade-delete the share.
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let transcription = Transcription(
            fileName: "meeting.wav",
            status: .completed,
            sourceType: .meeting
        )
        try transcriptionRepo.save(transcription)

        let publication = makePublication(transcriptionId: transcription.id)
        try await manager.dbQueue.write { db in try publication.insert(db) }

        _ = try transcriptionRepo.delete(id: transcription.id)

        let survivor = try XCTUnwrap(repo.fetch(id: publication.id), "share row must survive an un-detached source delete")
        XCTAssertNil(survivor.transcriptionId, "ON DELETE SET NULL, never CASCADE")
    }

    // MARK: - No secrets in SQLite

    func testPersistedOutboxRequestBodyNeverContainsPlaintextBundleText() async throws {
        let publication = makePublication()
        let plaintextMarker = "TOP SECRET MEETING NOTES"
        let bundle = try ShareBundle(
            publishedAt: publication.createdAt,
            sections: [.notes(title: "Notes", markdown: plaintextMarker)]
        )
        let locator = try ShareLocator(rawValue: XCTUnwrap(publication.locator))
        let envelope = try ShareCryptography.seal(
            plaintext: bundle.encodedJSON(),
            contentKey: .generate(),
            locator: locator,
            contentRevision: 1
        )
        let payload = ShareCreateOrUpdateRequestBody(
            locator: try XCTUnwrap(publication.locator),
            contentRevision: 1,
            expiresAt: publication.expiresAt,
            envelope: envelope
        )
        let operation = ShareOutboxOperation(
            sharePublicationId: publication.id,
            sequence: 0,
            kind: .create,
            idempotencyKey: ShareIdentifiers.generateIdempotencyKey(),
            requestBody: try ShareServiceJSON.makeEncoder().encode(payload)
        )
        try await repo.createPublication(publication, initialOperation: operation)

        let raw = try XCTUnwrap(String(data: operation.requestBody, encoding: .utf8))
        XCTAssertFalse(raw.contains(plaintextMarker))
        XCTAssertFalse(raw.contains("contentKey"))
    }

    // MARK: - Helpers

    private func confirmActive(_ publication: SharePublication) async throws {
        let resource = ShareResource(
            id: publication.remoteShareId,
            locatorCommitment: publication.locatorCommitment,
            contentRevision: 1,
            version: 1,
            contentWritable: true,
            accessState: .active,
            deletionState: .retained,
            ciphertextBytes: 128,
            createdAt: publication.createdAt,
            updatedAt: publication.createdAt,
            expiresAt: publication.expiresAt,
            maxExpiresAt: publication.maxExpiresAt,
            terminalAt: nil
        )
        try await repo.applyConfirmedReceipt(shareId: publication.id, resource: resource)
    }
}
