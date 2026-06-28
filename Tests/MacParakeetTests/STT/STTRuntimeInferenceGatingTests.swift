import XCTest
@testable import MacParakeetCore

/// Pins the macOS-14 SIGBUS invariant at the `STTRuntime` boundary: every
/// Parakeet TDT inference funnels through ``STTRuntime/gatedParakeetTranscribe``
/// and therefore through the injected ``ANEInferenceGate``.
///
/// `ANEInferenceGateTests` proves the gate primitive serializes; this proves the
/// runtime actually routes through it. The real `transcribe(job:)` paths can't
/// run in CI (CoreML/Parakeet models are unavailable), so the gate is injected
/// with `serializationRequired: true` and exercised through the same chokepoint
/// the production call sites use — which is why a future call site that bypasses
/// `gatedParakeetTranscribe` would not be covered, and must not be added.
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

    /// On macOS 14 (`serializationRequired: true`) concurrent Parakeet inference
    /// driven through the runtime's chokepoint must never overlap — the whole
    /// point of the gate. A regression that bypasses `gatedParakeetTranscribe`
    /// (as the dictation pad path originally did) reopens the concurrent
    /// Neural Engine SIGBUS.
    func testRuntimeSerializesParakeetInferenceWhenRequired() async {
        let runtime = STTRuntime(inferenceGate: ANEInferenceGate(serializationRequired: true))
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await runtime.gatedParakeetTranscribe {
                        await tracker.enter()
                        // Hold briefly so any overlap would be observable.
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await tracker.leave()
                    }
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "STTRuntime must serialize Parakeet inference through the gate when serialization is required")
    }

    /// On macOS 15+ (`serializationRequired: false`) the gate is a pass-through,
    /// so the runtime keeps full lane concurrency and pays nothing. Both closures
    /// must be inside the gate at once to clear the rendezvous; if the runtime
    /// serialized them the second would never arrive and the group would hang to
    /// a test timeout — so this can't pass by accident and has no timing flake.
    func testRuntimeRunsConcurrentlyWhenSerializationNotRequired() async {
        let runtime = STTRuntime(inferenceGate: ANEInferenceGate(serializationRequired: false))
        let rendezvous = Rendezvous(partyCount: 2)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await runtime.gatedParakeetTranscribe {
                        await rendezvous.arrive()
                    }
                }
            }
        }

        let released = await rendezvous.releasedPartyCount
        XCTAssertEqual(released, 2, "With serialization disabled both inferences must enter the gate concurrently")
    }
}
