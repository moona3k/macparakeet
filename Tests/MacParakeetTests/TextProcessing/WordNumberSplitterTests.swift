import XCTest
@testable import MacParakeetCore

final class WordNumberSplitterTests: XCTestCase {

    // MARK: - Text path

    func testSplitsLowercaseLetterPrefixFromDigits() {
        XCTAssertEqual(WordNumberSplitter.splitInText("next30 minutes"), "next 30 minutes")
        XCTAssertEqual(WordNumberSplitter.splitInText("the980 range"), "the 980 range")
        XCTAssertEqual(WordNumberSplitter.splitInText("between80 and90."), "between 80 and 90.")
    }

    func testKeepsPluralAndPunctuationWithTheNumber() {
        XCTAssertEqual(WordNumberSplitter.splitInText("high90s,"), "high 90s,")
        XCTAssertEqual(WordNumberSplitter.splitInText("arms30."), "arms 30.")
        XCTAssertEqual(WordNumberSplitter.splitInText("to100, then up95"), "to 100, then up 95")
    }

    func testSplitsTitleCasePrefix() {
        XCTAssertEqual(WordNumberSplitter.splitInText("Next30 minutes"), "Next 30 minutes")
        XCTAssertEqual(WordNumberSplitter.splitInText("Hello30"), "Hello 30")
    }

    func testLeavesCamelCaseAlphanumericsAlone() {
        // Product names with embedded uppercase should not be touched.
        XCTAssertEqual(WordNumberSplitter.splitInText("iPhone15"), "iPhone15")
        XCTAssertEqual(WordNumberSplitter.splitInText("iPad15 vs iPhone15"), "iPad15 vs iPhone15")
    }

    func testLeavesShortPrefixesAlone() {
        // MP3 — uppercase-only prefix doesn't match either branch.
        // v3, H2O — single-letter prefix is shorter than the 2-letter minimum.
        // The digit-run length no longer matters; the prefix shape is what
        // protects these legitimate alphanumerics.
        XCTAssertEqual(WordNumberSplitter.splitInText("MP3 player"), "MP3 player")
        XCTAssertEqual(WordNumberSplitter.splitInText("v3.0 release"), "v3.0 release")
        XCTAssertEqual(WordNumberSplitter.splitInText("H2O bottle"), "H2O bottle")
    }

    func testSplitsSingleDigitFusion() {
        // Fitness/exercise transcripts produce "and3", "add5", "in3" when
        // counting reps or callouts — these single-digit fusions used to
        // pass through and look terrible in subtitles. Now they split.
        XCTAssertEqual(WordNumberSplitter.splitInText("and3 and2 and1"), "and 3 and 2 and 1")
        XCTAssertEqual(WordNumberSplitter.splitInText("add5 to the cadence"), "add 5 to the cadence")
        XCTAssertEqual(WordNumberSplitter.splitInText("in3, two, one"), "in 3, two, one")
    }

    func testSplitsIndefiniteArticleFusion() {
        // Parakeet sometimes fuses the indefinite article "a" with the
        // following number ("a90-degree hold", "a15 second recovery").
        // The single-letter prefix is allowed only when the digit run is
        // ≥ 2, so legit identifiers like "v3" / "H2O" stay untouched
        // (covered by testLeavesShortPrefixesAlone).
        XCTAssertEqual(WordNumberSplitter.splitInText("a90-degree hold"), "a 90-degree hold")
        XCTAssertEqual(WordNumberSplitter.splitInText("with a10-second hold"), "with a 10-second hold")
        XCTAssertEqual(WordNumberSplitter.splitInText("take a15 second recovery"), "take a 15 second recovery")
    }

    func testLeavesAllCapsAlphanumericsAlone() {
        // All-caps prefix (acronyms like LSU30, NASA90) — don't auto-split.
        XCTAssertEqual(WordNumberSplitter.splitInText("LSU30 jersey"), "LSU30 jersey")
        XCTAssertEqual(WordNumberSplitter.splitInText("HTTP200 OK"), "HTTP200 OK")
    }

