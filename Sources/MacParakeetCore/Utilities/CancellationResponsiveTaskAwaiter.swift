import Foundation

/// A single cancellation-responsive waiter; cancellation never cancels the shared work.
final class CancellationResponsiveTaskAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let pendingResult: Result<Void, Error>?
                lock.lock()
                if let result {
                    pendingResult = result
                } else {
                    self.continuation = continuation
                    pendingResult = nil
                }
                lock.unlock()

                if let pendingResult {
                    continuation.resume(with: pendingResult)
                }
            }
        } onCancel: {
            resume(with: .failure(CancellationError()))
        }
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}
