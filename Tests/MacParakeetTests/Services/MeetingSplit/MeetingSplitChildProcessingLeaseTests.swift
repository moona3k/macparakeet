import Darwin
import XCTest
@testable import MacParakeetCore

final class MeetingSplitChildProcessingLeaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSplitChildProcessingLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSameChildConflictsUntilHolderReleases() throws {
        let childId = UUID()
        let holder = try MeetingSplitChildProcessingLease.acquire(childId: childId, recordingsRootURL: root)

        XCTAssertThrowsError(
            try MeetingSplitChildProcessingLease.acquire(childId: childId, recordingsRootURL: root)
        ) { error in
            guard case MeetingSplitChildProcessingLease.AcquisitionError.busy(let busyChildId) = error else {
                return XCTFail("expected busy, got \(error)")
            }
            XCTAssertEqual(busyChildId, childId)
        }

        let independentChild = try MeetingSplitChildProcessingLease.acquire(
            childId: UUID(), recordingsRootURL: root)
        independentChild.release()

        holder.release()
        let reacquired = try MeetingSplitChildProcessingLease.acquire(childId: childId, recordingsRootURL: root)
        reacquired.release()
    }

    func testSymlinkedLockFileIsNeverFollowed() throws {
        let childId = UUID()
        let locksDirectory = root.appendingPathComponent(
            MeetingSplitChildProcessingLease.locksDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("unrelated.txt")
        try Data("leave me alone".utf8).write(to: target)
        let lockURL = locksDirectory.appendingPathComponent("\(childId.uuidString.lowercased()).lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)

        XCTAssertThrowsError(
            try MeetingSplitChildProcessingLease.acquire(childId: childId, recordingsRootURL: root)
        ) { error in
            guard case MeetingSplitChildProcessingLease.AcquisitionError.ioFailure(let failedChildId, _) = error else {
                return XCTFail("expected ioFailure refusing the symlink, got \(error)")
            }
            XCTAssertEqual(failedChildId, childId)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("leave me alone".utf8))
    }

    func testCrossProcessHolderConflictsAndForcedExitReleasesLease() throws {
        let childId = UUID()
        let locksDirectory = root.appendingPathComponent(
            MeetingSplitChildProcessingLease.locksDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
        let lockPath = locksDirectory
            .appendingPathComponent("\(childId.uuidString.lowercased()).lock")
            .path
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
        process.standardOutput = stdoutPipe
        process.standardInput = Pipe()

        try process.run()
        try waitForLine("locked", on: stdoutPipe.fileHandleForReading)

        XCTAssertThrowsError(
            try MeetingSplitChildProcessingLease.acquire(childId: childId, recordingsRootURL: root)
        ) { error in
            guard case MeetingSplitChildProcessingLease.AcquisitionError.busy = error else {
                return XCTFail("expected busy from a cross-process holder, got \(error)")
            }
        }

        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()

        XCTAssertNoThrow(
            try MeetingSplitChildProcessingLease.acquire(childId: childId, recordingsRootURL: root).release()
        )
    }

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
