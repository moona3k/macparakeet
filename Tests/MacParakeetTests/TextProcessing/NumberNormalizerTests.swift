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

    // MARK: - 1-9 + measurement units

    func testHyphenatedCardinalUnit() {
        XCTAssertEqual(NumberNormalizer.normalize("four-minute warm-up"), "4-minute warm-up")
        XCTAssertEqual(NumberNormalizer.normalize("one-minute intervals"), "1-minute intervals")
        XCTAssertEqual(NumberNormalizer.normalize("nine-second hold"), "9-second hold")
    }

    func testSpaceSeparatedCardinalUnit() {
        XCTAssertEqual(NumberNormalizer.normalize("two minutes"), "2 minutes")
        XCTAssertEqual(NumberNormalizer.normalize("eight minutes of curls"), "8 minutes of curls")
        XCTAssertEqual(NumberNormalizer.normalize("three reps"), "3 reps")
    }

    func testCardinalNotFollowedByUnitStillSkipped() {
        // The pronoun reading is preserved when the next word isn't a known unit.
        XCTAssertEqual(NumberNormalizer.normalize("two ways to go"), "two ways to go")
        XCTAssertEqual(NumberNormalizer.normalize("one of them"), "one of them")
        XCTAssertEqual(NumberNormalizer.normalize("five fingers"), "five fingers")
    }
}
