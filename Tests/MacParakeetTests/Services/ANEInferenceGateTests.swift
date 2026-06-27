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
    /// so callers keep full concurrency and pay nothing.
    func testRunsConcurrentlyWhenSerializationNotRequired() async throws {
        let gate = ANEInferenceGate(serializationRequired: false)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try? await gate.withExclusiveAccess {
                        await tracker.enter()
                        // Wait (bounded) for at least one peer to enter too; a
                        // regression to serial behavior never reaches 2 and the
                        // bounded wait keeps the test from hanging.
                        for _ in 0..<200 where await tracker.current < 2 {
                            try? await Task.sleep(nanoseconds: 1_000_000)
                        }
                        await tracker.leave()
                    }
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertGreaterThanOrEqual(peak, 2, "With serialization disabled the gate must not serialize callers")
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
