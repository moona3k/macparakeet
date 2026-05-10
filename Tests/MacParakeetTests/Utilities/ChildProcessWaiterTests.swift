import Darwin
import XCTest
@testable import MacParakeetCore

final class ChildProcessWaiterTests: XCTestCase {
    private enum TestError: Error {
        case timedOut
    }

    func testTimeoutWaitsForStubbornProcessToExit() async throws {
        let process = stubbornShellProcess()
        try process.run()
        defer { killIfStillRunning(process) }

        do {
            try await ChildProcessWaiter.waitUntilExit(
                process,
                timeout: 0.05,
                killGracePeriod: 0.05,
                timeoutError: TestError.timedOut
            )
            XCTFail("Expected timeout")
        } catch TestError.timedOut {
            XCTAssertFalse(process.isRunning)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationWaitsForStubbornProcessToExit() async throws {
        let process = stubbornShellProcess()
        try process.run()
        defer { killIfStillRunning(process) }

        let task = Task {
            try await ChildProcessWaiter.waitUntilExit(
                process,
                timeout: 60,
                killGracePeriod: 0.05,
                timeoutError: TestError.timedOut
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(process.isRunning)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func stubbornShellProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while true; do :; done"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func killIfStillRunning(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
