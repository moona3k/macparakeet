import Foundation
import OSLog

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
/// Silence between utterances becomes leading silence of the next chunk (minor
/// STT cost, no correctness cost). The only deliberate overlap is a short tail
/// re-fed after a forced (max-duration) cut, because that cut lands mid-word;
/// the assembler's dedup harmlessly discards the duplicated tail words.
///
/// This type does not depend on FluidAudio — it round-trips the opaque
/// `MeetingVADStreamState` through a `MeetingVoiceActivityDetecting`.
actor SpeechBoundaryMeetingLiveAudioChunker: MeetingLiveAudioChunking {
    private static let sampleRate = 16_000
    /// `VadManager.chunkSize` — VAD streaming state advances by the sample count
    /// passed, so windows must be exactly this size to keep the boundary
    /// timeline aligned.
    private static let vadWindow = 4_096
    /// Degraded-fallback fixed cadence, identical to `AudioChunker`.
    private static let fixedWindow = 5 * sampleRate
    private static let fixedOverlap = 1 * sampleRate
    private static let fixedFlushMinimum = 8_000
    private static let maxConsecutiveVADErrors = 3

    private let vad: any MeetingVoiceActivityDetecting
    private let config: MeetingVADConfig
    private let minChunkSamples: Int
    private let maxChunkSamples: Int
    private let forceEmitTailOverlap: Int
    private let flushMinSamples: Int

    /// Samples from `lastEmittedSample` up to `totalSamplesSeen`; the audio a
    /// future chunk will be cut from. `buffer[0]` is absolute `lastEmittedSample`.
    private var buffer: [Float] = []
    /// Samples appended but not yet sliced into a VAD window (< `vadWindow`).
    private var pendingVAD: [Float] = []
    private var totalSamplesSeen = 0
    private var lastEmittedSample = 0
    private var sawSpeechSinceLastEmit = false
    private var vadState: MeetingVADStreamState?
    private var consecutiveVADErrors = 0
    private var fellBackToFixed = false
    private var diag = MeetingLiveChunkingDiagnostics(mode: .vad)

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SpeechBoundaryChunker")

    init(
        vad: any MeetingVoiceActivityDetecting,
        config: MeetingVADConfig = .default,
        minChunkSeconds: Double = 2.0,
        maxChunkSeconds: Double = 10.0,
        forceEmitTailOverlapSeconds: Double = 0.25,
        flushMinimumSeconds: Double = 0.5
    ) {
        self.vad = vad
        self.config = config
        self.minChunkSamples = Int(minChunkSeconds * Double(Self.sampleRate))
        self.maxChunkSamples = Int(maxChunkSeconds * Double(Self.sampleRate))
        self.forceEmitTailOverlap = Int(forceEmitTailOverlapSeconds * Double(Self.sampleRate))
        self.flushMinSamples = Int(flushMinimumSeconds * Double(Self.sampleRate))
    }

    var diagnostics: MeetingLiveChunkingDiagnostics { diag }

    func reset() async {
        buffer = []
        pendingVAD = []
        totalSamplesSeen = 0
        lastEmittedSample = 0
        sawSpeechSinceLastEmit = false
        vadState = nil
        consecutiveVADErrors = 0
        fellBackToFixed = false
        diag = MeetingLiveChunkingDiagnostics(mode: .vad)
    }

    func addSamples(_ samples: [Float]) async -> [AudioChunker.AudioChunk] {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        totalSamplesSeen += samples.count

        if fellBackToFixed {
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
            await process(window: window, into: &emitted)
            if fellBackToFixed {
                emitted.append(contentsOf: drainFixed())
                return emitted
            }
            if let forced = maybeForceEmitOrDropSilence() {
                emitted.append(forced)
            }
        }
        // A large single ingest can leave the buffer past the cap even after the
        // VAD windows are drained; keep emitting until it is bounded again.
        while let forced = maybeForceEmitOrDropSilence() {
            emitted.append(forced)
        }
        return emitted
    }

    func flush() async -> AudioChunker.AudioChunk? {
        if fellBackToFixed {
            return flushFixed()
        }

        // Best-effort: feed the sub-window tail so a speech segment that began in
        // the final < 256 ms before stop can still be recognized as speech.
        if !pendingVAD.isEmpty, let state = vadState {
            if let result = try? await vad.processStreamingChunk(pendingVAD, state: state, config: config) {
                vadState = result.state
                diag.recentProbability = result.probability
                if case .speechStart = result.event {
                    sawSpeechSinceLastEmit = true
                    diag.speechStartEvents += 1
                }
            }
            pendingVAD.removeAll()
        }

        guard sawSpeechSinceLastEmit, buffer.count >= flushMinSamples else {
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
            diag.recentProbability = result.probability

            switch result.event {
            case .speechStart:
                sawSpeechSinceLastEmit = true
                diag.speechStartEvents += 1
            case .speechEnd(let sampleIndex):
                diag.speechEndEvents += 1
                if let chunk = emitAtSpeechEnd(cutSample: sampleIndex) {
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
                logger.notice("meeting_vad_fallback_to_fixed source diagnostics will report mode=vad reason=vad_error")
            }
        }
    }

    /// Emit `[lastEmittedSample, cutSample)` when a speech segment ends. The cut
    /// is retroactive, so it can land before the current ingest position; we
    /// skip cuts that are too early or that would produce a sub-minimum chunk
    /// and let the next `speechEnd` extend the segment.
    private func emitAtSpeechEnd(cutSample: Int) -> AudioChunker.AudioChunk? {
        guard sawSpeechSinceLastEmit else { return nil }
        let length = cutSample - lastEmittedSample
        guard length >= minChunkSamples, length <= buffer.count else { return nil }
        let chunk = makeChunk(length: length, tailOverlap: 0)
        sawSpeechSinceLastEmit = false
        return chunk
    }

    /// When the buffer reaches the max-duration cap: force a cut (keeping a tail
    /// overlap for STT context) if speech was detected, otherwise discard the
    /// silence down to a small context window so memory and latency stay bounded.
    private func maybeForceEmitOrDropSilence() -> AudioChunker.AudioChunk? {
        guard buffer.count >= maxChunkSamples else { return nil }

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
        return makeChunk(length: maxChunkSamples, tailOverlap: forceEmitTailOverlap)
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
            buffer = []
            return nil
        }
        return makeChunk(length: buffer.count, tailOverlap: 0)
    }
}
