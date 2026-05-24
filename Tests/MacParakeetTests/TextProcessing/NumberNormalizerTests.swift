import XCTest
@testable import MacParakeetCore

final class NumberNormalizerTests: XCTestCase {

    // MARK: - Tens / teens (standalone)

    func testStandaloneTens() {
        XCTAssertEqual(NumberNormalizer.normalize("ten"), "10")
        XCTAssertEqual(NumberNormalizer.normalize("twenty"), "20")
        XCTAssertEqual(NumberNormalizer.normalize("ninety"), "90")
    }

    func testStandaloneTeens() {
        XCTAssertEqual(NumberNormalizer.normalize("eleven"), "11")
        XCTAssertEqual(NumberNormalizer.normalize("nineteen"), "19")
    }

    func testStandaloneTensInSentence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("next thirty seconds"),
            "next 30 seconds"
        )
        XCTAssertEqual(
            NumberNormalizer.normalize("Hold for ten breaths."),
            "Hold for 10 breaths."
        )
    }

    // MARK: - Hyphenated compounds

    func testHyphenatedCompounds() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty-five"), "25")
        XCTAssertEqual(NumberNormalizer.normalize("forty-three"), "43")
        XCTAssertEqual(NumberNormalizer.normalize("ninety-nine"), "99")
    }

    func testHyphenatedCompoundsInSentence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("Do forty-five reps."),
            "Do 45 reps."
        )
    }

    // MARK: - Space-separated compounds

    func testSpaceSeparatedCompounds() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty five"), "25")
        XCTAssertEqual(NumberNormalizer.normalize("sixty two"), "62")
    }

    // MARK: - 1–9 NOT touched standalone

    func testSinglesAreNotNormalised() {
        XCTAssertEqual(NumberNormalizer.normalize("one of them"), "one of them")
        XCTAssertEqual(NumberNormalizer.normalize("two ways to go"), "two ways to go")
        XCTAssertEqual(NumberNormalizer.normalize("five"), "five")
    }

    // MARK: - Idempotency

    func testIdempotency() {
        let input = "Hold for thirty seconds and do forty-five reps."
        let once = NumberNormalizer.normalize(input)
        let twice = NumberNormalizer.normalize(once)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once, "Hold for 30 seconds and do 45 reps.")
    }

    // MARK: - Case insensitivity

    func testCaseInsensitive() {
        XCTAssertEqual(NumberNormalizer.normalize("Twenty"), "20")
        XCTAssertEqual(NumberNormalizer.normalize("FORTY"), "40")
        XCTAssertEqual(NumberNormalizer.normalize("Sixty-Two"), "62")
    }

    // MARK: - Word-boundary safety

    func testDoesNotSplitMidWord() {
        // "tenant" contains "ten" but must not become "10ant".
        XCTAssertEqual(NumberNormalizer.normalize("the tenant moved"), "the tenant moved")
        // "fortyish" is not a real word but a safety check for boundary handling.
        XCTAssertEqual(NumberNormalizer.normalize("fortyish"), "fortyish")
    }

    func testEmptyString() {
        XCTAssertEqual(NumberNormalizer.normalize(""), "")
    }

    // MARK: - Hundreds

    func testHundredCardinals() {
        XCTAssertEqual(NumberNormalizer.normalize("one hundred"), "100")
        XCTAssertEqual(NumberNormalizer.normalize("five hundred"), "500")
        XCTAssertEqual(NumberNormalizer.normalize("nine hundred"), "900")
    }

    func testHundredsInSentence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("ninety-five to one hundred"),
            "95 to 100"
        )
        XCTAssertEqual(
            NumberNormalizer.normalize("one hundred plus"),
            "100 plus"
        )
    }

    // MARK: - "X oh Y" form

    func testOhFormReadsAsHundredsAndOnes() {
        XCTAssertEqual(NumberNormalizer.normalize("one oh five"), "105")
        XCTAssertEqual(NumberNormalizer.normalize("two oh seven"), "207")
        XCTAssertEqual(NumberNormalizer.normalize("nine oh nine"), "909")
    }

    func testOhFormInSentence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("one hundred to one oh five"),
            "100 to 105"
        )
    }

    // MARK: - 1-9 + measurement unit → digit

    /// Direction is spelled→digit to match precedent set by digit
    /// forms already in the SRT (Whisper emits both inconsistently;
    /// user feedback was about CONSISTENCY, not direction).
    func testHyphenatedCardinalUnitDigitizes() {
        XCTAssertEqual(NumberNormalizer.normalize("four-minute warm-up"), "4-minute warm-up")
        XCTAssertEqual(NumberNormalizer.normalize("one-minute intervals"), "1-minute intervals")
        XCTAssertEqual(NumberNormalizer.normalize("nine-second hold"), "9-second hold")
    }

    func testSpaceSeparatedCardinalUnitDigitizes() {
        XCTAssertEqual(NumberNormalizer.normalize("two minutes"), "2 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("eight minutes of curls"), "8 minutes of curls")
        XCTAssertEqual(NumberNormalizer.normalize("three reps"), "3 reps")
    }

    /// Pronoun / quantifier forms stay spelled — no measurement unit
    /// follows, so the measurement pass doesn't match.
    func testCardinalAsQuantifierStaysSpelled() {
        XCTAssertEqual(NumberNormalizer.normalize("two ways to go"), "two ways to go")
        XCTAssertEqual(NumberNormalizer.normalize("one of them"), "one of them")
        XCTAssertEqual(NumberNormalizer.normalize("five fingers"), "five fingers")
    }

    /// 10+ cardinals digitize via the standalone / compound /
    /// hundred / oh passes (covered above) — measurement pass also
    /// works for 1-9 + unit. Both directions land at digits.
    func testTensAndAboveStillDigitize() {
        XCTAssertEqual(NumberNormalizer.normalize("ten minutes"), "10 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("fifteen reps"), "15 reps")
        XCTAssertEqual(NumberNormalizer.normalize("thirty seconds"), "30 seconds")
        XCTAssertEqual(NumberNormalizer.normalize("forty-five reps"), "45 reps")
        XCTAssertEqual(NumberNormalizer.normalize("one hundred seconds"), "100 seconds")
    }

    // MARK: - Digit forms pass through unchanged

    /// Whisper-native digit forms stay as digits — no spelled
    /// pass converts them back. Consistency-as-digits is the rule.
    func testDigitMeasurementFormsStayDigit() {
        XCTAssertEqual(NumberNormalizer.normalize("4 minutes"), "4 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("3 reps"), "3 reps")
        XCTAssertEqual(NumberNormalizer.normalize("4-minute warm-up"), "4-minute warm-up")
        XCTAssertEqual(NumberNormalizer.normalize("10 minutes"), "10 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("44 minutes"), "44 minutes")
    }

    /// Bare digits in any context stay as digits — levels, versions,
    /// times, cadence increments.
    func testBareDigitStaysDigit() {
        XCTAssertEqual(NumberNormalizer.normalize("level 4"), "level 4")
        XCTAssertEqual(NumberNormalizer.normalize("iPhone 5"), "iPhone 5")
        XCTAssertEqual(NumberNormalizer.normalize("4 PM"), "4 PM")
        XCTAssertEqual(NumberNormalizer.normalize("got a 4 today"), "got a 4 today")
        XCTAssertEqual(NumberNormalizer.normalize("adding 5 to your cadence"), "adding 5 to your cadence")
        XCTAssertEqual(NumberNormalizer.normalize("Round 1 is done."), "Round 1 is done.")
        XCTAssertEqual(NumberNormalizer.normalize("on to round 2."), "on to round 2.")
    }

    // MARK: - Spelled countdown → digit

    /// Spelled-out countdowns ("three, two, one") get digitized to
    /// match the digit forms Whisper sometimes emits ("3, 2, 1")
    /// for the same audio. Outer regex requires 2+ cardinals
    /// separated by commas, so single spelled cardinals stay alone.
    func testSpelledThreeTwoOneDigitizes() {
        XCTAssertEqual(
            NumberNormalizer.normalize("Three, two, one, sit, 80 to 85."),
            "3, 2, 1, sit, 80 to 85."
        )
    }

    func testSpelledCountdownWithAndBeforeLastDigitizes() {
        XCTAssertEqual(
            NumberNormalizer.normalize("in three, two, and one."),
            "in 3, 2, and 1."
        )
    }

    func testSpelledFiveFourDigitizes() {
        XCTAssertEqual(
            NumberNormalizer.normalize("five, four, weights go down. three, two, one."),
            "5, 4, weights go down. 3, 2, 1."
        )
    }

    /// Digit countdowns pass through unchanged (already in target form).
    func testDigitCountdownStaysDigit() {
        XCTAssertEqual(
            NumberNormalizer.normalize("in 3, 2, 1, sit and recover"),
            "in 3, 2, 1, sit and recover"
        )
        XCTAssertEqual(
            NumberNormalizer.normalize("high 80s in 3, 2, and 1."),
            "high 80s in 3, 2, and 1."
        )
    }

    /// A SINGLE spelled cardinal in non-countdown context stays
    /// spelled — the `+` quantifier requires at least one follow-up
    /// `, N` to match.
    func testSingleSpelledCardinalStaysSpelled() {
        XCTAssertEqual(NumberNormalizer.normalize("one of them"), "one of them")
        XCTAssertEqual(NumberNormalizer.normalize("two ways to go"), "two ways to go")
        XCTAssertEqual(NumberNormalizer.normalize("five fingers"), "five fingers")
    }
}

