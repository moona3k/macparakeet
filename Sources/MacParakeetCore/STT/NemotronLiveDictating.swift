import Foundation

/// Shared live-dictation surface for the two Nemotron builds.
///
/// Both `NemotronEngine` (multilingual) and `NemotronEnglishEngine` wrap
/// FluidAudio streaming managers that emit partial transcripts during capture,
/// so `STTRuntime` can route a live dictation session to whichever build is
/// active without knowing the concrete engine type. The English build wraps a
/// buffer-based manager and the multilingual build a sample-based one, but both
/// expose the same begin → append → finish/cancel lifecycle behind this
/// protocol.
///
/// `: Actor` keeps the requirements actor-isolated (both engines are actors) and
/// makes `any NemotronLiveDictating` `Sendable`.
protocol NemotronLiveDictating: Actor {
    /// Whether the underlying models are loaded and ready to stream.
    func isReady() -> Bool

    /// Starts a live dictation session, delivering rolling partial transcripts
    /// through `onPartial`. `language` is honored by the multilingual build and
    /// ignored by the English-only build.
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
