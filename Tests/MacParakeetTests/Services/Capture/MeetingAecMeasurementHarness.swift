import Foundation
@testable import MacParakeetCore

// MARK: - Meeting AEC measurement harness
//
// A self-contained, deterministic test harness for *measuring* meeting acoustic
// echo cancellation, independent of any specific engine. The point is to turn
// "an echo canceller should help" into numbers (ERLE, near-end fidelity,
// delay sensitivity) on fixtures with full ground truth, so that when a real
// engine (LocalVQE, WebRTC AEC3, ...) is dropped behind the existing
// `MicConditioning` seam it can be scored on the same yardstick.
//
// Why synthetic fixtures first: a real Zoom recording does not tell you the
// separate near-end, far-end, and echo signals, so you cannot cleanly attribute
// "removed echo" vs "damaged the local voice." Here every component is known,
// so the metrics are exact. Real-recording validation is the *next* step, not
// the first one.
//
// Everything here is test-target only; production behavior is unchanged.

// MARK: Deterministic RNG

/// SplitMix64 — a tiny, deterministic PRNG so fixtures are byte-stable across
/// runs and CI. (`Date`/`arc4random` would make the metrics non-reproducible.)
struct MeetingAecRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextBits() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Float {
        Float(nextBits() >> 40) * (1.0 / Float(1 << 24))
    }

    /// Uniform in [-1, 1).
    mutating func nextSymmetric() -> Float {
        nextUnit() * 2 - 1
    }
}

// MARK: Signal synthesis

enum MeetingAecSignal {
    /// A deterministic, speech-like signal: a few "formant" tones summed under a
    /// slow syllabic amplitude envelope, plus a whisper of noise. Different
    /// `formants`/`seed` pairs produce decorrelated talkers, which is what lets
    /// the metrics separate "cancelled the far-end echo" from "kept the near-end
    /// voice." Not real speech — just colored, voiced-like, and reproducible.
    static func voiceLike(
        sampleCount: Int,
        sampleRate: Float,
        formants: [Float],
        seed: UInt64,
        amplitude: Float = 0.3,
        syllableHz: Float = 3.0
    ) -> [Float] {
        var rng = MeetingAecRandom(seed: seed)
        let phases = formants.map { _ in rng.nextUnit() * 2 * Float.pi }
        let phaseOffset = Float(seed % 7)
        let twoPi = 2 * Float.pi
        let formantCount = Float(max(formants.count, 1))

        var out = [Float](repeating: 0, count: sampleCount)
        for n in 0..<sampleCount {
            let t = Float(n) / sampleRate
            // Syllabic envelope with a floor so energy never fully vanishes.
            let env = powf(max(0, 0.5 + 0.5 * sinf(twoPi * syllableHz * t + phaseOffset)), 1.5)
            var s: Float = 0
            for (i, f) in formants.enumerated() {
                s += sinf(twoPi * f * t + phases[i])
            }
            s /= formantCount
            out[n] = amplitude * env * s + 0.002 * rng.nextSymmetric()
        }
        return out
    }

    static func silence(sampleCount: Int) -> [Float] {
        [Float](repeating: 0, count: sampleCount)
    }
}

/// A sparse acoustic echo path: speaker -> air -> mic, modeled as a few delayed,
/// attenuated copies of the far-end (a short impulse response). `nonlinearity`
/// adds a mild cubic term to mimic small-speaker distortion — set to 0 for the
/// linear baseline (a linear filter like NLMS can only fully chase linear echo;
/// nonlinear residue is part of why neural AEC is expected to win, and is a
/// fixture to add when a neural adapter lands).
struct MeetingAecEchoPath {
    let taps: [(delay: Int, gain: Float)]
    var nonlinearity: Float = 0

    func apply(to farEnd: [Float]) -> [Float] {
        let driven: [Float]
        if nonlinearity == 0 {
            driven = farEnd
        } else {
            driven = farEnd.map { $0 + nonlinearity * $0 * $0 * $0 }
        }
        var out = [Float](repeating: 0, count: driven.count)
        for tap in taps {
            guard tap.delay >= 0, tap.delay < driven.count else { continue }
            for i in tap.delay..<driven.count {
                out[i] += tap.gain * driven[i - tap.delay]
            }
        }
        return out
    }
}

// MARK: Scenario

