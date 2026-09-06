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

    func testReadReturnsAwaitingTranscriptionLockRegardlessOfPID() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(pid: 42, state: .awaitingTranscription)
        try store.write(lockFile, folderURL: folderURL)

        let readLockFile = try XCTUnwrap(store.read(folderURL: folderURL))

        XCTAssertEqual(readLockFile.state, .awaitingTranscription)
        XCTAssertEqual(readLockFile.pid, 42)
        XCTAssertEqual(readLockFile.folderURL?.standardizedFileURL, folderURL.standardizedFileURL)
    }

    func testHasLiveOwnerUsesReadableLockPID() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let liveStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [42])
        )
        try liveStore.write(
            makeLockFile(pid: 42, state: .awaitingTranscription),
            folderURL: folderURL
        )

        XCTAssertTrue(try liveStore.hasLiveOwner(folderURL: folderURL))
    }

    func testHasLiveOwnerReturnsFalseForDeadOrMissingOwner() throws {
        let deadFolderURL = tempRoot.appendingPathComponent("dead-session")
        try store.write(
            makeLockFile(pid: 42, state: .awaitingTranscription),
            folderURL: deadFolderURL
        )

        XCTAssertFalse(try store.hasLiveOwner(folderURL: deadFolderURL))
        XCTAssertFalse(
            try store.hasLiveOwner(
                folderURL: tempRoot.appendingPathComponent("missing-session")
            ))
    }

    func testFinalizationOwnershipClaimRewritesAndReleaseRestoresDeadOwner() throws {
        let folderURL = tempRoot.appendingPathComponent("claim-session")
        let original = makeLockFile(
            pid: 42,
            state: .awaitingTranscription,
            folderURL: folderURL
        )
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [101]),
            processID: 101
        )
        try claimingStore.write(original, folderURL: folderURL)

        let lease = try claimingStore.claimFinalizationOwnership(
            folderURL: folderURL
        )

        let claimed = try XCTUnwrap(claimingStore.read(folderURL: folderURL))
        XCTAssertEqual(claimed.pid, 101)
        XCTAssertEqual(claimed.state, .awaitingTranscription)
        XCTAssertEqual(claimed.finalizationLeaseId, lease.id)

        try claimingStore.releaseFinalizationOwnership(lease)

        XCTAssertEqual(try claimingStore.read(folderURL: folderURL), original)
    }

    func testFinalizationOwnershipClaimRefusesLiveOwner() throws {
        let folderURL = tempRoot.appendingPathComponent("live-claim-session")
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [42, 101]),
            processID: 101
        )
        let original = makeLockFile(
            pid: 42,
            state: .awaitingTranscription,
            folderURL: folderURL
        )
        try claimingStore.write(original, folderURL: folderURL)

        XCTAssertThrowsError(
            try claimingStore.claimFinalizationOwnership(folderURL: folderURL)
        ) { error in
            XCTAssertEqual(
                error as? MeetingFinalizationOwnershipError,
                .ownedByLiveProcess(pid: 42)
            )
        }
        XCTAssertEqual(try claimingStore.read(folderURL: folderURL), original)
    }

    func testFinalizationOwnershipClaimReplacesDeadProcessLease() throws {
        let folderURL = tempRoot.appendingPathComponent("stale-lease-session")
        let staleLeaseID = UUID()
        let staleLock = makeLockFile(
            pid: 42,
            state: .awaitingTranscription,
            folderURL: folderURL
        ).withFinalizationOwner(pid: 42, leaseID: staleLeaseID)
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [101]),
            processID: 101
        )
        try claimingStore.write(staleLock, folderURL: folderURL)

        let replacementLease = try claimingStore.claimFinalizationOwnership(
            folderURL: folderURL
        )

        let claimed = try XCTUnwrap(claimingStore.read(folderURL: folderURL))
        XCTAssertEqual(claimed.pid, 101)
        XCTAssertEqual(claimed.finalizationLeaseId, replacementLease.id)
        XCTAssertNotEqual(claimed.finalizationLeaseId, staleLeaseID)
    }

    func testFinalizationOwnershipClaimTreatsUnreadablePresentLockAsDeadEvidence() throws {
        let folderURL = tempRoot.appendingPathComponent("corrupt-claim-session")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
        )
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [101]),
            processID: 101
        )

        let lease = try claimingStore.claimFinalizationOwnership(folderURL: folderURL)

        let claimed = try XCTUnwrap(claimingStore.read(folderURL: folderURL))
        XCTAssertEqual(claimed.pid, 101)
        XCTAssertEqual(claimed.finalizationLeaseId, lease.id)
        XCTAssertEqual(claimed.state, .awaitingTranscription)
    }

    func testHasLiveOwnerHonorsPeekedPIDOnNewerSchemaLock() throws {
        let folderURL = tempRoot.appendingPathComponent("future-schema-live")
        let liveStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [42])
        )
        try writeRawLockFile(makeLockFile(schemaVersion: 999, pid: 42), folderURL: folderURL)

        XCTAssertNil(try liveStore.read(folderURL: folderURL))
        XCTAssertTrue(try liveStore.hasLiveOwner(folderURL: folderURL))
        XCTAssertFalse(
            try MeetingRecordingLockFileStore(
                processChecker: MockProcessAliveChecker(alivePIDs: [])
            ).hasLiveOwner(folderURL: folderURL)
        )
    }

    func testFinalizationOwnershipClaimRefusesLiveNewerSchemaLock() throws {
        let folderURL = tempRoot.appendingPathComponent("future-schema-claim")
        try writeRawLockFile(makeLockFile(schemaVersion: 999, pid: 42), folderURL: folderURL)
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [42, 101]),
            processID: 101
        )

        XCTAssertThrowsError(
            try claimingStore.claimFinalizationOwnership(folderURL: folderURL)
        ) { error in
            XCTAssertEqual(
                error as? MeetingFinalizationOwnershipError,
                .ownedByLiveProcess(pid: 42)
            )
        }
        XCTAssertNil(try claimingStore.read(folderURL: folderURL))
    }

    func testFinalizationOwnershipClaimReplacesDeadNewerSchemaLock() throws {
        let folderURL = tempRoot.appendingPathComponent("future-schema-dead")
        try writeRawLockFile(makeLockFile(schemaVersion: 999, pid: 42), folderURL: folderURL)
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [101]),
            processID: 101
        )

        let lease = try claimingStore.claimFinalizationOwnership(folderURL: folderURL)

        let claimed = try XCTUnwrap(claimingStore.read(folderURL: folderURL))
        XCTAssertEqual(claimed.pid, 101)
        XCTAssertEqual(claimed.finalizationLeaseId, lease.id)
        XCTAssertEqual(claimed.schemaVersion, MeetingRecordingLockFile.currentSchemaVersion)
    }

    func testFinalizationOwnershipClaimTreatsZeroByteLockAsDeadEvidence() throws {
        let folderURL = tempRoot.appendingPathComponent("zero-byte-claim-session")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data().write(to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [101]),
            processID: 101
        )

        let lease = try claimingStore.claimFinalizationOwnership(folderURL: folderURL)

        let claimed = try XCTUnwrap(claimingStore.read(folderURL: folderURL))
        XCTAssertEqual(claimed.pid, 101)
        XCTAssertEqual(claimed.finalizationLeaseId, lease.id)
    }

    func testFailedOwnershipReleaseCanBeReclaimedBySameProcess() throws {
        let folderURL = tempRoot.appendingPathComponent("failed-release-session")
        let claimingStore = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [101]),
            processID: 101
        )
        let original = makeLockFile(
            pid: 42,
            state: .awaitingTranscription,
            folderURL: folderURL
        )
        try claimingStore.write(
            original,
            folderURL: folderURL
        )
        let abandonedLease = try claimingStore.claimFinalizationOwnership(
            folderURL: folderURL
        )
        let claimedLock = try XCTUnwrap(
            claimingStore.read(folderURL: folderURL)
        )

        try FileManager.default.removeItem(at: folderURL)
        XCTAssertThrowsError(
            try claimingStore.releaseFinalizationOwnership(abandonedLease)
        )

        try claimingStore.write(claimedLock, folderURL: folderURL)
        XCTAssertFalse(try claimingStore.hasLiveOwner(folderURL: folderURL))
        XCTAssertEqual(
            try claimingStore.discoverOrphans(meetingsRoot: tempRoot).map(\.sessionId),
            [original.sessionId]
        )
        XCTAssertTrue(
            try claimingStore.discoverActiveSessions(meetingsRoot: tempRoot).isEmpty
        )

        let replacementLease = try claimingStore.claimFinalizationOwnership(
            folderURL: folderURL
        )

        XCTAssertNotEqual(replacementLease.id, abandonedLease.id)
        let replacementLock = try XCTUnwrap(
            claimingStore.read(folderURL: folderURL)
        )
        XCTAssertEqual(replacementLock.pid, 101)
        XCTAssertEqual(replacementLock.finalizationLeaseId, replacementLease.id)

        try claimingStore.releaseFinalizationOwnership(replacementLease)
        XCTAssertEqual(try claimingStore.read(folderURL: folderURL), original)

        let thirdLease = try claimingStore.claimFinalizationOwnership(
            folderURL: folderURL
        )
        XCTAssertNotEqual(thirdLease.id, replacementLease.id)
    }

    func testConcurrentFinalizationOwnershipClaimsAdmitOneProcess() async throws {
        let folderURL = tempRoot.appendingPathComponent("concurrent-claim-session")
        let processChecker = MockProcessAliveChecker(alivePIDs: [101, 202])
        let firstStore = MeetingRecordingLockFileStore(
            processChecker: processChecker,
            processID: 101
        )
        let secondStore = MeetingRecordingLockFileStore(
            processChecker: processChecker,
            processID: 202
        )
        let original = makeLockFile(
            pid: 42,
            state: .awaitingTranscription,
            folderURL: folderURL
        )

        for iteration in 0..<25 {
            try firstStore.write(original, folderURL: folderURL)
            let firstTask = Task.detached {
                try? firstStore.claimFinalizationOwnership(folderURL: folderURL)
            }
            let secondTask = Task.detached {
                try? secondStore.claimFinalizationOwnership(folderURL: folderURL)
            }
            let firstLease = await firstTask.value
            let secondLease = await secondTask.value
            let leases = [firstLease, secondLease].compactMap { $0 }

            XCTAssertEqual(
                leases.count,
                1,
                "Expected one finalization owner in iteration \(iteration)"
            )
            if let lease = leases.first {
                try firstStore.releaseFinalizationOwnership(lease)
            }
        }
    }

    func testDeleteRemovesFile() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        try store.write(makeLockFile(), folderURL: folderURL)

        try store.delete(folderURL: folderURL)

        XCTAssertFalse(
            FileManager.default.fileExists(
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

    // MARK: - discoverActiveSessions (inverse of discoverOrphans)

    func testDiscoverActiveSessionsReturnsLiveOwners() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let lockFile = makeLockFile(pid: 42)
        let store = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [42])
        )
        try store.write(lockFile, folderURL: folderURL)

        let active = try store.discoverActiveSessions(meetingsRoot: tempRoot)

        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.sessionId, lockFile.sessionId)
        XCTAssertEqual(active.first?.folderURL?.standardizedFileURL, folderURL.standardizedFileURL)
    }

    func testDiscoverActiveSessionsSkipsDeadOwners() throws {
        let folderURL = tempRoot.appendingPathComponent("session")
        let store = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [])
        )
        try store.write(makeLockFile(pid: 42), folderURL: folderURL)

        let active = try store.discoverActiveSessions(meetingsRoot: tempRoot)

        XCTAssertTrue(active.isEmpty)
    }

    func testDiscoverActiveSessionsIsNotRetentionSafetyPredicate() throws {
        let folderURL = tempRoot.appendingPathComponent("awaiting-transcription")
        let store = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [])
        )
        let awaiting = makeLockFile(pid: 42, state: .awaitingTranscription)
        try store.write(awaiting, folderURL: folderURL)

        let active = try store.discoverActiveSessions(meetingsRoot: tempRoot)
        let any = try store.discoverAnySessions(meetingsRoot: tempRoot)

        XCTAssertTrue(active.isEmpty, "active sessions are PID-live only")
        XCTAssertEqual(any.map(\.sessionId), [awaiting.sessionId])
        XCTAssertEqual(any.first?.state, .awaitingTranscription)
    }

    func testDiscoverActiveSessionsReturnsEmptyForMissingRoot() throws {
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)

        XCTAssertTrue(try store.discoverActiveSessions(meetingsRoot: missing).isEmpty)
    }

    // MARK: - discoverAnySessions (retention guard)

    func testDiscoverAnySessionsReturnsLiveAndDeadOwners() throws {
        let liveFolderURL = tempRoot.appendingPathComponent("live")
        let deadFolderURL = tempRoot.appendingPathComponent("dead")
        let store = MeetingRecordingLockFileStore(
            processChecker: MockProcessAliveChecker(alivePIDs: [42])
        )
        let live = makeLockFile(
            sessionId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 42,
            folderURL: liveFolderURL
        )
        let deadAwaiting = makeLockFile(
            sessionId: UUID(uuidString: "66666666-7777-8888-9999-000000000000")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_001),
            pid: 99,
            state: .awaitingTranscription,
            folderURL: deadFolderURL
        )
        try store.write(live, folderURL: liveFolderURL)
        try store.write(deadAwaiting, folderURL: deadFolderURL)

        let sessions = try store.discoverAnySessions(meetingsRoot: tempRoot)

        XCTAssertEqual(sessions.map(\.sessionId), [live.sessionId, deadAwaiting.sessionId])
        XCTAssertEqual(sessions.map(\.state), [.recording, .awaitingTranscription])
        XCTAssertEqual(
            sessions.map { $0.folderURL?.standardizedFileURL },
            [
                liveFolderURL.standardizedFileURL,
                deadFolderURL.standardizedFileURL,
            ])
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
        XCTAssertEqual(readLockFile.speechEngine.engine, .parakeet)
        XCTAssertFalse(readLockFile.speechEngineWasCaptured)
    }

    func testUncapturedSpeechEngineRemainsAbsentAfterRewrite() throws {
        let folderURL = tempRoot.appendingPathComponent("legacy-session")
        let lockFile = makeLockFile(folderURL: folderURL, speechEngineWasCaptured: false)

        try store.write(lockFile, folderURL: folderURL)

        let keys = try encodedJSONKeys(folderURL: folderURL)
        XCTAssertFalse(keys.contains("speechEngine"))
        let decoded = try XCTUnwrap(store.read(folderURL: folderURL))
        XCTAssertFalse(decoded.withFolderURL(folderURL).speechEngineWasCaptured)
    }

    func testReadTreatsSchemaOneSpeechEngineAsLegacyProvenance() throws {
        let folderURL = tempRoot.appendingPathComponent("schema-one-session")
        let legacyLockFile = makeLockFile(schemaVersion: 1, speechEngineWasCaptured: true)
        try writeRawLockFile(legacyLockFile, folderURL: folderURL)

        let decoded = try XCTUnwrap(store.read(folderURL: folderURL))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertFalse(decoded.speechEngineWasCaptured)
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

    func testReadFromLockFileWithMalformedStartContextStillRecoversMetadata() throws {
        let folderURL = tempRoot.appendingPathComponent("session-start-context")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let json = """
            {
                "schemaVersion": 1,
                "sessionId": "11111111-2222-3333-4444-555555555555",
                "startedAt": "2026-04-25T12:00:00Z",
                "pid": 123,
                "displayName": "Recoverable Session",
                "state": "recording",
                "startContext": {
                    "triggerKind": "future_trigger",
                    "sourceMode": "microphone_only"
                }
            }
            """
        try Data(json.utf8).write(to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))

        let readLockFile = try XCTUnwrap(store.read(folderURL: folderURL))
        XCTAssertNil(readLockFile.startContext, "malformed startContext must not block recovery")
        XCTAssertEqual(readLockFile.displayName, "Recoverable Session")
        XCTAssertEqual(readLockFile.sessionId, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    }

    func testReadFromLockFileWithMalformedCalendarSnapshotStillRecoversMetadata() throws {
        let folderURL = tempRoot.appendingPathComponent("session-calendar-snapshot")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let json = """
            {
                "schemaVersion": 1,
                "sessionId": "11111111-2222-3333-4444-555555555555",
                "startedAt": "2026-04-25T12:00:00Z",
                "pid": 123,
                "displayName": "Recoverable Session",
                "state": "recording",
                "calendarEventSnapshot": 42
            }
            """
        try Data(json.utf8).write(to: MeetingRecordingLockFileStore.lockFileURL(for: folderURL))

        let readLockFile = try XCTUnwrap(store.read(folderURL: folderURL))
        XCTAssertNil(
            readLockFile.calendarEventSnapshot,
            "malformed calendar snapshot must fall through to nil, not block recovery"
        )
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

    func testMeetingTypeRoundTripsAndSurvivesLockTransitions() throws {
        let folderURL = tempRoot.appendingPathComponent("typed-session")
        let meetingTypeId = UUID()
        let lockFile = makeLockFile(folderURL: folderURL)
            .withMeetingTypeId(meetingTypeId)
            .withNotes("note")
            .withState(.awaitingTranscription)

        try store.write(lockFile, folderURL: folderURL)

        XCTAssertEqual(try store.read(folderURL: folderURL)?.meetingTypeId, meetingTypeId)
    }

    private func makeLockFile(
        schemaVersion: Int = MeetingRecordingLockFile.currentSchemaVersion,
        sessionId: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        pid: Int32 = 123,
        displayName: String = "Team Sync",
        state: MeetingRecordingLockState = .recording,
        folderURL: URL? = nil,
        speechEngineWasCaptured: Bool = true
    ) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            pid: pid,
            displayName: displayName,
            state: state,
            speechEngineWasCaptured: speechEngineWasCaptured,
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
