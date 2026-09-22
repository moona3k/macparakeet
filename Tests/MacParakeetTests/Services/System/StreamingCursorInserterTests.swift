import XCTest
@testable import MacParakeetCore

private final class FakeStreamingPoster: StreamingCursorEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var posted: [String] = []
    var error: Error?
    var failAfterCount: Int?

    func typeUnicode(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failAfterCount, posted.count >= failAfterCount, let error {
            throw error
        }
        if failAfterCount == nil, let error {
            throw error
        }
        posted.append(text)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return posted
    }
}

private final class ImmediateStreamingClock: StreamingCursorClock, @unchecked Sendable {
    private(set) var sleeps: [Duration] = []

    func sleep(for duration: Duration) async throws {
        sleeps.append(duration)
        try Task.checkCancellation()
    }
}

private actor HoldUntilCancelledClock: StreamingCursorClock {
    private var sleepStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilSleepStarted() async {
        if sleepStarted { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func sleep(for duration: Duration) async throws {
        sleepStarted = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60))
    }
}

private final class InterruptOnSleepClock: StreamingCursorClock, @unchecked Sendable {
    private let interrupt: ManualInterrupt
    private var fired = false

    init(interrupt: ManualInterrupt) {
        self.interrupt = interrupt
    }

    func sleep(for duration: Duration) async throws {
        if !fired {
            fired = true
            interrupt.fire()
        }
        try Task.checkCancellation()
    }
}

private final class InterruptOnFirstPost: StreamingCursorEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let interrupt: ManualInterrupt
    private(set) var posted: [String] = []
    private var fired = false

    init(interrupt: ManualInterrupt) {
        self.interrupt = interrupt
    }

    func typeUnicode(_ text: String) throws {
        lock.lock()
        posted.append(text)
        let shouldFire = !fired
        fired = true
        lock.unlock()
        if shouldFire {
            interrupt.fire()
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return posted
    }
}

private final class ManualInterrupt: StreamingCursorInterruptListening, StreamingCursorInterruptToken,
    @unchecked Sendable
{
    private var handler: (@Sendable () -> Void)?

    func start(onInterrupt: @escaping @Sendable () -> Void) -> any StreamingCursorInterruptToken {
        handler = onInterrupt
        return self
    }

    func invalidate() {
        handler = nil
    }

    func fire() {
        handler?()
    }
}

final class StreamingCursorInserterTests: XCTestCase {
    func testPlaysBatchesInOrder() async throws {
        let poster = FakeStreamingPoster()
        let clock = ImmediateStreamingClock()
        let interrupts = ManualInterrupt()
        let inserter = StreamingCursorInserter(posting: poster, clock: clock, interrupts: interrupts)

        try await inserter.insert("Hello world!")

        XCTAssertEqual(poster.snapshot().joined(), "Hello world!")
        XCTAssertFalse(clock.sleeps.isEmpty)
    }

    func testInterruptFlushesRemainderAsBackToBackEvents() async throws {
        let poster = FakeStreamingPoster()
        let interrupts = ManualInterrupt()
        let clock = InterruptOnSleepClock(interrupt: interrupts)
        let inserter = StreamingCursorInserter(posting: poster, clock: clock, interrupts: interrupts)

        try await inserter.insert("Hello world!")

        XCTAssertEqual(poster.snapshot().joined(), "Hello world!")
        XCTAssertTrue(poster.snapshot().allSatisfy { $0.utf16.count <= StreamingCursorPolicy.maxUTF16PerEvent })
        XCTAssertGreaterThan(poster.snapshot().count, 1)
    }

    func testInterruptDuringFirstPostKeepsOriginalOrder() async throws {
        let interrupts = ManualInterrupt()
        let poster = InterruptOnFirstPost(interrupt: interrupts)
        let inserter = StreamingCursorInserter(
            posting: poster,
            clock: ImmediateStreamingClock(),
            interrupts: interrupts
        )

        try await inserter.insert("Hello world!")

        XCTAssertEqual(poster.snapshot().joined(), "Hello world!")
    }

    func testPartialFailureAfterCommitSurfacesPartialInsert() async {
        let poster = FakeStreamingPoster()
        poster.failAfterCount = 1
        poster.error = StreamingCursorError.eventCreationFailed
        let inserter = StreamingCursorInserter(
            posting: poster,
            clock: ImmediateStreamingClock(),
            interrupts: ManualInterrupt()
        )

        do {
            try await inserter.insert("Hello world!")
            XCTFail("expected partial insert")
        } catch let error as StreamingCursorError {
            XCTAssertEqual(error, .partialInsert)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(poster.snapshot().isEmpty)
        XCTAssertNotEqual(poster.snapshot().joined(), "Hello world!")
    }

    func testCancellationFlushesRemainderWithoutThrowing() async throws {
        let poster = FakeStreamingPoster()
        let clock = HoldUntilCancelledClock()
        let interrupts = ManualInterrupt()
        let inserter = StreamingCursorInserter(posting: poster, clock: clock, interrupts: interrupts)

        let task = Task {
            try await inserter.insert("Hello world!")
        }
        await clock.waitUntilSleepStarted()
        task.cancel()
        try await task.value
        XCTAssertEqual(poster.snapshot().joined(), "Hello world!")
    }

    func testEventFailureBeforeAnyCommitSurfacesUnavailable() async {
        let poster = FakeStreamingPoster()
        poster.error = StreamingCursorError.eventSourceUnavailable
        let inserter = StreamingCursorInserter(
            posting: poster,
            clock: ImmediateStreamingClock(),
            interrupts: ManualInterrupt()
        )

        do {
            try await inserter.insert("Hello world!")
            XCTFail("expected failure")
        } catch let error as StreamingCursorError {
            XCTAssertEqual(error, .eventSourceUnavailable)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(poster.snapshot().isEmpty)
    }
}
