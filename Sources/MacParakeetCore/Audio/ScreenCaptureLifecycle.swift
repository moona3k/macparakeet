import Foundation

enum CaptureLifecycleDeadlineError: Error, Equatable, LocalizedError {
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .startTimedOut:
            return "Screen capture start timed out"
        }
    }
}

enum ScreenCaptureStopOutcome: Equatable, Sendable {
    case completed
    case timedOut
    case cancelled
}

protocol ScreenCaptureLifecycleSession: AnyObject, Sendable {
    func startCapture(completionHandler: @escaping (Error?) -> Void)
    func stopCapture(completionHandler: @escaping (Error?) -> Void)
    func makeLateStartStopAction() -> @Sendable () -> Void
}

/// Owns the callback-style start/stop boundary for one screen-capture stream.
///
/// Framework callbacks are not trusted to arrive. The caller receives exactly
/// one terminal event, and a late successful start is stopped again so it
/// cannot revive a stream after timeout or cancellation.
final class ScreenCaptureLifecycleController: @unchecked Sendable {
    private let session: any ScreenCaptureLifecycleSession
    private let startTimeoutSeconds: TimeInterval
    private let stopTimeoutSeconds: TimeInterval
    private let lock = NSLock()
    private var pendingStart: CaptureLifecycleWaiter?
    private var startCancellationRequested = false

    init(
        session: any ScreenCaptureLifecycleSession,
        startTimeoutSeconds: TimeInterval,
        stopTimeoutSeconds: TimeInterval
    ) {
        self.session = session
        self.startTimeoutSeconds = max(0, startTimeoutSeconds)
        self.stopTimeoutSeconds = max(0, stopTimeoutSeconds)
    }

    func start() async throws {
        try Task.checkCancellation()
        let waiter = CaptureLifecycleWaiter()
        let wasAlreadyCancelled = lock.withLock { () -> Bool in
            guard !startCancellationRequested else { return true }
            pendingStart = waiter
            return false
        }
        guard !wasAlreadyCancelled else { throw CancellationError() }
        defer {
            lock.withLock {
                if pendingStart === waiter {
                    pendingStart = nil
                }
            }
        }

        let session = self.session
        let stopLateStart = session.makeLateStartStopAction()
        session.startCapture { error in
            let result: Result<Void, Error> = error.map(Result.failure) ?? .success(())
            let won = waiter.resolve(.completed(result))
            guard !won, error == nil else { return }

            // A timeout/cancellation already released the caller. A successful
            // callback means ScreenCaptureKit may now have activated the stream,
            // so issue a second non-blocking stop even if an earlier stop raced
            // the still-pending start. The action weakly targets the underlying
            // session/stream and does not retain this controller indefinitely.
            stopLateStart()
        }

        switch await waiter.wait(timeoutSeconds: startTimeoutSeconds) {
        case .completed(.success):
            return
        case .completed(.failure(let error)):
            throw error
        case .timedOut:
            throw CaptureLifecycleDeadlineError.startTimedOut
        case .cancelled:
            throw CancellationError()
        }
    }

    func cancelPendingStart() {
        let waiter = lock.withLock {
            startCancellationRequested = true
            return pendingStart
        }
        waiter?.resolve(.cancelled)
    }

    func stop() async -> ScreenCaptureStopOutcome {
        let waiter = CaptureLifecycleWaiter()
        session.stopCapture { _ in
            waiter.resolve(.completed(.success(())))
        }

        switch await waiter.wait(timeoutSeconds: stopTimeoutSeconds) {
        case .completed:
            return .completed
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }
}

/// Runs the complete async capture-start attempt behind a deadline without
/// waiting for a non-cooperative framework task to acknowledge cancellation.
/// The operation itself must validate lifecycle ownership after every await so
/// a late result cleans up rather than installing state.
enum BoundedCaptureStartAttempt {
    static func run(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let waiter = CaptureLifecycleWaiter()
        let operationTask = Task {
            do {
                try await operation()
                waiter.resolve(.completed(.success(())))
            } catch {
                waiter.resolve(.completed(.failure(error)))
            }
        }

        let event = await waiter.wait(timeoutSeconds: max(0, timeoutSeconds))
        switch event {
        case .completed(.success):
            return
        case .completed(.failure(let error)):
            throw error
        case .timedOut:
            operationTask.cancel()
            throw CaptureLifecycleDeadlineError.startTimedOut
        case .cancelled:
            operationTask.cancel()
            throw CancellationError()
        }
    }
}

private enum CaptureLifecycleWaitEvent: @unchecked Sendable {
    case completed(Result<Void, Error>)
    case timedOut
    case cancelled
}

private struct CaptureLifecycleWaitState {
    var event: CaptureLifecycleWaitEvent?
    var continuation: CheckedContinuation<CaptureLifecycleWaitEvent, Never>?
}

private final class CaptureLifecycleWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var state = CaptureLifecycleWaitState()

    @discardableResult
    func resolve(_ event: CaptureLifecycleWaitEvent) -> Bool {
        let result = lock.withLock {
            () -> (won: Bool, continuation: CheckedContinuation<CaptureLifecycleWaitEvent, Never>?) in
            guard state.event == nil else { return (false, nil) }
            state.event = event
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        result.continuation?.resume(returning: event)
        return result.won
    }

    func wait(timeoutSeconds: TimeInterval) async -> CaptureLifecycleWaitEvent {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyResolved = lock.withLock { () -> CaptureLifecycleWaitEvent? in
                    if let event = state.event {
                        return event
                    }
                    state.continuation = continuation
                    return nil
                }
                if let alreadyResolved {
                    continuation.resume(returning: alreadyResolved)
                    return
                }

                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0, timeoutSeconds)
                ) { [weak self] in
                    self?.resolve(.timedOut)
                }
            }
        } onCancel: {
            resolve(.cancelled)
        }
    }
}
