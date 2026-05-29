import Foundation

/// Diagnostics for a single live-chunking source (microphone or system).
///
/// Private observability only — never surfaced as user-facing text. Lets the
/// app answer "did this session use VAD or fixed fallback, and why" without
/// logging transcript content or audio. See
/// `plans/active/2026-05-meeting-vad-guided-live-chunking.md` §5.
struct MeetingLiveChunkingDiagnostics: Sendable, Equatable {
    enum Mode: String, Sendable {
        case fixed
        case vad
    }

    var mode: Mode
    /// `true` once a VAD-mode chunker has degraded to fixed-window emits after
    /// repeated streaming errors.
    var fellBackToFixed: Bool = false
    var chunksEmitted: Int = 0
    var speechStartEvents: Int = 0
    var speechEndEvents: Int = 0
    /// Max-duration force emits (no speech-end arrived before the cap).
    var forceEmits: Int = 0
    /// Windows of detected silence discarded without emitting a chunk.
    var droppedSilenceWindows: Int = 0
    var vadErrors: Int = 0
    /// Most recent VAD speech probability, for tuning visibility only.
    var recentProbability: Float = 0

    init(mode: Mode) {
        self.mode = mode
    }
}

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
    var diagnostics: MeetingLiveChunkingDiagnostics { get async }
}

/// Thin adapter that preserves the current fixed 5s / 1s-overlap behavior by
/// delegating to `AudioChunker`. This is the fallback path and the default
/// production behavior; it must stay byte-identical to `AudioChunker`.
actor FixedMeetingLiveAudioChunker: MeetingLiveAudioChunking {
    private let chunker = AudioChunker()
    private var diag = MeetingLiveChunkingDiagnostics(mode: .fixed)

    init() {}

    func addSamples(_ samples: [Float]) async -> [AudioChunker.AudioChunk] {
        guard let chunk = await chunker.addSamples(samples) else { return [] }
        diag.chunksEmitted += 1
        return [chunk]
    }

    func flush() async -> AudioChunker.AudioChunk? {
        guard let chunk = await chunker.flush() else { return nil }
        diag.chunksEmitted += 1
        return chunk
    }

    func reset() async {
        await chunker.reset()
        diag = MeetingLiveChunkingDiagnostics(mode: .fixed)
    }

    var diagnostics: MeetingLiveChunkingDiagnostics { diag }
}
