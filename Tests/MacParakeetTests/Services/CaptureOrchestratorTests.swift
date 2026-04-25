import AVFAudio
import XCTest
@testable import MacParakeetCore

final class CaptureOrchestratorTests: XCTestCase {
    // The pair joiner emits paired (mic+system) drains when both queues stay
    // below its 1-second lag threshold (16 000 samples at 16 kHz). 8 k per
    // cycle gives a clean paired drain on each push without tripping the
    // solo-source fallback. 10 cycles = 80 000 samples = one 5-second chunk
    // out of each chunker.
    private let cycleFrames = 8_000
    private let cyclesForOneChunk = 10

    /// Bug repro: when the microphone tap delivers buffers whose `isHostTimeValid`
    /// is false (so `hostTime` is nil) but the system tap delivers a real mach
    /// uptime, the orchestrator used to leave mic at `startMs=0` while stamping
    /// system chunks with the absolute uptime in ms. Downstream the assembler's
    /// `normalizedWords()` couldn't repair the gap because mic's 0 became the
    /// minimum, leaving system at uptime — the panel rendered as e.g. `1545:21`
    /// for a 2:35 recording.
    func testMicNilHostTime_systemValidUptime_keepsBothChunksWithinRecordingDuration() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: nil,
            systemHostTimeBaseSeconds: 92_721.0
        )

        guard let micStart = chunks.first(where: { $0.source == .microphone })?.chunk.startMs,
              let systemStart = chunks.first(where: { $0.source == .system })?.chunk.startMs else {
            XCTFail("expected one chunk per source, got \(chunks.map { ($0.source, $0.chunk.startMs) })")
            return
        }

        // Both chunks describe the same 5 s window, so their startMs values
        // should sit within a single chunk-duration of each other.
        let delta = abs(systemStart - micStart)
        XCTAssertLessThan(
            delta,
            5_000,
            "Cross-stream delta exploded: mic=\(micStart)ms system=\(systemStart)ms — system stamp leaked absolute uptime"
        )
    }

    /// When both sources deliver valid hostTimes, the orchestrator should
    /// preserve only the cross-stream delta — not the absolute uptime.
    /// Pre-fix, both sources cached their own absolute uptime and added it
    /// to every chunk; the assembler's later `normalizedWords()` masked the
    /// breakage by subtracting the min, but only when both sources had
    /// roughly equal first hostTimes. This test pins the relative semantics.
    func testBothValidHostTimes_preserveCrossStreamDeltaNotAbsoluteUptime() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: 92_721.0,
            // System started 200 ms after mic.
            systemHostTimeBaseSeconds: 92_721.200
        )

        guard let micStart = chunks.first(where: { $0.source == .microphone })?.chunk.startMs,
              let systemStart = chunks.first(where: { $0.source == .system })?.chunk.startMs else {
            XCTFail("expected one chunk per source")
            return
        }

        // The first source to publish a valid hostTime defines t=0, so its
        // first chunk should land near startMs=0.
        XCTAssertLessThan(
            micStart,
            5_000,
            "mic startMs leaked absolute uptime: \(micStart)ms"
        )
        // The second source's first chunk should sit at the cross-stream delta —
        // ~200 ms — not at uptime + 200.
        XCTAssertLessThan(
            systemStart,
            5_000,
            "system startMs leaked absolute uptime: \(systemStart)ms"
        )
        // And the delta itself should match the input (with mach-time rounding).
        let delta = systemStart - micStart
        XCTAssertEqual(
            delta,
            200,
            accuracy: 2,
            "cross-stream delta should be ~200ms, got \(delta)ms"
        )
    }

    /// Long-recording drift bug: when the system tap goes quiet for an
    /// extended stretch, the pair joiner emits "solo mic" pairs (mic samples +
    /// silence-padded system samples). Pre-fix, only the mic chunker was fed —
    /// the system chunker's `totalSamplesProcessed` stayed frozen while mic's
    /// kept tracking wallclock. Mic chunk timestamps drifted into the future
    /// relative to system; in a real recording, this rendered as
    /// "Me 17:24" inside a 9:20 elapsed session.
    ///
    /// Fix: feed both chunkers on every pair, using the silence-padded samples
    /// from the absent source so the two `totalSamplesProcessed` counters
    /// remain in lockstep with wallclock.
    func testMicOnlyStretchKeepsSystemChunkerAlignedWithMic() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        // Drive 30 cycles of mic-only ingests (no system pushes). At 8k samples
        // per cycle (0.5 s), the joiner enters solo-mic mode after the first
        // couple of cycles and stays there — exactly the pattern that produced
        // the observed drift in real recordings.
        var allChunks: [CaptureOrchestratorChunk] = []
        let cycleSeconds = Double(cycleFrames) / 16_000.0
        for cycle in 0..<30 {
            let micBatch = [Float](repeating: 0.1, count: cycleFrames)
            let micHostTime = AVAudioTime.hostTime(forSeconds: 100.0 + Double(cycle) * cycleSeconds)
            let out = await orchestrator.ingest(
                samples: micBatch,
                source: .microphone,
                hostTime: micHostTime,
                micConditioner: conditioner
            )
            allChunks.append(contentsOf: out.chunks)
        }

        let micChunks = allChunks.filter { $0.source == .microphone }
        let systemChunks = allChunks.filter { $0.source == .system }

        XCTAssertFalse(micChunks.isEmpty, "expected mic chunks during mic-only stretch")
        XCTAssertFalse(
            systemChunks.isEmpty,
            "system chunker emitted nothing during a mic-only stretch — its sample counter froze while mic's tracked wallclock, which is exactly the drift that produced 'Me 17:24' inside a 9:20 recording"
        )
        // Both chunkers should have processed the same amount of audio, so
        // they should emit the same number of chunks.
        XCTAssertEqual(
            micChunks.count,
            systemChunks.count,
            "mic and system chunkers diverged during mic-only stretch (mic=\(micChunks.count), system=\(systemChunks.count))"
        )
        // First-chunk startMs values should match — both saw the same wallclock.
        if let firstMic = micChunks.first?.chunk.startMs,
           let firstSystem = systemChunks.first?.chunk.startMs {
            XCTAssertEqual(
                firstMic,
                firstSystem,
                "first mic and system chunks misaligned: mic=\(firstMic)ms system=\(firstSystem)ms"
            )
        }
    }

    /// `reset()` must clear the shared origin so a fresh recording starts at
    /// t=0 instead of latching onto the previous session's uptime baseline.
    func testResetClearsTimelineOriginAcrossRecordings() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        // First recording at uptime ~92 721 s — discard chunks.
        _ = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: 92_721.0,
            systemHostTimeBaseSeconds: 92_721.0
        )

        await orchestrator.reset()

        // Second recording at uptime ~92 900 s — should restart relative to itself.
        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: 92_900.0,
            systemHostTimeBaseSeconds: 92_900.0
        )

        guard let micStart = chunks.first(where: { $0.source == .microphone })?.chunk.startMs,
              let systemStart = chunks.first(where: { $0.source == .system })?.chunk.startMs else {
            XCTFail("expected one chunk per source after reset")
            return
        }
        XCTAssertLessThan(
            micStart,
            5_000,
            "second recording's mic chunk leaked previous-session origin: \(micStart)ms"
        )
        XCTAssertLessThan(
            systemStart,
            5_000,
            "second recording's system chunk leaked previous-session origin: \(systemStart)ms"
        )
    }

    // MARK: - helpers

    /// Push `cycles` paired 8 k-sample batches through the orchestrator so the
    /// chunkers see steady paired drains. Each cycle stamps a fresh hostTime
    /// per source (advancing by 0.5 s — one batch duration), matching how the
    /// real audio stack delivers a new mach time on every buffer. Pass nil
    /// for a source's base seconds to simulate `isHostTimeValid == false`
    /// across the entire stream.
    private func driveCycles(
        orchestrator: CaptureOrchestrator,
        conditioner: PassthroughMicConditioner,
        cycles: Int,
        micHostTimeBaseSeconds: Double?,
        systemHostTimeBaseSeconds: Double?
    ) async -> [CaptureOrchestratorChunk] {
        let cycleSeconds = Double(cycleFrames) / 16_000.0
        var collected: [CaptureOrchestratorChunk] = []
        for cycle in 0..<cycles {
            let micBatch = [Float](repeating: 0.1, count: cycleFrames)
            let sysBatch = [Float](repeating: 0.1, count: cycleFrames)
            let micHostTime: UInt64? = micHostTimeBaseSeconds.map {
                AVAudioTime.hostTime(forSeconds: $0 + cycleSeconds * Double(cycle))
            }
            let sysHostTime: UInt64? = systemHostTimeBaseSeconds.map {
                AVAudioTime.hostTime(forSeconds: $0 + cycleSeconds * Double(cycle))
            }

            let outA = await orchestrator.ingest(
                samples: micBatch,
                source: .microphone,
                hostTime: micHostTime,
                micConditioner: conditioner
            )
            let outB = await orchestrator.ingest(
                samples: sysBatch,
                source: .system,
                hostTime: sysHostTime,
                micConditioner: conditioner
            )
            collected.append(contentsOf: outA.chunks)
            collected.append(contentsOf: outB.chunks)
        }
        return collected
    }
}

/// Test-only conditioner: forwards mic samples untouched so chunk math stays
/// predictable. Mirrors `VPIOConditioner` but without dragging audio-engine
/// types into the test fixture.
private final class PassthroughMicConditioner: MicConditioning {
    var mode: MeetingMicProcessingEffectiveMode { .raw }
    func condition(microphone: [Float], speaker: [Float]) -> [Float] { microphone }
    func reset() {}
}
