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
    /// where the digit form is correct. NOTE: a *sequence* of bare
    /// digits separated by commas IS converted (countdown pass) —
    /// tests for that live below.
    func testSingleDigitWithoutMeasurementUnitOrCountdownStaysDigit() {
        XCTAssertEqual(NumberNormalizer.normalize("level 4"), "level 4")
        XCTAssertEqual(NumberNormalizer.normalize("iPhone 5"), "iPhone 5")
        XCTAssertEqual(NumberNormalizer.normalize("4 PM"), "4 PM")
        XCTAssertEqual(NumberNormalizer.normalize("got a 4 today"), "got a 4 today")
    }

    // MARK: - Countdown sequence pass

    /// SRT 37 feedback: Whisper sometimes outputs countdown phrases
    /// as digits ("in 3, 2, 1, sit and recover") even when the
    /// speaker said "three, two, one". The measurement pass doesn't
    /// catch these because there's no unit after the digit. The
    /// countdown pass converts any sequence of 2+ single-digit
    /// cardinals separated by commas.
    func testThreeTwoOneCountdownGetsSpelled() {
        XCTAssertEqual(
            NumberNormalizer.normalize("in 3, 2, 1, sit and recover"),
            "in three, two, one, sit and recover"
        )
    }

    func testCountdownWithAndBeforeLastGetsSpelled() {
        XCTAssertEqual(
            NumberNormalizer.normalize("high 80s in 3, 2, and 1."),
            "high 80s in three, two, and one."
        )
    }

    func testLongerCountdownGetsSpelled() {
        XCTAssertEqual(
            NumberNormalizer.normalize("5, 4, 3, 2, 1, let's go"),
            "five, four, three, two, one, let's go"
        )
    }

    func testTwoDigitCountdownGetsSpelled() {
        // Real failure case (SRT 37 cue 349): "5, 4, weights go
        // down. 3, 2, 1." — two separate countdowns interrupted by
        // text; each one converts independently.
        XCTAssertEqual(
            NumberNormalizer.normalize("5, 4, weights go down. 3, 2, 1."),
            "five, four, weights go down. three, two, one."
        )
    }

    /// Cadence callouts and single bare digits stay as digits — the
    /// `+` quantifier in the countdown regex requires at least one
    /// `, N` after the first digit, so "85" or "100" alone don't
    /// match.
    func testCadenceCalloutsAndStandaloneDigitsStayDigit() {
        XCTAssertEqual(NumberNormalizer.normalize("85, 90, 95, and 100"), "85, 90, 95, and 100")
        XCTAssertEqual(NumberNormalizer.normalize("hold at 100"), "hold at 100")
        XCTAssertEqual(NumberNormalizer.normalize("around 4"), "around 4")
    }

    // MARK: - Trailing countdown (cross-cue leak)

    /// Real failure case from the export iteration: the speech
    /// engine emits "in 3, 2, 1, let's go" as one sentence but the
    /// cue-builder splits it across two cues. Cue N ends with
    /// "...in 3," — a single digit with no second digit in the
    /// same cue to anchor a sequence match. The trigger-word pass
    /// catches "in N," directly.
    func testInDigitCommaGetsSpelled() {
        XCTAssertEqual(
            NumberNormalizer.normalize("our pedals in 3,"),
            "our pedals in three,"
        )
        XCTAssertEqual(
            NumberNormalizer.normalize("next two minutes in 3,"),
            "next two minutes in three,"
        )
        XCTAssertEqual(
            NumberNormalizer.normalize("100 to 105 on your cadence in 3,"),
            "100 to 105 on your cadence in three,"
        )
    }

    func testInDigitPeriodGetsSpelled() {
        XCTAssertEqual(
            NumberNormalizer.normalize("we restart in 3."),
            "we restart in three."
        )
    }

    func testInDigitEndOfStringGetsSpelled() {
        // No trailing punctuation, end-of-string anchor.
        XCTAssertEqual(
            NumberNormalizer.normalize("starting in 5"),
            "starting in five"
        )
    }

    /// "in N + unit" stays owned by the measurement pass and ends
    /// up spelled correctly through that route — trigger pass
    /// should NOT also fire here (would double-process or interfere).
    /// The trailing pass requires `,` / `.` / end-of-string after
    /// the digit; "in 3 minutes" has a space + word, so no match.
    func testInDigitMeasurementGoesThroughMeasurementPath() {
        XCTAssertEqual(
            NumberNormalizer.normalize("in 3 minutes"),
            "in three minutes"
        )
        XCTAssertEqual(
            NumberNormalizer.normalize("in 4 reps"),
            "in four reps"
        )
    }

    /// Bare digits without the trigger word stay digits. The pass
    /// is narrow on purpose — only "in/at/after + digit + punct"
    /// is unambiguous enough to spell out without context.
    func testNonTriggerWordContextStaysDigit() {
        XCTAssertEqual(NumberNormalizer.normalize("level 4."), "level 4.")
        XCTAssertEqual(NumberNormalizer.normalize("scored a 5,"), "scored a 5,")
        XCTAssertEqual(NumberNormalizer.normalize("got a 3."), "got a 3.")
    }
}

