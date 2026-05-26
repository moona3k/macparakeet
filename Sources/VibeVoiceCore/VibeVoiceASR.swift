import AVFoundation
import Foundation
import CVibeVoice
import OSLog

/// Swift wrapper around the vibevoice.cpp C ABI. One actor per
/// process — the underlying C library uses a single global engine
/// (`vv_capi_load` is idempotent and replaces the engine on re-call).
///
/// Lifecycle:
/// 1. `loadModel(modelPath:tokenizerPath:)` — must be called once before any
///    `transcribe(...)` call. Takes ~13s on M1 Max with the Q4 GGUF.
/// 2. `transcribe(wavPath:)` — called many times. Returns diarized
///    segments via JSON parsing of the C ABI's output buffer.
/// 3. `unload()` — optional; process exit frees engine state.
public actor VibeVoiceASR {
    private static let logger = Logger(subsystem: "com.macparakeet.vibevoice", category: "VibeVoiceASR")

    /// Initial JSON output buffer. Long-form transcriptions can produce
    /// 50-100 KB of JSON; we start at 256 KB and grow on `outputBufferTooSmall`.
    private static let initialBufferSize: Int = 256 * 1024

    /// Grow up to 16 MB before giving up. Bounds the worst case so a
    /// runaway response can't OOM the host.
    private static let maxBufferSize: Int = 16 * 1024 * 1024

    /// Small pad above the reported required size so a slightly larger
    /// response on retry doesn't immediately trigger another grow.
    private static let bufferPad: Int = 1024

    private var isLoaded: Bool = false

    public init() {}

    /// Library version string from the C ABI. Useful for logging.
    public nonisolated var libraryVersion: String {
        guard let cstr = vv_capi_version() else { return "unknown" }
        return String(cString: cstr)
    }

    /// Load the ASR model + tokenizer. Idempotent — calling twice
    /// replaces the engine. Throws if either file is missing or if
    /// `vv_capi_load` returns non-zero.
    public func loadModel(modelPath: URL, tokenizerPath: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath.path) else {
            throw VibeVoiceASRError.fileNotFound(modelPath)
        }
        guard fm.fileExists(atPath: tokenizerPath.path) else {
            throw VibeVoiceASRError.fileNotFound(tokenizerPath)
        }

        let rc = modelPath.path.withCString { modelCStr in
            tokenizerPath.path.withCString { tokCStr in
                vv_capi_load(
                    nil,             // tts_model_path — ASR-only client
                    modelCStr,       // asr_model_path
                    tokCStr,         // tokenizer_path
                    nil,             // voice_path — TTS only
                    0                // n_threads — 0 = auto
                )
            }
        }
        guard rc == 0 else {
            isLoaded = false
            throw VibeVoiceASRError.loadFailed(code: rc)
        }
        isLoaded = true
    }

    /// Transcribe a WAV file. Returns one `DiarizedSegment` per row of
    /// the JSON returned by `vv_capi_asr`.
    public func transcribe(wavPath: URL) async throws -> [DiarizedSegment] {
        guard isLoaded else { throw VibeVoiceASRError.modelNotLoaded }
        guard FileManager.default.fileExists(atPath: wavPath.path) else {
            throw VibeVoiceASRError.fileNotFound(wavPath)
        }

        // Size the token budget by audio duration. vibevoice.cpp defaults
        // `max_new_tokens` to 256 — that's only ~80 seconds of speech.
        // English at typical pace is ~5 tokens/sec; we use 10/sec for
        // headroom (fast speech, diarization markers, etc.) with a 512
        // floor so very short clips still have room for boundary tokens.
        let audioSeconds = (try? Self.audioDuration(at: wavPath)) ?? 0
        let maxNewTokens = Int32(max(512, Int(audioSeconds * 10)))

        var bufferSize = Self.initialBufferSize
        while bufferSize <= Self.maxBufferSize {
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let written = wavPath.path.withCString { wavCStr in
                buffer.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
                    vv_capi_asr(
                        wavCStr,
                        bufPtr.baseAddress,
                        bufPtr.count,
                        maxNewTokens
                    )
                }
            }

            if written > 0 {
                // Success — buffer is NUL-terminated. Trim to the
                // written-bytes prefix and decode JSON.
                let jsonString = buffer.prefix(Int(written)).withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }
                guard let data = jsonString.data(using: .utf8) else {
                    Self.logger.error("VibeVoice returned non-UTF8 output (\(written, privacy: .public) bytes)")
                    throw VibeVoiceASRError.malformedJSON("non-UTF8 output")
                }
                do {
                    return try JSONDecoder().decode([DiarizedSegment].self, from: data)
                } catch {
                    // Dump the first 1500 chars of the raw JSON so we can
                    // tell whether vibevoice.cpp returned a different shape,
                    // partial output, or garbage. User-content data is the
                    // user's own transcription — `.public` matches what other
                    // STT engines log.
                    let preview = String(jsonString.prefix(1500))
                    Self.logger.error("VibeVoice JSON decode failed (\(written, privacy: .public) bytes): \(error.localizedDescription, privacy: .public)\nRaw output preview: \(preview, privacy: .public)")
                    throw VibeVoiceASRError.malformedJSON(error.localizedDescription)
                }
            } else if written == 0 {
                return []  // No transcription produced; empty audio or silence.
            } else {
                // Negative: either buffer-too-small (negated required size)
                // or a real error code. The C ABI doesn't distinguish in the
                // value itself; we differentiate by checking whether the
                // negated value is plausibly a buffer size.
                //
                // Defensive: Int32.min negation overflows in debug builds (Swift
                // traps signed-integer overflow). The C ABI's documented error
                // codes don't go anywhere near Int32.min, but we guard anyway
                // so a misbehaving library can't crash us with a debug trap.
                guard written != Int32.min else {
                    throw VibeVoiceASRError.transcribeFailed(code: written)
                }
                let requiredOrError = -Int(written)
                if requiredOrError > bufferSize && requiredOrError < Self.maxBufferSize * 2 {
                    bufferSize = min(requiredOrError + Self.bufferPad, Self.maxBufferSize)
                    continue  // Grow and retry.
                } else {
                    throw VibeVoiceASRError.transcribeFailed(code: written)
                }
            }
        }
        throw VibeVoiceASRError.outputBufferTooSmall(requiredBytes: bufferSize)
    }

    /// Reads the audio duration (in seconds) of a WAV file via AVAudioFile.
    /// Used to size `max_new_tokens` so vibevoice.cpp doesn't truncate
    /// long transcripts at the 256-token default.
    private static func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let frameCount = file.length
        let sampleRate = file.processingFormat.sampleRate
        return sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }

    /// Free engine state. Optional — process exit also frees it.
    public func unload() {
        guard isLoaded else { return }
        vv_capi_unload()
        isLoaded = false
    }
}
