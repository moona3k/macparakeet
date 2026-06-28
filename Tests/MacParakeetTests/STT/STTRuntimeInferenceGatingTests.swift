import XCTest
@testable import MacParakeetCore

/// Pins the macOS-14 SIGBUS invariant at the `STTRuntime` boundary: work run
/// through the runtime's injected ``ANEInferenceGate`` serializes.
///
/// `ANEInferenceGateTests` proves the gate primitive serializes; this proves the
/// runtime's injected gate is wired and serializing. The real `transcribe(job:)`
/// paths can't run in CI (CoreML/Parakeet models are unavailable) and inline the
/// gate inside actor-isolated closures that can't be reached from a test, so the
/// test exercises the same injected gate through the `runUnderInferenceGate`
/// seam. Production correctness — that every `manager.transcribe(...)` site wraps
/// `inferenceGate.withExclusiveAccess` — is enforced by review + the STT README,
/// not this test.
final class STTRuntimeInferenceGatingTests: XCTestCase {

    /// Tracks how many closures are inside the gate simultaneously.
    private actor ConcurrencyTracker {
        private(set) var peak = 0
        private var current = 0
        func enter() {
            current += 1
            peak = max(peak, current)
        }
        func leave() {
            current -= 1
        }
    }

    /// Releases its parties only once `partyCount` of them are inside at the same
    /// time, so the concurrency test proves overlap with no timing assumptions:
    /// if the runtime (wrongly) serialized the callers the second never arrives,
    /// the task group never completes, and the test fails by timing out.
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

    /// On macOS 14 (`serializationRequired: true`) concurrent work driven through
    /// the runtime's injected gate must never overlap — the whole point of the
    /// gate that the dictation pad path originally bypassed.
    ///
    /// Unlike the pass-through test below — which deadlocks the group if the gate
    /// wrongly serializes, so a false pass is impossible — this direction is
    /// probabilistic: a broken (non-serializing) gate would almost certainly let
    /// some of the 8 held tasks overlap (`peak > 1`), but a scheduler that happened
    /// to run them sequentially could in principle still yield `peak == 1`. The
    /// 2 ms hold across 8 tasks makes that astronomically unlikely; this mirrors
    /// `ANEInferenceGateTests.testSerializesConcurrentAccessWhenRequired`.
    func testRuntimeSerializesParakeetInferenceWhenRequired() async throws {
        let runtime = STTRuntime(inferenceGate: ANEInferenceGate(serializationRequired: true))
        let tracker = ConcurrencyTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await runtime.runUnderInferenceGate {
                        await tracker.enter()
                        do {
                            // Hold briefly so any overlap would be observable.
                            try await Task.sleep(nanoseconds: 2_000_000)
                            await tracker.leave()
                        } catch {
                            await tracker.leave()
                            throw error
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "STTRuntime must serialize Parakeet inference through the gate when serialization is required")
    }

    /// On macOS 15+ (`serializationRequired: false`) the gate is a pass-through,
    /// so the runtime keeps full lane concurrency and pays nothing. Both closures
    /// must be inside the gate at once to clear the rendezvous; if the runtime
    /// serialized them the second would never arrive and the group would hang to
    /// a test timeout — so this can't pass by accident and has no timing flake.
    func testRuntimeRunsConcurrentlyWhenSerializationNotRequired() async throws {
        let runtime = STTRuntime(inferenceGate: ANEInferenceGate(serializationRequired: false))
        let rendezvous = Rendezvous(partyCount: 2)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await runtime.runUnderInferenceGate {
                        await rendezvous.arrive()
                    }
                }
            }
            try await group.waitForAll()
        }

        let released = await rendezvous.releasedPartyCount
        XCTAssertEqual(released, 2, "With serialization disabled both inferences must enter the gate concurrently")
    }
}
