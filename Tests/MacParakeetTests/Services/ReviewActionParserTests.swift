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
}
