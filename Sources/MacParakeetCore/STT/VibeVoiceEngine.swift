import AVFoundation
import Foundation
import OSLog
import VibeVoiceCore

/// Wraps `VibeVoiceASR` (Phase 2.1) behind the same shape `STTRuntime`
/// already manages for Parakeet and Whisper. Owns model lifecycle for
/// the VibeVoice engine; the actor's serialization guarantees that
/// concurrent transcribe calls queue rather than corrupt the underlying
/// single-engine C library.
///
/// Lifecycle:
/// 1. `warmUp()` — calls `vv_capi_load` once. Takes ~13s on M1 Max with Q4.
/// 2. `transcribe(audioPath:job:)` — many calls. Returns `STTResult` with
///    diarized segments populated and word-level timing empty (VibeVoice
///    doesn't expose words via its C ABI).
/// 3. `unload()` — frees the underlying engine. Optional; process exit
///    also frees it.
public actor VibeVoiceEngine: STTTranscribing {
    private static let logger = Logger(subsystem: "com.macparakeet.vibevoice", category: "VibeVoiceEngine")

    private let asr: VibeVoiceASR
    private let modelDirectory: URL
    private var isLoaded = false

    /// `modelDirectory` defaults to the conventional location under
    /// `~/Library/Application Support/MacParakeet/models/stt/vibevoice/`.
    /// Override for tests.
    public init(modelDirectory: URL? = nil) {
        self.asr = VibeVoiceASR()
        self.modelDirectory = modelDirectory ?? Self.defaultModelDirectory()
    }

    public static func defaultModelDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MacParakeet")
            .appendingPathComponent("models")
            .appendingPathComponent("stt")
            .appendingPathComponent("vibevoice")
    }

    public func warmUp() async throws {
        if isLoaded { return }
        let model = modelDirectory.appendingPathComponent("vibevoice-asr-q4_k.gguf")
        let tok = modelDirectory.appendingPathComponent("tokenizer.gguf")
        try await asr.loadModel(modelPath: model, tokenizerPath: tok)
        isLoaded = true
    }

    /// Transcribes an audio file. Conforms to `STTTranscribing` so this engine
    /// can be used by the CLI's standalone engine path the same way Whisper is.
    ///
    /// VibeVoice's C ABI doesn't expose intermediate progress callbacks — the
    /// inference is an opaque load + run. Instead, we estimate progress from
    /// audio duration using RTF ≈ 0.5 (M1 Max, Q4 GGUF; empirical: 5-min clip
    /// transcribed in 2:35, so 0.52 measured). Short clips (<30 s) are
    /// faster (~0.07 RTF) due to load-dominated wall time, but long-form is
    /// the use case the bar matters for. Fires once per second, capped at 99%
    /// so an underestimated tail can't claim 100% before the real result
    /// arrives; we snap to 100% on success. Use the
    /// `STTRuntime.observeWarmUpProgress()` stream for visibility into the
    /// load step separately.
    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        // Timing breakdown for diagnosing GUI-vs-CLI perf gaps. All three
        // phases are logged at notice level so they persist in the unified
        // log and show up alongside the C library's `[vv I]` stderr lines
        // when tailing the dev log. View with:
        //   log stream --predicate 'subsystem == "com.macparakeet.vibevoice"' --info
        // or just `grep VibeVoice` on the dev log file.
        let overallStart = Date()

        let warmStart = Date()
        if !isLoaded { try await warmUp() }
        let warmElapsed = Date().timeIntervalSince(warmStart)

        // VibeVoice requires 24 kHz mono WAV. If the input is something
        // else (mp3/m4a/etc.), convert via the bundled FFmpeg into a temp
        // file before handing it to the C ABI.
        let convertStart = Date()
        let wavPath = try await Self.ensureWAV(audioPath)
        let convertElapsed = Date().timeIntervalSince(convertStart)
        defer {
            // Best-effort cleanup of the temp WAV we created.
            if wavPath != audioPath {
                try? FileManager.default.removeItem(atPath: wavPath)
            }
        }

        let audioSec = (try? Self.audioDuration(at: URL(fileURLWithPath: wavPath))) ?? 0
        Self.logger.notice("vibevoice transcribe starting: audio=\(audioSec, format: .fixed(precision: 1))s, warm=\(warmElapsed, format: .fixed(precision: 2))s, convert=\(convertElapsed, format: .fixed(precision: 2))s")

        // Time-based progress estimator. Fires every second while inference
        // is running so the UI shows the bar moving rather than sitting at
        // 0% for the full RTF window. Cancelled in `defer` after the C ABI
        // call returns (success or throw).
        let progressTask: Task<Void, Never>?
        if let onProgress {
            let estimatedTotalSec = audioSec > 0 ? audioSec * 0.5 : 60.0
            let startTime = Date()
            onProgress(0, 100)
            progressTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    let elapsed = Date().timeIntervalSince(startTime)
                    let percent = min(99, Int(elapsed / estimatedTotalSec * 100))
                    onProgress(percent, 100)
                }
            }
        } else {
            progressTask = nil
        }
        defer { progressTask?.cancel() }

        let inferStart = Date()
        let segments = try await asr.transcribe(wavPath: URL(fileURLWithPath: wavPath))
        let inferElapsed = Date().timeIntervalSince(inferStart)
        let overallElapsed = Date().timeIntervalSince(overallStart)
        let rtf = audioSec > 0 ? inferElapsed / audioSec : -1
        Self.logger.notice("vibevoice transcribe complete: infer=\(inferElapsed, format: .fixed(precision: 2))s, overall=\(overallElapsed, format: .fixed(precision: 2))s, RTF=\(rtf, format: .fixed(precision: 3)), segments=\(segments.count, privacy: .public)")

        onProgress?(100, 100)

        let sttSegments = segments.map { seg in
            STTSegment(
                startMs: Int(seg.startSec * 1000),
                endMs: Int(seg.endSec * 1000),
                text: seg.text,
                speakerId: seg.speakerId
            )
        }
        let joinedText = segments.map(\.text).joined(separator: "\n")

        return STTResult(
            text: joinedText,
            words: [],
            segments: sttSegments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "vibevoice-asr-q4_k"
        )
    }

    /// Reads the audio duration (in seconds) of a WAV file. Used to size the
    /// time-based progress estimate. Duplicated from `VibeVoiceASR` rather
    /// than promoted to a public helper — 4 lines, single caller per actor.
    private static func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let frameCount = file.length
        let sampleRate = file.processingFormat.sampleRate
        return sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }

    public func unload() async {
        await asr.unload()
        isLoaded = false
    }

    // MARK: - Audio conversion

    /// If the input is already a WAV, returns the path unchanged. Otherwise
    /// uses the bundled FFmpeg to produce a 24 kHz mono PCM WAV in `$TMPDIR`
    /// and returns its path. Caller is responsible for deletion.
    private static func ensureWAV(_ audioPath: String) async throws -> String {
        let lower = (audioPath as NSString).pathExtension.lowercased()
        if lower == "wav" {
            return audioPath
        }
        let ffmpeg = try BinaryBootstrap.requireRuntimeFFmpegPath()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibevoice-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", audioPath,
            "-ar", "24000",
            "-ac", "1",
            "-y", outputURL.path
        ]
        // Discard stdout/stderr via nullDevice — avoids the 64KB pipe buffer
        // deadlock that occurs when FFmpeg writes verbose progress output during
        // long conversions and waitUntilExit() stalls waiting for the process.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // TODO(Phase 2.2 Task 6): `waitUntilExit()` blocks the actor executor for the
        // duration of the FFmpeg conversion (potentially seconds for long inputs).
        // Replace with the async-wrapped runProcessAndWait(_:timeout:) pattern from
        // AudioFileConverter before STTRuntime wires this engine live.
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw STTError.transcriptionFailed("FFmpeg failed with status \(process.terminationStatus) converting to WAV")
        }
        return outputURL.path
    }
}
