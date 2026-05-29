import Foundation
import OSLog

/// Counters exposed for unit-test observation of the chunker's state machine
/// (silence drops, force emits, fallback). Not user-facing; carries no
/// transcript or audio. A natural hook for Phase 5 telemetry if it lands.
struct MeetingLiveChunkingDiagnostics: Sendable {
    var chunksEmitted = 0
    var speechEndEvents = 0
    var forceEmits = 0
    var droppedSilenceWindows = 0
    var vadErrors = 0
    var fellBackToFixed = false
}

/// Live-preview chunker that cuts at VAD speech boundaries instead of fixed
/// 5-second windows. See
/// `plans/active/2026-05-meeting-vad-guided-live-chunking.md`.
///
/// **Contiguous sample accounting.** Chunks tile the recording with no gaps in
/// the audio they emit, so `lastEmittedSample` always equals the absolute
/// sample index of `buffer[0]`, and therefore `chunk.startMs` always equals the
/// true absolute position of the chunk's first sample.
/// `MeetingTranscriptAssembler` dedups live words by absolute `endMs`, so a
/// `startMs` that understated the position would silently drop early words from
/// the preview. Contiguous accounting makes that impossible.
///
/// **Lockstep buffering.** Incoming samples are staged in `pendingVAD` and only
/// moved into the emittable `buffer` once they have been fed to VAD in exact
/// `VadManager.chunkSize` windows. So `buffer` only ever holds *VAD-examined*
/// audio, and the force-emit / silence-drop decisions (which key off
/// `buffer.count`) can never act on samples VAD has not analyzed — even for an
/// arbitrarily large single ingest.
///
/// Silence between utterances becomes leading silence of the next chunk (minor
/// STT cost, no correctness cost). The only deliberate overlap is a short tail
/// re-fed after a forced (max-duration) cut, because that cut lands mid-word;
/// the assembler's dedup harmlessly discards the duplicated tail words.
///
/// **Concurrency.** Methods mutate shared buffers across `await` points, so the
/// owner must call them serially. `CaptureOrchestrator` (the only caller) is an
/// actor that drives `addSamples`/`flush`/`reset` one at a time, satisfying this.
///
/// This type does not depend on FluidAudio — it round-trips the opaque
/// `MeetingVADStreamState` through a `MeetingVoiceActivityDetecting`.
actor SpeechBoundaryMeetingLiveAudioChunker: MeetingLiveAudioChunking {
    private static let sampleRate = 16_000
    /// `VadManager.chunkSize` — VAD streaming state advances by the sample count
    /// passed, so windows must be exactly this size to keep the boundary
    /// timeline aligned.
    private static let vadWindow = 4_096
    private static let minChunkSamples = 2 * sampleRate          // 2.0s
    private static let maxChunkSamples = 10 * sampleRate         // 10.0s
    private static let forceEmitTailOverlap = sampleRate / 4     // 0.25s
    private static let flushMinSamples = sampleRate / 2          // 0.5s
    /// Degraded-fallback fixed cadence, identical to `AudioChunker`.
    private static let fixedWindow = 5 * sampleRate
    private static let fixedOverlap = 1 * sampleRate
    private static let fixedFlushMinimum = 8_000
    private static let maxConsecutiveVADErrors = 3

    private let vad: any MeetingVoiceActivityDetecting
    private let config: MeetingVADConfig

    /// VAD-examined samples from `lastEmittedSample` up to the VAD frontier; the
    /// audio a future chunk will be cut from. `buffer[0]` is absolute
    /// `lastEmittedSample`, and `lastEmittedSample + buffer.count` is exactly the
    /// number of samples fed to VAD so far (minus what was emitted/dropped).
    private var buffer: [Float] = []
    /// Samples received but not yet sliced into a VAD window (< `vadWindow`).
    /// Not yet in `buffer`, so never counted by force-emit/silence-drop.
    private var pendingVAD: [Float] = []
    private var lastEmittedSample = 0
    private var sawSpeechSinceLastEmit = false
    private var vadState: MeetingVADStreamState?
    private var consecutiveVADErrors = 0
    private var fellBackToFixed = false
    private var diag = MeetingLiveChunkingDiagnostics()

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SpeechBoundaryChunker")

    init(vad: any MeetingVoiceActivityDetecting, config: MeetingVADConfig = .default) {
        self.vad = vad
        self.config = config
    }

    var diagnostics: MeetingLiveChunkingDiagnostics { diag }

    func reset() async {
        buffer = []
        pendingVAD = []
        lastEmittedSample = 0
        sawSpeechSinceLastEmit = false
        vadState = nil
        consecutiveVADErrors = 0
        fellBackToFixed = false
        diag = MeetingLiveChunkingDiagnostics()
    }

    func addSamples(_ samples: [Float]) async -> [AudioChunker.AudioChunk] {
        guard !samples.isEmpty else { return [] }

        if fellBackToFixed {
            buffer.append(contentsOf: samples)
            return drainFixed()
        }

        pendingVAD.append(contentsOf: samples)
        if vadState == nil {
            vadState = await vad.makeStreamState()
        }

        var emitted: [AudioChunker.AudioChunk] = []
        while pendingVAD.count >= Self.vadWindow {
            let window = Array(pendingVAD.prefix(Self.vadWindow))
            pendingVAD.removeFirst(Self.vadWindow)
            // Move the window into the emittable buffer *before* processing, so a
            // speech-end cut from this window has its audio available, and so the
            // VAD frontier (lastEmittedSample + buffer.count) stays exact.
            buffer.append(contentsOf: window)
            await process(window: window, into: &emitted)

            if fellBackToFixed {
                // Stage drains into the buffer so the fixed fallback emits the
                // complete audio; the staged samples are already accounted for.
                buffer.append(contentsOf: pendingVAD)
                pendingVAD.removeAll()
                emitted.append(contentsOf: drainFixed())
                return emitted
            }
            if let forced = maybeForceEmitOrDropSilence() {
                emitted.append(forced)
            }
        }
        return emitted
    }

    func flush() async -> AudioChunker.AudioChunk? {
        if fellBackToFixed {
            return flushFixed()
        }

        // Feed the sub-window tail so a clean speech end (or start) in the final
        // < 256 ms before stop is still recognized. The tail audio joins the
        // emittable buffer first so any speech-end cut has it available.
        if !pendingVAD.isEmpty, let state = vadState {
            let tail = pendingVAD
            pendingVAD.removeAll()
            buffer.append(contentsOf: tail)
            if let result = try? await vad.processStreamingChunk(tail, state: state, config: config) {
                vadState = result.state
                switch result.event {
                case .speechStart:
                    sawSpeechSinceLastEmit = true
                case .speechEnd(let cutSample):
                    diag.speechEndEvents += 1
                    // Trim trailing silence at the VAD-confirmed boundary. If the
                    // cut is sub-minimum we fall through and emit the whole spoken
                    // tail below (flush accepts shorter tails than streaming does).
                    if let chunk = emitAtSpeechEnd(cutSample: cutSample) {
                        return chunk
                    }
                case .none:
                    break
                }
            }
        }

        guard sawSpeechSinceLastEmit, buffer.count >= Self.flushMinSamples else {
            return nil
        }
        return makeChunk(length: buffer.count, tailOverlap: 0)
    }

    // MARK: - VAD streaming

    private func process(
        window: [Float],
        into emitted: inout [AudioChunker.AudioChunk]
    ) async {
        guard let state = vadState else { return }
        do {
            let result = try await vad.processStreamingChunk(window, state: state, config: config)
            vadState = result.state
            consecutiveVADErrors = 0

            switch result.event {
            case .speechStart:
                sawSpeechSinceLastEmit = true
            case .speechEnd(let cutSample):
                diag.speechEndEvents += 1
                if let chunk = emitAtSpeechEnd(cutSample: cutSample) {
                    emitted.append(chunk)
                }
            case .none:
                break
            }
        } catch {
            diag.vadErrors += 1
            consecutiveVADErrors += 1
            logger.error(
                "meeting_vad_stream_error consecutive=\(self.consecutiveVADErrors) error=\(error.localizedDescription, privacy: .public)"
            )
            if consecutiveVADErrors >= Self.maxConsecutiveVADErrors {
                fellBackToFixed = true
                diag.fellBackToFixed = true
                logger.notice("meeting_vad_fallback_to_fixed reason=vad_error")
            }
        }
    }

    /// Emit `[lastEmittedSample, cutSample)` when a speech segment ends. The cut
    /// is retroactive (absolute, from VAD's stream start), so it can land before
    /// the current ingest position.
    private func emitAtSpeechEnd(cutSample: Int) -> AudioChunker.AudioChunk? {
        guard sawSpeechSinceLastEmit else { return nil }
        let length = cutSample - lastEmittedSample
        if length <= 0 {
            // Boundary lands at/behind what we already emitted (e.g. a force-emit
            // advanced past where speech actually ended). Speech is over, so clear
            // the flag — otherwise trailing silence would never be dropped and
            // we'd force-emit silence every max-duration window.
            sawSpeechSinceLastEmit = false
            return nil
        }
        // Sub-minimum: keep buffering and let the next speechEnd extend the segment.
        guard length >= Self.minChunkSamples, length <= buffer.count else { return nil }
        let chunk = makeChunk(length: length, tailOverlap: 0)
        sawSpeechSinceLastEmit = false
        return chunk
    }

    /// When the buffer reaches the max-duration cap: force a cut (keeping a tail
    /// overlap for STT context) if speech was detected, otherwise discard the
    /// silence down to a small context window so memory and latency stay bounded.
    /// Operates only on VAD-examined audio (see lockstep buffering note).
    private func maybeForceEmitOrDropSilence() -> AudioChunker.AudioChunk? {
        guard buffer.count >= Self.maxChunkSamples else { return nil }

        guard sawSpeechSinceLastEmit else {
            let drop = buffer.count - Self.vadWindow
            if drop > 0 {
                buffer.removeFirst(drop)
                lastEmittedSample += drop
                diag.droppedSilenceWindows += 1
            }
            return nil
        }

        diag.forceEmits += 1
        return makeChunk(length: Self.maxChunkSamples, tailOverlap: Self.forceEmitTailOverlap)
    }

    /// Emit `buffer[0..<length]`, then advance by `length - tailOverlap`,
    /// retaining the tail so the next chunk re-includes it. Timestamps come
    /// strictly from sample counters (no wall clock).
    private func makeChunk(length: Int, tailOverlap: Int) -> AudioChunker.AudioChunk {
        let startMs = lastEmittedSample * 1000 / Self.sampleRate
        let endMs = (lastEmittedSample + length) * 1000 / Self.sampleRate
        let samples = Array(buffer.prefix(length))

        let advance = max(0, length - tailOverlap)
        buffer.removeFirst(min(advance, buffer.count))
        lastEmittedSample += advance
        diag.chunksEmitted += 1

        return AudioChunker.AudioChunk(samples: samples, startMs: startMs, endMs: endMs)
    }

    // MARK: - Degraded fixed fallback (shares the absolute sample counters so
    // timestamps stay monotonic across the switch).

    private func drainFixed() -> [AudioChunker.AudioChunk] {
        var out: [AudioChunker.AudioChunk] = []
        while buffer.count >= Self.fixedWindow {
            out.append(makeChunk(length: Self.fixedWindow, tailOverlap: Self.fixedOverlap))
        }
        return out
    }

    private func flushFixed() -> AudioChunker.AudioChunk? {
        guard buffer.count >= Self.fixedFlushMinimum else {
            // Discard the sub-minimum tail but keep the sample counter consistent
            // with the discarded audio, so the invariant holds if the instance is
            // ever reused without reset().
            lastEmittedSample += buffer.count
            buffer = []
            return nil
        }
        return makeChunk(length: buffer.count, tailOverlap: 0)
    }
}