/// One synthetic scenario with full ground truth retained, so metrics can be
/// computed exactly. `farEnd` doubles as the system-audio reference the AEC
/// receives. `mic` = nearEnd + echo(farEnd) + noise.
struct MeetingAecScenario {
    let name: String
    let sampleRate: Float
    let nearEnd: [Float]
    let farEnd: [Float]
    let echo: [Float]
    let mic: [Float]

    var sampleCount: Int { mic.count }

    /// Steady-state analysis window: the second half (so adaptive filters are
    /// scored after convergence, not during warm-up), minus the final frame. The
    /// streaming suppressor emits any trailing samples that do not fill a
    /// processor frame *raw* via `flush()`; excluding the last `maxFrameSize`
    /// samples keeps that uncancelled tail out of the measurement. (256 is the
    /// LocalVQE hop and every processor's frame size here.)
    static let maxFrameSize = 256
    var steadyStateWindow: Range<Int> { (sampleCount / 2)..<(sampleCount - Self.maxFrameSize) }
}

enum MeetingAecScenarioFactory {
    static let sampleRate: Float = 16_000
    // Decorrelated talkers: distinct fundamentals/formants + distinct seeds.
    static let nearFormants: [Float] = [110, 220, 660, 1_700]
    static let farFormants: [Float] = [150, 300, 900, 2_400]
    static let nearSeed: UInt64 = 0xA11CE
    static let farSeed: UInt64 = 0x0B0B
    static let noiseSeed: UInt64 = 0x015E

    static func make(
        name: String,
        nearEndActive: Bool,
        farEndActive: Bool,
        echoPath: MeetingAecEchoPath,
        sampleCount: Int = 24_000,
        noiseLevel: Float = 0.001
    ) -> MeetingAecScenario {
        let near = nearEndActive
            ? MeetingAecSignal.voiceLike(
                sampleCount: sampleCount, sampleRate: sampleRate,
                formants: nearFormants, seed: nearSeed)
            : MeetingAecSignal.silence(sampleCount: sampleCount)
        let far = farEndActive
            ? MeetingAecSignal.voiceLike(
                sampleCount: sampleCount, sampleRate: sampleRate,
                formants: farFormants, seed: farSeed)
            : MeetingAecSignal.silence(sampleCount: sampleCount)
        let echo = echoPath.apply(to: far)

        var noise = MeetingAecRandom(seed: noiseSeed)
        var mic = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            mic[i] = near[i] + echo[i] + noiseLevel * noise.nextSymmetric()
        }
        return MeetingAecScenario(
            name: name, sampleRate: sampleRate,
            nearEnd: near, farEnd: far, echo: echo, mic: mic)
    }
}

// MARK: Metrics

enum MeetingAecMetrics {
    static func power(_ signal: [Float], over window: Range<Int>) -> Double {
        guard !window.isEmpty else { return 0 }
        var acc = 0.0
        for i in window {
            let v = Double(signal[i])
            acc += v * v
        }
        return acc / Double(window.count)
    }

    /// Echo Return Loss Enhancement (dB): how much residual power dropped vs the
    /// unprocessed mic. Higher = more echo removed. Meaningful for far-end-only
    /// fixtures, where any mic energy is echo by construction.
    static func erleDB(mic: [Float], output: [Float], over window: Range<Int>) -> Double {
        let micPower = power(mic, over: window)
        let outPower = power(output, over: window)
        return 10 * log10(micPower / max(outPower, 1e-12))
    }

    /// Near-end error (dB relative to near-end power): how far the output drifts
    /// from the ideal "just the local voice" signal. Captures BOTH residual echo
    /// and damage to the local voice, so it is the honest double-talk score.
    /// Lower (more negative) is better; 0 dB means the error is as loud as the
    /// voice we wanted to keep.
    static func nearEndErrorDB(output: [Float], nearEnd: [Float], over window: Range<Int>) -> Double {
        guard !window.isEmpty else { return 0 }
        var errAcc = 0.0
        for i in window {
            let d = Double(output[i]) - Double(nearEnd[i])
            errAcc += d * d
        }
        let errPower = errAcc / Double(window.count)
        let nearPower = power(nearEnd, over: window)
        return 10 * log10(errPower / max(nearPower, 1e-12))
    }

