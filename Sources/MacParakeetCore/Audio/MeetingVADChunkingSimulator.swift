import AVFoundation
import Foundation

/// Headless replay of the meeting **live-preview** chunking path on an audio
/// file, so an agent can measure and compare the fixed vs VAD strategies without
/// a live meeting or the GUI. This exercises the exact production components
/// (`FixedMeetingLiveAudioChunker` / `SpeechBoundaryMeetingLiveAudioChunker` +
/// `MeetingVADService`) that drive the live transcript preview.
///
/// **What it measures.** Chunk boundaries on real speech, and the
/// **realtime factor** (`audioDuration / processingTime`). The realtime factor
/// is the decision proxy for "should VAD run inline in the capture task or be
/// decoupled onto its own task": if chunking runs at N×realtime offline, a live
/// source producing at 1×realtime can never back up the inline path, so the
/// inline coupling is safe. See
/// `plans/completed/2026-05-meeting-vad-guided-live-chunking.md` (Phase 0).
///
/// **What it does not measure.** Live ScreenCaptureKit/AVAudioEngine capture,
/// the real-time backpressure *dynamics*, the SwiftUI layer, or VAD-while-
/// Parakeet-STT contention (that needs a live meeting). The realtime factor
/// bounds the backpressure question; it does not reproduce it.
public enum MeetingVADChunkingSimulator {

    public enum Mode: String, Sendable, CaseIterable {
        case fixed
        case vad
    }

    public struct ChunkSummary: Sendable {
        public let index: Int
        public let startMs: Int
        public let endMs: Int
        public let durationMs: Int
        public let sampleCount: Int
    }

    public struct Report: Sendable {
        public let mode: String
        /// `false` when `mode == .vad` but the Silero model is not cached on disk
        /// — the live path would fall back to fixed for the session.
        public let vadAvailable: Bool
        public let audioDurationMs: Int
        public let ingestBatchCount: Int
        public let batchSamples: Int
        public let chunks: [ChunkSummary]
        public let processingSeconds: Double
        /// `audioDuration / processingTime`. > 1 means faster than realtime.
        public let realtimeFactor: Double
        public let perIngestMsP50: Double
        public let perIngestMsP99: Double
        public let perIngestMsMax: Double
        // Flattened chunker diagnostics (zero for the fixed strategy).
        public let chunksEmitted: Int
        public let speechEndEvents: Int
        public let forceEmits: Int
        public let droppedSilenceWindows: Int
        public let vadErrors: Int
        public let fellBackToFixed: Bool
    }

    public enum SimulatorError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case decodeFailed(String)
        case emptyAudio

        public var description: String {
            switch self {
            case .cannotOpen(let path): return "Cannot open audio file: \(path)"
            case .decodeFailed(let detail): return "Failed to decode audio: \(detail)"
            case .emptyAudio: return "Audio file decoded to zero samples"
            }
        }
    }

    /// Decode an audio file to mono 16 kHz `Float` samples, reusing the same
    /// downmix + resample path (`AudioChunker.extractAndResample`) the capture
    /// pipeline uses. Reads in blocks to bound memory on long recordings.
    public static func loadSamples16k(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SimulatorError.cannotOpen("\(url.path): \(error.localizedDescription)")
        }

        let format = file.processingFormat
        let blockFrames: AVAudioFrameCount = 1 << 20  // ~1M frames/block
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) * 16_000 / max(1, Int(format.sampleRate)))

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
                throw SimulatorError.decodeFailed("could not allocate read buffer")
            }
            do {
                try file.read(into: buffer)
            } catch {
                throw SimulatorError.decodeFailed(error.localizedDescription)
            }
            if buffer.frameLength == 0 { break }
            guard let block = AudioChunker.extractAndResample(from: buffer) else {
                throw SimulatorError.decodeFailed("unsupported sample format")
            }
            out.append(contentsOf: block)
        }

        guard !out.isEmpty else { throw SimulatorError.emptyAudio }
        return out
    }

    /// Replay `samples16k` through the chosen strategy in `batchSamples`-sized
    /// ingests (mirroring the capture cadence), timing each ingest.
    public static func simulate(
        samples16k samples: [Float],
        mode: Mode,
        batchSamples: Int
    ) async -> Report {
        let audioDurationMs = samples.count * 1000 / 16_000
        let batch = max(1, batchSamples)

        let chunker: any MeetingLiveAudioChunking
        switch mode {
        case .fixed:
            chunker = FixedMeetingLiveAudioChunker()
        case .vad:
            guard let vad = await MeetingVADService.makeIfModelCached(computeUnits: .cpuOnly) else {
                return Report(
                    mode: mode.rawValue, vadAvailable: false,
                    audioDurationMs: audioDurationMs, ingestBatchCount: 0,
                    batchSamples: batch, chunks: [], processingSeconds: 0,
                    realtimeFactor: 0, perIngestMsP50: 0, perIngestMsP99: 0, perIngestMsMax: 0,
                    chunksEmitted: 0, speechEndEvents: 0, forceEmits: 0,
                    droppedSilenceWindows: 0, vadErrors: 0, fellBackToFixed: false
                )
            }
            chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: vad)
        }

        await chunker.reset()

        var chunks: [ChunkSummary] = []
        var perIngestMs: [Double] = []
        var batchCount = 0
        var index = 0

        func record(_ produced: [AudioChunker.AudioChunk]) {
            for c in produced {
                chunks.append(ChunkSummary(
                    index: index, startMs: c.startMs, endMs: c.endMs,
                    durationMs: c.endMs - c.startMs, sampleCount: c.samples.count
                ))
                index += 1
            }
        }

        let started = DispatchTime.now().uptimeNanoseconds
        var offset = 0
        while offset < samples.count {
            let end = min(offset + batch, samples.count)
            let slice = Array(samples[offset..<end])
            offset = end

            let t0 = DispatchTime.now().uptimeNanoseconds
            let produced = await chunker.addSamples(slice)
            let dtMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
            perIngestMs.append(dtMs)
            batchCount += 1
            record(produced)
        }
        if let tail = await chunker.flush() {
            record([tail])
        }
        let processingSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000.0

        var diag = MeetingLiveChunkingDiagnostics()
        if let sb = chunker as? SpeechBoundaryMeetingLiveAudioChunker {
            diag = await sb.diagnostics
        }

        let sorted = perIngestMs.sorted()
        func pct(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(p / 100.0 * Double(sorted.count)))]
        }
        let audioSeconds = Double(samples.count) / 16_000.0

        return Report(
            mode: mode.rawValue,
            vadAvailable: true,
            audioDurationMs: audioDurationMs,
            ingestBatchCount: batchCount,
            batchSamples: batch,
            chunks: chunks,
            processingSeconds: processingSeconds,
            realtimeFactor: processingSeconds > 0 ? audioSeconds / processingSeconds : 0,
            perIngestMsP50: pct(50),
            perIngestMsP99: pct(99),
            perIngestMsMax: sorted.last ?? 0,
            chunksEmitted: diag.chunksEmitted,
            speechEndEvents: diag.speechEndEvents,
            forceEmits: diag.forceEmits,
            droppedSilenceWindows: diag.droppedSilenceWindows,
            vadErrors: diag.vadErrors,
            fellBackToFixed: diag.fellBackToFixed
        )
    }
}
