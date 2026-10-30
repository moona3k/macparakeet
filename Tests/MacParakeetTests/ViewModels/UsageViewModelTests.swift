import XCTest

@testable import MacParakeetCore
@testable import MacParakeetViewModels

private enum UsageReadFailure: Error { case unavailable }

private final class UsageReadStub: UsageEventRepositoryProtocol {
    let read: @Sendable (Date?) throws -> [UsageSummaryRow]
    let speech: @Sendable () throws -> [SpeechEngineUsageRow]
    let clear: @Sendable () throws -> Void

    init(
        read: @escaping @Sendable (Date?) throws -> [UsageSummaryRow],
        speech: @escaping @Sendable () throws -> [SpeechEngineUsageRow] = { [] },
        clear: @escaping @Sendable () throws -> Void = {}
    ) {
        self.read = read
        self.speech = speech
        self.clear = clear
    }

    func save(_ event: UsageEvent) throws {}
    func summary(since: Date?) throws -> [UsageSummaryRow] { try read(since) }
    func speechEngineUsage(since: Date?) throws -> [SpeechEngineUsageRow] { try speech() }
    func deleteAll() throws { try clear() }
}

@MainActor
final class UsageViewModelTests: XCTestCase {
    private func row(_ model: String) -> UsageSummaryRow {
        UsageSummaryRow(
            kind: .llm, provider: "custom", model: model, isLocal: false, requests: 1,
            promptTokens: 10, completionTokens: 5, tokensEstimated: false, audioMs: 0)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for usage state"); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testSlowOldPeriodCannotOverwriteNewerResultsOrErrorState() async {
        for oldFails in [false, true] {
            let oldStarted = expectation(description: "Old aggregation started")
            let releaseOld = DispatchSemaphore(value: 0)
            let now = Date(timeIntervalSince1970: 1_000_000)
            let oldSince = now.addingTimeInterval(-30 * 86_400)
            let oldRow = row("old")
            let newRow = row("new")
            let reader = UsageReadStub { since in
                XCTAssertFalse(Thread.isMainThread, "SQL aggregation must leave the UI thread")
                if since == oldSince {
                    oldStarted.fulfill()
                    XCTAssertEqual(releaseOld.wait(timeout: .now() + 5), .success)
                    if oldFails { throw UsageReadFailure.unavailable }
                    return [oldRow]
                }
                return [newRow]
            }
            let viewModel = UsageViewModel(readerProvider: { reader }, now: { now })
            let first = Task { await viewModel.reload() }
            await fulfillment(of: [oldStarted], timeout: 3)
            XCTAssertTrue(viewModel.isLoading)
            viewModel.period = .week
            await waitUntil { viewModel.aiRows == [newRow] && !viewModel.isLoading }
            releaseOld.signal()
            await first.value
            XCTAssertEqual(viewModel.aiRows, [newRow])
            XCTAssertNil(viewModel.loadError)
        }
    }

    func testAggregationPublishesOnlyAfterBothReadsSucceed() async {
        let result = row("partial")
        let reader = UsageReadStub(
            read: { _ in [result] },
            speech: {
                XCTAssertFalse(Thread.isMainThread)
                throw UsageReadFailure.unavailable
            })
        let viewModel = UsageViewModel(readerProvider: { reader })
        await viewModel.reload()
        XCTAssertTrue(viewModel.isEmpty, "A failed second read must not publish a partial snapshot")
        XCTAssertEqual(viewModel.loadError, "Could not load usage.")
        XCTAssertFalse(viewModel.isLoading)
    }

    func testCancelledReloadDoesNotPublishItsLateResult() async {
        let started = expectation(description: "Aggregation pending")
        let release = DispatchSemaphore(value: 0)
        let result = row("cancelled")
        let reader = UsageReadStub { _ in
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return [result]
        }
        let viewModel = UsageViewModel(readerProvider: { reader })
        let task = Task { await viewModel.reload() }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        release.signal()
        await task.value
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.loadError)
    }

    func testClearFailureRemainsVisibleAndKeepsCurrentSnapshot() async {
        let result = row("retained")
        let reader = UsageReadStub(
            read: { _ in [result] },
            clear: {
                XCTAssertFalse(Thread.isMainThread)
                throw UsageReadFailure.unavailable
            })
        let viewModel = UsageViewModel(readerProvider: { reader })
        await viewModel.reload()
        await viewModel.clearHistory()
        XCTAssertEqual(viewModel.aiRows, [result])
        XCTAssertEqual(viewModel.loadError, "Could not clear usage.")
        XCTAssertFalse(viewModel.isLoading)
    }

    func testPriceInputRequiresAnExplicitFiniteNonnegativeDecimal() {
        for invalid in ["", " ", ".", "1.", "0,", "-1", "NaN", "inf", "1e309", "1.2.3", "one", "1,000.5"] {
            XCTAssertNil(UsageViewModel.parsePrice(invalid), invalid)
        }
        XCTAssertEqual(UsageViewModel.parsePrice("0"), 0)
        XCTAssertEqual(UsageViewModel.parsePrice(" 0,15 "), 0.15)
        XCTAssertEqual(UsageViewModel.parsePrice(".25"), 0.25)
        XCTAssertEqual(UsageViewModel.parsePrice("2.50"), 2.5)
        XCTAssertEqual(UsageViewModel.formatCost(.infinity), "—")
        XCTAssertEqual(UsageViewModel.formatCost(.nan), "—")
    }

    func testEditorFormattingRoundTripsTinyAndLargeFinitePrices() {
        for value in [
            0, 0.000001, 0.000000000123, 2.5, 1e20, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude,
        ] {
            let text = UsageViewModel.priceEditorText(value)
            XCTAssertFalse(text.contains("e"), text)
            XCTAssertEqual(UsageViewModel.parsePrice(text), value, text)
        }
        XCTAssertEqual(UsageViewModel.priceEditorText(0.000001), "0.000001")
        XCTAssertEqual(UsageViewModel.priceEditorText(1e20), "100000000000000000000")
    }
}
