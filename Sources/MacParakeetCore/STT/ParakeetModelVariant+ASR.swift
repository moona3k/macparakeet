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
        // Omi Med is a v2 fine-tune with the identical component contract, so
        // the shared TDT runtime treats it as `.v2` — only the weights (loaded
        // from `OmiMedParakeetModel`'s local directory, never the stock v2
        // download cache) differ.
        case .omiMedV1: .v2
        }
    }

    /// Maps a loaded FluidAudio version back to the user-facing variant.
    /// Any non-`v2` version collapses to `.v3` — MacParakeet only exposes the
    /// v2/v3 pair, so the specialized CJK builds (if ever loaded) read as the
    /// multilingual default rather than crashing an exhaustive switch.
    /// `.v2` is ambiguous here (Omi Med also runs as `.v2`); callers that can
    /// know the active user-facing variant should prefer it over this mapping.
    public init(asrModelVersion: AsrModelVersion) {
        switch asrModelVersion {
        case .v2: self = .v2
        default: self = .v3
        }
    }
}
