import XCTest
@testable import MacParakeetCore

final class MeetingEchoSuppressorTests: XCTestCase {
    func testProcessesFullReferenceFramesAndPreservesSampleCount() {
        let processor = SubtractingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        let output = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2, 0.9],
            speaker: [0.1, 0.1, 0.2, 0.2, 0.8],
            hasSpeakerReference: true
        )

        XCTAssertEqual(output.count, 5)
        XCTAssertEqual(output.prefix(4).map { rounded($0) }, [0.4, 0.3, 0.1, 0.0])
        XCTAssertEqual(output.last, 0.9, "tail samples that do not fill a processor frame pass through raw")
        XCTAssertEqual(
            suppressor.diagnostics,
            MeetingEchoSuppressionDiagnostics(
                processorName: "subtracting-test",
                loaded: true,
                micFrames: 1,
                processedFrames: 1,
                rawFallbackFrames: 1,
                fullReferenceFrames: 1,
                partialReferenceFrames: 0,
                missingReferenceFrames: 0,
                processingFailures: 0
            )
        )
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

    func testResetClearsProcessorAndDiagnostics() {
        let processor = RecordingEchoProcessor(frameSize: 4)
        let suppressor = StreamingMeetingEchoSuppressor(processor: processor)

        _ = suppressor.condition(
            microphone: [0.5, 0.4, 0.3, 0.2],
            speaker: [0.1, 0.1, 0.1, 0.1],
            hasSpeakerReference: true
        )
        suppressor.reset()

        XCTAssertEqual(processor.resetCount, 1)
        XCTAssertEqual(suppressor.diagnostics.processedFrames, 0)
        XCTAssertEqual(suppressor.diagnostics.fullReferenceFrames, 0)
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
    private(set) var references: [[Float]] = []
    private(set) var resetCount = 0

    init(frameSize: Int) {
        self.frameSize = frameSize
    }

    func reset() {
        resetCount += 1
        references.removeAll()
    }

    func processFrame(microphone: [Float], reference: [Float], output: inout [Float]) throws {
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
