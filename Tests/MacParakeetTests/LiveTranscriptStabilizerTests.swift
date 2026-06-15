import XCTest
@testable import MacParakeetCore

/// Tests for `LiveTranscriptStabilizer` — the layer that turns the rolling,
/// frequently-revised live preview stream into a stable, append-only readout.
final class LiveTranscriptStabilizerTests: XCTestCase {

    // MARK: - Helpers

    /// Default holdback is 3; use words so the body/hypothesis split is obvious.
    private func makeStabilizer(
        hypothesisHoldback: Int = 3,
        anchorLength: Int = 6,
        maxCommittedWords: Int = 120
    ) -> LiveTranscriptStabilizer {
        LiveTranscriptStabilizer(
            hypothesisHoldback: hypothesisHoldback,
            anchorLength: anchorLength,
            maxCommittedWords: maxCommittedWords
        )
    }

    // MARK: - First ingest

    func testFirstIngestShowsEverything() {
        var s = makeStabilizer()
        XCTAssertEqual(s.ingest("the quick brown fox jumps"), "the quick brown fox jumps")
    }

    func testFirstIngestCommitsAllButHoldback() {
        var s = makeStabilizer()
        _ = s.ingest("the quick brown fox jumps")
        // 5 words, holdback 3 → first 2 committed.
        XCTAssertEqual(s.committedWords, ["the", "quick"])
    }

    func testShortUtteranceCommitsNothingButStillShows() {
        var s = makeStabilizer()
        // Fewer words than the holdback → nothing committed yet, all hypothesis.
        XCTAssertEqual(s.ingest("hello there"), "hello there")
        XCTAssertEqual(s.committedWords, [])
    }

    func testEmptyIngestKeepsExistingReadout() {
        var s = makeStabilizer()
        _ = s.ingest("the quick brown fox jumps")
        XCTAssertEqual(s.ingest("   "), "the quick brown fox jumps")
        XCTAssertEqual(s.ingest(""), "the quick brown fox jumps")
    }

    func testEmptyIngestKeepsShortHypothesisReadout() {
        var s = makeStabilizer()
        _ = s.ingest("hello there")
        XCTAssertEqual(s.ingest("   "), "hello there")
        XCTAssertEqual(s.committedWords, [])
    }

    // MARK: - Growing window (cumulative)

    func testGrowingWindowAppendsMonotonically() {
        var s = makeStabilizer()
        XCTAssertEqual(s.ingest("a b c d e"), "a b c d e")
        XCTAssertEqual(s.ingest("a b c d e f"), "a b c d e f")
        XCTAssertEqual(s.ingest("a b c d e f g"), "a b c d e f g")
        XCTAssertEqual(s.committedWords, ["a", "b", "c", "d"])
    }

    func testNemotronStyleCumulativePartials() {
        var s = makeStabilizer()
        XCTAssertEqual(s.ingest("hello"), "hello")
        XCTAssertEqual(s.ingest("hello world"), "hello world")
        XCTAssertEqual(s.ingest("hello world how"), "hello world how")
        XCTAssertEqual(s.ingest("hello world how are you"), "hello world how are you")
        XCTAssertEqual(s.ingest("hello world how are you today"), "hello world how are you today")
        XCTAssertEqual(s.committedWords, ["hello", "world", "how"])
    }

    // MARK: - Sliding window (Parakeet) — front drops off, back grows

    func testSlidingWindowKeepsCommittedBodyStable() {
        var s = makeStabilizer()
        // Simulate a sliding window that drops the front while extending the back.
        XCTAssertEqual(s.ingest("a b c d e"), "a b c d e")        // commit a b
        XCTAssertEqual(s.ingest("b c d e f"), "a b c d e f")      // commit c
        XCTAssertEqual(s.ingest("c d e f g"), "a b c d e f g")    // commit d
        XCTAssertEqual(s.ingest("d e f g h"), "a b c d e f g h")  // commit e
        XCTAssertEqual(s.ingest("e f g h i"), "a b c d e f g h i")
        // Nothing already shown was ever dropped or reordered.
        XCTAssertEqual(s.committedWords, ["a", "b", "c", "d", "e", "f"])
    }

    func testSlidingWindowThatDropsMultipleWordsPerPass() {
        var s = makeStabilizer()
        XCTAssertEqual(s.ingest("one two three four five six"), "one two three four five six")
        // Window jumps forward by three words at once.
        XCTAssertEqual(
            s.ingest("four five six seven eight nine"),
            "one two three four five six seven eight nine"
        )
    }

    // MARK: - Trailing-word revision must not corrupt the committed body

