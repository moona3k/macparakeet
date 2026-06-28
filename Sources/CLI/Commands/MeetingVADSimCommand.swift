import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli meeting-vad-sim <audio>` — headlessly replay the meeting
/// live-preview chunking path on an audio file and compare the fixed 5s strategy
/// against VAD speech-boundary chunking. Dev/agent tool for Phase 0 of the
/// VAD-guided live chunking plan: measures chunk boundaries on real speech and
/// the realtime factor that decides whether VAD can run inline in the capture
/// task. Does not exercise live capture or the GUI.
struct MeetingVADSimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting-vad-sim",
        abstract: "Replay meeting live-chunking (fixed vs VAD) on an audio file and report boundaries + realtime factor.",
        // Internal Phase-0 diagnostic, not part of the public agent surface
        // (deliberately absent from `spec --json`). Hidden from `--help` so the
        // human listing and the machine catalog agree; still invokable by name.
        shouldDisplay: false
    )

    @Argument(help: "Path to an audio file (wav/m4a/mp3/caf/aiff).")
    var audioPath: String

    @Option(name: .long, help: "Strategy: fixed | vad | both. Default: both.")
    var mode: String = "both"

    @Option(name: .long, help: "Ingest batch size in milliseconds (capture cadence). Default: 100.")
    var batchMs: Int = 100

    @Flag(name: .long, help: "Print every chunk boundary (default caps the list).")
    var allChunks: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    func run() async throws {
        try await emitJSONOrRethrow(json: json) {
            let url = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
            let modes = try parseModes()
            let batchSamples = max(1, batchMs) * 16  // 16 samples per ms @ 16kHz

            let samples = try MeetingVADChunkingSimulator.loadSamples16k(url: url)
            let level = amplitude(samples)
            if !json {
                print(String(format: "audio level     : peak=%@ dBFS  rms=%@ dBFS  (%@)",
                             dbfsString(level.peakDbfs), dbfsString(level.rmsDbfs), loudnessVerdict(level.rmsDbfs)))
            }

            var reports: [MeetingVADChunkingSimulator.Report] = []
            for m in modes {
                reports.append(await MeetingVADChunkingSimulator.simulate(
                    samples16k: samples, mode: m, batchSamples: batchSamples))
            }

            if json {
                try printJSON(reports.map(JSONReport.init))
            } else {
                for report in reports { printHuman(report) }
                if reports.count > 1 { printComparison(reports) }
            }
        }
    }

    private func amplitude(_ samples: [Float]) -> (peakDbfs: Double, rmsDbfs: Double) {
        var peak: Float = 0
        var sumSquares: Double = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSquares += Double(s) * Double(s)
        }
        let rms = samples.isEmpty ? 0 : (sumSquares / Double(samples.count)).squareRoot()
        let peakDbfs = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        let rmsDbfs = rms > 0 ? 20 * log10(rms) : -.infinity
        return (peakDbfs, rmsDbfs)
    }

    private func dbfsString(_ v: Double) -> String {
        v.isFinite ? String(format: "%.1f", v) : "-inf"
    }

    /// Rough interpretation so "0 chunks" is unambiguous: is the file actually
    /// silent, or is VAD missing audible speech? Keyed on RMS, not peak — a
    /// single click/notification hits a high peak on an otherwise silent track,
    /// so peak alone would mislabel silence as "normal level". Sustained speech
    /// lands around −30…−20 dBFS RMS; −45 and below carries no real speech.
    private func loudnessVerdict(_ rmsDbfs: Double) -> String {
        if !rmsDbfs.isFinite || rmsDbfs < -55 { return "silent — no sustained speech" }
        if rmsDbfs < -45 { return "near-silent" }
        if rmsDbfs < -30 { return "quiet speech" }
        return "active speech"
    }

    private func parseModes() throws -> [MeetingVADChunkingSimulator.Mode] {
        switch mode.lowercased() {
        case "fixed": return [.fixed]
        case "vad": return [.vad]
        case "both": return [.fixed, .vad]
        default: throw ValidationError("--mode must be one of: fixed, vad, both")
        }
    }

    private func printHuman(_ r: MeetingVADChunkingSimulator.Report) {
        print("")
        print("── mode: \(r.mode) " + String(repeating: "─", count: max(0, 40 - r.mode.count)))
        if r.mode == "vad" && !r.vadAvailable {
            print("  VAD model not cached — live path would fall back to fixed.")
            print("  (Launch MacParakeet with VAD enabled and let background prep fetch it, then retry.)")
            return
        }
        let durS = Double(r.audioDurationMs) / 1000.0
        print(String(format: "  audio duration   : %.1fs (%d ingest batches @ %dms)",
                     durS, r.ingestBatchCount, batchMs))
        print(String(format: "  processing time  : %.3fs  →  %.0f× realtime",
                     r.processingSeconds, r.realtimeFactor))
        print(String(format: "  per-ingest (ms)  : p50=%.3f  p99=%.3f  max=%.3f",
                     r.perIngestMsP50, r.perIngestMsP99, r.perIngestMsMax))
        let durations = r.chunks.map(\.durationMs)
        let avgDur = durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count
        print("  chunks emitted   : \(r.chunks.count)  (avg \(avgDur)ms)")
        if r.mode == "vad" {
            print("  vad diagnostics  : speechEnds=\(r.speechEndEvents) forceEmits=\(r.forceEmits) "
                  + "droppedSilence=\(r.droppedSilenceWindows) vadErrors=\(r.vadErrors) "
                  + "fellBackToFixed=\(r.fellBackToFixed)")
        }
        printBoundaries(r.chunks)
    }

    private func printBoundaries(_ chunks: [MeetingVADChunkingSimulator.ChunkSummary]) {
        guard !chunks.isEmpty else { return }
        let cap = 20
        let shown = allChunks ? chunks : Array(chunks.prefix(cap))
        print("  boundaries [startMs→endMs (durMs)]:")
        for c in shown {
            print(String(format: "    #%-3d %7d → %7d  (%5dms)", c.index, c.startMs, c.endMs, c.durationMs))
        }
        if !allChunks && chunks.count > cap {
            print("    … \(chunks.count - cap) more (use --all-chunks)")
        }
    }

    private func printComparison(_ reports: [MeetingVADChunkingSimulator.Report]) {
        guard let fixed = reports.first(where: { $0.mode == "fixed" }),
              let vad = reports.first(where: { $0.mode == "vad" }), vad.vadAvailable else { return }
        print("")
        print("── comparison ───────────────────────────")
        print("  chunks      : fixed=\(fixed.chunks.count)  vad=\(vad.chunks.count)")
        print(String(format: "  realtime    : fixed=%.0f×  vad=%.0f×", fixed.realtimeFactor, vad.realtimeFactor))
        print(String(format: "  vad overhead: %.3fs extra processing vs fixed",
                     max(0, vad.processingSeconds - fixed.processingSeconds)))
        // Decision hint for #2 (inline vs decouple).
        if vad.realtimeFactor >= 5 {
            print(String(format: "  → VAD runs at %.0f× realtime; inline-in-capture is safe (queue can't back up).",
                         vad.realtimeFactor))
        } else if vad.realtimeFactor > 0 {
            print(String(format: "  → VAD only %.1f× realtime; consider decoupling VAD onto its own task.",
                         vad.realtimeFactor))
        }
    }

    private struct JSONReport: Encodable {
        let mode: String
        let vadAvailable: Bool
        let audioDurationMs: Int
        let ingestBatchCount: Int
        let batchSamples: Int
        let chunkCount: Int
        let processingSeconds: Double
        let realtimeFactor: Double
        let perIngestMsP50: Double
        let perIngestMsP99: Double
        let perIngestMsMax: Double
        let chunksEmitted: Int
        let speechEndEvents: Int
        let forceEmits: Int
        let droppedSilenceWindows: Int
        let vadErrors: Int
        let fellBackToFixed: Bool
        let chunks: [Chunk]

        struct Chunk: Encodable {
            let index: Int
            let startMs: Int
            let endMs: Int
            let durationMs: Int
            let sampleCount: Int
        }

        init(_ r: MeetingVADChunkingSimulator.Report) {
            mode = r.mode
            vadAvailable = r.vadAvailable
            audioDurationMs = r.audioDurationMs
            ingestBatchCount = r.ingestBatchCount
            batchSamples = r.batchSamples
            chunkCount = r.chunks.count
            processingSeconds = r.processingSeconds
            realtimeFactor = r.realtimeFactor
            perIngestMsP50 = r.perIngestMsP50
            perIngestMsP99 = r.perIngestMsP99
            perIngestMsMax = r.perIngestMsMax
            chunksEmitted = r.chunksEmitted
            speechEndEvents = r.speechEndEvents
            forceEmits = r.forceEmits
            droppedSilenceWindows = r.droppedSilenceWindows
            vadErrors = r.vadErrors
            fellBackToFixed = r.fellBackToFixed
            chunks = r.chunks.map {
                Chunk(index: $0.index, startMs: $0.startMs, endMs: $0.endMs,
                      durationMs: $0.durationMs, sampleCount: $0.sampleCount)
            }
        }
    }
}
