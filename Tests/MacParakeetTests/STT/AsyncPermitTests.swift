import XCTest
@testable import MacParakeetCore

final class AsyncPermitTests: XCTestCase {
    func testCancelledWaiterDoesNotConsumeNextSignal() async throws {
        let permit = AsyncPermit()
        try await permit.wait()

        let cancelledTask = Task {
            try await permit.wait()
        }
        try await waitForPendingWaiters(1, permit: permit)

        cancelledTask.cancel()
        do {
            try await value(cancelledTask)
            XCTFail("Expected queued waiter to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(permit.pendingWaiterCount(), 0)

        let nextTask = Task {
            try await permit.wait()
        }
        try await waitForPendingWaiters(1, permit: permit)

        permit.signal()
        try await value(nextTask)
        permit.signal()
    }

    func testWaitersResumeInFIFOOrder() async throws {
        let permit = AsyncPermit()
        try await permit.wait()

        let firstTask = Task {
            try await permit.wait()
            return 1
        }
        try await waitForPendingWaiters(1, permit: permit)

        let secondTask = Task {
            try await permit.wait()
            return 2
        }
        try await waitForPendingWaiters(2, permit: permit)

        permit.signal()
        let firstValue = try await value(firstTask)
        XCTAssertEqual(firstValue, 1)
        permit.signal()
        let secondValue = try await value(secondTask)
        XCTAssertEqual(secondValue, 2)
        permit.signal()
    }

    private func waitForPendingWaiters(
        _ count: Int,
        permit: AsyncPermit,
        timeout: Duration = .seconds(1)
    ) async throws {
        let start = ContinuousClock.now
        while permit.pendingWaiterCount() != count {
            if start.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for \(count) pending waiters")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func value<T>(
        _ task: Task<T, any Error>,
        timeout: Duration = .seconds(1)
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await task.value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AsyncPermitTestError.timeout
            }
            let result = try await group.next()!
            return result
        }
    }
}

private enum AsyncPermitTestError: Error {
    case timeout
}
