import XCTest
@testable import MacParakeetCore

/// Parser-only tests for `ReviewActionParser`. The reviewer pipeline
/// has its own integration tests; this file pins the JSON tolerance
/// and validation rules at the parsing layer.
final class ReviewActionParserTests: XCTestCase {

    // MARK: - Happy path

    func testParsesKeep() {
        let r = ReviewActionParser.parse(#"{"action":"keep"}"#)
        XCTAssertEqual(r, .success(.keep))
    }

    func testParsesMerge() {
        let r = ReviewActionParser.parse(#"{"action":"merge"}"#)
        XCTAssertEqual(r, .success(.merge))
    }

    func testParsesShiftToAWithN() {
        let r = ReviewActionParser.parse(#"{"action":"shift_to_a","n":2}"#)
        XCTAssertEqual(r, .success(.shiftToA(n: 2)))
    }

    func testParsesShiftToBWithN() {
        let r = ReviewActionParser.parse(#"{"action":"shift_to_b","n":1}"#)
        XCTAssertEqual(r, .success(.shiftToB(n: 1)))
    }

    func testAcceptsActionCaseInsensitive() {
        XCTAssertEqual(ReviewActionParser.parse(#"{"action":"KEEP"}"#), .success(.keep))
        XCTAssertEqual(ReviewActionParser.parse(#"{"action":"Merge"}"#), .success(.merge))
    }

    // MARK: - JSON tolerance

    func testStripsCodeFences() {
        let r = ReviewActionParser.parse("""
        ```json
        {"action":"keep"}
        ```
        """)
        XCTAssertEqual(r, .success(.keep))
    }

    func testStripsLineComments() {
        // Same JSONC tolerance as LayoutPlanParser — the LLM sometimes
        // mimics arrow-style annotations from prompt examples.
        let r = ReviewActionParser.parse(#"""
        {
          "action": "shift_to_a", // compound modifier
          "n": 1
        }
        """#)
        XCTAssertEqual(r, .success(.shiftToA(n: 1)))
    }

    // MARK: - Failures

    func testRejectsMalformedJSON() {
        XCTAssertEqual(ReviewActionParser.parse("not json"),
                       .failure(.malformedJSON))
    }

    func testRejectsMissingActionKey() {
        XCTAssertEqual(ReviewActionParser.parse(#"{"verdict":"keep"}"#),
                       .failure(.missingActionKey))
    }

    func testRejectsUnknownAction() {
        XCTAssertEqual(ReviewActionParser.parse(#"{"action":"frobnicate"}"#),
                       .failure(.unknownAction("frobnicate")))
    }

    func testRejectsShiftWithoutN() {
        XCTAssertEqual(ReviewActionParser.parse(#"{"action":"shift_to_a"}"#),
                       .failure(.missingNForShift("shift_to_a")))
    }

    func testRejectsShiftWithNTooLarge() {
        // n=3 is the upper bound. n=4 must be rejected to keep
        // the reviewer from reshaping a cue dramatically in one pass.
        XCTAssertEqual(ReviewActionParser.parse(#"{"action":"shift_to_a","n":4}"#),
                       .failure(.nOutOfRange(action: "shift_to_a", n: 4)))
    }

    func testRejectsShiftWithNZero() {
        XCTAssertEqual(ReviewActionParser.parse(#"{"action":"shift_to_b","n":0}"#),
                       .failure(.nOutOfRange(action: "shift_to_b", n: 0)))
    }

    // MARK: - Batched parser

    func testParseBatchHandlesMixedActions() {
        let json = #"{"decisions":[{"pair":0,"action":"keep"},{"pair":1,"action":"merge"},{"pair":2,"action":"shift_to_a","n":2},{"pair":3,"action":"shift_to_b","n":1}]}"#
        guard case .success(let decisions) = ReviewActionParser.parseBatch(json) else {
            XCTFail("Expected success, got: \(ReviewActionParser.parseBatch(json))")
            return
        }
        XCTAssertEqual(decisions.count, 4)
        XCTAssertEqual(decisions[0], ReviewBatchDecision(pairIndex: 0, action: .keep))
        XCTAssertEqual(decisions[1], ReviewBatchDecision(pairIndex: 1, action: .merge))
        XCTAssertEqual(decisions[2], ReviewBatchDecision(pairIndex: 2, action: .shiftToA(n: 2)))
        XCTAssertEqual(decisions[3], ReviewBatchDecision(pairIndex: 3, action: .shiftToB(n: 1)))
    }

    /// A malformed individual decision is silently dropped, not fatal
    /// for the whole batch — matches the philosophy that the apply
    /// pass re-validates every suggestion anyway.
    func testParseBatchDropsInvalidDecisionsButKeepsValidOnes() {
        let json = #"{"decisions":[{"pair":0,"action":"keep"},{"pair":1,"action":"frobnicate"},{"pair":2,"action":"shift_to_a"},{"pair":3,"action":"merge"}]}"#
        guard case .success(let decisions) = ReviewActionParser.parseBatch(json) else {
            XCTFail("Expected success, got: \(ReviewActionParser.parseBatch(json))")
            return
        }
        // pair 0 (keep) + pair 3 (merge) survive. pair 1 has an unknown
        // action; pair 2 has shift without n — both dropped.
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0].pairIndex, 0)
        XCTAssertEqual(decisions[1].pairIndex, 3)
    }

    /// Whole-batch JSON parse failure surfaces as a typed failure so
    /// callers can fall back to .keep for every pair in the batch.
    func testParseBatchRejectsMalformedJSON() {
        XCTAssertEqual(
            ReviewActionParser.parseBatch("not json"),
            .failure(.malformedJSON)
        )
    }

    /// Missing `decisions` key is a typed failure (vs. wrong shape).
    func testParseBatchRejectsMissingDecisionsKey() {
        XCTAssertEqual(
            ReviewActionParser.parseBatch(#"{"action":"keep"}"#),
            .failure(.missingDecisionsKey)
        )
    }

    /// Accepts `index` as an alias for `pair` — models sometimes drift
    /// to using `index`, and we want to tolerate it rather than drop
    /// the whole batch.
    func testParseBatchAcceptsIndexAsAliasForPair() {
        let json = #"{"decisions":[{"index":0,"action":"keep"},{"index":1,"action":"merge"}]}"#
        guard case .success(let decisions) = ReviewActionParser.parseBatch(json) else {
            XCTFail("Expected success, got: \(ReviewActionParser.parseBatch(json))")
            return
        }
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0].pairIndex, 0)
        XCTAssertEqual(decisions[1].pairIndex, 1)
    }
}