    func testTrailingHypothesisRevisionDoesNotCorruptBody() {
        var s = makeStabilizer()
        // "emo" is an incomplete trailing word that later resolves to "emotion".
        XCTAssertEqual(s.ingest("your mind or your emo"), "your mind or your emo")
        XCTAssertEqual(s.ingest("your mind or your emotion"), "your mind or your emotion")
        XCTAssertEqual(s.ingest("your mind or your emotion or"), "your mind or your emotion or")
        // The incomplete "emo" was held back as hypothesis, never committed.
        XCTAssertFalse(s.committedWords.contains("emo"))
        XCTAssertEqual(s.committedWords, ["your", "mind", "or"])
    }

    // MARK: - Punctuation / casing drift in the overlap region

    func testPunctuationAndCasingDriftStillAligns() {
        var s = makeStabilizer()
        _ = s.ingest("so first of all we should")
        // Next pass capitalizes the sentence start and adds a comma — alignment
        // is normalized so this does not double-commit "so first".
        let out = s.ingest("So first of all, we should decide now")
        // Display keeps original punctuation ("all,"); only alignment is
        // normalized, so "so first of all" is not double-committed.
        XCTAssertEqual(out, "so first of all, we should decide now")
        // No duplicated "so"/"first" leaked into the committed body.
        XCTAssertEqual(s.committedWords.filter { $0.lowercased() == "first" }.count, 1)
    }

    // MARK: - Repeated phrases

    func testRepeatedPhraseIsNeitherDroppedNorDuplicated() {
        var s = makeStabilizer()
        XCTAssertEqual(s.ingest("the cat the cat sat"), "the cat the cat sat")
        // Extending the same repeated phrase must keep both copies and not
        // collapse or duplicate the repeated run.
        let out = s.ingest("the cat the cat sat down")
        XCTAssertEqual(out, "the cat the cat sat down")
    }

    func testAdjacentStutterOnAnchorWordIsNotDuplicated() {
        var s = makeStabilizer(hypothesisHoldback: 0)
        _ = s.ingest("we need the")
        // The transcriber stutters the committed tail word ("the the"). The weak
        // single-word anchor takes the rightmost match so the readout advances
        // past the stutter instead of re-appending "the".
        XCTAssertEqual(s.ingest("the the report now"), "we need the report now")
    }

    // MARK: - Shorter re-statement (retraction) must not duplicate

    func testShorterRestatementDoesNotDuplicate() {
        var s = makeStabilizer()
        _ = s.ingest("alpha bravo charlie delta echo")   // commits alpha bravo
        // A glitchy shorter pass that re-states an already-committed prefix.
        let out = s.ingest("alpha bravo")
        XCTAssertEqual(out, "alpha bravo")
        XCTAssertEqual(s.committedWords, ["alpha", "bravo"])
    }

    // MARK: - Genuine gap (long pause) appends new content

    func testNonOverlappingGapAppendsAsNew() {
        var s = makeStabilizer()
        _ = s.ingest("first sentence ends here now")       // commits "first sentence"
        // Speaker paused; the window moved entirely onto new, non-overlapping
        // words — they are appended after the committed body rather than
        // replacing it.
        let out = s.ingest("brand new unrelated words appear")
        XCTAssertTrue(out.hasPrefix("first sentence"))
        XCTAssertTrue(out.hasSuffix("brand new unrelated words appear"))
    }

    // MARK: - Memory cap

    func testCommittedBufferIsCapped() {
        var s = makeStabilizer(hypothesisHoldback: 0, maxCommittedWords: 5)
        for i in 0..<50 {
            _ = s.ingest((0...i).map { "w\($0)" }.joined(separator: " "))
        }
        XCTAssertLessThanOrEqual(s.committedWords.count, 5)
        // The most recent words are retained.
        XCTAssertEqual(s.committedWords.last, "w49")
    }

    // MARK: - Reset

    func testResetClearsCommittedState() {
        var s = makeStabilizer()
        _ = s.ingest("a b c d e f")
        XCTAssertFalse(s.committedWords.isEmpty)
        s.reset()
        XCTAssertEqual(s.committedWords, [])
        // A fresh session starts clean — no leakage from the prior transcript.
        XCTAssertEqual(s.ingest("x y z"), "x y z")
        XCTAssertEqual(s.committedWords, [])
    }

    // MARK: - Idempotence

    func testRepeatedIdenticalIngestIsStable() {
        var s = makeStabilizer()
        let first = s.ingest("the quick brown fox jumps over")
        let again = s.ingest("the quick brown fox jumps over")
        XCTAssertEqual(first, again)
        XCTAssertEqual(s.committedWords, ["the", "quick", "brown"])
    }
}
