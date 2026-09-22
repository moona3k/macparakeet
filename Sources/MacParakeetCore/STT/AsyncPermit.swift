import Foundation

/// A FIFO, cancellation-aware async counting semaphore.
///
/// `wait()` suspends until a permit is available (or the task is cancelled,
/// which throws `CancellationError` and surrenders the waiter's place in line);
/// `signal()` returns a permit, waking the longest-waiting waiter first. Used to
/// serialize work that must not overlap — `WhisperEngine` transcriptions, and
/// (via `ANEInferenceGate`) all Neural Engine inference on macOS 14.
final class AsyncPermit: @unchecked Sendable {
    private final class WaitState: @unchecked Sendable {
        var cancelled = false
        var completed = false
    }

    private struct Waiter {
        let state: WaitState
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var permits: Int
    private var waiterOrder: [UUID] = []
    private var waiterHeadIndex = 0
    private var waiters: [UUID: Waiter] = [:]

    init(value: Int = 1) {
        permits = max(0, value)
    }

    func wait() async throws {
        let id = UUID()
        let state = WaitState()
        try await withTaskCancellationHandler {
            let _: Void = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if state.cancelled {
                    state.completed = true
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if permits > 0 {
                    permits -= 1
                    state.completed = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiterOrder.append(id)
                    waiters[id] = Waiter(state: state, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelWaiter(id: id, state: state)
        }
    }

    private func cancelWaiter(id: UUID, state: WaitState) {
        lock.lock()
        if state.completed {
            lock.unlock()
            return
        }
        guard let waiter = waiters.removeValue(forKey: id) else {
            state.cancelled = true
            lock.unlock()
            return
        }
        state.completed = true
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
    }

    func signal() {
        lock.lock()
        while waiterHeadIndex < waiterOrder.count {
            let id = waiterOrder[waiterHeadIndex]
            waiterHeadIndex += 1
            guard let waiter = waiters.removeValue(forKey: id) else {
                continue
            }
            waiter.state.completed = true
            compactWaiterOrderIfNeeded()
            lock.unlock()
            waiter.continuation.resume()
            return
        }
        permits += 1
        compactWaiterOrderIfNeeded()
        lock.unlock()
    }

    func pendingWaiterCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    private func compactWaiterOrderIfNeeded() {
        guard waiterHeadIndex > 64, waiterHeadIndex * 2 > waiterOrder.count else {
            return
        }
        waiterOrder = Array(waiterOrder.dropFirst(waiterHeadIndex))
        waiterHeadIndex = 0
    }
}
