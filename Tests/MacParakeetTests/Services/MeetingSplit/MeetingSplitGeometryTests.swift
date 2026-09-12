import XCTest
@testable import MacParakeetCore

/// Coverage for `MeetingSplitGeometry`/`MeetingSplitSourceRange` (plan #895
/// U2a). Deliberately independent of any transcript, word timing or speaker
/// data: these are plain audio-range checks.
final class MeetingSplitGeometryTests: XCTestCase {

    // MARK: - Valid geometry

    func testTwoPartsProducesTwoContiguousGaplessRanges() throws {
        let ranges = try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: [4_000])

        XCTAssertEqual(ranges, [
            MeetingSplitSourceRange(startMs: 0, endMs: 4_000),
            MeetingSplitSourceRange(startMs: 4_000, endMs: 10_000),
        ])
    }

    func testThreePartsProducesThreeContiguousGaplessRanges() throws {
        let ranges = try MeetingSplitGeometry.ranges(durationMs: 9_000, cutPointsMs: [2_000, 6_000])

        XCTAssertEqual(ranges, [
            MeetingSplitSourceRange(startMs: 0, endMs: 2_000),
            MeetingSplitSourceRange(startMs: 2_000, endMs: 6_000),
            MeetingSplitSourceRange(startMs: 6_000, endMs: 9_000),
        ])
    }

    func testAdjacentRangesShareAnExactBoundaryWithNoGapOrOverlap() throws {
        let ranges = try MeetingSplitGeometry.ranges(durationMs: 12_345, cutPointsMs: [1, 5_000, 12_344])

        for index in 1..<ranges.count {
            XCTAssertEqual(ranges[index - 1].endMs, ranges[index].startMs, "no gap or overlap at cut \(index)")
        }
        XCTAssertEqual(ranges.first?.startMs, 0)
        XCTAssertEqual(ranges.last?.endMs, 12_345)
    }

    func testDurationMsIsEndMinusStart() {
        XCTAssertEqual(MeetingSplitSourceRange(startMs: 500, endMs: 1_700).durationMs, 1_200)
    }

    // MARK: - Invalid geometry

    func testZeroDurationIsRejected() {
        XCTAssertThrowsError(try MeetingSplitGeometry.ranges(durationMs: 0, cutPointsMs: [1])) { error in
            XCTAssertEqual(error as? MeetingSplitCutValidationError, .invalidDuration(durationMs: 0))
        }
    }

    func testNoCutsIsRejected() {
        XCTAssertThrowsError(try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: [])) { error in
            XCTAssertEqual(error as? MeetingSplitCutValidationError, .noCuts)
        }
    }

    func testZeroCutIsRejectedAsOutOfRange() {
        XCTAssertThrowsError(try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: [0])) { error in
            XCTAssertEqual(error as? MeetingSplitCutValidationError, .cutOutOfRange(ms: 0, durationMs: 10_000))
        }
    }

    func testTerminalCutAtSourceDurationIsRejected() {
        XCTAssertThrowsError(try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: [10_000])) { error in
            XCTAssertEqual(error as? MeetingSplitCutValidationError, .cutOutOfRange(ms: 10_000, durationMs: 10_000))
        }
    }

    func testOutOfRangeCutBeyondDurationIsRejected() {
        XCTAssertThrowsError(try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: [10_001])) { error in
            XCTAssertEqual(error as? MeetingSplitCutValidationError, .cutOutOfRange(ms: 10_001, durationMs: 10_000))
        }
    }

    func testDuplicateCutsAreRejected() {
        XCTAssertThrowsError(try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: [3_000, 3_000])) {
            error in
            XCTAssertEqual(
                error as? MeetingSplitCutValidationError, .unorderedOrDuplicateCuts(ms: [3_000, 3_000]))
        }
    }

    func testUnorderedCutsAreRejected() {
        XCTAssertThrowsError(try MeetingSplitGeometry.ranges(durationMs: 10_000, cutPointsMs: [6_000, 2_000])) {
            error in
            XCTAssertEqual(
                error as? MeetingSplitCutValidationError, .unorderedOrDuplicateCuts(ms: [6_000, 2_000]))
        }
    }
}
