import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class PromptVersionDiffViewModelTests: XCTestCase {
    func testComputesOffMainThreadAndReusesImmutableVersionPair() async {
        let calls = DiffCallCounter()
        let viewModel = PromptVersionDiffViewModel { from, to in
            XCTAssertFalse(Thread.isMainThread)
            await calls.increment()
            return PromptDiffService.diff(from: from, to: to)
        }
        let from = version("Original")
        let to = version("Updated")

        await viewModel.load(from: from, to: to)
        let first = viewModel.diff
        await viewModel.load(from: to, to: from)
        await viewModel.load(from: from, to: to)

        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(viewModel.diff, first)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testOlderCompletionCannotReplaceNewSelection() async {
        let started = expectation(description: "First comparison started")
        let gate = DiffGate()
        let from = version("Original")
        let firstTo = version("First")
        let secondTo = version("Second")
        let viewModel = PromptVersionDiffViewModel { from, to in
            if to.id == firstTo.id {
                await gate.wait(started: started)
            }
            return PromptDiffService.diff(from: from, to: to)
        }
        let first = Task { await viewModel.load(from: from, to: firstTo) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertNil(viewModel.diff)

        await viewModel.load(from: from, to: secondTo)
        let expected = PromptDiffService.diff(from: from, to: secondTo)
        XCTAssertEqual(viewModel.diff, expected)
        await gate.release()
        await first.value

        XCTAssertEqual(viewModel.diff, expected)
        XCTAssertEqual(viewModel.selection, .init(from: from, to: secondTo))
        XCTAssertFalse(viewModel.isLoading)
    }

    func testCancellationReachesWorkerAndDoesNotPublishOrCacheResult() async {
        let started = expectation(description: "Comparison started")
        let gate = DiffGate()
        let calls = DiffCallCounter()
        let viewModel = PromptVersionDiffViewModel { from, to in
            await calls.increment()
            if await calls.count == 1 {
                await gate.wait(started: started)
                XCTAssertTrue(Task.isCancelled)
            }
            return PromptDiffService.diff(from: from, to: to)
        }
        let from = version("Original")
        let to = version("Updated")
        let loading = Task { await viewModel.load(from: from, to: to) }
        await fulfillment(of: [started], timeout: 2)
        loading.cancel()
        await gate.release()
        await loading.value
        XCTAssertNil(viewModel.diff)
        XCTAssertFalse(viewModel.isLoading)

        await viewModel.load(from: from, to: to)
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertNotNil(viewModel.diff)
    }

    private func version(_ content: String) -> PromptVersion {
        PromptVersion(promptId: UUID(), versionNumber: 1, content: content)
    }
}

private actor DiffCallCounter {
    private(set) var count = 0

    func increment() { count += 1 }
}

private actor DiffGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
