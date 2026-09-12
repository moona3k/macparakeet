import Darwin
import XCTest
@testable import MacParakeetCore

/// Focused coverage for `MeetingSplitChildFolderClaim`'s stage-then-publish
/// claim: a fresh private sibling scratch folder is fully
/// marked first, then published to the final destination with one exclusive
/// atomic rename, so the final path is never observable half-claimed
/// (created but not yet marked) after a crash or failure.
final class MeetingSplitChildFolderClaimTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSplitChildFolderClaimTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Success

    func testClaimCreatesAFreshMarkedFolderAndLeavesNoScratchBehind() throws {
        let operationId = UUID()
        let childId = UUID()
        let folderURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)

        let claimed = try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)

        XCTAssertEqual(claimed, folderURL)
        XCTAssertTrue(isPlainDirectory(folderURL))
        XCTAssertEqual(
            try markerContents(of: folderURL), MarkerContents(operationId: operationId, childId: childId))
        XCTAssertTrue(scratchEntries(in: root).isEmpty, "a successful publish must leave no scratch sibling behind")
    }

    // MARK: - Collision: safe same-key retry of this exact operation/child

    func testClaimReclaimsAnInterruptedAttemptAtTheSameOperationAndChild() throws {
        let operationId = UUID()
        let childId = UUID()
        let folderURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)

        _ = try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)
        try Data("stale partial export".utf8).write(to: folderURL.appendingPathComponent("meeting-playback.m4a"))

        let reclaimed = try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)

        XCTAssertEqual(reclaimed, folderURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("meeting-playback.m4a").path),
            "reclaiming this operation's own interrupted attempt must clear its stale content"
        )
        XCTAssertEqual(
            try markerContents(of: folderURL), MarkerContents(operationId: operationId, childId: childId))
        XCTAssertTrue(scratchEntries(in: root).isEmpty)
    }

    // MARK: - Refusal: unexpected existing content is never touched

    func testClaimRefusesAPlainDirectoryWithNoMarkerWithoutTouchingIt() throws {
        let operationId = UUID()
        let childId = UUID()
        let folderURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let sentinelURL = folderURL.appendingPathComponent("someone-elses-file.txt")
        try Data("unrelated content".utf8).write(to: sentinelURL)

        XCTAssertThrowsError(
            try MeetingSplitChildFolderClaim.claim(
                operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)
        ) { error in
            guard case MeetingSplitChildFolderClaimError.unexpectedExistingContent(let path) = error else {
                return XCTFail("expected unexpectedExistingContent, got \(error)")
            }
            XCTAssertEqual(path, folderURL.path)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinelURL.path), "unrelated existing content must be untouched")
        XCTAssertTrue(scratchEntries(in: root).isEmpty, "a refused claim must not leave its own scratch folder behind")
    }

    func testClaimRefusesAFolderWithAMismatchedMarkerWithoutTouchingIt() throws {
        let otherOperationId = UUID()
        let otherChildId = UUID()
        let childId = UUID()
        let folderURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)
        // A different operation/child's own claim happens to have used this
        // exact folder name (in practice: a coincidental collision, since
        // real child ids are fresh UUIDs). Its marker must protect it from
        // an unrelated operation's claim.
        _ = try MeetingSplitChildFolderClaim.claim(
            operationId: otherOperationId, childId: otherChildId, folderURL: folderURL, fileManager: .default)

        XCTAssertThrowsError(
            try MeetingSplitChildFolderClaim.claim(
                operationId: UUID(), childId: childId, folderURL: folderURL, fileManager: .default)
        ) { error in
            guard case MeetingSplitChildFolderClaimError.unexpectedExistingContent = error else {
                return XCTFail("expected unexpectedExistingContent, got \(error)")
            }
        }
        XCTAssertEqual(
            try markerContents(of: folderURL), MarkerContents(operationId: otherOperationId, childId: otherChildId),
            "the other operation's own marker must survive untouched"
        )
    }

    func testClaimRefusesASymlinkAtTheFinalPathWithoutFollowingOrRemovingIt() throws {
        let operationId = UUID()
        let childId = UUID()
        let targetURL = root.appendingPathComponent("real-target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try Data("do not touch".utf8).write(to: targetURL.appendingPathComponent("secret.txt"))
        let symlinkURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(
            try MeetingSplitChildFolderClaim.claim(
                operationId: operationId, childId: childId, folderURL: symlinkURL, fileManager: .default)
        ) { error in
            guard case MeetingSplitChildFolderClaimError.unexpectedExistingContent = error else {
                return XCTFail("expected unexpectedExistingContent, got \(error)")
            }
        }
        let resourceValues = try symlinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(resourceValues.isSymbolicLink, true, "the symlink itself must be left in place, never removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("secret.txt").path))
    }

    // MARK: - Marker-write failure never leaves a half-claimed final folder

    func testPreExistingScratchContentIsNeverReclaimedByName() throws {
        let operationId = UUID()
        let childId = UUID()
        let scratch = root.appendingPathComponent(".meeting-split-child-scratch-\(operationId.uuidString)-\(childId.uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let sentinel = scratch.appendingPathComponent("unfamiliar-content.txt")
        let expected = Data("not owned by this operation".utf8)
        try expected.write(to: sentinel)

        let folder = try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId,
            folderURL: root.appendingPathComponent(childId.uuidString), fileManager: .default)

        XCTAssertEqual(try Data(contentsOf: sentinel), expected)
        XCTAssertEqual(try markerContents(of: folder), MarkerContents(operationId: operationId, childId: childId))
        XCTAssertEqual(scratchEntries(in: root), [scratch.lastPathComponent])
    }

    /// Regression for the exact crash window this claim's stage-then-publish
    /// design closes: before, `mkdir(final)` then a separate marker write
    /// meant a failure in between left `final` existing but unmarked, which
    /// every future retry then refused forever. Now the marker is written
    /// into a private scratch folder *before* anything is ever placed at the
    /// final path, so a write failure there can never touch `final` at all.
    func testMarkerWriteFailureLeavesNothingAtTheFinalPathAndARetryStillSucceeds() throws {
        let operationId = UUID()
        let childId = UUID()
        let folderURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)

        // Fail exactly after exclusive scratch creation, without changing
        // the process-wide umask while unrelated asynchronous work may run.
        XCTAssertThrowsError(try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default,
            writeMarker: { _, url in
                XCTAssertTrue(self.isPlainDirectory(url.deletingLastPathComponent()))
                throw CocoaError(.fileWriteNoPermission)
            }
        )) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folderURL.path),
            "a marker-write failure must never leave anything at the final path"
        )
        XCTAssertTrue(
            scratchEntries(in: root).isEmpty,
            "a marker-write failure must not leave its own scratch folder behind either"
        )

        // A plain retry, with normal permissions restored, must still
        // succeed cleanly — the failed attempt above left nothing behind to
        // refuse it.
        let retried = try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)
        XCTAssertEqual(retried, folderURL)
        XCTAssertEqual(
            try markerContents(of: folderURL), MarkerContents(operationId: operationId, childId: childId))
    }

    // MARK: - removeIfOwn

    func testRemoveIfOwnDeletesOnlyAFolderCarryingItsExactMarker() throws {
        let operationId = UUID()
        let childId = UUID()
        let folderURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)
        _ = try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)

        try MeetingSplitChildFolderClaim.removeIfOwn(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testRemoveIfOwnLeavesAMismatchedMarkerUntouched() throws {
        let operationId = UUID()
        let childId = UUID()
        let folderURL = root.appendingPathComponent(childId.uuidString, isDirectory: true)
        _ = try MeetingSplitChildFolderClaim.claim(
            operationId: operationId, childId: childId, folderURL: folderURL, fileManager: .default)

        try MeetingSplitChildFolderClaim.removeIfOwn(
            operationId: UUID(), childId: childId, folderURL: folderURL, fileManager: .default)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path), "a mismatched marker must never be removed")
    }

    // MARK: - Helpers

    private struct MarkerContents: Equatable {
        let operationId: UUID
        let childId: UUID
    }

    private func markerContents(of folderURL: URL) throws -> MarkerContents {
        let data = try Data(
            contentsOf: folderURL.appendingPathComponent(".meeting-split-child-marker.json"))
        struct Decoded: Decodable {
            let operationId: UUID
            let childId: UUID
        }
        let decoded = try JSONDecoder().decode(Decoded.self, from: data)
        return MarkerContents(operationId: decoded.operationId, childId: decoded.childId)
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return false }
        return values.isSymbolicLink != true && values.isDirectory == true
    }

    private func scratchEntries(in directory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasPrefix(".meeting-split-child-scratch-") }
    }
}
