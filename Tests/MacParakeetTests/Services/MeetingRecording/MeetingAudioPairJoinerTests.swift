import XCTest
@testable import MacParakeetCore

final class MeetingAudioPairJoinerTests: XCTestCase {
    func testDrainPairsSplitsAsymmetricFramesWithoutPaddingAndPreservesHostTimes() {
        var joiner = MeetingAudioPairJoiner()
        joiner.push(samples: [0.1, 0.2], hostTime: 100, source: .microphone)
        joiner.push(samples: [0.3], hostTime: 200, source: .system)

        let pairs = joiner.drainPairs()
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].microphoneSamples, [0.1])
        XCTAssertEqual(pairs[0].systemSamples, [0.3])
        XCTAssertEqual(pairs[0].microphoneHostTime, 100)
        XCTAssertEqual(pairs[0].systemHostTime, 200)

        let flushed = joiner.flushRemainingPairs()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].microphoneSamples, [0.2])
        XCTAssertEqual(flushed[0].systemSamples, [0.0])
        XCTAssertNil(flushed[0].systemHostTime)
    }

    func testDrainPairsEmitsMicWithSilenceAfterLagThreshold() {
        var joiner = MeetingAudioPairJoiner()
        for index in 0...(MeetingAudioPairJoiner.maxLag) {
            joiner.push(samples: [Float(index)], hostTime: UInt64(index), source: .microphone)
        }

        let pairs = joiner.drainPairs()
        XCTAssertEqual(pairs.count, MeetingAudioPairJoiner.maxLag + 1)
        XCTAssertEqual(pairs[0].microphoneSamples, [0.0])
        XCTAssertEqual(pairs[0].systemSamples, [0.0])
        XCTAssertEqual(pairs[0].microphoneHostTime, 0)
        XCTAssertNil(pairs[0].systemHostTime)
    }

    func testFlushRemainingEmitsPendingFramesWithoutLag() {
        var joiner = MeetingAudioPairJoiner()
        joiner.push(samples: [1.0, -1.0], hostTime: 123, source: .microphone)

        let pairs = joiner.flushRemainingPairs()
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].microphoneSamples, [1.0, -1.0])
        XCTAssertEqual(pairs[0].systemSamples, [0.0, 0.0])
        XCTAssertEqual(pairs[0].microphoneHostTime, 123)
        XCTAssertNil(pairs[0].systemHostTime)
    }

    func testPushDropsOldestFramesWhenQueueOverflows() {
        var joiner = MeetingAudioPairJoiner()
        for index in 0..<35 {
            joiner.push(samples: [Float(index)], hostTime: UInt64(index), source: .microphone)
        }

        let pairs = joiner.flushRemainingPairs()
        XCTAssertEqual(pairs.count, 30)
        XCTAssertEqual(pairs.first?.microphoneSamples, [5.0])
        XCTAssertEqual(pairs.first?.microphoneHostTime, 5)
        XCTAssertEqual(pairs.last?.microphoneSamples, [34.0])
        XCTAssertEqual(pairs.last?.microphoneHostTime, 34)
    }

    func testDrainDiagnosticsReportsOverflowEvents() {
        var joiner = MeetingAudioPairJoiner()
        for index in 0..<35 {
            joiner.push(samples: [Float(index)], hostTime: UInt64(index), source: .microphone)
        }

        let diagnostics = joiner.drainDiagnostics()
        XCTAssertEqual(diagnostics.count, 5)
        for diagnostic in diagnostics {
            guard case .queueOverflow(let source, let droppedFrames, let queueDepth) = diagnostic.kind else {
                return XCTFail("Expected queueOverflow diagnostic")
            }
            XCTAssertEqual(source, .microphone)
            XCTAssertEqual(droppedFrames, 1)
            XCTAssertEqual(queueDepth, 30)
        }
        XCTAssertTrue(joiner.drainDiagnostics().isEmpty)
    }
}
