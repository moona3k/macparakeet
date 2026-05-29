import Foundation

/// MacParakeet-owned abstraction over meeting live-preview chunking, so product
/// code (`CaptureOrchestrator`) depends on one shape regardless of whether the
/// underlying strategy is fixed 5s windows or VAD speech boundaries.
///
/// `addSamples` returns an array because a boundary-driven chunker can emit
/// zero, one, or several chunks for a single ingest; the fixed adapter simply
/// returns at most one.
protocol MeetingLiveAudioChunking: Sendable {
    func addSamples(_ samples: [Float]) async -> [AudioChunker.AudioChunk]
    func flush() async -> AudioChunker.AudioChunk?
    func reset() async
}

/// Thin adapter that preserves the current fixed 5s / 1s-overlap behavior by
/// delegating to `AudioChunker`. This is the fallback path and the default
/// production behavior; it stays byte-identical to `AudioChunker`.
actor FixedMeetingLiveAudioChunker: MeetingLiveAudioChunking {
    private let chunker = AudioChunker()

    init() {}

    func addSamples(_ samples: [Float]) async -> [AudioChunker.AudioChunk] {
        if let chunk = await chunker.addSamples(samples) {
            return [chunk]
        }
        return []
    }

    func flush() async -> AudioChunker.AudioChunk? {
        await chunker.flush()
    }

    func reset() async {
        await chunker.reset()
    }
}
