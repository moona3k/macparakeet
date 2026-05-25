import XCTest
@testable import MacParakeetCore

/// Integration tests for the LLM review pass.
///
/// Two layers covered here:
/// 1. `SubtitleLLMReviewer.review(...)` — drives the LLM round-trip
///    with a scripted mock and asserts the parsed suggestions are
///    what we expect per pair.
/// 2. `ExportService.applyReviewSuggestionsForTesting(...)` — feeds a
///    pre-built suggestion list through the actual cue-mutation path
///    and asserts the cue array changes (or doesn't) correctly.
///
/// The two layers are tested separately so a parsing/prompt change
/// can't accidentally mask an apply-pass regression and vice-versa.
@MainActor
final class SubtitleLLMReviewerTests: XCTestCase {

    // MARK: - Reviewer with scripted LLM

    /// 3 cues → 2 pairs. With default `pairsPerBatch = 5`, both pairs
    /// fit in ONE batched LLM call. Mock returns a single response with
    /// two decisions: shift_to_a for pair 0, keep for pair 1.
    func testReviewProducesOneSuggestionPerPair() async {
        let llm = ScriptedReviewerLLM(responses: [
            #"{"decisions":[{"pair":0,"action":"shift_to_a","n":1},{"pair":1,"action":"keep"}]}"#
        ])
        let reviewer = SubtitleLLMReviewer(llmService: llm, maxConcurrency: 1)
        let cues = [
            SubtitleLLMReviewer.ReviewableCue(
                startMs: 0, endMs: 1000, text: "because your 4 minute"
            ),
            SubtitleLLMReviewer.ReviewableCue(
                startMs: 1100, endMs: 2500, text: "warm-up starts right now."
            ),
            SubtitleLLMReviewer.ReviewableCue(
                startMs: 2600, endMs: 4000, text: "If you are new to Connect"
            )
        ]
        let suggestions = await reviewer.review(cues: cues, config: .default)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions[0].pairIndex, 0)
        XCTAssertEqual(suggestions[0].action, .shiftToA(n: 1))
        XCTAssertEqual(suggestions[1].pairIndex, 1)
        XCTAssertEqual(suggestions[1].action, .keep)
    }

    /// Malformed JSON in the LLM response should land as `.keep` for
    /// every pair in the batch — never silently corrupt the layout.
    func testReviewFallsBackToKeepOnMalformedResponse() async {
        let llm = ScriptedReviewerLLM(responses: ["this is not json"])
        let reviewer = SubtitleLLMReviewer(llmService: llm, maxConcurrency: 1)
        let cues = [
            SubtitleLLMReviewer.ReviewableCue(startMs: 0, endMs: 1000, text: "Cue A text here."),
            SubtitleLLMReviewer.ReviewableCue(startMs: 1100, endMs: 2000, text: "Cue B text here.")
        ]
        let s = await reviewer.review(cues: cues, config: .default)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].action, .keep)
    }

    /// LLM throwing (network error, etc.) should also fall back to
    /// `.keep` per pair — never propagate the error up.
    func testReviewFallsBackToKeepWhenLLMThrows() async {
        let reviewer = SubtitleLLMReviewer(llmService: ThrowingLLM(), maxConcurrency: 1)
        let cues = [
            SubtitleLLMReviewer.ReviewableCue(startMs: 0, endMs: 1000, text: "Cue A text here."),
            SubtitleLLMReviewer.ReviewableCue(startMs: 1100, endMs: 2000, text: "Cue B text here.")
        ]
        let s = await reviewer.review(cues: cues, config: .default)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].action, .keep)
    }

    // MARK: - Batching

    /// 8 cues = 7 pairs. With `pairsPerBatch = 5` we get 2 batches: pairs
    /// 0..4 in batch 1, pairs 5..6 in batch 2. Each batch is ONE LLM call.
    /// Verifies the call count + that absolute pair indices come back
    /// correctly mapped from each batch's local indices.
    func testReviewBatchesPairsAndMapsIndicesBack() async {
        let batch1 = #"{"decisions":[{"pair":0,"action":"keep"},{"pair":1,"action":"keep"},{"pair":2,"action":"shift_to_a","n":2},{"pair":3,"action":"keep"},{"pair":4,"action":"keep"}]}"#
        let batch2 = #"{"decisions":[{"pair":0,"action":"merge"},{"pair":1,"action":"keep"}]}"#
        let llm = ScriptedReviewerLLM(responses: [batch1, batch2])
        let reviewer = SubtitleLLMReviewer(
            llmService: llm,
            maxConcurrency: 1,
            pairsPerBatch: 5
        )
        var cues: [SubtitleLLMReviewer.ReviewableCue] = []
        for i in 0..<8 {
            cues.append(SubtitleLLMReviewer.ReviewableCue(
                startMs: i * 1000, endMs: i * 1000 + 800, text: "Cue \(i) text content."
            ))
        }
        let s = await reviewer.review(cues: cues, config: .default)
        XCTAssertEqual(s.count, 7, "7 pairs in, 7 suggestions out")
        XCTAssertEqual(s[2].action, .shiftToA(n: 2), "Pair 2 in batch 1 → absolute index 2")
        XCTAssertEqual(s[5].action, .merge, "Pair 0 in batch 2 → absolute index 5")
        // Only 2 LLM calls total (vs 7 in the old per-pair design).
        XCTAssertEqual(llm.callCount, 2, "Should have made exactly 2 batched calls")
    }

    /// If the LLM returns FEWER decisions than the batch contains
    /// (e.g. truncated response), the missing pairs default to `.keep`
    /// rather than being dropped entirely. Caller relies on this for
    /// progress accounting and final-cue stability.
    func testMissingDecisionsInBatchedResponseDefaultToKeep() async {
        // 3 pairs in the batch, but the response only contains pair 0.
        let llm = ScriptedReviewerLLM(responses: [
            #"{"decisions":[{"pair":0,"action":"shift_to_a","n":1}]}"#
        ])
        let reviewer = SubtitleLLMReviewer(
            llmService: llm,
            maxConcurrency: 1,
            pairsPerBatch: 5
        )
        let cues = (0..<4).map { i in
            SubtitleLLMReviewer.ReviewableCue(
                startMs: i * 1000, endMs: i * 1000 + 800, text: "Cue \(i) text content."
            )
        }
        let s = await reviewer.review(cues: cues, config: .default)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0].action, .shiftToA(n: 1))
        XCTAssertEqual(s[1].action, .keep, "Pair 1 missing from response → defaults to keep")
        XCTAssertEqual(s[2].action, .keep, "Pair 2 missing from response → defaults to keep")
    }

    /// 1-cue input has 0 pairs to review.
    func testReviewWithFewerThanTwoCuesReturnsEmpty() async {
        let reviewer = SubtitleLLMReviewer(
            llmService: ScriptedReviewerLLM(responses: []),
            maxConcurrency: 1
        )
        let cues = [
            SubtitleLLMReviewer.ReviewableCue(startMs: 0, endMs: 1000, text: "Only cue.")
        ]
        let s = await reviewer.review(cues: cues, config: .default)
        XCTAssertEqual(s.count, 0)
    }

    // MARK: - Prompt content

    /// Pin the action vocabulary in the prompt so a future edit makes
    /// noise in the diff.
    func testPromptIncludesActionVocabulary() {
        let a = SubtitleLLMReviewer.ReviewableCue(startMs: 0, endMs: 1000, text: "Cue A")
        let b = SubtitleLLMReviewer.ReviewableCue(startMs: 1100, endMs: 2000, text: "Cue B")
        let prompt = SubtitleLLMReviewer.buildBatchedPrompt(cues: [a, b], prev: nil, next: nil, config: .default)
        for token in [#""keep""#, #""merge""#, #""shift_to_a""#, #""shift_to_b""#] {
            XCTAssertTrue(prompt.contains(token),
                          "Prompt missing action token \(token)")
        }
        XCTAssertTrue(prompt.contains("DEFAULT to \"keep\""),
                      "Prompt should bias toward `keep`")
        XCTAssertTrue(prompt.contains(#""decisions""#),
                      "Batched prompt should describe the `decisions` response shape")
    }

    /// Context cues (prev/next) appear in the prompt when provided,
    /// and not when nil.
    func testPromptIncludesContextWhenProvided() {
        let a = SubtitleLLMReviewer.ReviewableCue(startMs: 0, endMs: 1000, text: "Cue A")
        let b = SubtitleLLMReviewer.ReviewableCue(startMs: 1100, endMs: 2000, text: "Cue B")
        let prev = SubtitleLLMReviewer.ReviewableCue(startMs: -1000, endMs: 0, text: "Previous context")
        let next = SubtitleLLMReviewer.ReviewableCue(startMs: 2100, endMs: 3000, text: "Next context")
        let promptWithCtx = SubtitleLLMReviewer.buildBatchedPrompt(
            cues: [a, b], prev: prev, next: next, config: .default
        )
        XCTAssertTrue(promptWithCtx.contains("Previous context"))
        XCTAssertTrue(promptWithCtx.contains("Next context"))

        let promptNoCtx = SubtitleLLMReviewer.buildBatchedPrompt(
            cues: [a, b], prev: nil, next: nil, config: .default
        )
        XCTAssertFalse(promptNoCtx.contains("Previous context"))
        XCTAssertFalse(promptNoCtx.contains("Next context"))
    }

    /// Batched prompt for a 4-cue window numbers boundaries 0..2 and
    /// labels each cue with its bracketed index.
    func testBatchedPromptNumbersBoundariesAndLabelsCues() {
        let cues = (0..<4).map { i in
            SubtitleLLMReviewer.ReviewableCue(
                startMs: i * 1000, endMs: i * 1000 + 800, text: "Cue \(i) body text."
            )
        }
        let prompt = SubtitleLLMReviewer.buildBatchedPrompt(
            cues: cues, prev: nil, next: nil, config: .default
        )
        // 4 cues → 3 boundaries (pairs 0, 1, 2).
        XCTAssertTrue(prompt.contains("pair 0:"))
        XCTAssertTrue(prompt.contains("pair 1:"))
        XCTAssertTrue(prompt.contains("pair 2:"))
        XCTAssertFalse(prompt.contains("pair 3:"))
        // Cue labels.
        XCTAssertTrue(prompt.contains("[0]"))
        XCTAssertTrue(prompt.contains("[3]"))
    }

    // MARK: - Apply suggestions

    /// `.keep` is a no-op: cue list comes back identical.
    func testApplyKeepIsNoOp() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: "Cue A.", speakerId: nil),
            ExportService.SubtitleCue(startMs: 1100, endMs: 2000, text: "Cue B.", speakerId: nil)
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .keep)
        ]
        let out = service.applyReviewSuggestionsForTesting(cues, suggestions: suggestions, config: .default)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "Cue A.")
        XCTAssertEqual(out[1].text, "Cue B.")
    }

    /// `.merge` combines adjacent cues, dropping cue B from the list.
    func testApplyMergeCombinesAdjacent() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: "Hello there", speakerId: nil),
            ExportService.SubtitleCue(startMs: 1100, endMs: 2000, text: "friend.", speakerId: nil)
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .merge)
        ]
        let out = service.applyReviewSuggestionsForTesting(cues, suggestions: suggestions, config: .default)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Hello there friend.")
        XCTAssertEqual(out[0].startMs, 0)
        XCTAssertEqual(out[0].endMs, 2000)
    }

    /// `.shiftToA(n: 1)` moves the first word of B to the end of A.
    /// Pinned to the SRT 32 cue 6 failure shape ("4 minute" / "warm-up
    /// starts").
    func testApplyShiftToAMovesWordsRightToLeft() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: "because your 4 minute", speakerId: nil),
            ExportService.SubtitleCue(startMs: 1100, endMs: 2500, text: "warm-up starts right now.", speakerId: nil)
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .shiftToA(n: 1))
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 42)
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "because your 4 minute warm-up")
        XCTAssertEqual(out[1].text, "starts right now.")
    }

    /// `.shiftToB(n: 1)` moves the last word of A to the start of B.
    /// Pinned to the SRT 31 cue 10/11 failure shape ("...have you. Go"
    /// / "ahead and..."). The deterministic bad-starter pass already
    /// catches this case, but a reviewer-driven fix is the fallback
    /// for cases where bad-starter can't.
    func testApplyShiftToBMovesWordsLeftToRight() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: "It is great to have you. Go", speakerId: nil),
            ExportService.SubtitleCue(startMs: 1100, endMs: 4000, text: "ahead and find a cadence.", speakerId: nil)
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .shiftToB(n: 1))
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 42)
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "It is great to have you.")
        XCTAssertEqual(out[1].text, "Go ahead and find a cadence.")
    }

    /// Validator rejects a merge that would overshoot budget — the
    /// suggestion is silently dropped and cues stay as they were.
    func testApplyMergeOverBudgetIsRejected() {
        let service = ExportService()
        // 50-char + 50-char = ~101 chars combined. 2× maxCharsPerLine
        // budget is 42×2 = 84, so the merge exceeds budget.
        let longA = String(repeating: "a", count: 50)
        let longB = String(repeating: "b", count: 50)
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: longA, speakerId: nil),
            ExportService.SubtitleCue(startMs: 1100, endMs: 2000, text: longB, speakerId: nil)
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .merge)
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 42)
        )
        XCTAssertEqual(out.count, 2, "Over-budget merge must be rejected")
    }

    /// Validator rejects a merge across a long utterance gap (> 500 ms)
    /// — those are two genuinely separate utterances regardless of
    /// what the LLM thinks.
    func testApplyMergeAcrossLongGapIsRejected() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: "First.", speakerId: nil),
            // 2 second gap.
            ExportService.SubtitleCue(startMs: 3000, endMs: 4000, text: "Second.", speakerId: nil)
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .merge)
        ]
        let out = service.applyReviewSuggestionsForTesting(cues, suggestions: suggestions, config: .default)
        XCTAssertEqual(out.count, 2, "Merge across long gap must be rejected")
    }

    /// A shift that would leave cue B with fewer than 10 chars is
    /// rejected — the floor protects against stranded fragments.
    func testApplyShiftToALeavingBTooShortIsRejected() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: "First cue", speakerId: nil),
            // Only 7 chars, all in 2 words. shift_to_a n=1 would leave
            // "short." (6 chars) — under the 10-char floor.
            ExportService.SubtitleCue(startMs: 1100, endMs: 2000, text: "really short.", speakerId: nil)
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .shiftToA(n: 1))
        ]
        let out = service.applyReviewSuggestionsForTesting(cues, suggestions: suggestions, config: .default)
        // Cue B left at 7 chars would be too short — rejection means
        // the cues stay split as they were.
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].text, "really short.")
    }

    // MARK: - SRT 33 regression: validator must mirror rebalance rules

    /// SRT 33 cue 1: reviewer voted shift_to_a n=1 to pull "We" from
    /// cue B ("We will spend...") onto cue A ("...arms 30."). That
    /// would have created the trailing-sentence-fragment pattern
    /// `rebalanceTrailingSentenceFragment` exists to prevent. The
    /// validator must reject this move.
    func testApplyShiftToAThatCreatesTrailingFragmentIsRejected() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(
                startMs: 0, endMs: 9943,
                text: "What is going on Echelon and welcome in to your intervals in arms 30.",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 10243, endMs: 13145,
                text: "We will spend the next 30 minutes right here on our bike",
                speakerId: nil
            )
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .shiftToA(n: 1))
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 42)
        )
        // Cue A must not end with stranded "We".
        XCTAssertFalse(
            out[0].text.hasSuffix("We") || out[0].text.contains("30. We"),
            "Cue A acquired stranded 'We'. Cues: \(out.map(\.text))"
        )
    }

    /// SRT 33 cue 4: reviewer voted a shift that left cue A ending
    /// on "because" — a subordinator that's a hard bad-ender. The
    /// validator must reject this so the deterministic bad-ender
    /// pass's invariant holds.
    func testApplyShiftThatCreatesBadEnderIsRejected() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(
                startMs: 17_817, endMs: 21_186,
                text: "Let's get our hands to the handlebar, legs are moving because your",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 21_187, endMs: 22_822,
                text: "4 minute warm-up starts right now.",
                speakerId: nil
            )
        ]
        // shift_to_b n=1 would remove "your" from cue A's tail,
        // leaving cue A ending on "because" — bad ender.
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .shiftToB(n: 1))
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 42)
        )
        // Cue A must not end on "because".
        let lastA = out[0].text.split(separator: " ").last.map(String.init) ?? ""
        XCTAssertNotEqual(
            lastA.trimmingCharacters(in: .punctuationCharacters).lowercased(),
            "because",
            "Cue A acquired bad-ender 'because'. Cues: \(out.map(\.text))"
        )
    }

    /// SRT 33 cue 12/13: reviewer's shift produced
    ///   "...our warm"
    ///   "-up and over the course..."
    /// Splitting "warm-up" by leaving "-up" at the start of cue B is
    /// always wrong. Validator must reject any shift_to_a where the
    /// moved word(s) include a hyphen-prefixed token.
    func testApplyShiftLeavingHyphenSuffixOnNewCueBIsRejected() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(
                startMs: 0, endMs: 1000,
                text: "That is where we will spend the first half of our warm",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 1100, endMs: 2000,
                text: "-up and over the course of this 4 minutes we'll work",
                speakerId: nil
            )
        ]
        // shift_to_a n=1 would move "-up" to cue A's tail — but the
        // moved word starting with `-` signals a hyphen-split word
        // and the validator must reject.
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .shiftToA(n: 1))
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 42)
        )
        // Cues stay as they were — the move was rejected. Cue A must
        // NOT end with "-up" (which would mean we accepted the shift).
        XCTAssertFalse(
            out[0].text.hasSuffix("-up") || out[0].text.hasSuffix("warm -up"),
            "Cue A acquired hyphen-suffix '-up'. Cues: \(out.map(\.text))"
        )
    }

    /// SRT 33 cue 102: reviewer packed three complete sentences into
    /// one cue ("Beautiful." + "Round 1 is done." + "We are now
    /// moving on to round 2."). Validator must reject merges where
    /// both A and B end with sentence terminators and are substantial.
    func testApplyMergeOfTwoCompleteSentencesIsRejected() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(
                startMs: 0, endMs: 1000,
                text: "Round 1 is done.",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 1100, endMs: 2500,
                text: "We are now moving on to round 2.",
                speakerId: nil
            )
        ]
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .merge)
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 65)
        )
        // Merge rejected — cues stay as two.
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "Round 1 is done.")
    }

    /// Index bookkeeping: when an earlier merge collapses two cues
    /// into one, later suggestions targeting subsequent pairs must
    /// still land on the right cues. The applier walks suggestions
    /// in pair-index order with an offset counter.
    func testApplyHandlesIndexShiftAfterMerge() {
        let service = ExportService()
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 1000, text: "Hello there", speakerId: nil),
            ExportService.SubtitleCue(startMs: 1100, endMs: 2000, text: "friend.", speakerId: nil),
            ExportService.SubtitleCue(startMs: 2100, endMs: 3000, text: "How are you", speakerId: nil),
            ExportService.SubtitleCue(startMs: 3100, endMs: 4000, text: "today?", speakerId: nil)
        ]
        // Pair 0 = (cue 0, cue 1) → merge.
        // Pair 2 = (cue 2, cue 3) → merge.
        // After applying pair 0, the cue list is 3 long; the second
        // merge targets pair_index=2 which is now `cues[1]` and
        // `cues[2]` (offset = -1 after first merge).
        let suggestions = [
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 0, action: .merge),
            SubtitleLLMReviewer.ReviewSuggestion(pairIndex: 2, action: .merge)
        ]
        let out = service.applyReviewSuggestionsForTesting(
            cues,
            suggestions: suggestions,
            config: SubtitleExportConfig(maxCharsPerLine: 42)
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "Hello there friend.")
        XCTAssertEqual(out[1].text, "How are you today?")
    }
}