    /// Largest absolute sample deviation from a reference signal. Used to assert
    /// exact pass-through (e.g. silent reference must not touch the local voice).
    static func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
        var worst: Float = 0
        for i in 0..<min(a.count, b.count) {
            worst = max(worst, abs(a[i] - b[i]))
        }
        return worst
    }
}

// MARK: Runner

enum MeetingAecRunner {
    /// Streams a scenario through a conditioner in irregular chunks (exercising
    /// the real frame-carry/flush path) and returns output aligned 1:1 with the
    /// mic input. Resets the conditioner first so each measurement is independent.
    static func run(
        _ conditioner: any MicConditioning,
        scenario: MeetingAecScenario,
        chunkSizes: [Int] = [320, 256, 160, 512, 128]
    ) -> [Float] {
        conditioner.reset()
        var output: [Float] = []
        output.reserveCapacity(scenario.sampleCount)
        var cursor = 0
        var sizeIndex = 0
        while cursor < scenario.sampleCount {
            let size = max(1, chunkSizes[sizeIndex % chunkSizes.count])
            sizeIndex += 1
            let end = min(cursor + size, scenario.sampleCount)
            let mic = Array(scenario.mic[cursor..<end])
            let reference = Array(scenario.farEnd[cursor..<end])
            output += conditioner.condition(
                microphone: mic, speaker: reference, hasSpeakerReference: true)
            cursor = end
        }
        output += conditioner.flush()
        return output
    }
}

// MARK: Reference echo processors (baselines, test-only)

/// A normalized least-mean-squares adaptive filter — the classical, non-neural
/// AEC baseline (the Corti FDAF/NLMS family). It learns the echo path from the
/// far-end reference and subtracts its estimate. Deliberately has NO double-talk
/// detector, so the harness can *measure* the well-known failure: during
/// double-talk the local voice perturbs adaptation. Establishes the floor a
/// neural engine must beat.
final class MeetingAecNLMSProcessor: MeetingEchoSuppressing, @unchecked Sendable {
    let name = "nlms-baseline"
    let sampleRate: Int
    let frameSize: Int

    private let filterLength: Int
    private let stepSize: Float
    private let regularization: Float
    private var weights: [Float]
    private var history: [Float]  // history[0] = newest reference sample
    private let lock = NSLock()

    init(
        sampleRate: Int = 16_000,
        frameSize: Int = 256,
        filterLength: Int = 256,
        stepSize: Float = 0.5,
        regularization: Float = 1e-6
    ) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.filterLength = max(1, filterLength)
        self.stepSize = stepSize
        self.regularization = regularization
        self.weights = [Float](repeating: 0, count: max(1, filterLength))
        self.history = [Float](repeating: 0, count: max(1, filterLength))
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in weights.indices { weights[i] = 0 }
        for i in history.indices { history[i] = 0 }
    }

    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws {
        lock.lock(); defer { lock.unlock() }
        for n in 0..<frameSize {
            // Shift the new reference sample into history[0].
            var k = filterLength - 1
            while k > 0 {
                history[k] = history[k - 1]
                k -= 1
            }
            history[0] = reference[n]

            var estimate: Float = 0
            var energy: Float = 0
            for j in 0..<filterLength {
                estimate += weights[j] * history[j]
                energy += history[j] * history[j]
            }
            let error = microphone[n] - estimate
            output[n] = error

            let scale = stepSize * error / (energy + regularization)
            if scale != 0 {
                for j in 0..<filterLength {
                    weights[j] += scale * history[j]
                }
            }
        }
    }
}

/// An oracle that knows the true single-tap echo gain and subtracts it from the
/// (already delay-aligned) reference. It cannot exist in production — it is the
/// harness's "perfect alignment" yardstick: with the correct reference delay it
/// cancels almost completely, and a mis-set delay collapses it, which is exactly
/// how it characterizes the pipeline's #1 risk (mic/reference time alignment).
final class MeetingAecOracleSubtractor: MeetingEchoSuppressing, @unchecked Sendable {
    let name = "oracle-subtractor"
    let sampleRate: Int
    let frameSize: Int
    private let gain: Float

    init(sampleRate: Int = 16_000, frameSize: Int = 256, gain: Float) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.gain = gain
    }

    func reset() {}

    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws {
        for n in 0..<frameSize {
            output[n] = microphone[n] - gain * reference[n]
        }
    }
}
