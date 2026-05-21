import XCTest
@testable import MacParakeetCore

final class SubtitleSentenceSegmenterTests: XCTestCase {

    // MARK: - Helpers

    /// Synthesize a `[WordTimestamp]` from a sentence string, with a fixed
    /// 200 ms inter-word gap unless `gapsAfter` overrides specific indices.
    private func words(
        _ string: String,
        startMs: Int = 0,
        wordDurMs: Int = 300,
        gapMs: Int = 200,
        gapsAfter: [Int: Int] = [:]
    ) -> [WordTimestamp] {
        let tokens = string.split(separator: " ").map(String.init)
        var out: [WordTimestamp] = []
        var t = startMs
        for (i, tok) in tokens.enumerated() {
            out.append(WordTimestamp(word: tok, startMs: t, endMs: t + wordDurMs, confidence: 0.99))
            let gap = gapsAfter[i] ?? gapMs
            t = t + wordDurMs + gap
        }
        return out
    }

    // MARK: - Word-count invariant

    /// Every test should preserve every word — Σ wordCount across units == input.count.
    private func assertCovers(_ units: [SentenceUnit], _ words: [WordTimestamp], file: StaticString = #file, line: UInt = #line) {
        let total = units.reduce(0) { $0 + $1.wordCount }
        XCTAssertEqual(total, words.count, "SentenceUnits must cover every input word", file: file, line: line)
        for i in 1..<units.count {
            XCTAssertEqual(units[i].startIndex, units[i - 1].endIndex + 1,
                "Units must be contiguous; got gap at \(i)", file: file, line: line)
        }
    }

    // MARK: - Aligner

    func testAlignerBuildsContiguousSpans() {
        let ws = words("Hello world today")
        let view = SubtitleSentenceAligner.align(words: ws)
        XCTAssertEqual(view.joinedText, "Hello world today")
        XCTAssertEqual(view.spans.count, 3)
        XCTAssertEqual(view.spans[0].textStart, 0)
        XCTAssertEqual(view.spans[0].textEnd, 5)
        XCTAssertEqual(view.spans[1].textStart, 6)
        XCTAssertEqual(view.spans[1].textEnd, 11)
        XCTAssertEqual(view.spans[2].textStart, 12)
        XCTAssertEqual(view.spans[2].textEnd, 17)
    }

    func testAlignerFindsWordsForCharRange() {
        let ws = words("Hello world today")
        let view = SubtitleSentenceAligner.align(words: ws)
        // Range "world tod" → words 1..2
        let r = SubtitleSentenceAligner.wordRange(forCharRange: 6, length: 9, in: view)
        XCTAssertEqual(r?.startIndex, 1)
        XCTAssertEqual(r?.endIndex, 2)
    }

    // MARK: - Happy path

    func testThreeSentencesSplitCorrectly() {
        let ws = words("This is one. This is two. This is three.")
        let units = SubtitleSentenceSegmenter.segment(words: ws)
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0].text, "This is one.")
        XCTAssertEqual(units[1].text, "This is two.")
        XCTAssertEqual(units[2].text, "This is three.")
        for u in units {
            XCTAssertTrue(u.endsWithStrongPunctuation)
        }
        assertCovers(units, ws)
    }

    // MARK: - Long sentence

    func testLongSentenceStaysOneUnit() {
        let text = "We are going to spend the next thirty minutes here on the bike mixing some intervals with some arm work."
        let ws = words(text)
        let units = SubtitleSentenceSegmenter.segment(words: ws)
        XCTAssertEqual(units.count, 1, "Single punctuated sentence should remain one unit")
        XCTAssertEqual(units[0].wordCount, ws.count)
        assertCovers(units, ws)
    }

    // MARK: - Tiny sentence

    func testTinySentencesStayDistinctUntilMergePass() {
        let ws = words("Yes. I think so.")
        let units = SubtitleSentenceSegmenter.segment(words: ws)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].text, "Yes.")
        XCTAssertEqual(units[1].text, "I think so.")
        assertCovers(units, ws)
    }

    // MARK: - No punctuation + long-pause fallback

    func testNoPunctuationLongPauseSplitsUnit() {
        // 9 words with no periods. Place a 1800 ms pause after word index 3
        // (between "go" and "we"), and another after index 6.
        let ws = words(
            "let us all go we will work hard today",
            gapsAfter: [3: 1800, 6: 1800]
        )
        let units = SubtitleSentenceSegmenter.segment(words: ws, longPauseMs: 1500)
        XCTAssertEqual(units.count, 3, "Two long pauses should split into 3 units")
        XCTAssertEqual(units[0].endIndex, 3)
        XCTAssertEqual(units[1].endIndex, 6)
        XCTAssertEqual(units[2].endIndex, 8)
        for u in units {
            XCTAssertFalse(u.endsWithStrongPunctuation, "No periods → no strong punctuation")
        }
        assertCovers(units, ws)
    }

    // MARK: - Honorifics

    func testHonorificDoesNotEndUnit() {
        let ws = words("Hello Mr. Smith. How are you?")
        let units = SubtitleSentenceSegmenter.segment(words: ws)
        XCTAssertEqual(units.count, 2, "'Mr.' must not start a new unit")
        XCTAssertEqual(units[0].text, "Hello Mr. Smith.")
        XCTAssertEqual(units[1].text, "How are you?")
        assertCovers(units, ws)
    }

    // MARK: - Degenerate

    func testEmptyInputReturnsEmpty() {
        let units = SubtitleSentenceSegmenter.segment(words: [])
        XCTAssertTrue(units.isEmpty)
    }

    func testSingleWordReturnsOneUnit() {
        let ws = words("Hello.")
        let units = SubtitleSentenceSegmenter.segment(words: ws)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].text, "Hello.")
        assertCovers(units, ws)
    }
}
