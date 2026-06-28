import Foundation

/// The result of estimating how far the microphone's echo lags the system-audio
/// reference: the bulk delay in samples, plus a normalized-correlation confidence
/// in `0...1` (how strongly the reference explains the mic at that lag).
struct MeetingEchoDelayEstimate: Sendable, Equatable {
    let delaySamples: Int
    let confidence: Float
}

/// Estimates the bulk delay between the system-audio reference and the echo it
/// produces in the microphone, so the echo suppressor can read the reference at
/// the right offset.
///
/// Why this exists: the meeting measurement harness showed that reference/mic
/// time alignment is the dominant factor in whether cancellation works at all,
/// and that the bulk offset between the microphone clock and the ScreenCaptureKit
/// system-audio clock can be far larger than any practical adaptive filter can
/// span. A fixed `referenceDelaySamples` cannot track that. This recovers the
/// bulk delay from the audio itself; the downstream adaptive/neural filter then
/// only has to model the residual room response within its own length.
///
/// Method: a pre-emphasized normalized cross-correlation search. Pre-emphasis
/// (a one-tap high-pass) flattens the steep spectral tilt of speech so the
/// correlation peak is sharp rather than smeared; normalization makes the peak a
/// scale-independent confidence so a weak/absent echo can be rejected rather than
/// snapping to a spurious lag. The search is bulk-delay only (non-negative lags,
/// since echo always trails the played reference); sub-sample precision is left
/// to the adaptive filter, which absorbs a few samples of residual error.
struct MeetingEchoDelayEstimator: Sendable {
    /// Largest delay searched, in samples. Echo cannot precede the reference, so
    /// only `0...maxLagSamples` is considered.
    let maxLagSamples: Int
    /// One-tap pre-emphasis coefficient applied to both signals before
    /// correlating (`y[n] = x[n] - coeff * x[n-1]`). 0 disables it.
    let preEmphasis: Float
    /// Minimum normalized-correlation peak to trust an estimate; below this the
    /// estimator reports `nil` (no reliable echo to align to).
    let minConfidence: Float
    /// Number of samples correlated when scoring each lag. Larger is steadier but
    /// slower; the estimate uses the most-recent window that fits.
    let analysisWindowSamples: Int

    init(
        maxLagSamples: Int = 1_600,
        preEmphasis: Float = 0.95,
        minConfidence: Float = 0.3,
        analysisWindowSamples: Int = 8_192
    ) {
        self.maxLagSamples = max(0, maxLagSamples)
        self.preEmphasis = preEmphasis
        self.minConfidence = min(1, max(0, minConfidence))
        self.analysisWindowSamples = max(1, analysisWindowSamples)
    }

    /// Estimate the bulk delay at which `reference` best explains `microphone`.
    /// `reference[i]` and `microphone[i]` must share a stream timebase (sample `i`
    /// is the same instant in both). Returns `nil` when the inputs are too short
    /// or the best correlation peak is below `minConfidence`.
    func estimate(microphone: [Float], reference: [Float]) -> MeetingEchoDelayEstimate? {
        let count = min(microphone.count, reference.count)
        // Need room for the largest lag plus at least some window to correlate.
        guard count > maxLagSamples + 1 else { return nil }

        let micEmphasized = Self.preEmphasized(microphone, coefficient: preEmphasis, count: count)
        let refEmphasized = Self.preEmphasized(reference, coefficient: preEmphasis, count: count)

        // Use the most-recent window that fits after reserving `maxLagSamples` of
        // history so `reference[n - lag]` is always in range. The `count` guard
        // above keeps `count - maxLagSamples >= 2`, so `windowLength >= 1`.
        let windowLength = min(analysisWindowSamples, count - maxLagSamples)
        let windowStart = count - windowLength

        return micEmphasized.withUnsafeBufferPointer { mic in
            refEmphasized.withUnsafeBufferPointer { ref in
                var micEnergy: Float = 0
                for n in windowStart..<count {
                    micEnergy += mic[n] * mic[n]
                }
                guard micEnergy > 0 else { return nil }

                var refEnergies: [Float] = []
                refEnergies.reserveCapacity(maxLagSamples + 1)
                var currentRefEnergy: Float = 0
                for n in windowStart..<count {
                    let r = ref[n]
                    currentRefEnergy += r * r
                }
                refEnergies.append(currentRefEnergy)
                if maxLagSamples > 0 {
                    for lag in 1...maxLagSamples {
                        let removed = ref[count - lag]
                        let added = ref[windowStart - lag]
                        currentRefEnergy += added * added - removed * removed
                        refEnergies.append(max(0, currentRefEnergy))
                    }
                }

                var bestLag = 0
                var bestScore: Float = 0  // |normalized correlation|
                for lag in 0...maxLagSamples {
                    let refEnergy = refEnergies[lag]
                    guard refEnergy > 0 else { continue }
                    var cross: Float = 0
                    for n in windowStart..<count {
                        let r = ref[n - lag]
                        cross += mic[n] * r
                    }
                    let normalized = cross / (micEnergy * refEnergy).squareRoot()
                    let score = min(1, abs(normalized))
                    if score > bestScore {
                        bestScore = score
                        bestLag = lag
                    }
                }

                guard bestScore >= minConfidence else { return nil }
                return MeetingEchoDelayEstimate(delaySamples: bestLag, confidence: bestScore)
            }
        }
    }

    private static func preEmphasized(_ signal: [Float], coefficient: Float, count: Int) -> [Float] {
        guard coefficient != 0, count > 0 else { return Array(signal.prefix(count)) }
        var out = [Float](repeating: 0, count: count)
        out[0] = signal[0]
        for n in 1..<count {
            out[n] = signal[n] - coefficient * signal[n - 1]
        }
        return out
    }
}
