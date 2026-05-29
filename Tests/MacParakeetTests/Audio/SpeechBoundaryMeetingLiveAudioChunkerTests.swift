import XCTest
@testable import MacParakeetCore

/// Deterministic state-machine coverage for the VAD speech-boundary chunker,
/// driven by a scripted fake VAD so no FluidAudio models are loaded.
final class SpeechBoundaryMeetingLiveAudioChunkerTests: XCTestCase {
    private let window = 4_096
    private let minChunkSamples = 32_000   // 2.0s
    private let maxChunkSamples = 160_000  // 10.0s
    private let flushMinSamples = 8_000    // 0.5s

    // MARK: - speech-end emits

    func testSpeechEndAfterMinimumEmitsOneContiguousChunk() async {
        // speechStart at the first window, speechEnd at the 10th (40 960 samples).
        let vad = FakeMeetingVAD(events: [
            1: .speechStart,
            10: .speechEnd(sampleIndex: 40_960),
        ])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        let chunks = await feed(chunker, windows: 10)

        XCTAssertEqual(chunks.count, 1)
        let chunk = chunks[0]
        XCTAssertEqual(chunk.samples.count, 40_960)
        XCTAssertEqual(chunk.startMs, 0)
        XCTAssertEqual(chunk.endMs, 2_560)
    }

    func testSubMinimumSpeechEndIsNotEmittedButExtendedByNextEnd() async {
        // First speech-end lands at 16 000 samples (1.0s < 2.0s min) and must be
        // skipped; the next end at 40 960 emits a single chunk covering both.
        let vad = FakeMeetingVAD(events: [
            1: .speechStart,
            4: .speechEnd(sampleIndex: 16_000),
            10: .speechEnd(sampleIndex: 40_960),
        ])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        let chunks = await feed(chunker, windows: 10)

        XCTAssertEqual(chunks.count, 1, "sub-minimum end must not emit on its own")
        XCTAssertEqual(chunks[0].samples.count, 40_960)
        XCTAssertEqual(chunks[0].startMs, 0)
    }

