import Foundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    private struct StubDiscoverService: DiscoverServiceProtocol {
        let feed: DiscoverFeed

        func loadContent() async -> DiscoverFeed { feed }
        func fetchFresh() async -> DiscoverFeed? { feed }
    }

    private var emptyFeed: DiscoverFeed {
        DiscoverFeed(version: 1, items: [], featuredIndex: 0)
    }

    /// A feed with a real item, so assertions about cleared items and the
    /// sidebar card verify actual clearing instead of being vacuously true
    /// against an already-empty feed.
    private func oneItemFeed(version: Int = 1) -> DiscoverFeed {
        DiscoverFeed(
            version: version,
            items: [
                DiscoverItem(
                    id: "test-item-\(version)",
                    type: .tip,
                    title: "Test title",
                    body: "Test body",
                    icon: "sparkles"
                ),
            ],
            featuredIndex: 0
        )
    }

    func testCancelDiscoverClearsLoadedFeed() async {
        let viewModel = DiscoverViewModel()
        viewModel.configure(service: StubDiscoverService(feed: oneItemFeed()))
        viewModel.loadCached()

        // Await the load task itself rather than sleeping for a fixed
        // interval, so this cannot flake on a slow or loaded CI host.
        await viewModel.loadTask?.value
        XCTAssertNotNil(viewModel.feed)
        XCTAssertFalse(viewModel.allItems.isEmpty)
        XCTAssertNotNil(viewModel.sidebarItem)

        viewModel.cancelDiscover()
        XCTAssertNil(viewModel.feed)
        XCTAssertTrue(viewModel.allItems.isEmpty)
        XCTAssertNil(viewModel.sidebarItem)
    }

    private actor CountingDiscoverService: DiscoverServiceProtocol {
        private(set) var loadCount = 0
        private(set) var fetchCount = 0

        func loadContent() async -> DiscoverFeed {
            loadCount += 1
            return DiscoverFeed(version: 1, items: [])
        }

        func fetchFresh() async -> DiscoverFeed? {
            fetchCount += 1
            return DiscoverFeed(version: 1, items: [])
        }
    }

    func testCancellationStopsQueuedAndNewServiceWork() async {
        let service = CountingDiscoverService()
        let viewModel = DiscoverViewModel()
        viewModel.configure(service: service)
        viewModel.loadCached()
        viewModel.refreshInBackground()
        let queuedLoad = viewModel.loadTask
        let queuedRefresh = viewModel.refreshTask

        // Disable before either scheduled task gets an actor turn.
        viewModel.cancelDiscover()
        viewModel.loadCached()
        viewModel.refreshInBackground()
        let disabledLoad = viewModel.loadTask
        let disabledRefresh = viewModel.refreshTask

        await queuedLoad?.value
        await queuedRefresh?.value
        await disabledLoad?.value
        await disabledRefresh?.value
        let loadCount = await service.loadCount
        let fetchCount = await service.fetchCount
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertNil(viewModel.feed)
    }

    /// Two-phase synchronization point for holding `fetchFresh()` suspended.
    ///
    /// The service calls `wait()`, which records entry and suspends until
    /// `open()`. The test awaits `entered()` to know the refresh is inside
    /// `fetchFresh()`, and awaits the refresh task's `value` after `open()`
    /// to know it has fully completed — no step depends on wall-clock timing.
    private actor Gate {
        private var isOpen = false
        private var hasEntered = false
        private var openContinuation: CheckedContinuation<Void, Never>?
        private var entryContinuation: CheckedContinuation<Void, Never>?

        func wait() async {
            hasEntered = true
            entryContinuation?.resume()
            entryContinuation = nil
            if isOpen { return }
            await withCheckedContinuation { openContinuation = $0 }
        }

        /// Suspends until the service has entered `wait()`.
        func entered() async {
            if hasEntered { return }
            await withCheckedContinuation { entryContinuation = $0 }
        }

        func open() {
            isOpen = true
            openContinuation?.resume()
            openContinuation = nil
        }
    }

    /// First `fetchFresh()` waits on `firstGate` and returns nil; the second
    /// waits on `secondGate` and returns a feed. An actor so the call counter
    /// is race-free without any locking.
    private actor TwoPhaseDiscoverService: DiscoverServiceProtocol {
        let cached: DiscoverFeed
        let firstGate: Gate
        let secondGate: Gate
        let replacementFeed: DiscoverFeed
        private var calls = 0
        private(set) var replacementWasCancelled = false

        init(
            cached: DiscoverFeed,
            firstGate: Gate,
            secondGate: Gate,
            replacementFeed: DiscoverFeed
        ) {
            self.cached = cached
            self.firstGate = firstGate
            self.secondGate = secondGate
            self.replacementFeed = replacementFeed
        }

        func loadContent() async -> DiscoverFeed { cached }

        func fetchFresh() async -> DiscoverFeed? {
            calls += 1
            let call = calls

            if call == 1 {
                await firstGate.wait()
                return nil
            }
            await secondGate.wait()
            replacementWasCancelled = Task.isCancelled
            return replacementFeed
        }
    }

    /// Regression: a stale refresh returning nil used to fall through to
    /// `refreshTask = nil`, clearing the reference to a *replacement* refresh
    /// started after a disable/re-enable. A later disable then could not cancel
    /// the replacement, which went on to publish a feed after the user opted out.
    func testStaleRefreshCannotStrandAReplacementRefreshTask() async {
        let firstGate = Gate()
        let secondGate = Gate()
        let service = TwoPhaseDiscoverService(
            cached: emptyFeed,
            firstGate: firstGate,
            secondGate: secondGate,
            // A non-empty feed, so the final "nothing was published" checks
            // would fail loudly if the stale refresh did publish it.
            replacementFeed: oneItemFeed(version: 2)
        )

        let viewModel = DiscoverViewModel()
        viewModel.configure(service: service)

        // Refresh 1 starts and is definitely suspended inside fetchFresh().
        viewModel.refreshInBackground()
        let firstRefresh = viewModel.refreshTask
        await firstGate.entered()

        // User disables, then re-enables before refresh 1 returns.
        viewModel.cancelDiscover()
        viewModel.configure(service: service)
        viewModel.refreshInBackground()
        let secondRefresh = viewModel.refreshTask
        await secondGate.entered()

        // The stale refresh 1 now completes with nil — and must not clear the
        // replacement's `refreshTask` reference on its way out.
        await firstGate.open()
        await firstRefresh?.value

        // User disables again. This must still cancel refresh 2.
        viewModel.cancelDiscover()

        // Refresh 2 completes with a feed, after the opt-out.
        await secondGate.open()
        await secondRefresh?.value
        let replacementWasCancelled = await service.replacementWasCancelled
        XCTAssertTrue(replacementWasCancelled, "Disabling must cancel the replacement request, not just hide its result")

        XCTAssertNil(viewModel.feed, "No feed may be published after Discover is disabled")
        XCTAssertTrue(viewModel.allItems.isEmpty)
    }


    /// Service whose `loadContent()` suspends on a gate while `fetchFresh()`
    /// returns immediately, so a test can force the cache read to lose the
    /// race against the background refresh.
    private actor SlowCacheDiscoverService: DiscoverServiceProtocol {
        let cached: DiscoverFeed
        let fresh: DiscoverFeed
        let cacheGate: Gate

        init(cached: DiscoverFeed, fresh: DiscoverFeed, cacheGate: Gate) {
            self.cached = cached
            self.fresh = fresh
            self.cacheGate = cacheGate
        }

        func loadContent() async -> DiscoverFeed {
            await cacheGate.wait()
            return cached
        }

        func fetchFresh() async -> DiscoverFeed? { fresh }
    }

    /// Regression: `loadCached()` used to publish unconditionally, so a slow
    /// cache read finishing after the background refresh replaced the fresh
    /// feed with stale cached content until a later relaunch or refresh.
    func testSlowCacheLoadDoesNotReplaceFreshFeed() async {
        let cacheGate = Gate()
        let cachedFeed = oneItemFeed(version: 1)
        let freshFeed = oneItemFeed(version: 2)
        let service = SlowCacheDiscoverService(
            cached: cachedFeed,
            fresh: freshFeed,
            cacheGate: cacheGate
        )

        let viewModel = DiscoverViewModel()
        viewModel.configure(service: service)
        defer { viewModel.cancelDiscover() }

        // The cache read suspends on the gate; the refresh completes first
        // and publishes the fresh feed.
        viewModel.loadCached()
        await cacheGate.entered()
        viewModel.refreshInBackground()
        await viewModel.refreshTask?.value
        XCTAssertEqual(viewModel.feed, freshFeed)

        // The stale cache read now completes. It must not overwrite the
        // fresher content.
        await cacheGate.open()
        await viewModel.loadTask?.value
        XCTAssertEqual(viewModel.feed, freshFeed, "A late cache load must not replace a fresh feed")
    }

    func testLateCacheCannotPublishAfterDisableAndReenable() async {
        let cacheGate = Gate()
        let oldFeed = oneItemFeed(version: 1)
        let newFeed = oneItemFeed(version: 2)
        let viewModel = DiscoverViewModel()
        defer { viewModel.cancelDiscover() }
        viewModel.configure(service: SlowCacheDiscoverService(
            cached: oldFeed,
            fresh: oldFeed,
            cacheGate: cacheGate
        ))
        viewModel.loadCached()
        let oldLoad = viewModel.loadTask
        await cacheGate.entered()

        viewModel.cancelDiscover()
        viewModel.configure(service: StubDiscoverService(feed: newFeed))
        await cacheGate.open()
        await oldLoad?.value
        XCTAssertNil(viewModel.feed, "Re-enabling must not revive a cancelled cache load")

        viewModel.loadCached()
        await viewModel.loadTask?.value
        XCTAssertEqual(viewModel.feed, newFeed)
    }
}
