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

    func testLoadCachedIsInertAfterCancel() {
        let viewModel = DiscoverViewModel()
        viewModel.configure(service: StubDiscoverService(feed: oneItemFeed()))
        viewModel.cancelDiscover()

        // `cancelDiscover` drops the service, so both entry points must be
        // no-ops until `configure(service:)` runs again on re-enable. No task
        // is even created, which makes this exact: there is nothing to wait
        // for, rather than something that has "probably finished by now".
        viewModel.loadCached()
        viewModel.refreshInBackground()

        XCTAssertNil(viewModel.loadTask)
        XCTAssertNil(viewModel.refreshTask)
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
        XCTAssertNotNil(secondRefresh)
        await secondGate.entered()

        // The stale refresh 1 now completes with nil — and must not clear the
        // replacement's `refreshTask` reference on its way out.
        await firstGate.open()
        await firstRefresh?.value
        XCTAssertNotNil(
            viewModel.refreshTask,
            "A stale refresh must not strand its replacement"
        )

        // User disables again. This must still cancel refresh 2.
        viewModel.cancelDiscover()

        // Refresh 2 completes with a feed, after the opt-out.
        await secondGate.open()
        await secondRefresh?.value

        XCTAssertNil(viewModel.feed, "No feed may be published after Discover is disabled")
        XCTAssertTrue(viewModel.allItems.isEmpty)
    }

    func testCancelDiscoverIsSafeBeforeConfigure() {
        let viewModel = DiscoverViewModel()
        viewModel.cancelDiscover()
        XCTAssertNil(viewModel.feed)
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
}
