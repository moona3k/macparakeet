import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class MandalaDataTests: XCTestCase {
    func testWordTimestampSamplingAlwaysReturnsTwentyFourPoints() {
        XCTAssertEqual(MandalaData.from(wordTimestamps: []).radialPoints.count, 24)

        let one = [WordTimestamp(word: "hi", startMs: 0, endMs: 100, confidence: 0.9)]
        XCTAssertEqual(MandalaData.from(wordTimestamps: one).radialPoints.count, 24)

        let twentyThree = (0..<23).map { index in
            WordTimestamp(word: "w", startMs: index, endMs: index + 1, confidence: 0.5)
        }
        XCTAssertEqual(MandalaData.from(wordTimestamps: twentyThree).radialPoints.count, 24)

        let many = (0..<2_000).map { index in
            WordTimestamp(
                word: "w",
                startMs: index,
                endMs: index + 1,
                confidence: Double(index) / 2_000
            )
        }
        let sampled = MandalaData.from(wordTimestamps: many)
        XCTAssertEqual(sampled.radialPoints.count, 24)
        XCTAssertEqual(sampled.radialPoints[0], 0, accuracy: 0.0001)
    }

    func testTextSamplingDoesNotRequireTheFullString() {
        let short = MandalaData.from(text: "abc", durationMs: 1_000)
        XCTAssertEqual(short.radialPoints.count, 24)

        let long = String(repeating: "word ", count: 20_000)
        let fromLong = MandalaData.from(text: long, durationMs: 7_200_000)
        XCTAssertEqual(fromLong.radialPoints.count, 24)
    }
}
