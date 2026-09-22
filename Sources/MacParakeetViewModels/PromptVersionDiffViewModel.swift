import Foundation
import MacParakeetCore

/// Keeps expensive comparisons outside SwiftUI body evaluation and the main actor.
@MainActor @Observable
public final class PromptVersionDiffViewModel {
    public struct Selection: Hashable, Sendable {
        public let fromID: UUID
        public let toID: UUID

        public init(from: PromptVersion, to: PromptVersion) {
            fromID = from.id
            toID = to.id
        }
    }

    public private(set) var diff: PromptVersionDiff?
    public private(set) var selection: Selection?
    public private(set) var isLoading = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cache: [Selection: PromptVersionDiff] = [:]
    @ObservationIgnored private var cacheOrder: [Selection] = []
    @ObservationIgnored private let compute: @Sendable (PromptVersion, PromptVersion) async -> PromptVersionDiff

    public init(
        compute: @escaping @Sendable (PromptVersion, PromptVersion) async -> PromptVersionDiff = {
            PromptDiffService.diff(from: $0, to: $1)
        }
    ) {
        self.compute = compute
    }

    public func load(from: PromptVersion, to: PromptVersion) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let requestGeneration = generation
        let requestedSelection = Selection(from: from, to: to)
        selection = requestedSelection
        diff = cache[requestedSelection]
        if diff != nil {
            isLoading = false
            return
        }
        isLoading = true

        let compute = self.compute
        let worker = Task.detached(priority: .userInitiated) {
            await compute(from, to)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard generation == requestGeneration else { return }
        isLoading = false
        guard !Task.isCancelled else { return }

        // Versions are immutable; their ordered IDs identify a reusable result.
        // Bound retention because a prompt may contain an arbitrarily long history.
        cache[requestedSelection] = result
        cacheOrder.append(requestedSelection)
        if cacheOrder.count > 8 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        diff = result
    }
}
