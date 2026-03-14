import XCTest
@testable import MacParakeetCore

final class SpeakerMergerTests: XCTestCase {

    // MARK: - Empty inputs

    func testEmptyWords() {
        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: [], segments: [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 5000)
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptySegments() {
        let words = [WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9)]
        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].speakerId)
    }

    func testBothEmpty() {
        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: [], segments: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Exact overlap

    func testExactOverlap() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9),
            WordTimestamp(word: "world", startMs: 500, endMs: 1000, confidence: 0.9),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000)
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertEqual(result[0].speakerId, "S1")
        XCTAssertEqual(result[1].speakerId, "S1")
    }

    // MARK: - Two speakers

    func testTwoSpeakers() {
        let words = [
            WordTimestamp(word: "Hi", startMs: 0, endMs: 500, confidence: 0.9),
            WordTimestamp(word: "there", startMs: 500, endMs: 1000, confidence: 0.9),
            WordTimestamp(word: "Bye", startMs: 2000, endMs: 2500, confidence: 0.9),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1500),
            SpeakerSegment(speakerId: "S2", startMs: 1500, endMs: 3000),
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertEqual(result[0].speakerId, "S1")
        XCTAssertEqual(result[1].speakerId, "S1")
        XCTAssertEqual(result[2].speakerId, "S2")
    }

    // MARK: - Partial overlap / most overlap wins

    func testPartialOverlapMostOverlapWins() {
        // Word spans 400-900ms. S1 covers 0-600, S2 covers 600-2000.
        // Overlap with S1: 200ms (400-600), overlap with S2: 300ms (600-900)
        // S2 wins.
        let words = [
            WordTimestamp(word: "split", startMs: 400, endMs: 900, confidence: 0.9),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 600),
            SpeakerSegment(speakerId: "S2", startMs: 600, endMs: 2000),
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertEqual(result[0].speakerId, "S2")
    }

    // MARK: - No overlap → nil

    func testNoOverlap() {
        let words = [
            WordTimestamp(word: "gap", startMs: 5000, endMs: 5500, confidence: 0.9),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000),
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertNil(result[0].speakerId)
    }

    // MARK: - Gaps between segments

    func testWordInGap() {
        let words = [
            WordTimestamp(word: "A", startMs: 0, endMs: 500, confidence: 0.9),
            WordTimestamp(word: "gap", startMs: 1500, endMs: 2000, confidence: 0.9),
            WordTimestamp(word: "B", startMs: 3000, endMs: 3500, confidence: 0.9),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000),
            SpeakerSegment(speakerId: "S2", startMs: 2500, endMs: 4000),
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertEqual(result[0].speakerId, "S1")
        XCTAssertNil(result[1].speakerId)
        XCTAssertEqual(result[2].speakerId, "S2")
    }

    // MARK: - Single speaker

    func testSingleSpeaker() {
        let words = (0..<5).map { i in
            WordTimestamp(word: "w\(i)", startMs: i * 300, endMs: i * 300 + 250, confidence: 0.9)
        }
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 5000)
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        for word in result {
            XCTAssertEqual(word.speakerId, "S1")
        }
    }

    // MARK: - Many speakers

    func testManySpeakers() {
        let words = [
            WordTimestamp(word: "A", startMs: 0, endMs: 500, confidence: 0.9),
            WordTimestamp(word: "B", startMs: 1000, endMs: 1500, confidence: 0.9),
            WordTimestamp(word: "C", startMs: 2000, endMs: 2500, confidence: 0.9),
            WordTimestamp(word: "D", startMs: 3000, endMs: 3500, confidence: 0.9),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 800),
            SpeakerSegment(speakerId: "S2", startMs: 800, endMs: 1800),
            SpeakerSegment(speakerId: "S3", startMs: 1800, endMs: 2800),
            SpeakerSegment(speakerId: "S4", startMs: 2800, endMs: 4000),
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertEqual(result[0].speakerId, "S1")
        XCTAssertEqual(result[1].speakerId, "S2")
        XCTAssertEqual(result[2].speakerId, "S3")
        XCTAssertEqual(result[3].speakerId, "S4")
    }

    // MARK: - Tie-breaking: earlier segment wins

    func testTieBreakingEarlierSegmentWins() {
        // Word spans 500-1000ms. S1: 0-750 (250ms overlap), S2: 750-1500 (250ms overlap)
        // Equal overlap → earlier segment (S1) wins
        let words = [
            WordTimestamp(word: "tie", startMs: 500, endMs: 1000, confidence: 0.9),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 750),
            SpeakerSegment(speakerId: "S2", startMs: 750, endMs: 1500),
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertEqual(result[0].speakerId, "S1")
    }

    // MARK: - Preserves word content

    func testPreservesWordContent() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.95),
        ]
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000)
        ]

        let result = SpeakerMerger.mergeWordTimestampsWithSpeakers(words: words, segments: segments)
        XCTAssertEqual(result[0].word, "Hello")
        XCTAssertEqual(result[0].startMs, 0)
        XCTAssertEqual(result[0].endMs, 500)
        XCTAssertEqual(result[0].confidence, 0.95)
        XCTAssertEqual(result[0].speakerId, "S1")
    }
}
