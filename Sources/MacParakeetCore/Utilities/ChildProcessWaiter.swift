import Darwin
import Foundation
import os

enum ChildProcessWaiter {
    private enum Outcome: Sendable {
        case exited
        case timedOut
    }

    static func waitUntilExit(
        _ process: Process,
        timeout: TimeInterval,
        killGracePeriod: TimeInterval = 2,
        timeoutError: @autoclosure @escaping @Sendable () -> Error
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                try await waitUntilExitBody(
                    process,
                    timeout: timeout,
                    killGracePeriod: killGracePeriod,
                    timeoutError: timeoutError
                )
            } onCancel: {
                terminate(process, killGracePeriod: killGracePeriod)
            }
        } catch is CancellationError {
            terminate(process, killGracePeriod: killGracePeriod)
            await awaitProcessTermination(process)
            throw CancellationError()
        }

        try Task.checkCancellation()
    }

    private static func waitUntilExitBody(
        _ process: Process,
        timeout: TimeInterval,
        killGracePeriod: TimeInterval,
        timeoutError: @escaping @Sendable () -> Error
    ) async throws {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                await awaitProcessTermination(process)
                return .exited
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds(for: timeout))
                return .timedOut
            }

            guard let first = try await group.next() else { return }
            switch first {
            case .exited:
                group.cancelAll()
                return
            case .timedOut:
                terminate(process, killGracePeriod: killGracePeriod)
                while let outcome = try await group.next() {
                    if case .exited = outcome {
                        group.cancelAll()
                        throw timeoutError()
                    }
                }
                throw timeoutError()
            }
        }
    }

    private static func awaitProcessTermination(_ process: Process) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    continuation.resume()
                }
            }

            if !process.isRunning {
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    process.terminationHandler = nil
                    continuation.resume()
                }
            }
        }
    }

    private static func terminate(_ process: Process, killGracePeriod: TimeInterval) {
        guard process.isRunning else { return }
        process.terminate()

        let stuckProcess = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGracePeriod) {
            guard stuckProcess.isRunning else { return }
            kill(stuckProcess.processIdentifier, SIGKILL)
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds)
    }
}
