import FluidAudio
import Foundation

/// FluidAudio `ASRConfig` for MacParakeet's Parakeet TDT `AsrManager`s.
///
/// Long files are split into 15 s windows. FluidAudio's default runs four of
/// those windows at once on the same compiled `MLModel`s. macOS 14's Neural
/// Engine prediction path is not reentrant for that (issue #997), and
/// ``ANEInferenceGate`` only wraps the outer `transcribe` call.
enum ParakeetTDTASRConfig {
    static func make(
        serializationRequired: Bool = ANEInferenceGate.serializationRequiredForCurrentOS
    ) -> ASRConfig {
        guard serializationRequired else { return .default }
        return ASRConfig(parallelChunkConcurrency: 1)
    }
}
