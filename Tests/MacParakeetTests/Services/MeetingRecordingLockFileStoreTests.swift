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

    // MARK: - ADR-020 §9 — notes field

    func testWriteThenReadRoundTripsNotes() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(folderURL: folderURL).withNotes("buy milk\nfix the bug")

        try store.write(lockFile, folderURL: folderURL)

        let readLockFile = try XCTUnwrap(store.read(folderURL: folderURL))
        XCTAssertEqual(readLockFile.notes, "buy milk\nfix the bug")
    }

    func testNilNotesIsNotEncoded() throws {
        // `encodeIfPresent` with `nil` notes must omit the key entirely so
        // pre-v0.8 readers (and any external tools) don't trip on a
        // surprise `notes: null` field.
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(folderURL: folderURL)

        try store.write(lockFile, folderURL: folderURL)

        let keys = try encodedJSONKeys(folderURL: folderURL)
        XCTAssertFalse(keys.contains("notes"), "nil notes must not be persisted to JSON")
    }

    func testReadFromLockFileMissingNotesKeyDecodesAsNil() throws {
        // Simulates an upgrade path: a lock file written by the previous app
        // version (pre-v0.8) has no `notes` key. The new reader must decode
        // it cleanly with `notes = nil` rather than rejecting the file.
        let folderURL = tempRoot.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let json = """
        {
            "schemaVersion": 1,
            "sessionId": "11111111-2222-3333-4444-555555555555",
            "startedAt": "2026-04-25T12:00:00Z",
            "pid": 123,
            "displayName": "Old Session",
            "state": "recording"
        }
        """
        try Data(json.utf8).write(to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))

        let readLockFile = try XCTUnwrap(store.read(folderURL: folderURL))
        XCTAssertNil(readLockFile.notes)
        XCTAssertEqual(readLockFile.displayName, "Old Session")
    }

    func testReadFromLockFileWithMalformedNotesValueStillRecoversMetadata() throws {
        // ADR-020 §9: notes are decoded as a separate `try?` step so a
        // type-mismatch on the notes field cannot block recovery of the
        // structural fields (the audio metadata is what really matters).
        // Here we make `notes` a number rather than a string — the structural
        // fields must still decode and `notes` falls back to `nil`.
        let folderURL = tempRoot.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let json = """
        {
            "schemaVersion": 1,
            "sessionId": "11111111-2222-3333-4444-555555555555",
            "startedAt": "2026-04-25T12:00:00Z",
            "pid": 123,
            "displayName": "Recoverable Session",
            "state": "recording",
            "notes": 42
        }
        """
        try Data(json.utf8).write(to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))

        let readLockFile = try XCTUnwrap(store.read(folderURL: folderURL))
        XCTAssertNil(readLockFile.notes, "malformed notes must fall through to nil, not block recovery")
        XCTAssertEqual(readLockFile.displayName, "Recoverable Session")
    }

    func testWithNotesPreservesEverythingElse() throws {
        let lockFile = makeLockFile().withNotes("first note")
        let updated = lockFile.withNotes("second note")
        XCTAssertEqual(updated.notes, "second note")
        XCTAssertEqual(updated.sessionId, lockFile.sessionId)
        XCTAssertEqual(updated.displayName, lockFile.displayName)
        XCTAssertEqual(updated.startedAt, lockFile.startedAt)
        XCTAssertEqual(updated.pid, lockFile.pid)
        XCTAssertEqual(updated.state, lockFile.state)
        XCTAssertEqual(updated.schemaVersion, lockFile.schemaVersion)
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
