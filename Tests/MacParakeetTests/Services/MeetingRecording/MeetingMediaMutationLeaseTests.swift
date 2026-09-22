import Darwin
import XCTest
@testable import MacParakeetCore

final class MeetingMediaMutationLeaseTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMediaMutationLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAcquireCreatesHiddenLockFileAndReleaseIsIdempotent() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let lease = try MeetingMediaMutationLease.acquire(roots: [root])
        let lockURL = root.appendingPathComponent(MeetingMediaMutationLease.lockFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))

        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: lockURL.path, isDirectory: &isDirectory)
        XCTAssertFalse(isDirectory.boolValue, "lock file must be a regular file, not a directory")

        lease.release()
        lease.release() // idempotent: must not crash or double-close the fd
    }

    func testSameProcessIndependentAcquisitionsConflict() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try MeetingMediaMutationLease.acquire(roots: [root])
        XCTAssertThrowsError(try MeetingMediaMutationLease.acquire(roots: [root])) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy(let busyRoot) = error else {
                return XCTFail("Expected .busy, got \(error)")
            }
            XCTAssertEqual(busyRoot, root.resolvingSymlinksInPath().standardizedFileURL.path)
        }

        first.release()

        // Once released, a fresh acquisition of the same root must succeed.
        let third = try MeetingMediaMutationLease.acquire(roots: [root])
        third.release()
    }

    func testReleaseThenReacquireSucceeds() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let lease = try MeetingMediaMutationLease.acquire(roots: [root])
        lease.release()

        XCTAssertNoThrow(try MeetingMediaMutationLease.acquire(roots: [root]).release())
    }

    func testDeinitReleasesLease() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Discarding the result immediately deallocates it (nothing retains
        // it); deinit must drop the flock so the next acquisition succeeds
        // without an explicit `release()` call.
        _ = try MeetingMediaMutationLease.acquire(roots: [root])

        XCTAssertNoThrow(try MeetingMediaMutationLease.acquire(roots: [root]).release())
    }

    func testSeparateRootsDoNotConflict() throws {
        let rootA = try makeTempRoot()
        let rootB = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let leaseA = try MeetingMediaMutationLease.acquire(roots: [rootA])
        let leaseB = try MeetingMediaMutationLease.acquire(roots: [rootB])
        leaseA.release()
        leaseB.release()
    }

    func testAliasRootsShareLockKey() throws {
        let root = try makeTempRoot()
        let aliasParent = try makeTempRoot()
        let aliasURL = aliasParent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: root)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: aliasParent)
        }

        let lease = try MeetingMediaMutationLease.acquire(roots: [root])
        XCTAssertThrowsError(try MeetingMediaMutationLease.acquire(roots: [aliasURL])) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy = error else {
                return XCTFail("Expected alias path to resolve to the same lock key and conflict, got \(error)")
            }
        }
        lease.release()

        // After releasing the canonical root's lease, the alias path must be
        // acquirable -- proving both paths shared one root key throughout.
        XCTAssertNoThrow(try MeetingMediaMutationLease.acquire(roots: [aliasURL]).release())
    }

    func testPartialMultiRootAcquireUnwindsOnConflict() throws {
        // Both roots share one parent and differ only in a "0-"/"1-" prefix,
        // so their canonicalized, sorted acquisition order is deterministic
        // (A before B) rather than incidental on UUID-derived names: this
        // test pins that the multi-root acquire actually acquires A *before*
        // hitting B's conflict, not merely that some root eventually fails.
        let parent = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let rootA = parent.appendingPathComponent("0-a", isDirectory: true)
        let rootB = parent.appendingPathComponent("1-b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        XCTAssertLessThan(
            rootA.resolvingSymlinksInPath().standardizedFileURL.path,
            rootB.resolvingSymlinksInPath().standardizedFileURL.path,
            "test setup must guarantee A sorts before B")

        let busyHolder = try MeetingMediaMutationLease.acquire(roots: [rootB])

        // Pass the roots in reverse (B, A) order to prove the acquisition
        // order comes from sorting inside `acquire`, not from argument order.
        XCTAssertThrowsError(try MeetingMediaMutationLease.acquire(roots: [rootB, rootA])) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy(let busyRoot) = error else {
                return XCTFail("Expected .busy for root B, got \(error)")
            }
            XCTAssertEqual(busyRoot, rootB.resolvingSymlinksInPath().standardizedFileURL.path)
        }

        // A must have been acquired and then released by the failed
        // multi-root acquire: a fresh, independent acquisition of A alone
        // must succeed immediately.
        let leaseA = try MeetingMediaMutationLease.acquire(roots: [rootA])
        leaseA.release()
        busyHolder.release()
    }

    func testCrossProcessAcquisitionConflictsAndReleasesOnExit() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = root.appendingPathComponent(MeetingMediaMutationLease.lockFileName).path

        let script = """
        import fcntl, sys
        f = open(sys.argv[1], "a+")
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        sys.stdout.write("locked\\n")
        sys.stdout.flush()
        sys.stdin.readline()
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, lockPath]
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe

        try process.run()
        defer {
            if process.isRunning {
                stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
                process.waitUntilExit()
            }
        }

        try waitForLine("locked", on: stdoutPipe.fileHandleForReading)

        XCTAssertThrowsError(try MeetingMediaMutationLease.acquire(roots: [root])) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy = error else {
                return XCTFail("Expected .busy from a real cross-process flock holder, got \(error)")
            }
        }

        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
        process.waitUntilExit()

        // Process death (here, clean exit after releasing) drops the flock:
        // no PID-stale bookkeeping is involved, only the kernel's own release.
        XCTAssertNoThrow(try MeetingMediaMutationLease.acquire(roots: [root]).release())
    }

    func testForcedProcessDeathReleasesLeaseForReacquisition() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = root.appendingPathComponent(MeetingMediaMutationLease.lockFileName).path

        let script = """
        import fcntl, sys
        f = open(sys.argv[1], "a+")
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        sys.stdout.write("locked\\n")
        sys.stdout.flush()
        sys.stdin.readline()
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, lockPath]
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe

        try process.run()
        try waitForLine("locked", on: stdoutPipe.fileHandleForReading)

        XCTAssertThrowsError(try MeetingMediaMutationLease.acquire(roots: [root])) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.busy = error else {
                return XCTFail("Expected .busy while the helper still holds the lock, got \(error)")
            }
        }

        // Forced, uncooperative death: no `atexit`/finally in the helper ever
        // runs. Proves the kernel alone releases `flock` on process exit,
        // independent of any cooperative shutdown path.
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()

        XCTAssertNoThrow(try MeetingMediaMutationLease.acquire(roots: [root]).release())
    }

    // MARK: - Unexpected lock file type

    func testSymlinkAtLockPathIsRejectedWithoutFollowingIt() throws {
        let root = try makeTempRoot()
        let outsideRoot = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let outsideTarget = outsideRoot.appendingPathComponent("elsewhere")
        XCTAssertTrue(FileManager.default.createFile(atPath: outsideTarget.path, contents: Data()))
        let lockURL = root.appendingPathComponent(MeetingMediaMutationLease.lockFileName)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: outsideTarget)

        XCTAssertThrowsError(try MeetingMediaMutationLease.acquire(roots: [root])) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.ioFailure = error else {
                return XCTFail("Expected ioFailure refusing to follow a symlinked lock file, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outsideTarget), Data(), "the symlink target must never be locked or written")
    }

    func testNonRegularLockFileIsRejected() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = root.appendingPathComponent(MeetingMediaMutationLease.lockFileName).path
        XCTAssertEqual(mkfifo(lockPath, 0o600), 0, "test setup must create a FIFO at the lock path")

        XCTAssertThrowsError(try MeetingMediaMutationLease.acquire(roots: [root])) { error in
            guard case MeetingMediaMutationLease.AcquisitionError.unexpectedLockFileType = error else {
                return XCTFail("Expected unexpectedLockFileType for a FIFO at the lock path, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Bounded polling readiness check (`poll(2)` with a per-iteration
    /// timeout, re-checked against an overall deadline), not a blocking
    /// `FileHandle.availableData` read: that call blocks until at least one
    /// byte or EOF arrives, so a hung helper process would leave this test
    /// stuck past `timeout` instead of failing with `XCTFail`.
    private func waitForLine(
        _ expected: String,
        on handle: FileHandle,
        timeout: TimeInterval = 10
    ) throws {
        let fileDescriptor = handle.fileDescriptor
        let existingFlags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1_000))
            guard poll(&pollDescriptor, 1, min(remainingMs, 200)) > 0,
                pollDescriptor.revents & Int16(POLLIN) != 0
            else { continue }

            var chunk = [UInt8](repeating: 0, count: 4_096)
            let bytesRead = read(fileDescriptor, &chunk, chunk.count)
            guard bytesRead > 0 else { continue }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if let text = String(data: buffer, encoding: .utf8), text.contains(expected) {
                return
            }
        }
        XCTFail("Timed out waiting for helper process to report '\(expected)'")
    }
}
