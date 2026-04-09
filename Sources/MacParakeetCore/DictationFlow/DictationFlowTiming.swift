import Foundation

/// Shared timing values used across the dictation flow.
/// Keeping these in Core gives state/effects and UI a single source of truth.
public enum DictationFlowTiming {
    /// How long the no-speech terminal state should remain visible before dismiss.
    public static let noSpeechDismissSeconds: Double = 2.5
}
