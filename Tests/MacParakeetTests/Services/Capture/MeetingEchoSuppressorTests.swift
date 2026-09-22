import XCTest
@testable import MacParakeetCore

final class MeetingEchoSuppressorTests: XCTestCase {
    func testProcessesFullReferenceFramesAndHoldsTailForNextCall() {
        let processor = SubtractingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        let output = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2, 0.9],
            speaker: [0.1, 0.1, 0.2, 0.2, 0.8],
            hasSpeakerReference: true
        )

        XCTAssertEqual(output.count, 4, "tail samples that do not fill a processor frame are held, not emitted raw")
        XCTAssertEqual(output.map { rounded($0) }, [0.4, 0.3, 0.1, 0.0])
        XCTAssertEqual(
            suppressor.diagnostics,
            MeetingEchoSuppressionDiagnostics(
                processorName: "subtracting-test",
                loaded: true,
                micFrames: 1,
                processedFrames: 1,
                rawFallbackFrames: 0,
                fullReferenceFrames: 1,
                partialReferenceFrames: 0,
                missingReferenceFrames: 0,
                processingFailures: 0
            )
        )
    }

    func testHeldTailJoinsNextCallIntoContiguousFrames() {
        let processor = RecordingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        let first = suppressor.condition(
            microphone: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            speaker: [1.1, 1.2, 1.3, 1.4, 1.5, 1.6],
            hasSpeakerReference: true
        )
        let second = suppressor.condition(
            microphone: [0.7, 0.8],
            speaker: [1.7, 1.8],
            hasSpeakerReference: true
        )

        XCTAssertEqual(first, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(second, [0.5, 0.6, 0.7, 0.8], "second frame must start with the carried tail")
        XCTAssertEqual(processor.microphones, [[0.1, 0.2, 0.3, 0.4], [0.5, 0.6, 0.7, 0.8]])
        XCTAssertEqual(
            processor.references,
            [[1.1, 1.2, 1.3, 1.4], [1.5, 1.6, 1.7, 1.8]],
            "reference samples must stay aligned with carried microphone samples across calls"
        )
        XCTAssertEqual(suppressor.diagnostics.rawFallbackFrames, 0)
    }

    func testProcessedStreamIsInvariantToBatchSize() {
        let microphone: [Float] = (0..<23).map { Float($0) / 100 }
        let speaker: [Float] = (0..<23).map { Float($0) / 200 }

        let single = StreamingMeetingEchoSuppressor(processor: SubtractingEchoProcessor(frameSize: 4))
        var singleOutput = single.condition(microphone: microphone, speaker: speaker, hasSpeakerReference: true)
        singleOutput += single.flush()

        let batched = StreamingMeetingEchoSuppressor(processor: SubtractingEchoProcessor(frameSize: 4))
        var batchedOutput: [Float] = []
        var cursor = 0
        for batchSize in [3, 7, 1, 5, 4, 2, 1] {
            let next = min(cursor + batchSize, microphone.count)
            batchedOutput += batched.condition(
                microphone: Array(microphone[cursor..<next]),
                speaker: Array(speaker[cursor..<next]),
                hasSpeakerReference: true
            )
            cursor = next
        }
        batchedOutput += batched.flush()

        XCTAssertEqual(cursor, microphone.count)
        XCTAssertEqual(batchedOutput, singleOutput, "splitting the stream into batches must not change the output")
    }

    func testReferenceDelayReadsOlderSpeakerSamples() {
        let processor = RecordingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor, referenceDelaySamples: 2)

        _ = suppressor.condition(
            microphone: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            speaker: [1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8],
            hasSpeakerReference: true
        )

        XCTAssertEqual(
            processor.references,
            [[0, 0, 1.1, 1.2], [1.3, 1.4, 1.5, 1.6]],
            "frame at position p must read reference from p - delay, zero-filled before stream start"
        )
        XCTAssertEqual(suppressor.diagnostics.partialReferenceFrames, 1)
        XCTAssertEqual(suppressor.diagnostics.fullReferenceFrames, 1)
    }

    func testFlushDrainsHeldTailRaw() {
        let processor = SubtractingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        _ = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2, 0.9],
            speaker: [0.1, 0.1, 0.2, 0.2, 0.8],
            hasSpeakerReference: true
        )
        let tail = suppressor.flush()

        XCTAssertEqual(tail, [0.9], "flush returns held samples unprocessed")
        XCTAssertEqual(suppressor.diagnostics.rawFallbackFrames, 1)
        XCTAssertEqual(suppressor.flush(), [], "second flush has nothing left to drain")
    }

    func testMissingReferenceUsesZeroReferenceAndIncrementsDiagnostics() {
        let processor = RecordingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        let output = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2],
            speaker: [0, 0, 0, 0],
            hasSpeakerReference: false
        )

        XCTAssertEqual(output, [0.5, 0.4, 0.3, 0.2])
        XCTAssertEqual(processor.references, [[0, 0, 0, 0]])
        XCTAssertEqual(suppressor.diagnostics.missingReferenceFrames, 1)
        XCTAssertEqual(suppressor.diagnostics.fullReferenceFrames, 0)
    }

    func testPartialReferenceZeroPadsUnavailableRegion() {
        let processor = RecordingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        _ = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2],
            speaker: [0.1, 0.2],
            hasSpeakerReference: true
        )

        XCTAssertEqual(processor.references, [[0.1, 0.2, 0, 0]])
        XCTAssertEqual(suppressor.diagnostics.partialReferenceFrames, 1)
    }

    func testProcessorFailureFallsBackToRawFrame() {
        let processor = ThrowingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        let output = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2],
            speaker: [0.1, 0.1, 0.1, 0.1],
            hasSpeakerReference: true
        )

        XCTAssertEqual(output, [0.5, 0.4, 0.3, 0.2])
        XCTAssertEqual(suppressor.diagnostics.rawFallbackFrames, 1)
        XCTAssertEqual(suppressor.diagnostics.processingFailures, 1)
    }

    func testResetClearsProcessorDiagnosticsAndCarriedSamples() {
        let processor = RecordingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        _ = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2, 0.9],
            speaker: [0.1, 0.1, 0.1, 0.1, 0.1],
            hasSpeakerReference: true
        )
        suppressor.reset()
        _ = suppressor.condition(
            microphone: [0.6, 0.7, 0.8, 0.9],
            speaker: [0.2, 0.2, 0.2, 0.2],
            hasSpeakerReference: true
        )

        XCTAssertEqual(processor.resetCount, 1)
        XCTAssertEqual(
            processor.microphones.last,
            [0.6, 0.7, 0.8, 0.9],
            "samples held before reset must not leak into post-reset frames"
        )
        XCTAssertEqual(suppressor.diagnostics.micFrames, 1)
        XCTAssertEqual(suppressor.flush(), [])
    }

    // MARK: Adaptive reference delay

    func testAdaptiveSuppressorRecoversLargeBulkDelayFromZeroSeed() {
        // A 600-sample bulk delay the static zero seed cannot align. With an
        // estimator the suppressor recovers it from the audio and cancels in
        // steady state, where the static-zero case (see the measurement tests)
        // leaves the echo untouched or worse.
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: [(delay: 600, gain: 0.6)]),
            noiseLevel: 0.0001)

        let adaptive = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6),
            referenceDelaySamples: 0,
            estimator: MeetingEchoDelayEstimator())
        let output = MeetingAecRunner.run(adaptive, scenario: scenario)

        let erle = MeetingAecMetrics.erleDB(
            mic: scenario.mic, output: output, over: scenario.steadyStateWindow)
        XCTAssertGreaterThan(erle, 20, "the suppressor self-aligns to the bulk delay and cancels in steady state")
        XCTAssertGreaterThanOrEqual(adaptive.diagnostics.delayEstimateCount, 1)
        XCTAssertEqual(adaptive.diagnostics.currentDelaySamples, 600, accuracy: 2, "adopts the recovered delay")
        XCTAssertGreaterThan(adaptive.diagnostics.delayConfidence, 0.5)
    }

    func testAdaptiveSuppressorKeepsSeedWhenReferenceIsSilent() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "near-end-only", nearEndActive: true, farEndActive: false,
            echoPath: MeetingAecEchoPath(taps: [(delay: 600, gain: 0.6)]))

        let seed = 5
        let adaptive = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6),
            referenceDelaySamples: seed,
            estimator: MeetingEchoDelayEstimator())
        _ = MeetingAecRunner.run(adaptive, scenario: scenario)

        XCTAssertEqual(adaptive.diagnostics.currentDelaySamples, seed, "a silent reference keeps the seed delay")
        XCTAssertEqual(adaptive.diagnostics.delayEstimateCount, 0)
        XCTAssertGreaterThanOrEqual(
            adaptive.diagnostics.rejectedDelayEstimates, 1,
            "a silent far-end is a rejected estimate, not an adopted one")
    }

    func testResetClearsAdaptiveDelayState() {
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: [(delay: 600, gain: 0.6)]),
            noiseLevel: 0.0001)

        let adaptive = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6),
            referenceDelaySamples: 0,
            estimator: MeetingEchoDelayEstimator())
        _ = MeetingAecRunner.run(adaptive, scenario: scenario)
        XCTAssertGreaterThanOrEqual(adaptive.diagnostics.delayEstimateCount, 1)

        adaptive.reset()
        XCTAssertEqual(adaptive.diagnostics.currentDelaySamples, 0, "reset returns the delay to the seed")
        XCTAssertEqual(adaptive.diagnostics.delayConfidence, 0, "reset clears the last adopted estimate confidence")
        XCTAssertEqual(adaptive.diagnostics.delayEstimateCount, 0)
        XCTAssertEqual(adaptive.diagnostics.rejectedDelayEstimates, 0)
        XCTAssertEqual(adaptive.flush(), [])
    }

    func testAdaptiveSuppressorFeedsEstimatorEnoughSamplesForSmallWindows() {
        // Guards the buffer/threshold floor of maxLag + 2: a tiny analysis window
        // must not leave the suppressor permanently one sample short of
        // estimate()'s requirement, which would make every attempt return nil.
        let scenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true,
            echoPath: MeetingAecEchoPath(taps: [(delay: 20, gain: 0.6)]),
            noiseLevel: 0.0001)
        let adaptive = StreamingMeetingEchoSuppressor(
            processor: MeetingAecOracleSubtractor(gain: 0.6),
            referenceDelaySamples: 0,
            estimator: MeetingEchoDelayEstimator(maxLagSamples: 64, analysisWindowSamples: 1))
        _ = MeetingAecRunner.run(adaptive, scenario: scenario)

        XCTAssertGreaterThanOrEqual(
            adaptive.diagnostics.delayEstimateCount, 1,
            "the suppressor must supply enough samples for estimate() to run, even with a tiny window")
    }

    private func rounded(_ value: Float) -> Float {
        (value * 1_000).rounded() / 1_000
    }
}

