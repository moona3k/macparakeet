import XCTest
@testable import MacParakeetCore

final class TranscriptParagraphBuilderTests: XCTestCase {
    func testGroupsThreeSentencesIntoOneReadableParagraph() {
        let words = [
            word("First.", startMs: 0, endMs: 400),
            word("Second.", startMs: 500, endMs: 900),
            word("Third.", startMs: 1_000, endMs: 1_400),
            word("Fourth.", startMs: 1_500, endMs: 1_900),
        ]

        let paragraphs = TranscriptParagraphBuilder.build(from: words)

        XCTAssertEqual(
            paragraphs,
            [
                TranscriptParagraph(
                    startMs: 0,
                    endMs: 1_400,
                    text: "First. Second. Third.",
                    speakerId: nil
                ),
                TranscriptParagraph(
                    startMs: 1_500,
                    endMs: 1_900,
                    text: "Fourth.",
                    speakerId: nil
                ),
            ])
    }

    func testStartsANewParagraphWhenTheSpeakerChanges() {
        let words = [
            word("Hello", startMs: 0, endMs: 300, speakerId: "speaker-1"),
            word("there", startMs: 350, endMs: 650),
            word("Hi", startMs: 700, endMs: 900, speakerId: "speaker-2"),
        ]

        let paragraphs = TranscriptParagraphBuilder.build(from: words)

        XCTAssertEqual(
            paragraphs,
            [
                TranscriptParagraph(
                    startMs: 0,
                    endMs: 650,
                    text: "Hello there",
                    speakerId: "speaker-1"
                ),
                TranscriptParagraph(
                    startMs: 700,
                    endMs: 900,
                    text: "Hi",
                    speakerId: "speaker-2"
                ),
            ])
    }

    func testStartsANewParagraphAfterAReadingPause() {
        let words = [
            word("Before", startMs: 0, endMs: 500),
            word("After", startMs: 3_000, endMs: 3_400),
        ]

        let paragraphs = TranscriptParagraphBuilder.build(from: words)

        XCTAssertEqual(paragraphs.map(\.text), ["Before", "After"])
    }

    func testCapsAParagraphAtEightyWords() {
        let words = (0..<81).map { index in
            word("word\(index)", startMs: index * 100, endMs: index * 100 + 50)
        }

        let paragraphs = TranscriptParagraphBuilder.build(from: words)

        XCTAssertEqual(paragraphs.map { $0.text.split(separator: " ").count }, [80, 1])
        XCTAssertEqual(paragraphs.last?.text, "word80")
    }

    func testCarriesSpeakerIdentityAcrossSentenceBoundaries() {
        let words = [
            word("First.", startMs: 0, endMs: 300, speakerId: "speaker-1"),
            word("Second.", startMs: 350, endMs: 650),
            word("Third.", startMs: 700, endMs: 1_000),
            word("Fourth.", startMs: 1_050, endMs: 1_350),
        ]

        let paragraphs = TranscriptParagraphBuilder.build(from: words)

        XCTAssertEqual(paragraphs.map(\.speakerId), ["speaker-1", "speaker-1"])
    }

    private func word(
        _ text: String,
        startMs: Int,
        endMs: Int,
        speakerId: String? = nil
    ) -> WordTimestamp {
        WordTimestamp(
            word: text,
            startMs: startMs,
            endMs: endMs,
            confidence: 0.9,
            speakerId: speakerId
        )
    }
}
