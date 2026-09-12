import XCTest
import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class ShareDraftViewModelTests: XCTestCase {
    nonisolated private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func source(meeting: Bool = true) -> ShareDraftSource {
        ShareDraftSource(
            transcription: Transcription(
                fileName: "Private file", rawTranscript: "Transcript words", sourceType: meeting ? .meeting : .file,
                userNotes: meeting ? "My notes" : nil),
            title: "Visible title",
            summaries: meeting ? [.init(id: UUID(), title: "Decisions", markdown: "Actual visible result")] : [])
    }

    func testMeetingDefaultsPreviewActualSummaryAndNotesOnly() async throws {
        let service = ShareUIServiceStub()
        let model = ShareDraftViewModel(source: source(), service: service, now: { self.now })
        await model.preparePreview()
        let bundle = try XCTUnwrap(model.preview)
        XCTAssertEqual(bundle.sections.count, 2)
        XCTAssertEqual(bundle.sections[0], .summary(title: "Decisions", markdown: "Actual visible result"))
        XCTAssertEqual(bundle.sections[1], .notes(title: "Notes", markdown: "My notes"))
        XCTAssertNil(bundle.title)
        XCTAssertNil(bundle.source)
        XCTAssertFalse(model.manifest.includeTranscript)
    }

    func testTranscriptOnlyDefaultsAndUnavailableTiming() async throws {
        let model = ShareDraftViewModel(
            source: source(meeting: false), service: ShareUIServiceStub(), now: { self.now })
        XCTAssertTrue(model.manifest.includeTranscript)
        model.manifest.includeTimestamps = true
        model.manifest.includeSpeakerLabels = true
        await model.preparePreview()
        XCTAssertFalse(model.manifest.includeTimestamps)
        XCTAssertFalse(model.manifest.includeSpeakerLabels)
        XCTAssertEqual(try XCTUnwrap(model.preview).sections.count, 1)
    }

    func testContextualSummaryAndEmptySelection() async {
        let input = source()
        let model = ShareDraftViewModel(
            source: input, service: ShareUIServiceStub(), selectedSummaryID: input.summaries[0].id, now: { self.now })
        await model.preparePreview()
        XCTAssertEqual(model.preview?.sections.count, 1)
        model.manifest.summaryIDs = []
        await model.preparePreview()
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.canPublish)
    }

    func testPublishedBundleExactlyMatchesFrozenPreviewAndDoubleClickDoesNotDuplicate() async throws {
        let service = ShareUIServiceStub()
        let model = ShareDraftViewModel(source: source(), service: service, now: { self.now })
        await model.preparePreview()
        let preview = try XCTUnwrap(model.preview)
        async let first: Void = model.publish()
        async let second: Void = model.publish()
        _ = await (first, second)
        let calls = await service.publishCalls
        let submitted = await service.receivedBundle
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(submitted, preview)
        XCTAssertNotNil(model.link)
    }

    func testInvalidExpiryDoesNotCallService() async {
        let service = ShareUIServiceStub()
        let model = ShareDraftViewModel(source: source(), service: service, now: { self.now })
        await model.preparePreview()
        for invalid in [now, now.addingTimeInterval(7_776_001), now.addingTimeInterval(1.5)] {
            model.expiresAt = invalid
            await model.publish()
            XCTAssertNotNil(model.errorMessage)
        }
        let calls = await service.publishCalls
        XCTAssertEqual(calls, 0)
    }

    func testPrePersistenceFailureKeepsDraftRetryable() async {
        let service = ShareUIServiceStub()
        await service.setMode(.failure)
        let model = ShareDraftViewModel(source: source(), service: service, now: { self.now })
        await model.preparePreview()
        await model.publish()
        XCTAssertNotNil(model.preview)
        XCTAssertNil(model.publication)
        XCTAssertNil(model.link)
        XCTAssertTrue(model.canPublish)
    }

    func testUncertainCreateHasNoLinkAndCannotCreateDuplicateOnRetry() async {
        let service = ShareUIServiceStub()
        await service.setMode(.uncertain)
        let model = ShareDraftViewModel(source: source(), service: service, now: { self.now })
        await model.preparePreview()
        await model.publish()
        await model.publish()
        XCTAssertNotNil(model.publication)
        XCTAssertNil(model.link)
        XCTAssertFalse(model.canPublish)
        let calls = await service.publishCalls
        XCTAssertEqual(calls, 1)
    }

    func testUpdateKeepsURLAndPublishesOnlyAfterExplicitAction() async throws {
        let service = ShareUIServiceStub()
        let input = source()
        let old = ShareUIServiceStub.publication(sourceID: input.transcription.id)
        await service.seed(old)
        let before = try await service.confirmedLink(shareId: old.id)
        let model = ShareDraftViewModel(source: input, service: service, updating: old, now: { self.now })
        await model.preparePreview()
        let callsBefore = await service.updateCalls
        XCTAssertEqual(callsBefore, 0)
        await model.publish()
        XCTAssertEqual(model.publication?.contentRevision, 2)
        XCTAssertEqual(model.link?.url, before?.url)
    }
}

