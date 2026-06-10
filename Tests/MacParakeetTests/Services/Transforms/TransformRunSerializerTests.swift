import XCTest
@testable import MacParakeetCore

/// Regression tests for AUDIT-072: a re-triggered Transform must not start
/// its body (selection capture) until the previous run has fully wound
/// down, because `TransformExecutor` deliberately runs its replace phase to
/// completion after cancellation.
final class TransformRunSerializerTests: XCTestCase {
    /// MainActor-confined event log + gate shared between test and run bodies.
    @MainActor
    private final class RunLog {
        var entries: [String] = []
        var gateOpen = false
        func append(_ entry: String) { entries.append(entry) }
    }

    /// Deterministic wait: yield the main actor until `condition` holds.
    /// Bounded so a regression fails the test instead of hanging it.
    @MainActor
    private func yieldUntil(
        _ condition: () -> Bool,
        attempts: Int = 10_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @MainActor
    func testRunsBodyWhenIdle() async {
        let serializer = TransformRunSerializer()
        let log = RunLog()

        let task = serializer.replace { log.append("ran") }
        await task.value

        XCTAssertEqual(log.entries, ["ran"])
    }

    @MainActor
    func testReplaceCancelsCooperativeRunningBody() async {
        let serializer = TransformRunSerializer()
        let log = RunLog()

        let first = serializer.replace {
            log.append("first:start")
            while !Task.isCancelled { await Task.yield() }
            log.append("first:cancelled")
        }
        let started = await yieldUntil { log.entries.contains("first:start") }
        XCTAssertTrue(started, "first body never started")

        let second = serializer.replace { log.append("second:start") }
        await first.value
        await second.value

        XCTAssertEqual(log.entries, ["first:start", "first:cancelled", "second:start"])
    }

    /// The AUDIT-072 case: the first body simulates the executor's replace
    /// phase, which keeps running after cancellation. The second body must
    /// not start until the first has fully returned.
    @MainActor
    func testSecondBodyWaitsForCancellationResistantFirstBody() async {
        let serializer = TransformRunSerializer()
        let log = RunLog()

        let first = serializer.replace {
            log.append("first:start")
            // Ignore cancellation, like pasteAndRestore's post-gate phase.
            while !log.gateOpen { await Task.yield() }
            log.append("first:end")
        }
        let started = await yieldUntil { log.entries.contains("first:start") }
        XCTAssertTrue(started, "first body never started")

        let second = serializer.replace { log.append("second:start") }

        // Give an unserialized implementation ample opportunity to misbehave.
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(
            log.entries, ["first:start"],
            "second body must not start while the first run winds down"
        )

        log.gateOpen = true
        await first.value
        await second.value
        XCTAssertEqual(log.entries, ["first:start", "first:end", "second:start"])
    }

    /// A run superseded while still queued behind its predecessor never
    /// starts at all — only the latest trigger wins.
    @MainActor
    func testQueuedBodySupersededBeforeStartNeverRuns() async {
        let serializer = TransformRunSerializer()
        let log = RunLog()

        let first = serializer.replace {
            log.append("first:start")
            while !log.gateOpen { await Task.yield() }
            log.append("first:end")
        }
        let started = await yieldUntil { log.entries.contains("first:start") }
        XCTAssertTrue(started, "first body never started")

        let second = serializer.replace { log.append("second:start") }
        let third = serializer.replace { log.append("third:start") }

        log.gateOpen = true
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(
            log.entries, ["first:start", "first:end", "third:start"],
            "a queued run superseded before starting must never run"
        )
    }

    @MainActor
    func testCancelPreventsQueuedBodyFromRunning() async {
        let serializer = TransformRunSerializer()
        let log = RunLog()

        let first = serializer.replace {
            log.append("first:start")
            while !log.gateOpen { await Task.yield() }
            log.append("first:end")
        }
        let started = await yieldUntil { log.entries.contains("first:start") }
        XCTAssertTrue(started, "first body never started")

        let second = serializer.replace { log.append("second:start") }
        serializer.cancel()

        log.gateOpen = true
        await first.value
        await second.value

        XCTAssertFalse(
            log.entries.contains("second:start"),
            "a cancelled queued run must not start"
        )
    }
}
