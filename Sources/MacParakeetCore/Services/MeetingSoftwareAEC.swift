import Foundation

struct MeetingSoftwareAECConfig: Sendable, Equatable {
    /// Adaptive filter length in samples at 16kHz.
    /// 384 samples ~= 24ms echo path tail.
    var filterLength: Int = 384
    /// NLMS adaptation learning rate.
    var learningRate: Float = 0.12
    /// Small constant to prevent divide-by-zero in normalization.
    var normalizationEpsilon: Float = 1e-6
    /// Enable adaptation only when far-end signal exceeds this RMS floor.
    var referenceSignalFloor: Float = 0.002
    /// Disable adaptation when near-end dominates by this multiplier.
    var doubleTalkNearVsFarRatio: Float = 2.5
    /// Light leakage so the model can forget stale room paths.
    var leakage: Float = 1e-5
    /// Update weights every Nth sample to reduce CPU.
    var adaptationStride: Int = 2
    /// Large offline buffers are passed through to avoid blocking actor hot paths.
    /// Meeting capture normally arrives in small callback-sized frames.
    var passthroughFrameThreshold: Int = 8_192

    static let `default` = MeetingSoftwareAECConfig()
}

/// Lightweight software AEC using NLMS adaptive filtering over the paired
/// speaker (reference) and microphone (observed) streams.
final class MeetingSoftwareAEC: @unchecked Sendable {
    private let config: MeetingSoftwareAECConfig
    private var weights: [Float]
    private var referenceHistory: [Float]
    private var referenceCursor: Int = 0
    private var referenceEnergy: Float = 0
    private var samplesSeen: Int = 0

    init(config: MeetingSoftwareAECConfig = .default) {
        self.config = config
        let length = max(config.filterLength, 32)
        self.weights = [Float](repeating: 0, count: length)
        self.referenceHistory = [Float](repeating: 0, count: length)
    }

    func reset() {
        weights = [Float](repeating: 0, count: weights.count)
        referenceHistory = [Float](repeating: 0, count: referenceHistory.count)
        referenceCursor = 0
        referenceEnergy = 0
        samplesSeen = 0
    }

    func process(microphone: [Float], speaker: [Float]) -> [Float] {
        guard !microphone.isEmpty else { return [] }
        if microphone.count > config.passthroughFrameThreshold {
            return microphone
        }

        let farRms = rms(speaker)
        let nearRms = rms(microphone)
        let shouldAdapt = farRms >= config.referenceSignalFloor
            && nearRms <= farRms * config.doubleTalkNearVsFarRatio

        var output = [Float](repeating: 0, count: microphone.count)
        for index in 0..<microphone.count {
            let farSample = index < speaker.count ? speaker[index] : 0
            pushReferenceSample(farSample)

            let estimatedEcho = estimateEcho()
            let cleanSample = microphone[index] - estimatedEcho
            output[index] = cleanSample.clamped(to: -1...1)

            if shouldAdapt, config.adaptationStride > 0, samplesSeen.isMultiple(of: config.adaptationStride) {
                adaptWeights(error: cleanSample)
            }
            samplesSeen += 1
        }
        return output
    }

    private func pushReferenceSample(_ sample: Float) {
        let replaced = referenceHistory[referenceCursor]
        referenceEnergy += (sample * sample) - (replaced * replaced)
        referenceHistory[referenceCursor] = sample
        referenceCursor = (referenceCursor + 1) % referenceHistory.count
    }

    private func estimateEcho() -> Float {
        var estimate: Float = 0
        var historyIndex = referenceCursor - 1
        if historyIndex < 0 {
            historyIndex += referenceHistory.count
        }

        for tap in 0..<weights.count {
            estimate += weights[tap] * referenceHistory[historyIndex]
            historyIndex -= 1
            if historyIndex < 0 {
                historyIndex += referenceHistory.count
            }
        }
        return estimate
    }

    private func adaptWeights(error: Float) {
        let denominator = max(referenceEnergy + config.normalizationEpsilon, config.normalizationEpsilon)
        let normalizedStep = config.learningRate * error / denominator
        let keep = max(0, 1 - config.leakage)

        var historyIndex = referenceCursor - 1
        if historyIndex < 0 {
            historyIndex += referenceHistory.count
        }

        for tap in 0..<weights.count {
            let x = referenceHistory[historyIndex]
            let updated = (weights[tap] * keep) + (normalizedStep * x)
            weights[tap] = updated

            historyIndex -= 1
            if historyIndex < 0 {
                historyIndex += referenceHistory.count
            }
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        var sampleCount: Int = 0
        for sample in samples where sample.isFinite {
            sumSquares += sample * sample
            sampleCount += 1
        }
        guard sampleCount > 0 else { return 0 }
        return sqrt(sumSquares / Float(sampleCount))
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