actor ShareUIServiceStub: ShareManaging {
    enum Mode { case success, failure, uncertain }
    var mode = Mode.success
    var rows: [SharePublication] = []
    var work: [UUID: [ShareOutboxOperation]] = [:]
    var publishCalls = 0
    var updateCalls = 0
    var refreshCalls = 0
    var receivedBundle: ShareBundle?
    let fullLink = ShareLink.generate()
    func setMode(_ value: Mode) { mode = value }
    func seed(_ row: SharePublication, operations: [ShareOutboxOperation] = []) {
        rows = [row]; work[row.id] = operations
    }
    static func publication(sourceID: UUID? = nil) -> SharePublication {
        SharePublication(
            remoteShareId: "r", locator: "l", locatorCommitment: "c", ownerId: "owner", createdCredentialGeneration: 1,
            version: 1, accessState: .active, createdAt: Date(timeIntervalSince1970: 2_000_000_000),
            expiresAt: Date(timeIntervalSince1970: 2_002_592_000),
            maxExpiresAt: Date(timeIntervalSince1970: 2_007_776_000), transcriptionId: sourceID)
    }
    func listPublications() -> [SharePublication] { rows }
    func refreshPublications() -> [SharePublication] { refreshCalls += 1; return rows }
    func pendingOperations(shareId: UUID) -> [ShareOutboxOperation] { work[shareId] ?? [] }
    func confirmedLink(shareId: UUID) -> ShareLink? {
        rows.first(where: { $0.id == shareId && $0.isConfirmed && $0.contentWritable && !$0.isTerminal }) == nil
            ? nil : fullLink
    }
    func publish(
        bundle: ShareBundle, transcriptionId: UUID?, expiresAt: Date?, projectionManifest: Data?, contentDigest: String?
    ) async throws -> SharePublishResult {
        publishCalls += 1; receivedBundle = bundle
        await Task.yield()
        if mode == .failure { throw ShareClientError.network }
        var row = Self.publication(sourceID: transcriptionId)
        row.projectionManifest = projectionManifest; row.contentDigest = contentDigest
        if mode == .uncertain { row.version = nil; row.accessState = nil }
        rows.append(row)
        if mode == .uncertain { throw ShareClientError.network }
        return SharePublishResult(publication: row, link: fullLink)
    }
    func updateContent(shareId: UUID, bundle: ShareBundle, projectionManifest: Data?, contentDigest: String?) throws
        -> SharePublication
    {
        updateCalls += 1; receivedBundle = bundle
        guard let index = rows.firstIndex(where: { $0.id == shareId }) else {
            throw ShareCoordinatorError.shareNotFound
        }
        rows[index].contentRevision += 1; rows[index].projectionManifest = projectionManifest;
        rows[index].contentDigest = contentDigest
        return rows[index]
    }
    func changeExpiry(shareId: UUID, newExpiresAt: Date) throws -> SharePublication {
        throw ShareCoordinatorError.shareNotActive
    }
    func stop(shareId: UUID) throws -> SharePublication { throw ShareClientError.network }
    func resumePendingWork() {}
    func forgetCompletedPublication(shareId: UUID) { rows.removeAll { $0.id == shareId } }
    func setUpRecovery() throws -> ShareRecoverySetupResult { throw ShareCoordinatorError.deviceCredentialMissing }
    func replaceRecovery(currentRecoveryToken: ShareRecoveryToken) throws -> ShareRecoverySetupResult {
        throw ShareCoordinatorError.deviceCredentialMissing
    }
    func removeRecovery(currentRecoveryToken: ShareRecoveryToken) throws -> ShareOwnerMetadata {
        throw ShareCoordinatorError.deviceCredentialMissing
    }
    func pendingRecoveryCode() -> ShareRecoveryToken? { nil }
    func acknowledgeRecoveryCodeSaved() {}
    func reconcileLostRecoveryConfiguration() -> ShareOwnerMetadata? { nil }
    func recoverOwnership(recoveryToken: ShareRecoveryToken, replacementRecoveryVerifier: String?) throws
        -> ShareOwnerMetadata
    { throw ShareCoordinatorError.recoverySwitchBlocked }
    func reconcileLostRecoveryImport() -> Bool { false }
    func discardCredentialAfterRecoveryLoss() throws { throw ShareCoordinatorError.sharesNotTerminal }
}
