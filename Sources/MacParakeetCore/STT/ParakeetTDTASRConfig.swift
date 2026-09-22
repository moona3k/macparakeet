import CoreML
import FluidAudio
import Foundation

/// FluidAudio `ASRConfig` and load-time encoder units for MacParakeet's
/// Parakeet TDT `AsrManager`s.
///
/// Long files are split into 15 s windows. FluidAudio's default runs four of
/// those windows at once on the same compiled `MLModel`s. macOS 14's Neural
/// Engine prediction path is not reentrant (issue #997).
/// ``ANEInferenceGate`` only wraps the outer `transcribe` call, so this type
/// also sets `parallelChunkConcurrency: 1` and moves the conformer encoder to
/// `.cpuAndGPU` on 14. 15+ keeps FluidAudio defaults. One shared model bundle,
/// so Sonoma dictation uses the same encoder units.
enum ParakeetTDTASRConfig {
    static func make(
        serializationRequired: Bool = ANEInferenceGate.serializationRequiredForCurrentOS
    ) -> ASRConfig {
        guard serializationRequired else { return .default }
        return ASRConfig(parallelChunkConcurrency: 1)
    }

    /// `nil` leaves FluidAudio's ANE encoder default. `.cpuAndGPU` on macOS 14.
    static func encoderComputeUnits(
        serializationRequired: Bool = ANEInferenceGate.serializationRequiredForCurrentOS
    ) -> MLComputeUnits? {
        guard serializationRequired else { return nil }
        return .cpuAndGPU
    }
}
