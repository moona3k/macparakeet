import FluidAudio

/// Bridges the Foundation-only ``ParakeetModelVariant`` preference to the
/// FluidAudio `AsrModelVersion` the runtime actually loads. Kept in the STT
/// layer so `SpeechEnginePreference.swift` never has to import CoreML/FluidAudio.
extension ParakeetModelVariant {
    /// The FluidAudio TDT `AsrModelVersion` this variant loads, or `nil` for
    /// ``unified`` — Parakeet Unified is a separate FluidAudio runtime with no
    /// `AsrModelVersion` (see ``usesUnifiedEngine``). Returning an optional
    /// makes the compiler flag every `AsrManager`-keyed site that must special-
    /// case the unified build instead of silently mishandling it.
    public var asrModelVersion: AsrModelVersion? {
        switch self {
        case .v3: .v3
        case .v2: .v2
        case .unified: nil
        }
    }

    /// Maps a loaded FluidAudio version back to the user-facing variant.
    /// Any non-`v2` version collapses to `.v3` — MacParakeet only exposes the
    /// v2/v3 pair, so the specialized CJK builds (if ever loaded) read as the
    /// multilingual default rather than crashing an exhaustive switch.
    public init(asrModelVersion: AsrModelVersion) {
        switch asrModelVersion {
        case .v2: self = .v2
        default: self = .v3
        }
    }
}
