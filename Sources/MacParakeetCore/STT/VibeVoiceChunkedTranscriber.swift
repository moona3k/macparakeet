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
        // Implemented in Task 10 (after orchestration tests are written).
        throw STTError.transcriptionFailed("VibeVoiceChunkedTranscriber.transcribe not yet implemented")
    }
}
