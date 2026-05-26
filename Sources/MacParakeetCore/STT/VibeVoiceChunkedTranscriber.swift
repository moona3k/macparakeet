import AVFoundation
import Foundation
import OSLog

/// Orchestrates long-form VibeVoice transcription by splitting the source
/// audio into ~5-minute chunks, transcribing each via the inner engine, and
/// merging the per-chunk segments into a single `STTResult`.
///
/// Lives in `MacParakeetCore` (not `VibeVoiceCore`) because it depends on
/// `BinaryBootstrap.requireRuntimeFFmpegPath()` to invoke FFmpeg for the
/// silence-detect and segment-split passes.
///
/// Fail-all on chunk error: if any chunk's `engine.transcribe(...)` throws,
/// the whole job throws. No partial transcript is returned. See the spec
/// `docs/superpowers/specs/2026-05-26-vibevoice-chunked-transcription-design.md`
/// for the rationale.
public actor VibeVoiceChunkedTranscriber {
    private static let logger = Logger(
        subsystem: "com.macparakeet.vibevoice",
        category: "VibeVoiceChunkedTranscriber"
    )

    private let engine: any STTTranscribing
    private let chunkLengthSec: Double
    private let minTailSec: Double
    private let silenceWindowSec: Double
    private let silenceThresholdDb: Double
    private let silenceMinDurationSec: Double

    /// - Parameters:
    ///   - engine: An `STTTranscribing`-conforming engine. In production this
    ///             is a `VibeVoiceEngine`. Tests pass a fake.
    ///   - chunkLengthSec: Target seconds per chunk. Defaults to 300 (5 min).
    ///   - minTailSec: If the final chunk would be shorter than this, the
    ///                 last boundary is dropped so the tail folds into the
    ///                 prior chunk. Defaults to 30.
    ///   - silenceWindowSec: ± seconds around each target boundary to search
    ///                       for silence. Defaults to 15.
    ///   - silenceThresholdDb: FFmpeg silencedetect `n` parameter in dB.
    ///                         Defaults to -30.
    ///   - silenceMinDurationSec: FFmpeg silencedetect `d` parameter in s.
    ///                            Defaults to 0.3.
    public init(
        engine: any STTTranscribing,
        chunkLengthSec: Double = 300,
        minTailSec: Double = 30,
        silenceWindowSec: Double = 15,
        silenceThresholdDb: Double = -30,
        silenceMinDurationSec: Double = 0.3
    ) {
        self.engine = engine
        self.chunkLengthSec = chunkLengthSec
        self.minTailSec = minTailSec
        self.silenceWindowSec = silenceWindowSec
        self.silenceThresholdDb = silenceThresholdDb
        self.silenceMinDurationSec = silenceMinDurationSec
    }

    /// Transcribes a long-form audio file by chunking + sequential engine calls.
    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let overallStart = Date()
        let audioURL = URL(fileURLWithPath: audioPath)

        // 1. Measure audio duration
        let audioSec = try AudioFileConverter.audioDuration(at: audioURL)

        // 2. Plan: compute target boundaries
        let targets = VibeVoiceChunkPlanning.computeChunkPlan(
            audioSec: audioSec,
            chunkLengthSec: chunkLengthSec,
            minTailSec: minTailSec
        )

        // 3. Silence-detect via FFmpeg, parse, refine boundaries
        let silenceStart = Date()
        let silences = try await runSilenceDetect(audioPath: audioPath)
        let refinedBoundaries = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets,
            silences: silences,
            windowSec: silenceWindowSec
        )
        let silenceElapsed = Date().timeIntervalSince(silenceStart)

        // 4. Compute chunk start offsets (parallel to chunk files): [0, b1, b2, ..., bN-1]
        let chunkStartOffsets: [Double] = [0] + refinedBoundaries
        let totalChunks = chunkStartOffsets.count

        // 5. Split via FFmpeg segment muxer
        let splitStart = Date()
        let chunkURLs = try await splitAudio(audioPath: audioPath, boundaries: refinedBoundaries)
        let splitElapsed = Date().timeIntervalSince(splitStart)
        defer {
            for url in chunkURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Defensive: chunk count from FFmpeg must match what we planned.
        guard chunkURLs.count == totalChunks else {
            throw STTError.transcriptionFailed(
                "FFmpeg produced \(chunkURLs.count) chunks but plan expected \(totalChunks)"
            )
        }

        Self.logger.notice("chunked transcribe starting: audio=\(audioSec, format: .fixed(precision: 1))s, totalChunks=\(totalChunks, privacy: .public), silenceDetect=\(silenceElapsed, format: .fixed(precision: 2))s, split=\(splitElapsed, format: .fixed(precision: 2))s")

        // 6. Loop: transcribe each chunk sequentially, merge segments
        var perChunkSegments: [[STTSegment]] = []
        let inferStart = Date()
        for (chunkIndex, chunkURL) in chunkURLs.enumerated() {
            let perChunkProgress: (@Sendable (Int, Int) -> Void)? = onProgress.map { outer in
                { localPct, _ in
                    let overall = VibeVoiceChunkPlanning.overallProgress(
                        chunkIndex: chunkIndex,
                        localPct: localPct,
                        totalChunks: totalChunks
                    )
                    outer(overall, 100)
                }
            }
            let chunkResult = try await engine.transcribe(
                audioPath: chunkURL.path,
                job: job,
                onProgress: perChunkProgress
            )
            let chunkSegments = chunkResult.segments ?? []
            if chunkResult.segments == nil {
                Self.logger.notice("chunk \(chunkIndex, privacy: .public) returned nil segments; treating as empty")
            }
            perChunkSegments.append(chunkSegments)
        }
        let inferElapsed = Date().timeIntervalSince(inferStart)

        // 7. Merge segments with chunk offsets
        let mergedSegments = VibeVoiceChunkPlanning.mergeSegments(
            chunkOffsetsSec: chunkStartOffsets,
            perChunkSegments: perChunkSegments
        )

        // Final progress snap to 100
        onProgress?(100, 100)

        let overallElapsed = Date().timeIntervalSince(overallStart)
        let rtf = audioSec > 0 ? inferElapsed / audioSec : -1
        Self.logger.notice("chunked transcribe complete: chunks=\(totalChunks, privacy: .public), infer=\(inferElapsed, format: .fixed(precision: 2))s, overall=\(overallElapsed, format: .fixed(precision: 2))s, RTF=\(rtf, format: .fixed(precision: 3)), segments=\(mergedSegments.count, privacy: .public)")

        return STTResult(
            text: mergedSegments.map(\.text).joined(separator: "\n"),
            words: [],
            segments: mergedSegments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "vibevoice-asr-q4_k-chunked"
        )
    }

    // MARK: - FFmpeg helpers

    private func runSilenceDetect(audioPath: String) async throws -> [ClosedRange<Double>] {
        let ffmpeg = try BinaryBootstrap.requireRuntimeFFmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", audioPath,
            "-af", "silencedetect=n=\(silenceThresholdDb)dB:d=\(silenceMinDurationSec)",
            "-f", "null", "-"
        ]

        // Use a temp file for stderr instead of a Pipe() to avoid the 64KB
        // pipe-buffer deadlock on long files. silencedetect emits one line per
        // interval to stderr, and large files can exceed the buffer. See the
        // same pattern in AudioFileConverter.runFFmpegConversion.
        let tempDir = FileManager.default.temporaryDirectory
        let stderrURL = tempDir.appendingPathComponent("vv-silencedetect-stderr-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { stderrHandle.closeFile() }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        try await runProcessAndWait(process, timeout: 600)

        // FFmpeg silencedetect emits a non-zero exit only on real errors;
        // missing matches are not errors. We tolerate any exit code and
        // parse whatever was emitted — empty result → uniform-split fallback.
        stderrHandle.synchronizeFile()
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
    }

    private func splitAudio(audioPath: String, boundaries: [Double]) async throws -> [URL] {
        // Defensive: an empty boundary list would cause FFmpeg's segment muxer
        // to default to ~2-second splits — producing hundreds of tiny chunks.
        // Caller (computeChunkPlan + STTRuntime routing) should never reach this,
        // but guard so a regression doesn't kick off a runaway split.
        guard !boundaries.isEmpty else {
            throw STTError.transcriptionFailed(
                "splitAudio called with no boundaries; route through single-shot engine instead"
            )
        }

        let ffmpeg = try BinaryBootstrap.requireRuntimeFFmpegPath()
        let uuid = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory
        let outputPattern = tempDir
            .appendingPathComponent("vv-chunk-\(uuid)-%03d.wav").path
        let prefix = "vv-chunk-\(uuid)-"

        // Self-contained cleanup: if anything below throws (FFmpeg non-zero
        // exit, cancellation, directory-listing failure), FFmpeg may have
        // already produced some chunk files in $TMPDIR. The caller's defer
        // can't reach them because chunkURLs hasn't been bound yet — it's
        // the return value of this throwing call. Mirror the pattern in
        // AudioFileConverter.runFFmpegConversion (succeeded flag).
        var succeeded = false
        defer {
            if !succeeded {
                if let allFiles = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
                    for name in allFiles where name.hasPrefix(prefix) && name.hasSuffix(".wav") {
                        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent(name))
                    }
                }
            }
        }

        var args = [
            "-i", audioPath,
            "-ar", "24000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            "-map", "0:a",
            "-f", "segment"
        ]
        if !boundaries.isEmpty {
            args.append(contentsOf: ["-segment_times", boundaries.map { String($0) }.joined(separator: ",")])
        }
        args.append("-y")
        args.append(outputPattern)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args

        // Use a temp file for stderr so we can surface FFmpeg's failure reason
        // in the error message, and to stay consistent with the pipe-buffer
        // deadlock guard used elsewhere in the codebase.
        let stderrURL = tempDir.appendingPathComponent("vv-segment-stderr-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { stderrHandle.closeFile() }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        try await runProcessAndWait(process, timeout: 600)

        guard process.terminationStatus == 0 else {
            stderrHandle.synchronizeFile()
            let stderrStr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "Unknown error"
            throw STTError.transcriptionFailed(
                "FFmpeg segment split failed with status \(process.terminationStatus): \(AudioFileConverter.tailForError(stderrStr))"
            )
        }

        // Discover the produced files. FFmpeg writes vv-chunk-<uuid>-000.wav,
        // -001.wav, ... — discover by listing the temp dir.
        let allFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let chunks = allFiles
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".wav") }
            .sorted()  // lexical order matches numeric for zero-padded 3-digit indices
            .map { tempDir.appendingPathComponent($0) }
        succeeded = true
        return chunks
    }

    private func runProcessAndWait(_ process: Process, timeout: TimeInterval) async throws {
        try process.run()
        try await ChildProcessWaiter.waitUntilExit(
            process,
            timeout: timeout,
            timeoutError: STTError.transcriptionFailed("FFmpeg timed out")
        )
    }
}
