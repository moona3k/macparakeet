import XCTest
@testable import MacParakeetCore

/// Measurement-first characterization of meeting AEC. These tests do not pin a
/// shipping behavior; they establish a yardstick (ERLE, near-end fidelity, delay
/// sensitivity) on ground-truth fixtures so a real engine can later be scored on
/// the same scenarios. The `print` summaries are the deliverable — the first
/// concrete numbers behind "will an echo canceller actually help us."
final class MeetingAecMeasurementTests: XCTestCase {

    // Single dominant tap, for the alignment/oracle experiments.
    private let singleTapEcho = MeetingAecEchoPath(taps: [(delay: 120, gain: 0.6)])
    // A short multi-tap room response, for the realistic baseline experiments.
    private let multiTapEcho = MeetingAecEchoPath(
        taps: [(delay: 120, gain: 0.6), (delay: 180, gain: 0.25), (delay: 240, gain: 0.12)]
    )
    private let trueDelay = 120

    // MARK: Harness sanity — pass-through changes nothing, so ERLE is ~0 dB.

    func testPassthroughLeavesEchoUntouched() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true, echoPath: singleTapEcho)
        let output = MeetingAecRunner.run(PassthroughMicConditioner(), scenario: scenario)

        XCTAssertEqual(output.count, scenario.sampleCount, "output must align 1:1 with the mic input")
        let erle = MeetingAecMetrics.erleDB(
            mic: scenario.mic, output: output, over: scenario.steadyStateWindow)
        XCTAssertEqual(erle, 0, accuracy: 0.5, "pass-through removes no echo")
    }

    // MARK: Oracle — perfect alignment cancels; mis-set delay collapses.

    func testOracleWithCorrectReferenceDelayCancelsEcho() {
        // Low noise floor so this isolates *alignment* quality, not the
        // noise floor that ultimately caps any canceller.
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: singleTapEcho, noiseLevel: 0.0001)
        let suppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6),
            referenceDelaySamples: trueDelay)
        let output = MeetingAecRunner.run(suppressor, scenario: scenario)

        let erle = MeetingAecMetrics.erleDB(
            mic: scenario.mic, output: output, over: scenario.steadyStateWindow)
        print("[AEC] oracle @ correct delay (\(trueDelay)): ERLE = \(fmt(erle)) dB")
        XCTAssertGreaterThan(erle, 30, "with the reference aligned, the echo is almost entirely removed")
    }

    func testOracleWithMisalignedReferenceDelayFailsToCancel() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: singleTapEcho, noiseLevel: 0.0001)
        let suppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6),
            referenceDelaySamples: trueDelay - 40)  // 2.5 ms off at 16 kHz
        let output = MeetingAecRunner.run(suppressor, scenario: scenario)

        let erle = MeetingAecMetrics.erleDB(
            mic: scenario.mic, output: output, over: scenario.steadyStateWindow)
        print("[AEC] oracle @ misaligned delay (\(trueDelay - 40)): ERLE = \(fmt(erle)) dB")
        XCTAssertLessThan(erle, 6, "a 2.5 ms reference misalignment defeats cancellation — alignment is the #1 risk")
    }

    /// Prints ERLE across a sweep of reference delays so the sharp peak at the
    /// true echo delay is visible. Characterization, not a hard gate.
    func testReferenceDelaySensitivitySweep() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: singleTapEcho, noiseLevel: 0.0001)
        let offsets = [-120, -80, -40, -20, -10, 0, 10, 20, 40, 80, 120]
        var best = (offset: 0, erle: -Double.infinity)
        print("[AEC] reference-delay sensitivity sweep (true delay = \(trueDelay) samples):")
        for offset in offsets {
            let delay = max(0, trueDelay + offset)
            let suppressor = StreamingMeetingEchoSuppressor(
                processor: MeetingAecOracleSubtractor(gain: 0.6), referenceDelaySamples: delay)
            let output = MeetingAecRunner.run(suppressor, scenario: scenario)
            let erle = MeetingAecMetrics.erleDB(
                mic: scenario.mic, output: output, over: scenario.steadyStateWindow)
            print("        offset \(pad(offset)) samples -> ERLE \(fmt(erle)) dB")
            if erle > best.erle { best = (offset, erle) }
        }
        XCTAssertEqual(best.offset, 0, "cancellation must peak exactly at the true echo delay")
    }

    // MARK: NLMS baseline — silent remote is a no-op; far-end echo is reduced.

    func testNLMSLeavesLocalVoiceUntouchedWhenRemoteIsSilent() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "near-end-only", nearEndActive: true, farEndActive: false, echoPath: multiTapEcho)
        let suppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecNLMSProcessor(), referenceDelaySamples: trueDelay)
        let output = MeetingAecRunner.run(suppressor, scenario: scenario)

        let drift = MeetingAecMetrics.maxAbsDifference(output, scenario.mic)
        XCTAssertLessThan(drift, 1e-5, "a silent reference must pass the recorded mic through unchanged")
    }

    func testNLMSReducesFarEndEcho() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true, echoPath: multiTapEcho)
        let suppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecNLMSProcessor(), referenceDelaySamples: trueDelay)
        let output = MeetingAecRunner.run(suppressor, scenario: scenario)

        let erle = MeetingAecMetrics.erleDB(
            mic: scenario.mic, output: output, over: scenario.steadyStateWindow)
        print("[AEC] NLMS far-end-only steady-state ERLE = \(fmt(erle)) dB")
        XCTAssertGreaterThan(erle, 8, "the classical baseline removes meaningful echo with no near-end present")
    }

    // MARK: NLMS double-talk — the hard case, quantified.

    func testNLMSDoubleTalkQuantifiesTheTradeoff() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "double-talk", nearEndActive: true, farEndActive: true, echoPath: multiTapEcho)
        let window = scenario.steadyStateWindow

        let suppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecNLMSProcessor(), referenceDelaySamples: trueDelay)
        let processed = MeetingAecRunner.run(suppressor, scenario: scenario)
        let passthrough = MeetingAecRunner.run(PassthroughMicConditioner(), scenario: scenario)

        let nlmsError = MeetingAecMetrics.nearEndErrorDB(
            output: processed, nearEnd: scenario.nearEnd, over: window)
        let rawError = MeetingAecMetrics.nearEndErrorDB(
            output: passthrough, nearEnd: scenario.nearEnd, over: window)

        // For contrast: the same filter with no competing near-end.
        let cleanScenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true, echoPath: multiTapEcho)
        let cleanSuppressor = StreamingMeetingEchoSuppressor(
            processor: MeetingAecNLMSProcessor(), referenceDelaySamples: trueDelay)
        let cleanOut = MeetingAecRunner.run(cleanSuppressor, scenario: cleanScenario)
        let singleTalkERLE = MeetingAecMetrics.erleDB(
            mic: cleanScenario.mic, output: cleanOut, over: cleanScenario.steadyStateWindow)

        let improvement = rawError - nlmsError  // positive = NLMS reduced the error
        print("[AEC] double-talk near-end error: raw \(fmt(rawError)) dB -> NLMS \(fmt(nlmsError)) dB "
            + "(improvement \(fmt(improvement)) dB); single-talk ERLE for reference \(fmt(singleTalkERLE)) dB")

        // The honest, well-known result: a naive NLMS with NO double-talk
        // detector barely helps — and here slightly hurts — when the local voice
        // overlaps the echo, because the near-end perturbs adaptation. This is
        // the failure a shipping engine must beat, and the reason double-talk is
        // a release gate rather than an afterthought.
        XCTAssertLessThan(improvement, 2.0,
            "naive NLMS (no double-talk detector) does not meaningfully reduce error under continuous double-talk")
        XCTAssertGreaterThan(singleTalkERLE - improvement, 10.0,
            "double-talk extracts a large penalty vs the no-near-end case (the local voice perturbs adaptation)")
    }

    // MARK: Formatting helpers

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func pad(_ value: Int) -> String {
        String(format: "%+4d", value)
    }
}
