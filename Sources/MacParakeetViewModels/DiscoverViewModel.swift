import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class DiscoverViewModel {
    public var feed: DiscoverFeed?

    public var sidebarItem: DiscoverItem? {
        guard let items = feed?.items, !items.isEmpty else { return nil }
        return items[sidebarIndex % items.count]
    }

    public var featuredItem: DiscoverItem? {
        feed?.featuredItem
    }

    private var sidebarIndex: Int = Int.random(in: 0..<100)
    private var rotationTask: Task<Void, Never>?

    public var allItems: [DiscoverItem] {
        feed?.items ?? []
    }

    private var service: (any DiscoverServiceProtocol)?
    /// `loadTask` and `refreshTask` are `private(set)` rather than `private`
    /// so tests can await an in-flight task's completion deterministically
    /// instead of sleeping for a guessed interval.
    private(set) var loadTask: Task<Void, Never>?
    private(set) var refreshTask: Task<Void, Never>?
    /// Bumped whenever a refresh starts or Discover is cancelled. A completing
    /// refresh only touches `feed` or `refreshTask` while it still owns the
    /// current generation, so a stale task cannot clear a replacement task's
    /// reference or publish a feed after the user has opted out.
    private var refreshGeneration = 0

    public init() {}

    public func configure(service: any DiscoverServiceProtocol) {
        self.service = service
    }

    public func loadCached() {
        guard let service else { return }
        loadTask?.cancel()
        loadTask = Task {
            guard !Task.isCancelled else { return }
            let result = await service.loadContent()
            guard !Task.isCancelled else { return }
            // A background refresh started alongside this load may already
            // have published fresher content; cached content only fills an
            // empty surface and never replaces a fresh feed.
            if feed == nil {
                feed = result
            }
            loadTask = nil
            startRotation()
        }
    }

    private func startRotation() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                sidebarIndex += 1
            }
        }
    }

    /// Cancel any in-flight Discover work and drop the loaded feed.
    ///
    /// Called when the user turns Discover off. Without this, a cache load,
    /// background refresh, or the 30-second rotation task started while
    /// Discover was visible would keep running behind a hidden surface.
    /// Clearing `service` also makes `loadCached()` and `refreshInBackground()`
    /// no-ops until `configure(service:)` runs again on re-enable.
    public func cancelDiscover() {
        refreshGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        rotationTask?.cancel()
        rotationTask = nil
        feed = nil
        service = nil
    }

    public func refreshInBackground() {
        guard let service else { return }
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask = Task { [generation] in
            guard !Task.isCancelled else { return }
            let freshFeed = await service.fetchFresh()
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            if let freshFeed {
                feed = freshFeed
            }
            refreshTask = nil
        }
    }
}
