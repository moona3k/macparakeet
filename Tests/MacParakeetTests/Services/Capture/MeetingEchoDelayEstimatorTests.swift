import Foundation
import Dispatch
import XCTest
@testable import MacParakeetCore

/// Characterizes the bulk reference-delay estimator and proves its product value:
/// a delay larger than the adaptive filter can span defeats cancellation with a
/// static offset, and recovering it from the audio restores it.
final class MeetingEchoDelayEstimatorTests: XCTestCase {

    private let estimator = MeetingEchoDelayEstimator()

    func testRecoversBulkDelayOnFarEndOnly() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: [(delay: 600, gain: 0.6)]))

        let estimate = estimator.estimate(microphone: scenario.mic, reference: scenario.farEnd)
        XCTAssertNotNil(estimate)
        print(
            "[AEC] delay estimate (far-end-only): \(estimate?.delaySamples ?? -1) samples, "
                + "confidence \(String(format: "%.2f", estimate?.confidence ?? 0))")
        XCTAssertEqual(estimate!.delaySamples, 600, accuracy: 2, "recovers the true bulk delay")
        XCTAssertGreaterThan(estimate!.confidence, 0.5, "a clean echo is a confident estimate")
    }

    func testRecoversBulkDelayUnderDoubleTalk() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "double-talk", nearEndActive: true, farEndActive: true,
            echoPath: MeetingAecEchoPath(
                taps: [(delay: 600, gain: 0.6), (delay: 640, gain: 0.25), (delay: 680, gain: 0.12)]))

        let estimate = estimator.estimate(microphone: scenario.mic, reference: scenario.farEnd)
        XCTAssertNotNil(estimate, "the echo is still findable when the local speaker overlaps it")
        print(
            "[AEC] delay estimate (double-talk): \(estimate?.delaySamples ?? -1) samples, "
                + "confidence \(String(format: "%.2f", estimate?.confidence ?? 0))")
        XCTAssertEqual(estimate!.delaySamples, 600, accuracy: 5, "locks onto the dominant tap despite near-end energy")
    }

    func testReturnsNilWhenRemoteIsSilent() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "near-end-only", nearEndActive: true, farEndActive: false,
            echoPath: MeetingAecEchoPath(taps: [(delay: 600, gain: 0.6)]))

        let estimate = estimator.estimate(microphone: scenario.mic, reference: scenario.farEnd)
        XCTAssertNil(estimate, "no reference energy means no delay to report, not a spurious lag")
    }

    func testReturnsNilOnSilence() {
        let zeros = [Float](repeating: 0, count: 24_000)
        XCTAssertNil(estimator.estimate(microphone: zeros, reference: zeros))
    }

    func testReturnsNilWhenInputShorterThanSearchRange() {
        let short = [Float](repeating: 0.1, count: 100)
        XCTAssertNil(
            estimator.estimate(microphone: short, reference: short),
            "too few samples to span the lag search returns nil rather than a degenerate peak")
    }

    func testConfidenceContractIsClampedToNormalizedRange() {
        let signal = (0..<256).map { sin(Float($0) * 0.1) }
        let estimator = MeetingEchoDelayEstimator(
            maxLagSamples: 0,
            minConfidence: 2,
            analysisWindowSamples: 128
        )

        let estimate = estimator.estimate(microphone: signal, reference: signal)

        XCTAssertNotNil(estimate, "minConfidence above 1 is clamped to the normalized range")
        XCTAssertLessThanOrEqual(estimate!.confidence, 1)
        XCTAssertGreaterThanOrEqual(estimate!.confidence, 0)
    }

    func testKnownLagConfidenceMatchesScalarFormula() {
        let farOnly = MeetingAecScenarioFactory.make(
            name: "far-end-only",
            nearEndActive: false,
            farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: [(delay: 600, gain: 0.6)])
        )
        let doubleTalk = MeetingAecScenarioFactory.make(
            name: "double-talk",
            nearEndActive: true,
            farEndActive: true,
            echoPath: MeetingAecEchoPath(
                taps: [(delay: 600, gain: 0.6), (delay: 640, gain: 0.25), (delay: 680, gain: 0.12)])
        )
        let representative = Self.makeRepresentativeFixture()
        let cases = [
            (name: "far-end-only", microphone: farOnly.mic, reference: farOnly.farEnd, delay: 600),
            (name: "double-talk", microphone: doubleTalk.mic, reference: doubleTalk.farEnd, delay: 600),
            (
                name: "representative-window", microphone: representative.microphone,
                reference: representative.reference, delay: representative.delay
            ),
        ]

        for testCase in cases {
            let estimate = estimator.estimate(microphone: testCase.microphone, reference: testCase.reference)

            XCTAssertNotNil(estimate, testCase.name)
            XCTAssertEqual(estimate!.delaySamples, testCase.delay, "keeps the same chosen lag for \(testCase.name)")
            XCTAssertEqual(
                estimate!.confidence,
                Self.scalarConfidence(
                    microphone: testCase.microphone,
                    reference: testCase.reference,
                    lag: testCase.delay,
                    estimator: estimator
                )!,
                accuracy: 0.0001,
                "keeps the normalized-correlation value equivalent to the scalar formula for \(testCase.name)"
            )
        }
    }

    func testRepresentativeEstimateCompletesWithinSanityBudget() {
        let fixture = Self.makeRepresentativeFixture()
        _ = estimator.estimate(microphone: fixture.microphone, reference: fixture.reference)

        let start = DispatchTime.now().uptimeNanoseconds
        let estimate = estimator.estimate(microphone: fixture.microphone, reference: fixture.reference)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate!.delaySamples, fixture.delay)
        print("[AEC] estimator representative call: \(String(format: "%.2f", elapsedMs)) ms")
        XCTAssertLessThan(
            elapsedMs,
            200,
            "representative delay estimation should stay comfortably below offline-render throughput limits"
        )
    }

    /// The money test: a large bulk delay (600 samples) that a fixed zero offset
    /// cannot align. Uses the oracle subtractor so the result reflects *alignment*
    /// alone, not a filter's incidental ability to predict a periodic reference —
    /// at static zero the subtraction is unaligned and removes no echo (it can
    /// even add energy), while feeding the *estimated* delay restores cancellation.
    func testEstimatedDelayRestoresCancellationBeyondStaticAlignment() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: [(delay: 600, gain: 0.6)]),
            noiseLevel: 0.0001)
        let window = scenario.steadyStateWindow

        let staticZero = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6), referenceDelaySamples: 0)
        let zeroOut = MeetingAecRunner.run(staticZero, scenario: scenario)
        let zeroERLE = MeetingAecMetrics.erleDB(mic: scenario.mic, output: zeroOut, over: window)

        let estimate = estimator.estimate(microphone: scenario.mic, reference: scenario.farEnd)
        XCTAssertNotNil(estimate)
        let estimated = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6),
            referenceDelaySamples: estimate!.delaySamples)
        let estimatedOut = MeetingAecRunner.run(estimated, scenario: scenario)
        let estimatedERLE = MeetingAecMetrics.erleDB(mic: scenario.mic, output: estimatedOut, over: window)

        print(
            "[AEC] cancellation vs delay handling: static-zero \(String(format: "%.1f", zeroERLE)) dB "
                + "-> estimated-delay \(String(format: "%.1f", estimatedERLE)) dB")
        XCTAssertLessThan(zeroERLE, 5, "a large bulk delay is uncancellable with a static zero offset")
        XCTAssertGreaterThan(estimatedERLE, 20, "the estimated delay realigns the reference and cancels the echo")
    }

    private static func makeRepresentativeFixture(
        delay: Int = 600,
        maxLagSamples: Int = 1_600,
        analysisWindowSamples: Int = 8_192
    ) -> (microphone: [Float], reference: [Float], delay: Int) {
        let sampleCount = maxLagSamples + analysisWindowSamples
        let scenario = MeetingAecScenarioFactory.make(
            name: "representative-estimator-window",
            nearEndActive: true,
            farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: [(delay: delay, gain: 0.6)]),
            sampleCount: sampleCount,
            noiseLevel: 0.0001
        )
        return (scenario.mic, scenario.farEnd, delay)
    }

    private static func scalarConfidence(
        microphone: [Float],
        reference: [Float],
        lag: Int,
        estimator: MeetingEchoDelayEstimator
    ) -> Float? {
        let count = min(microphone.count, reference.count)
        guard count > estimator.maxLagSamples + 1, lag >= 0, lag <= estimator.maxLagSamples else { return nil }

        let micEmphasized = preEmphasized(microphone, coefficient: estimator.preEmphasis, count: count)
        let refEmphasized = preEmphasized(reference, coefficient: estimator.preEmphasis, count: count)
        let windowLength = min(estimator.analysisWindowSamples, count - estimator.maxLagSamples)
        let windowStart = count - windowLength

        var micEnergy: Float = 0
        var refEnergy: Float = 0
        var cross: Float = 0
        for n in windowStart..<count {
            let mic = micEmphasized[n]
            let ref = refEmphasized[n - lag]
            micEnergy += mic * mic
            refEnergy += ref * ref
            cross += mic * ref
        }
        guard micEnergy > 0, refEnergy > 0 else { return nil }
        let normalized = cross / (micEnergy * refEnergy).squareRoot()
        return min(1, abs(normalized))
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
