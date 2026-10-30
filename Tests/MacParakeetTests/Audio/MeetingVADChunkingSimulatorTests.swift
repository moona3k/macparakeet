import XCTest
@testable import MacParakeetCore

/// Exercises the report returned to `meeting-vad-sim` using independently
/// calculated fixed windows. Real VAD/model quality is a separate contract.
final class MeetingVADChunkingSimulatorTests: XCTestCase {
    func testFixedReplayReportsOverlappingWindowsAndFlushedTail() async {
        let report = await MeetingVADChunkingSimulator.simulate(
            samples16k: [Float](repeating: 0.3, count: 368_000),
            mode: .fixed,
            batchSamples: 1_600
        )

        // 23 seconds at 16 kHz: five 5-second windows advancing by 4 seconds,
        // then the remaining 20–23-second tail, including the final overlap.
        XCTAssertEqual(report.mode, "fixed")
        XCTAssertTrue(report.vadAvailable)
        XCTAssertEqual(report.audioDurationMs, 23_000)
        XCTAssertEqual(report.ingestBatchCount, 230)
        XCTAssertEqual(report.batchSamples, 1_600)
        XCTAssertEqual(report.chunks.map(\.index), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(report.chunks.map(\.startMs), [0, 4_000, 8_000, 12_000, 16_000, 20_000])
        XCTAssertEqual(report.chunks.map(\.endMs), [5_000, 9_000, 13_000, 17_000, 21_000, 23_000])
        XCTAssertEqual(report.chunks.map(\.durationMs), [5_000, 5_000, 5_000, 5_000, 5_000, 3_000])
        XCTAssertEqual(report.chunks.map(\.sampleCount), [80_000, 80_000, 80_000, 80_000, 80_000, 48_000])
        XCTAssertEqual(report.forceEmits, 0)
        XCTAssertEqual(report.droppedSilenceWindows, 0)
        XCTAssertFalse(report.fellBackToFixed)
    }

    func testPartialIngestBatchIsIncludedInFinalReport() async {
        // 128 complete ingests plus 496 samples: unlike 192,000 samples,
        // this input is genuinely uneven at the 1,500-sample ingest boundary.
        let report = await MeetingVADChunkingSimulator.simulate(
            samples16k: [Float](repeating: 0.3, count: 192_496),
            mode: .fixed,
            batchSamples: 1_500
        )

        XCTAssertEqual(report.audioDurationMs, 12_031)
        XCTAssertEqual(report.ingestBatchCount, 129)
        XCTAssertEqual(report.batchSamples, 1_500)
        XCTAssertEqual(report.chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(report.chunks.map(\.startMs), [0, 4_000, 8_000])
        XCTAssertEqual(report.chunks.map(\.endMs), [5_000, 9_000, 12_031])
        XCTAssertEqual(report.chunks.map(\.durationMs), [5_000, 5_000, 4_031])
        XCTAssertEqual(report.chunks.map(\.sampleCount), [80_000, 80_000, 64_496])
    }
}