    func testConsecutiveSpeechEndsAreContiguous() async {
        // Two valid speech segments: ends at 40 960 and 81 920.
        let vad = FakeMeetingVAD(events: [
            1: .speechStart,
            10: .speechEnd(sampleIndex: 40_960),
            11: .speechStart,
            20: .speechEnd(sampleIndex: 81_920),
        ])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        let chunks = await feed(chunker, windows: 20)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startMs, 0)
        XCTAssertEqual(chunks[0].endMs, 2_560)
        // Contiguous accounting: the second chunk begins exactly where the first ended.
        XCTAssertEqual(chunks[1].startMs, chunks[0].endMs)
        XCTAssertEqual(chunks[1].startMs, 2_560)
        XCTAssertEqual(chunks[1].endMs, 5_120)
    }

    // MARK: - silence handling

    func testSilenceOnlyInputEmitsNothing() async {
        let vad = FakeMeetingVAD()  // never reports speech
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        let chunks = await feed(chunker, windows: 6)  // ~1.5s, below max

        XCTAssertTrue(chunks.isEmpty)
    }

    func testProlongedSilenceIsDiscardedNotEmitted() async {
        let vad = FakeMeetingVAD()  // never reports speech
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        // 45 windows = 184 320 samples, well past the 160 000 max.
        let chunks = await feed(chunker, windows: 45)

        XCTAssertTrue(chunks.isEmpty, "silence must never be emitted as a chunk")
        let diag = await chunker.diagnostics
        XCTAssertGreaterThanOrEqual(diag.droppedSilenceWindows, 1)
        XCTAssertEqual(diag.forceEmits, 0)
    }

    // MARK: - max-duration force emit

    func testForceEmitAtMaxDurationKeepsTailOverlap() async {
        // speechStart, then a long monologue with no speech-end.
        let vad = FakeMeetingVAD(events: [1: .speechStart])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        // 40 windows = 163 840 samples; force-emit fires once buffer ≥ 160 000.
        let chunks = await feed(chunker, windows: 40)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, maxChunkSamples)
        XCTAssertEqual(chunks[0].startMs, 0)
        XCTAssertEqual(chunks[0].endMs, 10_000)

        let diag = await chunker.diagnostics
        XCTAssertEqual(diag.forceEmits, 1)

        // The retained 250ms tail means the next chunk re-includes it: feed
        // another long stretch and confirm the next chunk starts before the
        // previous end (deliberate overlap the assembler dedups).
        let more = await feed(chunker, windows: 40)
        if let next = more.first {
            XCTAssertLessThan(next.startMs, 10_000, "force-emit tail overlap should re-feed audio")
            XCTAssertEqual(next.startMs, (maxChunkSamples - 4_000) * 1000 / 16_000)
        } else {
            XCTFail("expected a second force-emit after another long stretch")
        }
    }

    // MARK: - flush

    func testFlushEmitsSpokenTail() async {
        let vad = FakeMeetingVAD(events: [1: .speechStart])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        _ = await feed(chunker, windows: 5)  // 20 480 samples, no end event
        let tail = await chunker.flush()

        XCTAssertNotNil(tail)
        XCTAssertEqual(tail?.samples.count, 20_480)
        XCTAssertEqual(tail?.startMs, 0)
        XCTAssertEqual(tail?.endMs, 1_280)
    }

    func testFlushDropsSilentTail() async {
        let vad = FakeMeetingVAD()  // no speech
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        _ = await feed(chunker, windows: 5)
        let tail = await chunker.flush()

        XCTAssertNil(tail, "a tail with no detected speech must be dropped")
    }

    func testFlushDropsTinyTail() async {
        let vad = FakeMeetingVAD(events: [1: .speechStart])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        _ = await feed(chunker, windows: 1)  // 4 096 < 8 000 flush minimum
        let tail = await chunker.flush()

        XCTAssertNil(tail, "a sub-0.5s tail must be dropped")
    }

    // MARK: - reset

    func testResetRestartsTimelineAtZero() async {
        let vad = FakeMeetingVAD(events: [
            1: .speechStart,
            10: .speechEnd(sampleIndex: 40_960),
        ])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        _ = await feed(chunker, windows: 10)
        await chunker.reset()

        let after = await chunker.flush()
        XCTAssertNil(after, "reset should clear the buffer")

        let diag = await chunker.diagnostics
        XCTAssertEqual(diag.chunksEmitted, 0)
        XCTAssertEqual(diag.speechEndEvents, 0)
    }

    // MARK: - fallback

    func testRepeatedVADErrorsFallBackToFixedChunking() async {
        let vad = FakeMeetingVAD(failCalls: [1, 2, 3])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        // Feed enough to cross the fixed 5s window after fallback.
        let chunks = await feed(chunker, windows: 25)

        let diag = await chunker.diagnostics
        XCTAssertTrue(diag.fellBackToFixed)
        XCTAssertGreaterThanOrEqual(diag.vadErrors, 3)
        XCTAssertFalse(chunks.isEmpty, "fixed fallback should still emit live chunks")
        // First fixed chunk mirrors AudioChunker: 80 000 samples starting at 0.
        XCTAssertEqual(chunks[0].samples.count, 80_000)
        XCTAssertEqual(chunks[0].startMs, 0)
        XCTAssertEqual(chunks[0].endMs, 5_000)
        // Timestamps stay monotonic across the switch.
        for (lhs, rhs) in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThanOrEqual(lhs.startMs, rhs.startMs)
        }
    }

    func testTransientVADErrorDoesNotTriggerFallback() async {
        let vad = FakeMeetingVAD(
            events: [
                1: .speechStart,
                10: .speechEnd(sampleIndex: 40_960),
            ],
            failCalls: [2]  // single transient error, recovers on call 3
        )
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        let chunks = await feed(chunker, windows: 10)

        let diag = await chunker.diagnostics
        XCTAssertFalse(diag.fellBackToFixed)
        XCTAssertEqual(diag.vadErrors, 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, 40_960)
    }

    // MARK: - lockstep buffering (regression: large ingest must not drop unexamined speech)

    func testLargeSingleIngestDropsLeadingSilenceButKeepsLaterSpeech() async {
        // One giant ingest (45 windows) where VAD only detects speech at window
        // 41. Because the emittable buffer only ever holds VAD-examined audio,
        // the leading silence (windows 1–39) is dropped, window 40 is retained as
        // context, and the speech (windows 41–45) is preserved — never discarded
        // ahead of the VAD read head.
        let vad = FakeMeetingVAD(events: [41: .speechStart])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        let emitted = await chunker.addSamples([Float](repeating: 0.1, count: 45 * window))
        XCTAssertTrue(emitted.isEmpty, "speech only just started; nothing to emit yet")

        let tail = await chunker.flush()
        XCTAssertEqual(tail?.samples.count, 24_576, "speech audio must survive the silence drop")
        XCTAssertEqual(tail?.startMs, 9_984, "leading silence (windows 1–39) should be dropped")
        XCTAssertEqual(tail?.endMs, 11_520)

        let diag = await chunker.diagnostics
        XCTAssertGreaterThanOrEqual(diag.droppedSilenceWindows, 1)
    }

    func testStaleRetroactiveSpeechEndDropsTrailingSilenceInsteadOfForcing() async {
        // speechStart, continuous speech to a 10s force-emit (window 40), then a
        // speechEnd whose retroactive index (150 000) lands BEFORE the
        // post-force-emit lastEmittedSample (156 000). The stale cut must clear
        // the speech flag so the trailing silence is DROPPED — not force-emitted
        // as a silence chunk every 10s.
        let vad = FakeMeetingVAD(events: [
            1: .speechStart,
            41: .speechEnd(sampleIndex: 150_000),
        ])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        // 40 windows force-emit once; window 41 delivers the stale end; the rest
        // is silence that should reach the max cap (~window 78) and be dropped.
        let chunks = await feed(chunker, windows: 78)

        XCTAssertEqual(chunks.count, 1, "only the single force-emit should be emitted")
        let diag = await chunker.diagnostics
        XCTAssertEqual(diag.forceEmits, 1, "a stale end must not leave the speech flag set (which would force-emit silence)")
        XCTAssertGreaterThanOrEqual(diag.droppedSilenceWindows, 1, "post-speech silence should be dropped")
    }

    func testFlushTrimsTrailingSilenceAtSpeechEndBoundary() async {
        // Speech for 10 windows, then a clean speech-end inside the final partial
        // (< 256 ms) tail fed at flush. flush() must cut at the VAD boundary
        // rather than emit the trailing silence after it.
        let vad = FakeMeetingVAD(events: [
            1: .speechStart,
            11: .speechEnd(sampleIndex: 40_960),  // fires when the tail is fed at flush
        ])
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)

        let emitted = await chunker.addSamples([Float](repeating: 0.1, count: 10 * window + 2_000))
        XCTAssertTrue(emitted.isEmpty)

        let tail = await chunker.flush()
        XCTAssertEqual(tail?.samples.count, 40_960, "trailing silence past the speech-end must be trimmed")
        XCTAssertEqual(tail?.startMs, 0)
        XCTAssertEqual(tail?.endMs, 2_560)
    }

    // MARK: - helpers

    /// Feed `windows` of exactly 4 096 samples, mirroring the production cadence
    /// where each ingest is roughly one VAD window. Returns all emitted chunks.
    @discardableResult
    private func feed(
        _ chunker: SpeechBoundaryMeetingLiveAudioChunker,
        windows: Int,
        value: Float = 0.1
    ) async -> [AudioChunker.AudioChunk] {
        var all: [AudioChunker.AudioChunk] = []
        for _ in 0..<windows {
            all += await chunker.addSamples([Float](repeating: value, count: window))
        }
        return all
    }
}

private enum FakeVADError: Error {
    case boom
}

/// Scripted VAD: emits the programmed event for a given 1-based call index, and
/// throws on `failCalls`. State is ignored (the chunker round-trips it).
private actor FakeMeetingVAD: MeetingVoiceActivityDetecting {
    private var callIndex = 0
    private let events: [Int: MeetingVADEvent]
    private let failCalls: Set<Int>

    init(events: [Int: MeetingVADEvent] = [:], failCalls: Set<Int> = []) {
        self.events = events
        self.failCalls = failCalls
    }

    func makeStreamState() -> MeetingVADStreamState {
        MeetingVADStreamState()
    }

    func processStreamingChunk(
        _ samples: [Float],
        state: MeetingVADStreamState,
        config: MeetingVADConfig
    ) throws -> MeetingVADResult {
        callIndex += 1
        if failCalls.contains(callIndex) {
            throw FakeVADError.boom
        }
        return MeetingVADResult(state: state, event: events[callIndex])
    }
}
