import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingLockFileStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: MeetingRecordingLockFileStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecordingLockFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = MeetingRecordingLockFileStore(processChecker: MockProcessAliveChecker(alivePIDs: []))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        store = nil
        tempRoot = nil
    }

    func testWriteThenReadRoundTrip() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(folderURL: folderURL)

        try store.write(lockFile, folderURL: folderURL)

        let readLockFile = try XCTUnwrap(store.read(folderURL: folderURL))
        XCTAssertEqual(readLockFile, lockFile)
        XCTAssertFalse(try encodedJSONKeys(folderURL: folderURL).contains("folderURL"))
    }

    func testReadFromMissingFolderReturnsNil() throws {
        let folderURL = tempRoot.appendingPathComponent("missing")

        XCTAssertNil(try store.read(folderURL: folderURL))
    }

    func testReadFromCorruptJSONReturnsNil() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
        )

        XCTAssertNil(try store.read(folderURL: folderURL))
    }

    func testReadFromUnknownSchemaVersionReturnsNil() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(schemaVersion: 999)

        try writeRawLockFile(lockFile, folderURL: folderURL)

        XCTAssertNil(try store.read(folderURL: folderURL))
    }

    func testDeleteRemovesFile() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        try store.write(makeLockFile(), folderURL: folderURL)

        try store.delete(folderURL: folderURL)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MeetingRecordingLockFileStore.lockFileURL(for: folderURL).path
        ))
    }

    func testDiscoverOrphansSkipsLiveOwners() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(pid: 42)
        let store = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [42])
        )
        try store.write(lockFile, folderURL: folderURL)

        let discoveries = try store.discoverOrphans(meetingsRoot: tempRoot)

        XCTAssertTrue(discoveries.isEmpty)
    }

    func testDiscoverOrphansReturnsDeadOwnersWithFolderURL() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(pid: 42)
        let store = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [])
        )
        try store.write(lockFile, folderURL: folderURL)

        let discoveries = try store.discoverOrphans(meetingsRoot: tempRoot)

        let discovery = try XCTUnwrap(discoveries.first)
        XCTAssertEqual(discoveries.count, 1)
        XCTAssertEqual(discovery.withFolderURL(folderURL), lockFile.withFolderURL(folderURL))
        XCTAssertEqual(discovery.folderURL?.standardizedFileURL, folderURL.standardizedFileURL)
        XCTAssertEqual(discovery.sessionId, lockFile.sessionId)
        XCTAssertEqual(discovery.displayName, lockFile.displayName)
    }

    func testDiscoverOrphansHandlesUnknownSchemaVersion() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        try writeRawLockFile(makeLockFile(schemaVersion: 999), folderURL: folderURL)

        let discoveries = try store.discoverOrphans(meetingsRoot: tempRoot)

        XCTAssertTrue(discoveries.isEmpty)
    }

    func testDiscoverOrphansSkipsCorruptJSON() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(
            to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
        )

        let discoveries = try store.discoverOrphans(meetingsRoot: tempRoot)

        XCTAssertTrue(discoveries.isEmpty)
    }

    private func makeLockFile(
        schemaVersion: Int = MeetingRecordingLockFile.currentSchemaVersion,
        sessionId: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        pid: Int32 = 123,
        displayName: String = "Team Sync",
        folderURL: URL? = nil
    ) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            folderURL: folderURL
        )
    }

    private func writeRawLockFile(_ lockFile: MeetingRecordingLockFile, folderURL: URL) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(lockFile)
        try data.write(to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))
    }

    private func encodedJSONKeys(folderURL: URL) throws -> Set<String> {
        let data = try Data(contentsOf: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return Set(dictionary.keys)
    }
}

private struct MockProcessAliveChecker: ProcessAliveChecking {
    let alivePIDs: Set<Int32>

    func isAlive(pid: Int32) -> Bool {
        alivePIDs.contains(pid)
    }
}
