import XCTest
@testable import MacParakeetCore

final class ANEInferenceGateTests: XCTestCase {

    /// Tracks how many closures are inside the gate simultaneously.
    private actor ConcurrencyTracker {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() {
            current += 1
            peak = max(peak, current)
        }
        func leave() {
            current -= 1
        }
    }

    /// A rendezvous that releases its parties only once `partyCount` of them are
    /// inside it at the same time. Lets the concurrency test prove overlap with no
    /// timing assumptions: if the gate (wrongly) serialized the callers the second
    /// never arrives, so the task group never completes and the test fails by
    /// timing out — deterministic, not flaky.
    private actor Rendezvous {
        private let partyCount: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var releasedPartyCount = 0

        init(partyCount: Int) {
            self.partyCount = partyCount
        }

        func arrive() async {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                guard waiting.count >= partyCount else { return }
                releasedPartyCount += waiting.count
                let parties = waiting
                waiting.removeAll()
                for party in parties { party.resume() }
            }
        }
    }

    /// On macOS 14 (`serializationRequired: true`) the gate must let at most one
    /// inference run at a time — the whole point of the SIGBUS fix.
    func testSerializesConcurrentAccessWhenRequired() async throws {
        let gate = ANEInferenceGate(serializationRequired: true)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await gate.withExclusiveAccess {
                        await tracker.enter()
                        // Hold briefly so any overlap would be observable.
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await tracker.leave()
                    }
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "Gate must allow at most one inference at a time when serialization is required")
    }

    /// On macOS 15+ (`serializationRequired: false`) the gate is a pass-through,
    /// so callers keep full concurrency. Both closures must be inside the gate at
    /// the same time to clear the rendezvous; if the gate serialized them the
    /// second would never arrive and the task group would hang to a test timeout —
    /// so this can't pass by accident, and it has no timing assumptions to flake.
    func testRunsConcurrentlyWhenSerializationNotRequired() async throws {
        let gate = ANEInferenceGate(serializationRequired: false)
        let rendezvous = Rendezvous(partyCount: 2)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await gate.withExclusiveAccess {
                        await rendezvous.arrive()
                    }
                }
            }
        }

        let released = await rendezvous.releasedPartyCount
        XCTAssertEqual(released, 2, "With serialization disabled both callers must enter the gate concurrently")
    }

    /// The body's value and errors propagate unchanged through the gate.
    func testPropagatesReturnValueAndErrors() async throws {
        let gate = ANEInferenceGate(serializationRequired: true)

        let value = try await gate.withExclusiveAccess { 42 }
        XCTAssertEqual(value, 42)

        struct Boom: Error {}
        do {
            _ = try await gate.withExclusiveAccess { throw Boom() }
            XCTFail("Expected the body's error to propagate")
        } catch is Boom {
            // Expected — and the permit was released, so the next call proceeds.
        }

        let after = try await gate.withExclusiveAccess { "ok" }
        XCTAssertEqual(after, "ok", "A thrown body must still release the gate")
    }
}