    func testLeavesDigitPrefixedTokensAlone() {
        // Tokens that *start* with digits ("90s", "1080p") shouldn't change.
        XCTAssertEqual(WordNumberSplitter.splitInText("the 90s were great"), "the 90s were great")
        XCTAssertEqual(WordNumberSplitter.splitInText("rendered at 1080p"), "rendered at 1080p")
    }

    func testIsIdempotent() {
        let once = WordNumberSplitter.splitInText("next30 minutes between80 and90.")
        let twice = WordNumberSplitter.splitInText(once)
        XCTAssertEqual(once, twice)
    }

    func testHandlesEmptyAndPlainText() {
        XCTAssertEqual(WordNumberSplitter.splitInText(""), "")
        XCTAssertEqual(WordNumberSplitter.splitInText("nothing to split here"), "nothing to split here")
    }

    // MARK: - Token path

    func testSplitTokenReturnsNilForCleanTokens() {
        XCTAssertNil(WordNumberSplitter.splitToken("hello"))
        XCTAssertNil(WordNumberSplitter.splitToken("MP3"))
        XCTAssertNil(WordNumberSplitter.splitToken("iPhone15"))
        XCTAssertNil(WordNumberSplitter.splitToken("90s"))
    }

    func testSplitTokenReturnsParts() {
        guard let parts = WordNumberSplitter.splitToken("next30") else {
            XCTFail("expected split for 'next30'")
            return
        }
        XCTAssertEqual(parts.prefix, "next")
        XCTAssertEqual(parts.suffix, "30")
    }

    func testSplitTokenKeepsTrailingPunctuationWithSuffix() {
        let parts = WordNumberSplitter.splitToken("arms30.")
        XCTAssertEqual(parts?.prefix, "arms")
        XCTAssertEqual(parts?.suffix, "30.")

        let plural = WordNumberSplitter.splitToken("high90s,")
        XCTAssertEqual(plural?.prefix, "high")
        XCTAssertEqual(plural?.suffix, "90s,")
    }

    // MARK: - WordTimestamp path

    func testSplitWordsRewritesTokenWithInteriorSpace() {
        let input = [
            WordTimestamp(word: "next30", startMs: 1000, endMs: 1600, confidence: 0.9, speakerId: "S1")
        ]
        let out = WordNumberSplitter.splitWords(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].word, "next 30")
        XCTAssertEqual(out[0].startMs, 1000)
        XCTAssertEqual(out[0].endMs, 1600)
        XCTAssertEqual(out[0].confidence, 0.9)
        XCTAssertEqual(out[0].speakerId, "S1")
    }

    func testSplitWordsLeavesCleanTokensUntouched() {
        let input = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 200, confidence: 1, speakerId: nil),
            WordTimestamp(word: "MP3", startMs: 200, endMs: 400, confidence: 1, speakerId: nil),
            WordTimestamp(word: "iPhone15", startMs: 400, endMs: 700, confidence: 1, speakerId: nil)
        ]
        let out = WordNumberSplitter.splitWords(input)
        XCTAssertEqual(out, input)
    }

    func testSplitWordsKeepsPunctuationWithNumber() {
        let input = [
            WordTimestamp(word: "arms30.", startMs: 0, endMs: 500, confidence: 0.95, speakerId: nil),
            WordTimestamp(word: "high90s,", startMs: 500, endMs: 1000, confidence: 0.95, speakerId: nil)
        ]
        let out = WordNumberSplitter.splitWords(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].word, "arms 30.")
        XCTAssertEqual(out[1].word, "high 90s,")
    }

    // MARK: - Pipeline integration

    func testPipelineRunsSplitStep() {
        let pipeline = TextProcessingPipeline()
        let result = pipeline.process(
            text: "we'll spend the next30 minutes between80 and90.",
            customWords: [],
            snippets: []
        )
        XCTAssertEqual(result.text, "We'll spend the next 30 minutes between 80 and 90.")
    }
}
