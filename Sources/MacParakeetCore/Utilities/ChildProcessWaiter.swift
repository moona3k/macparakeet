import Darwin
import Foundation
import os

enum ChildProcessWaiter {
    private enum WaitEvent: Sendable {
        case exited
        case timedOut
        case cancelled
    }

    private struct WaitState {
        var outcome: WaitEvent?
        var continuation: CheckedContinuation<WaitEvent, Never>?
    }

    private final class ExitWaiter: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: WaitState())

        func install(_ continuation: CheckedContinuation<WaitEvent, Never>) -> WaitEvent? {
            state.withLock { state in
                if let outcome = state.outcome {
                    return outcome
                }
                state.continuation = continuation
                return nil
            }
        }

        func resume(_ outcome: WaitEvent, process: Process) {
            let result = state.withLock { state -> (completed: Bool, continuation: CheckedContinuation<WaitEvent, Never>?) in
                guard state.outcome == nil else { return (false, nil) }
                state.outcome = outcome
                let continuation = state.continuation
                state.continuation = nil
                return (true, continuation)
            }
            guard result.completed else { return }
            process.terminationHandler = nil
            result.continuation?.resume(returning: outcome)
        }
    }

    static func waitUntilExit(
        _ process: Process,
        timeout: TimeInterval,
        killGracePeriod: TimeInterval = 2,
        killConfirmationTimeout: TimeInterval = 5,
        timeoutError: @autoclosure @escaping @Sendable () -> Error
    ) async throws {
        let firstEvent = await awaitProcessEvent(
            process,
            timeout: timeout,
            resumeOnCancellation: true
        )

        switch firstEvent {
        case .exited:
            try Task.checkCancellation()
        case .timedOut:
            terminate(process, killGracePeriod: killGracePeriod)
            _ = await awaitProcessEvent(
                process,
                timeout: killGracePeriod + killConfirmationTimeout,
                resumeOnCancellation: false
            )
            throw timeoutError()
        case .cancelled:
            terminate(process, killGracePeriod: killGracePeriod)
            _ = await awaitProcessEvent(
                process,
                timeout: killGracePeriod + killConfirmationTimeout,
                resumeOnCancellation: false
            )
            throw CancellationError()
        }
    }

    private static func awaitProcessEvent(
        _ process: Process,
        timeout: TimeInterval,
        resumeOnCancellation: Bool
    ) async -> WaitEvent {
        let waiter = ExitWaiter()
        let operation = {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitEvent, Never>) in
                process.terminationHandler = { _ in
                    waiter.resume(.exited, process: process)
                }

                if let outcome = waiter.install(continuation) {
                    process.terminationHandler = nil
                    continuation.resume(returning: outcome)
                    return
                }

                if timeout <= 0 {
                    waiter.resume(.timedOut, process: process)
                } else {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        waiter.resume(.timedOut, process: process)
                    }
                }

                if !process.isRunning {
                    waiter.resume(.exited, process: process)
                }
            }
        }

        if resumeOnCancellation {
            return await withTaskCancellationHandler {
                await operation()
            } onCancel: {
                waiter.resume(.cancelled, process: process)
            }
        }

        return await operation()
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
}
