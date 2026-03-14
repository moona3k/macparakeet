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
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init() {}

    public func configure(service: any DiscoverServiceProtocol) {
        self.service = service
    }

    public func loadCached() {
        guard let service else { return }
        loadTask?.cancel()
        loadTask = Task {
            let result = await service.loadContent()
            guard !Task.isCancelled else { return }
            feed = result
            loadTask = nil
            startRotation()
        }
    }

    private func startRotation() {
        rotationTask?.cancel()
        rotationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                sidebarIndex += 1
            }
        }
    }

    public func refreshInBackground() {
        guard let service else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            if let freshFeed = await service.fetchFresh() {
                guard !Task.isCancelled else { return }
                feed = freshFeed
            }
            refreshTask = nil
        }
    }
}
