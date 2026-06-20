import FluidAudio
@testable import MacParakeetCore
import XCTest

final class STTWordTimingBuilderTests: XCTestCase {
    func testWordsGroupSentencePieceTokens() {
        let words = STTWordTimingBuilder.words(from: [
            TokenTiming(token: "▁hello", tokenId: 1, startTime: 0.10, endTime: 0.18, confidence: 0.8),
            TokenTiming(token: "world", tokenId: 2, startTime: 0.18, endTime: 0.36, confidence: 1.0),
            TokenTiming(token: "▁again", tokenId: 3, startTime: 0.50, endTime: 0.72, confidence: 0.9),
        ])

        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].word, "helloworld")
        XCTAssertEqual(words[0].startMs, 100)
        XCTAssertEqual(words[0].endMs, 360)
        XCTAssertEqual(words[0].confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(words[1].word, "again")
        XCTAssertEqual(words[1].startMs, 500)
        XCTAssertEqual(words[1].endMs, 720)
        XCTAssertEqual(words[1].confidence, 0.9, accuracy: 0.0001)
    }

    func testWordsIgnoreBlankTokens() {
        let words = STTWordTimingBuilder.words(from: [
            TokenTiming(token: "▁", tokenId: 1, startTime: 0, endTime: 0.08, confidence: 0.5),
            TokenTiming(token: "▁done", tokenId: 2, startTime: 0.16, endTime: 0.32, confidence: 0.95),
        ])

        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].word, "done")
        XCTAssertEqual(words[0].startMs, 160)
        XCTAssertEqual(words[0].endMs, 320)
    }

    func testWordsStartPlainFirstTokenAsWord() {
        let words = STTWordTimingBuilder.words(from: [
            TokenTiming(token: "hello", tokenId: 1, startTime: 0.04, endTime: 0.20, confidence: 0.7),
            TokenTiming(token: "▁world", tokenId: 2, startTime: 0.32, endTime: 0.48, confidence: 0.9),
        ])

        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].word, "hello")
        XCTAssertEqual(words[0].startMs, 40)
        XCTAssertEqual(words[0].endMs, 200)
        XCTAssertEqual(words[1].word, "world")
        XCTAssertEqual(words[1].startMs, 320)
        XCTAssertEqual(words[1].endMs, 480)
    }

    func testWordsReturnEmptyForAllBlankTokens() {
        let words = STTWordTimingBuilder.words(from: [
            TokenTiming(token: "▁", tokenId: 1, startTime: 0.00, endTime: 0.04, confidence: 0.2),
            TokenTiming(token: " ", tokenId: 2, startTime: 0.04, endTime: 0.08, confidence: 0.3),
            TokenTiming(token: "\n", tokenId: 3, startTime: 0.08, endTime: 0.12, confidence: 0.4),
        ])

        XCTAssertTrue(words.isEmpty)
    }

    func testWordsAverageConfidenceAcrossMultipleTokens() {
        let words = STTWordTimingBuilder.words(from: [
            TokenTiming(token: "▁pro", tokenId: 1, startTime: 0.10, endTime: 0.18, confidence: 0.2),
            TokenTiming(token: "duc", tokenId: 2, startTime: 0.18, endTime: 0.26, confidence: 0.5),
            TokenTiming(token: "tion", tokenId: 3, startTime: 0.26, endTime: 0.40, confidence: 0.8),
        ])

        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].word, "production")
        XCTAssertEqual(words[0].startMs, 100)
        XCTAssertEqual(words[0].endMs, 400)
        XCTAssertEqual(words[0].confidence, 0.5, accuracy: 0.0001)
    }
}
