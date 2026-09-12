import GRDB
import XCTest
@testable import MacParakeetCore

final class ShareDeletionPropagationTests: XCTestCase {
    private func fixture() throws -> (DatabaseManager, TranscriptionRepository, Transcription, SharePublication) {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let source = Transcription(fileName: "synthetic.wav", rawTranscript: "Private local text", status: .completed)
        try repo.save(source)
        let now = Date()
        var share = SharePublication(
            remoteShareId: ShareIdentifiers.generate16ByteIdentifier(), locator: ShareLocator.generate().rawValue,
            locatorCommitment: ShareVerifier.locator(.generate()), ownerId: ShareIdentifiers.generate16ByteIdentifier(),
            createdCredentialGeneration: 1, createdAt: now, expiresAt: now.addingTimeInterval(86400),
            maxExpiresAt: now.addingTimeInterval(7_776_000), transcriptionId: source.id)
        share.version = 1
        share.accessState = .active
        share.projectionManifest = Data("local selection".utf8)
        share.contentDigest = "local digest"
        try manager.dbQueue.write { try share.insert($0) }
        return (manager, repo, source, share)
    }

    func testDirectDeletionAtomicallyDetachesAndQueuesPermanentStop() throws {
        let (manager, repo, source, share) = try fixture()
        XCTAssertTrue(try repo.delete(id: source.id))
        let ledger = SharePublicationRepository(dbQueue: manager.dbQueue)
        let detached = try XCTUnwrap(ledger.fetch(id: share.id))
        XCTAssertNil(detached.transcriptionId)
        XCTAssertNil(detached.projectionManifest)
        XCTAssertNil(detached.contentDigest)
        XCTAssertTrue(detached.isDetached)
        XCTAssertEqual(try ledger.fetchNextPendingOperation(forShareId: share.id)?.kind, .delete)
        XCTAssertNil(try repo.fetch(id: source.id))
        XCTAssertFalse(try repo.delete(id: source.id))
    }

    func testSingleAndBulkDeletionNotifyOnlyAfterStopIntentCommits() throws {
        for bulk in [false, true] {
            let (manager, _, source, share) = try fixture()
            let notified = expectation(description: "committed stop notification")
            let ledger = SharePublicationRepository(dbQueue: manager.dbQueue)
            let repo = TranscriptionRepository(dbQueue: manager.dbQueue) {
                // Reading through a new database access proves notification is outside the transaction.
                XCTAssertEqual(try? ledger.fetchNextPendingOperation(forShareId: share.id)?.kind, .delete)
                notified.fulfill()
            }
            if bulk { try repo.deleteAll() } else { XCTAssertTrue(try repo.delete(id: source.id)) }
            wait(for: [notified], timeout: 1)
        }
    }

    func testPreparationNotifiesEvenWhenLaterAssetCleanupFails() throws {
        let (manager, _, source, share) = try fixture()
        let notified = expectation(description: "stop committed before asset failure")
        let ledger = SharePublicationRepository(dbQueue: manager.dbQueue)
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue) {
            XCTAssertEqual(try? ledger.fetchNextPendingOperation(forShareId: share.id)?.kind, .delete)
            notified.fulfill()
        }
        struct FileFailure: Error {}
        XCTAssertThrowsError(try TranscriptionDeletionCoordinator.delete(
            source, repository: repo, credentials: ShareCredentialStore(store: InMemoryKeyValueStore()),
            removeAssets: { _ in throw FileFailure() }))
        wait(for: [notified], timeout: 1)
        XCTAssertNotNil(try repo.fetch(id: source.id))
    }

    func testNoNotificationForUnsharedSourceOrRolledBackStop() throws {
        let (manager, _, source, _) = try fixture()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue) {
            XCTFail("uncommitted or absent stop must not notify")
        }
        try manager.dbQueue.write {
            try $0.execute(sql: "CREATE TRIGGER reject_stop BEFORE INSERT ON share_outbox_operations BEGIN SELECT RAISE(ABORT, 'failure'); END")
        }
        XCTAssertThrowsError(try repo.prepareForDeletion(id: source.id))
        XCTAssertThrowsError(try repo.delete(id: source.id))
        XCTAssertThrowsError(try repo.deleteAll())
        let unshared = Transcription(fileName: "unshared.wav", status: .completed)
        try repo.save(unshared)
        XCTAssertTrue(try repo.prepareForDeletion(id: unshared.id).isEmpty)
        XCTAssertTrue(try repo.delete(id: unshared.id))
    }

    func testOutboxFailurePreventsSourceAndAssetDeletion() throws {
        let (manager, repo, source, _) = try fixture()
        try manager.dbQueue.write {
            try $0.execute(
                sql:
                    "CREATE TRIGGER reject_share_delete BEFORE INSERT ON share_outbox_operations BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
            )
        }
        var removedAssets = false
        XCTAssertThrowsError(
            try TranscriptionDeletionCoordinator.delete(
                source, repository: repo,
                credentials: ShareCredentialStore(store: InMemoryKeyValueStore()),
                removeAssets: { _ in removedAssets = true }))
        XCTAssertFalse(removedAssets)
        XCTAssertNotNil(try repo.fetch(id: source.id))
    }

    func testFileFailurePreservesSourceButNotContentKeyOrPermanentStopIntent() throws {
        let (manager, repo, source, share) = try fixture()
        let keys = ShareCredentialStore(store: InMemoryKeyValueStore())
        try keys.saveContentKey(.generate(), forRemoteShareId: share.remoteShareId)
        struct FileFailure: Error {}
        XCTAssertThrowsError(
            try TranscriptionDeletionCoordinator.delete(
                source, repository: repo,
                credentials: keys, removeAssets: { _ in throw FileFailure() }))
        XCTAssertNotNil(try repo.fetch(id: source.id))
        XCTAssertNil(try keys.loadContentKey(forRemoteShareId: share.remoteShareId))
        let ledger = SharePublicationRepository(dbQueue: manager.dbQueue)
        XCTAssertEqual(try ledger.fetchNextPendingOperation(forShareId: share.id)?.kind, .delete)
    }

    func testDeleteAllRetainsRevocationAndAudioOnlyUpdateDoesNotStop() throws {
        let (manager, repo, source, share) = try fixture()
        let ledger = SharePublicationRepository(dbQueue: manager.dbQueue)
        try repo.updateFilePath(id: source.id, filePath: nil)
        XCTAssertNil(try ledger.fetchNextPendingOperation(forShareId: share.id))
        try repo.deleteAll()
        XCTAssertEqual(try repo.count(), 0)
        XCTAssertEqual(try ledger.fetchNextPendingOperation(forShareId: share.id)?.kind, .delete)
    }
}
