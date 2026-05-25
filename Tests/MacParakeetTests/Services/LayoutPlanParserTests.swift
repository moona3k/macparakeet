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

    /// Gaps wider than the auto-repair cap (3 indices) still fall back
    /// to the deterministic builder — silently dropping 4+ words would
    /// be a worse error than a chunk fallback.
    func testWideGapBetweenCuesIsRejected() {
        let ws = words(10)
        // Skips indices 4, 5, 6, 7, 8 → 5-word gap, > maxGapToRepair.
        let json = #"{"cues":[{"start":0,"end":3},{"start":9,"end":9}]}"#
        XCTAssertEqual(
            LayoutPlanParser.parse(json, words: ws, perCueBudget: 100),
            .failure(.gapBetweenCues(prevEnd: 3, nextStart: 9))
        )
    }

    /// SRT (38) regression: Gemma 4 occasionally skipped a single
    /// index when emitting cue ranges — `{end:9},{start:11}` (word 10
    /// missing). Before the fix, the whole 80-word chunk fell back to
    /// deterministic layout, producing ~50 extra cues. Now the parser
    /// extends the previous cue to swallow the missing index(es).
    func testOneIndexGapAutoCorrects() {
        let ws = words(10)
        // Skips index 5: gap of 1 → autoCorrectGaps extends prev to {0,5}.
        let json = #"{"cues":[{"start":0,"end":4},{"start":6,"end":9}]}"#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        guard case .success(let ranges) = result else {
            XCTFail("One-index gap should auto-repair; got: \(result)")
            return
        }
        XCTAssertEqual(ranges, [.init(start: 0, end: 5), .init(start: 6, end: 9)])
    }

    /// Two-index gap is still inside the repair cap.
    func testTwoIndexGapAutoCorrects() {
        let ws = words(10)
        // Skips indices 4, 5: gap of 2 → autoCorrectGaps extends prev to {0,5}.
        let json = #"{"cues":[{"start":0,"end":3},{"start":6,"end":9}]}"#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        guard case .success(let ranges) = result else {
            XCTFail("Two-index gap should auto-repair; got: \(result)")
            return
        }
        XCTAssertEqual(ranges, [.init(start: 0, end: 5), .init(start: 6, end: 9)])
    }

    /// Wider overlaps (e.g. 3-index) also auto-correct now: the
    /// shared indices stay with the previous cue and the next cue
    /// starts right after. This is "good enough" — the LLM made a
    /// mistake and any deterministic resolution beats falling back
    /// the whole transcript to the deterministic builder.
    func testWideOverlapAutoCorrects() {
        let ws = words(10)
        // cue1={0,5}, cue2={3,9}. Auto-correct nudges cue2 to {6,9}.
        let json = #"{"cues":[{"start":0,"end":5},{"start":3,"end":9}]}"#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        guard case .success(let ranges) = result else {
            XCTFail("Wider overlap should auto-correct; got: \(result)")
            return
        }
        XCTAssertEqual(ranges, [.init(start: 0, end: 5), .init(start: 6, end: 9)])
    }

    /// SRT 29 regression: the LLM emitted
    /// `[{0,11},{12,20},{21,47},{48,50},{51,57},{58,69},{70,78},{78,79}]`
    /// for chunk 882-961 (word indices 0-79 in chunk-local space).
    /// Index 78 appears in BOTH the last two cues — a one-index
    /// overlap. The whole 30-min transcript fell back to deterministic
    /// because of this one chunk. Parser now auto-corrects.
    func testOneIndexOverlapIsAutoCorrected() {
        let ws = words(80)
        let json = #"{"cues":[{"start":0,"end":11},{"start":12,"end":20},{"start":21,"end":47},{"start":48,"end":50},{"start":51,"end":57},{"start":58,"end":69},{"start":70,"end":78},{"start":78,"end":79}]}"#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        guard case .success(let ranges) = result else {
            XCTFail("Parser should auto-correct one-index overlap; got: \(result)")
            return
        }
        XCTAssertEqual(ranges.count, 8)
        // Last cue's start should have been bumped from 78 to 79.
        XCTAssertEqual(ranges[6], .init(start: 70, end: 78))
        XCTAssertEqual(ranges[7], .init(start: 79, end: 79))
    }

    /// SRT 30 regression: the LLM emitted JSON with `// ...`
    /// trailing comments annotating each cue. JSONSerialization
    /// rejects this. Parser now strips JSONC-style comments first.
    func testJSONWithLineCommentsIsAccepted() {
        let ws = words(51)
        let json = #"""
        {
          "cues": [
            {"start": 0, "end": 8},   // We'll slow it down and we'll stand it up.
            {"start": 9, "end": 15},  // 20 seconds away from our next jog.
            {"start": 16, "end": 22}, // Just like before, hands will stay low.
            {"start": 23, "end": 33}, // You're going to go tall over your pedals, 70 to 75.
            {"start": 34, "end": 37}, // Slow it down now.
            {"start": 38, "end": 42}, // Start to slow it down.
            {"start": 43, "end": 44}, // Low 70s.
            {"start": 45, "end": 50}  // Stand up in 3, 2, 1.
          ]
        }
        """#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        guard case .success(let ranges) = result else {
            XCTFail("Parser should strip // comments and succeed; got: \(result)")
            return
        }
        XCTAssertEqual(ranges.count, 8)
        XCTAssertEqual(ranges.first, .init(start: 0, end: 8))
        XCTAssertEqual(ranges.last, .init(start: 45, end: 50))
    }

    /// Block comments and string-internal `//` should also be handled.
    func testJSONWithBlockCommentsAndStringSlashes() {
        let ws = words(3)
        // Block comment between cues + a `//` inside (escaped) string
        // content — though there's no string field in CueRange the
        // stripper must not eat slashes that are inside JSON strings
        // in general.
        let json = #"""
        {
          /* layout from LLM run 42 */
          "cues": [{"start": 0, "end": 2}]
        }
        """#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        XCTAssertNotNil(try? result.get())
    }

    /// Edge case: a cue that would auto-correct into an empty range
    /// (start > end) is dropped; remaining cues still cover the words.
    func testOverlapCollapsingToEmptyCueIsDropped() {
        // [{0,5},{5,5}] — corrects start 5 → 6, but cue would be
        // {6,5} (empty). Drop it. Single cue {0,5} still covers all 6 words.
        let ws = words(6)
        let json = #"{"cues":[{"start":0,"end":5},{"start":5,"end":5}]}"#
        let result = LayoutPlanParser.parse(json, words: ws, perCueBudget: 100)
        guard case .success(let ranges) = result else {
            XCTFail("Expected single-cue success after dropping empty range; got: \(result)")
            return
        }
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], .init(start: 0, end: 5))
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