private final class SubtractingEchoProcessor: MeetingEchoSuppressing, @unchecked Sendable {
    let name = "subtracting-test"
    let sampleRate = 16_000
    let frameSize: Int

    init(frameSize: Int) {
        self.frameSize = frameSize
    }

    func reset() {}

    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws {
        for index in output.indices {
            output[index] = microphone[index] - reference[index]
        }
    }
}

private final class RecordingEchoProcessor: MeetingEchoSuppressing, @unchecked Sendable {
    let name = "recording-test"
    let sampleRate = 16_000
    let frameSize: Int
    private(set) var microphones: [[Float]] = []
    private(set) var references: [[Float]] = []
    private(set) var resetCount = 0

    init(frameSize: Int) {
        self.frameSize = frameSize
    }

    func reset() {
        resetCount += 1
        microphones.removeAll()
        references.removeAll()
    }

    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws {
        microphones.append(microphone)
        references.append(reference)
        for index in output.indices {
            output[index] = microphone[index]
        }
    }
}

private final class ThrowingEchoProcessor: MeetingEchoSuppressing, @unchecked Sendable {
    enum Failure: Error {
        case simulated
    }

    let name = "throwing-test"
    let sampleRate = 16_000
    let frameSize: Int

    init(frameSize: Int) {
        self.frameSize = frameSize
    }

    func reset() {}

    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws {
        throw Failure.simulated
    }
}