// MARK: - Test doubles

/// Returns scripted responses in call order. Cycles if more calls
/// happen than responses (defensive for parallel reviewer dispatch).
private final class ScriptedReviewerLLM: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var _callCount = 0

    init(responses: [String]) { self.responses = responses }

    /// Total `transform(...)` invocations. Lets batching tests assert
    /// the reviewer made fewer LLM round-trips after the refactor.
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func transform(text: String, prompt: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !responses.isEmpty else {
            return #"{"decisions":[{"pair":0,"action":"keep"}]}"#
        }
        let r = responses[_callCount % responses.count]
        _callCount += 1
        return r
    }

    // Stubs for the rest of the protocol.
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        let out = try await transform(text: text, prompt: prompt)
        return LLMResult(output: out, provider: "test", model: "test", latencyMs: 0)
    }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult {
        LLMFormatterResult(
            result: LLMResult(output: "", provider: "test", model: "test", latencyMs: 0),
            operationID: "test",
            inputChars: 0,
            outputChars: 0,
            inputTruncated: false,
            defaultPromptUsed: defaultPromptUsed,
            messageCount: 0
        )
    }
}

private final class ThrowingLLM: LLMServiceProtocol, @unchecked Sendable {
    func transform(text: String, prompt: String) async throws -> String { throw LLMError.notConfigured }
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { throw LLMError.notConfigured }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> String { throw LLMError.notConfigured }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { throw LLMError.notConfigured }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { throw LLMError.notConfigured }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> LLMResult { throw LLMError.notConfigured }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult { throw LLMError.notConfigured }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult { throw LLMError.notConfigured }
}
