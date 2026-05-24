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

    // MARK: - 1-9 cardinals (intentionally left spelled out)

    /// SRT 35 feedback: digit-only forms like "4 minute" / "1 minute"
    /// read awkwardly in subtitles. Per standard editorial convention
    /// (AP / Chicago style: spell out one through nine, use digits
    /// for 10+), 1-9 cardinals stay spelled — even when followed by
    /// a measurement unit or hyphenated to one.
    func testHyphenatedCardinalUnitStaysSpelled() {
        XCTAssertEqual(NumberNormalizer.normalize("four-minute warm-up"), "four-minute warm-up")
        XCTAssertEqual(NumberNormalizer.normalize("one-minute intervals"), "one-minute intervals")
        XCTAssertEqual(NumberNormalizer.normalize("nine-second hold"), "nine-second hold")
    }

    func testSpaceSeparatedCardinalUnitStaysSpelled() {
        XCTAssertEqual(NumberNormalizer.normalize("two minutes"), "two minutes")
        XCTAssertEqual(NumberNormalizer.normalize("eight minutes of curls"), "eight minutes of curls")
        XCTAssertEqual(NumberNormalizer.normalize("three reps"), "three reps")
    }

    /// Pronoun / quantifier forms also stay spelled (still 1-9, so
    /// nothing changes vs the prior behaviour here — these would
    /// have been wrong to digitize whether or not a unit followed).
    func testCardinalAsQuantifierStaysSpelled() {
        XCTAssertEqual(NumberNormalizer.normalize("two ways to go"), "two ways to go")
        XCTAssertEqual(NumberNormalizer.normalize("one of them"), "one of them")
        XCTAssertEqual(NumberNormalizer.normalize("five fingers"), "five fingers")
    }

    /// 10+ cardinals still digitize — the other passes (standalone /
    /// compound / hundred / oh) handle these. Pinning here so a
    /// future "spell out everything" regression would surface.
    func testTensAndAboveStillDigitize() {
        XCTAssertEqual(NumberNormalizer.normalize("ten minutes"), "10 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("fifteen reps"), "15 reps")
        XCTAssertEqual(NumberNormalizer.normalize("thirty seconds"), "30 seconds")
        XCTAssertEqual(NumberNormalizer.normalize("forty-five reps"), "45 reps")
        XCTAssertEqual(NumberNormalizer.normalize("one hundred seconds"), "100 seconds")
    }

    // MARK: - Digit → spelled reverse pass

    /// SRT 36 feedback: Parakeet emits "4 minutes" / "3 minutes"
    /// natively even when speaker says the spelled form. The reverse
    /// pass converts single-digit cardinals followed by a measurement
    /// unit back to spelled form.
    func testDigitOneToNineWithSpaceUnitGetsSpelled() {
        XCTAssertEqual(NumberNormalizer.normalize("4 minutes"), "four minutes")
        XCTAssertEqual(NumberNormalizer.normalize("3 reps"), "three reps")
        XCTAssertEqual(NumberNormalizer.normalize("1 minute"), "one minute")
        XCTAssertEqual(NumberNormalizer.normalize("8 minutes of curls"), "eight minutes of curls")
    }

    func testDigitOneToNineWithHyphenUnitGetsSpelled() {
        XCTAssertEqual(NumberNormalizer.normalize("4-minute warm-up"), "four-minute warm-up")
        XCTAssertEqual(NumberNormalizer.normalize("9-second hold"), "nine-second hold")
    }

    /// 10+ digits stay as digits — the `[1-9]` upper bound in the
    /// regex pins this so a future "spell everything" regression
    /// would surface here.
    func testDigit10AndAboveStaysDigit() {
        XCTAssertEqual(NumberNormalizer.normalize("10 minutes"), "10 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("15 seconds"), "15 seconds")
        XCTAssertEqual(NumberNormalizer.normalize("44 minutes"), "44 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("100 reps"), "100 reps")
        XCTAssertEqual(NumberNormalizer.normalize("30-second hold"), "30-second hold")
    }

    /// Bare digits without a known measurement unit don't get
    /// touched — those could be levels, versions, scores, etc.
    /// where the digit form is correct.
    func testDigitWithoutMeasurementUnitStaysDigit() {
        XCTAssertEqual(NumberNormalizer.normalize("level 4"), "level 4")
        XCTAssertEqual(NumberNormalizer.normalize("iPhone 5"), "iPhone 5")
        XCTAssertEqual(NumberNormalizer.normalize("4 PM"), "4 PM")
        XCTAssertEqual(NumberNormalizer.normalize("got a 4 today"), "got a 4 today")
    }
}
