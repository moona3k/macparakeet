import Foundation

/// Shared live-dictation surface for native streaming engines.
///
/// Nemotron multilingual, Nemotron English, and Parakeet Unified each wrap a
/// FluidAudio streaming manager that emits partial transcripts during capture.
/// `STTRuntime` uses this protocol to hold the active streaming engine without
/// coupling the live dictation lifecycle to a concrete model family.
///
/// `: Actor` keeps the requirements actor-isolated and makes
/// `any NativeLiveDictating` `Sendable`.
protocol NativeLiveDictating: Actor {
    /// Whether the underlying models are loaded and ready to stream.
    func isReady() -> Bool

    /// Starts a live dictation session, delivering rolling partial transcripts
    /// through `onPartial`. `language` is honored by engines with a language
    /// hint surface and ignored by English-only builds.
    func beginLiveDictation(
        language: String?,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws

    /// Feeds the next slice of 16 kHz mono Float32 capture samples.
    func processLiveDictationSamples(_ samples: [Float]) async throws

    /// Flushes remaining audio and returns the final transcript for the session.
    func finishLiveDictation() async throws -> STTResult

    /// Tears the session down without producing a result.
    func cancelLiveDictation() async
}
