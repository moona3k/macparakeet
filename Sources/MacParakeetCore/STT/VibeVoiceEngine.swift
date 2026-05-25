import Foundation
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
public actor VibeVoiceEngine {
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

    public func transcribe(audioPath: String, job: STTJobKind) async throws -> STTResult {
        if !isLoaded { try await warmUp() }

        // VibeVoice requires 24 kHz mono WAV. If the input is something
        // else (mp3/m4a/etc.), convert via the bundled FFmpeg into a temp
        // file before handing it to the C ABI.
        let wavPath = try await Self.ensureWAV(audioPath)
        defer {
            // Best-effort cleanup of the temp WAV we created.
            if wavPath != audioPath {
                try? FileManager.default.removeItem(atPath: wavPath)
            }
        }

        let segments = try await asr.transcribe(wavPath: URL(fileURLWithPath: wavPath))
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
