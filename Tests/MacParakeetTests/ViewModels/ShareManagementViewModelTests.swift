import XCTest
import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class ShareManagementViewModelTests: XCTestCase {
    func testUnconfiguredSurfaceDoesNotStartWork() async {
        let model = ShareManagementViewModel()
        await model.refresh()
        XCTAssertFalse(model.isConfigured)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.publications.isEmpty)
        XCTAssertFalse(AppFeatures.shareLinksEnabled)
        XCTAssertFalse(AppFeatures.isShareLinksAvailable(arguments: []))
    }

    func testPendingStopNeverClaimsRevocation() async {
        let service = ShareUIServiceStub()
        let row = ShareUIServiceStub.publication()
        let operation = ShareOutboxOperation(sharePublicationId: row.id, sequence: 0, kind: .delete, idempotencyKey: "key", requestBody: Data())
        await service.seed(row, operations: [operation])
        let model = ShareManagementViewModel()
        model.configure(service: service, sourceLoader: { _ in nil })
        await model.refresh()
        XCTAssertTrue(model.status(for: row).contains("may still work"))
        XCTAssertNil(model.links[row.id])
        XCTAssertFalse(model.canManage(row))
    }

    func testRecoveredShareIsManagementOnlyAndTerminalCannotResume() async {
        let service = ShareUIServiceStub()
        var row = ShareUIServiceStub.publication()
        row.contentWritable = false; row.locator = nil
        await service.seed(row)
        let model = ShareManagementViewModel()
        model.configure(service: service, sourceLoader: { _ in nil })
        await model.refresh()
        XCTAssertFalse(model.canUpdate(row))
        XCTAssertNil(model.links[row.id])
        XCTAssertTrue(model.status(for: row).contains("management only"))
        row.accessState = .stopped
        XCTAssertFalse(model.canManage(row))
    }

    func testLocalChangesAreStaleWithoutAutomaticUpdate() async throws {
        let service = ShareUIServiceStub()
        let original = Transcription(fileName: "Meeting", rawTranscript: "Original", sourceType: .file)
        let source = ShareDraftSource(transcription: original, title: "Meeting", summaries: [])
        let manifest = ShareProjectionManifest(includeTranscript: true)
        var row = ShareUIServiceStub.publication(sourceID: original.id)
        row.projectionManifest = try JSONEncoder().encode(manifest)
        row.contentDigest = try source.bundle(manifest: manifest, publishedAt: Date()).contentDigest()
        await service.seed(row)
        var changed = original; changed.rawTranscript = "Changed locally"
        let updated = ShareDraftSource(transcription: changed, title: "Meeting", summaries: [])
        let model = ShareManagementViewModel()
        model.configure(service: service, sourceLoader: { _ in updated })
        await model.refresh()
        XCTAssertTrue(model.staleIDs.contains(row.id))
        XCTAssertTrue(model.canUpdate(row))
        let calls = await service.updateCalls
        XCTAssertEqual(calls, 0)
    }

    func testRecoverySwitchFailureKeepsExistingRowsAndExplainsPreflight() async {
        let service = ShareUIServiceStub()
        let row = ShareUIServiceStub.publication()
        await service.seed(row)
        let model = ShareManagementViewModel()
        model.configure(service: service, sourceLoader: { _ in nil })
        let token = ShareRecoveryToken.generate(ownerId: Data(repeating: 1, count: 16))
        await model.importRecovery(code: token.rawValue)
        XCTAssertEqual(model.publications.map(\.id), [row.id])
        XCTAssertTrue(model.errorMessage?.contains("credentials have been kept") == true)
    }

    func testUnreadableLocalSourceDoesNotBlockRemoteReconciliation() async {
        let service = ShareUIServiceStub()
        let row = ShareUIServiceStub.publication(sourceID: UUID())
        await service.seed(row)
        let model = ShareManagementViewModel()
        model.configure(service: service, sourceLoader: { _ in
            throw NSError(domain: "SyntheticSourceReadFailure", code: 1)
        })

        await model.refresh()

        let refreshCalls = await service.refreshCalls
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(model.publications.map(\.id), [row.id])
        XCTAssertNil(model.titles[row.id])
        XCTAssertFalse(model.canUpdate(row))
        XCTAssertTrue(model.canManage(row))
        XCTAssertNil(model.errorMessage)
    }
}
