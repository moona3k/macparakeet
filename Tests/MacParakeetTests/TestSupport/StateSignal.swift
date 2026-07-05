import Foundation

actor StateSignal<T: Equatable & Sendable> {
    private struct Waiter {
        let id: UUID
        let value: T
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var emittedValues: [T] = []
    private var waiters: [Waiter] = []

    var history: [T] {
        emittedValues
    }

    func emit(_ value: T) {
        emittedValues.append(value)

        let matchingWaiters = waiters.filter { $0.value == value }
        waiters.removeAll { $0.value == value }
        matchingWaiters.forEach { $0.continuation.resume(returning: true) }
    }

    func wait(for value: T, timeout: Duration = .seconds(1)) async -> Bool {
        if emittedValues.contains(value) {
            return true
        }

        let id = UUID()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.registerWaiter(id: id, value: value)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return await self.timeOutWaiter(id: id, value: value)
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func registerWaiter(id: UUID, value: T) async -> Bool {
        if emittedValues.contains(value) {
            return true
        }

        return await withCheckedContinuation { continuation in
            if emittedValues.contains(value) {
                continuation.resume(returning: true)
            } else {
                waiters.append(Waiter(id: id, value: value, continuation: continuation))
            }
        }
    }

    private func timeOutWaiter(id: UUID, value: T) -> Bool {
        if emittedValues.contains(value) {
            return true
        }

        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return emittedValues.contains(value)
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
        return false
    }
}
