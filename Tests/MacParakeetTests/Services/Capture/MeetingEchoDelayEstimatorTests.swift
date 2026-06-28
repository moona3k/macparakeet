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
        print("[AEC] delay estimate (far-end-only): \(estimate?.delaySamples ?? -1) samples, "
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
        print("[AEC] delay estimate (double-talk): \(estimate?.delaySamples ?? -1) samples, "
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

        print("[AEC] cancellation vs delay handling: static-zero \(String(format: "%.1f", zeroERLE)) dB "
            + "-> estimated-delay \(String(format: "%.1f", estimatedERLE)) dB")
        XCTAssertLessThan(zeroERLE, 5, "a large bulk delay is uncancellable with a static zero offset")
        XCTAssertGreaterThan(estimatedERLE, 20, "the estimated delay realigns the reference and cancels the echo")
    }
}
