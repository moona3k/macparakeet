import Foundation

/// Batches streamed text deltas so the UI publishes at most once per
/// `interval` instead of once per token (#1132). The first delta publishes
/// immediately. Callers must `flush()` when the stream ends so no text is
/// dropped.
struct StreamingTextCoalescer {
    let interval: Duration
    private var pending = ""
    private var lastPublished: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    /// Buffers `delta` and returns the text to publish now, if the interval
    /// has elapsed since the last publication.
    mutating func append(_ delta: String, at now: ContinuousClock.Instant) -> String? {
        pending += delta
        if let lastPublished, now - lastPublished < interval {
            return nil
        }
        lastPublished = now
        return takePending()
    }

    /// Returns any buffered text that has not been published yet.
    mutating func flush() -> String? {
        takePending()
    }

    private mutating func takePending() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending = "" }
        return pending
    }
}
