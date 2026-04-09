import Foundation
import MacParakeetCore

/// Centralized no-speech animation timings.
/// Anchored to the shared no-speech dismiss window from Core to prevent drift.
enum NoSpeechAnimationTiming {
    static let dismissSeconds = DictationFlowTiming.noSpeechDismissSeconds

    // MerkabaDissipateView phases
    static let merkabaSettleDuration = 0.45
    static let merkabaDissolveDuration = 0.4
    static let merkabaDissolveDelay = 0.3
    static let merkabaExhaleDuration = 0.35
    static let merkabaExhaleDelay = 0.55

    // NoSpeechContentView phases
    static let leafFadeInDuration = 0.5
    static let leafFadeInDelay = 0.35
    static let leafDriftDuration = 1.6
    static let leafDriftDelay = 0.35
    static let textFadeInDuration = 0.4
    static let textFadeInDelay = 0.75
    static let leafRecedeDuration = 0.55
    static let leafRecedeDelay = 1.5

    static let completionBufferSeconds = 0.2

    static let estimatedAnimationCompletionSeconds = max(
        max(merkabaSettleDuration, merkabaDissolveDelay + merkabaDissolveDuration),
        max(
            merkabaExhaleDelay + merkabaExhaleDuration,
            max(
                leafFadeInDelay + leafFadeInDuration,
                max(
                    leafDriftDelay + leafDriftDuration,
                    max(textFadeInDelay + textFadeInDuration, leafRecedeDelay + leafRecedeDuration)
                )
            )
        )
    )

#if DEBUG
    static let isDismissWindowSufficient =
        estimatedAnimationCompletionSeconds + completionBufferSeconds <= dismissSeconds
#endif
}
