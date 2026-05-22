import XCTest
@testable import MacParakeetCore

final class LayoutPlanParserTests: XCTestCase {

    /// Synthesize a word array of N short words for parser tests.
    private func words(_ n: Int) -> [WordTimestamp] {
        (0..<n).map { i in
            WordTimestamp(word: "w\(i)", startMs: i * 100, endMs: i * 100 + 80, confidence: 0.99)
        }
    }

    // MARK: - Happy path

    func testValidJSONIsAccepted() {
        let ws = words(10)
        let json = #"{"cues":[{"start":0,"end":3},{"start":4,"end":6},{"start":7,"end":9}]}"#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        switch result {
        case .success(let ranges):
            XCTAssertEqual(ranges.count, 3)
            XCTAssertEqual(ranges[0], .init(start: 0, end: 3))
            XCTAssertEqual(ranges[1], .init(start: 4, end: 6))
            XCTAssertEqual(ranges[2], .init(start: 7, end: 9))
        case .failure(let f):
            XCTFail("Expected success, got \(f)")
        }
    }

    func testValidJSONInCodeFenceIsAccepted() {
        let ws = words(5)
        let json = """
        ```json
        {"cues":[{"start":0,"end":4}]}
        ```
        """
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        XCTAssertNotNil(try? result.get())
    }

    // MARK: - Malformed input

    func testNonJSONIsRejected() {
        let ws = words(3)
        XCTAssertEqual(
            LayoutPlanParser.parse("not json at all", words: ws, perCueBudget: 100),
            .failure(.malformedJSON)
        )
    }

    func testMissingCuesKeyIsRejected() {
        let ws = words(3)
        XCTAssertEqual(
            LayoutPlanParser.parse(#"{"other":[]}"#, words: ws, perCueBudget: 100),
            .failure(.missingCuesKey)
        )
    }

    func testEmptyCuesIsRejected() {
        let ws = words(3)
        XCTAssertEqual(
            LayoutPlanParser.parse(#"{"cues":[]}"#, words: ws, perCueBudget: 100),
            .failure(.emptyCues)
        )
    }

    // MARK: - Range validation

    func testRangeOutOfBoundsIsRejected() {
        let ws = words(5)
        let json = #"{"cues":[{"start":0,"end":10}]}"#
        XCTAssertEqual(
            LayoutPlanParser.parse(json, words: ws, perCueBudget: 100),
            .failure(.rangeOutOfBounds(start: 0, end: 10, wordCount: 5))
        )
    }

    func testInvertedRangeIsRejected() {
        let ws = words(5)
        let json = #"{"cues":[{"start":3,"end":1}]}"#
        XCTAssertEqual(
            LayoutPlanParser.parse(json, words: ws, perCueBudget: 100),
            .failure(.rangeInverted(start: 3, end: 1))
        )
    }

    // MARK: - Coverage validation

    func testGapBetweenCuesIsRejected() {
        let ws = words(10)
        let json = #"{"cues":[{"start":0,"end":3},{"start":6,"end":9}]}"#
        XCTAssertEqual(
            LayoutPlanParser.parse(json, words: ws, perCueBudget: 100),
            .failure(.gapBetweenCues(prevEnd: 3, nextStart: 6))
        )
    }

    func testOverlapBetweenCuesIsRejected() {
        let ws = words(10)
        let json = #"{"cues":[{"start":0,"end":5},{"start":3,"end":9}]}"#
        XCTAssertEqual(
            LayoutPlanParser.parse(json, words: ws, perCueBudget: 100),
            .failure(.overlapBetweenCues(prevEnd: 5, nextStart: 3))
        )
    }

    func testMustStartAtZero() {
        let ws = words(10)
        let json = #"{"cues":[{"start":2,"end":9}]}"#
        XCTAssertEqual(
            LayoutPlanParser.parse(json, words: ws, perCueBudget: 100),
            .failure(.doesNotStartAtZero(firstStart: 2))
        )
    }

    func testMustEndAtLastWord() {
        let ws = words(10)
        let json = #"{"cues":[{"start":0,"end":7}]}"#
        XCTAssertEqual(
            LayoutPlanParser.parse(json, words: ws, perCueBudget: 100),
            .failure(.doesNotEndAtLast(lastEnd: 7, wordCount: 10))
        )
    }

    // MARK: - Budget enforcement (deferred to the planner)

    /// The parser intentionally does NOT enforce the per-cue size cap —
    /// the LLM consistently overshoots it (75–115 chars at a 65-char
    /// budget in real data) and rejecting the whole chunk on that basis
    /// wastes the rest of the LLM's good boundary choices.
    /// `SubtitleLLMLayoutPlanner.runOne` runs an auto-split pass after
    /// parsing that breaks oversized cues at the best linguistic point.
    func testCueExceedingBudgetIsStillAcceptedByParser() {
        // 5 words joined "w0 w1 w2 w3 w4" = 14 chars, well over the 10
        // budget. Old parser would have rejected; new parser accepts and
        // leaves the size handling to the planner.
        let ws = words(5)
        let json = #"{"cues":[{"start":0,"end":4}]}"#
        XCTAssertNotNil(try? LayoutPlanParser.parse(json, words: ws, perCueBudget: 10).get())
    }
}
