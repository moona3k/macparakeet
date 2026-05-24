import XCTest
@testable import MacParakeetCore

/// Pinned regressions for the LLM-cue post-processing pipeline.
/// Reproduces real failure scenarios observed in user exports and asserts
/// that the merge/wrap passes recover gracefully.
@MainActor
final class ApplyTimingPostProcessingTests: XCTestCase {

    /// SRT 22 regression: the LLM emitted the cadence callout "Eighty two
    /// eighty five." across two cues — "Eighty two eighty" + "five. Oh
    /// yeah." — and the user saw "82 80" / "five." in the final SRT
    /// because normalization couldn't bridge the cue boundary.
    /// `mergeOrphanedCues` should have absorbed the tiny tail; if it
    /// doesn't, this test fails and we know there's a real bug rather
    /// than just LLM bad luck.
    func testMergesCadenceCalloutFragmentedByLLM() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            // Cue 122 in SRT 22.
            ExportService.SubtitleCue(
                startMs: 485118,
                endMs: 486152,
                text: "Eighty two eighty",
                speakerId: nil
            ),
            // Cue 123 in SRT 22.
            ExportService.SubtitleCue(
                startMs: 486219,
                endMs: 491424,
                text: "five. Oh yeah.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 800,
            normalizeNumbers: true
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        XCTAssertEqual(out.count, 1, "Tiny tail cue should have been absorbed")
        // After normalization, "Eighty two eighty five. Oh yeah." -> "82 85. Oh yeah."
        XCTAssertTrue(
            out[0].text.contains("82 85"),
            "Merged + normalized cue should read '82 85', got: \(out[0].text)"
        )
    }

    /// SRT 22 actually-shipped regression: same LLM-fragmented cadence
    /// callout, but with the user's REAL GUI config which has
    /// `gapThresholdMs: 0`. Before the fix, the merge gap check
    /// `(gap > gapThresholdMs)` treats *any* nonzero gap as "too long" —
    /// so the 67 ms artifact between two adjacent words blocks the merge
    /// and the user sees "82 80" / "five. Oh yeah." instead of the
    /// merged & normalized "82 85. Oh yeah.".
    ///
    /// The fix is to apply a floor inside the tiny-cue-merge gap check
    /// so a strict user-set threshold can't block merges across the
    /// sub-second gaps that are just word-timing artifacts.
    // MARK: - Bad-ender rebalance (SRT 24 regressions)

    /// SRT 24 block 213/214: cue 213 ended with "and" — explicitly
    /// forbidden by the prompt's bad-ender rule but the LLM did it
    /// anyway. The deterministic rebalance should slide "and" into
    /// cue 214 so it reads as a phrase boundary, not a hanging
    /// conjunction.
    func testRebalancesTrailingAndIntoNextCue() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 873_186, endMs: 878_390,
                text: "85 for 30 seconds 90 for 30 seconds 95 and then 100 and",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 878_391, endMs: 881_827,
                text: "we do it two times through that means this lower zone",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        XCTAssertEqual(out.count, 2)
        XCTAssertFalse(
            out[0].text.lowercased().hasSuffix(" and"),
            "Cue 1 must not end with 'and'; got: \(out[0].text)"
        )
        XCTAssertTrue(
            out[1].text.lowercased().hasPrefix("and "),
            "Cue 2 should start with 'and'; got: \(out[1].text)"
        )
    }

    /// SRT 24 block 47/48: cue 47 ended with "should be" — two bad
    /// enders stacked. Sliding 1 word leaves "should" trailing
    /// (still bad), so the rebalance should iterate or move 2 words.
    func testRebalancesShouldBeIntoNextCue() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 156_389, endMs: 157_857,
                text: "by now your heart rate should be",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 157_891, endMs: 161_494,
                text: "getting up, and you should be ready to jump into these jogs.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        let last = out[0].text.split(separator: " ").last.map(String.init) ?? ""
        let stripped = last.trimmingCharacters(in: .punctuationCharacters).lowercased()
        XCTAssertFalse(
            ["be", "should", "is", "are", "was", "were"].contains(stripped),
            "Cue 1 must not end with an auxiliary verb; got: \(out[0].text)"
        )
    }

    // MARK: - Trailing sentence fragment

    /// SRT 31 cue 10/11 regression: the LLM packed the first word of
    /// a new sentence ("Go") onto the tail of cue 10, leaving the
    /// natural phrase "Go ahead" split across the cue boundary:
    ///   10: "It is great to have you. Go"
    ///   11: "ahead and find a cadence somewhere between 80 and 90."
    /// Neither bad-ender ("Go" isn't a function word) nor bad-starter
    /// ("ahead" isn't in `badStarters`) fires here — this is a
    /// structural fix (sentence boundary should be cue boundary).
    func testTrailingSentenceFragmentMovesForward() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 33_266, endMs: 34_100,
                text: "It is great to have you. Go",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 34_134, endMs: 38_104,
                text: "ahead and find a cadence somewhere between 80 and 90.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 42,
            maxLinesPerCue: 2,
            gapThresholdMs: 800
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // Cue 1 ends cleanly at the sentence terminator — no fragment.
        let cue1Normalized = out[0].text.replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(
            cue1Normalized.trimmingCharacters(in: .whitespaces).hasSuffix("you."),
            "Cue 1 should end at the sentence terminator. Got: \(cue1Normalized)"
        )
        XCTAssertFalse(
            cue1Normalized.contains(" Go") || cue1Normalized.hasSuffix("Go"),
            "Cue 1 should no longer carry the trailing 'Go'. Got: \(cue1Normalized)"
        )
        // Cue 2 starts with the moved word — "Go ahead" reunited.
        // Whichever cue holds them, they must be adjacent (no word
        // between them, line-break tolerated).
        let joined = out.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: " ")
        XCTAssertTrue(
            joined.contains("Go ahead"),
            "Output should contain 'Go ahead' as adjacent tokens. Got: \(joined)"
        )
    }

    /// A cue that already ends cleanly at a sentence terminator
    /// should be left alone — no spurious moves.
    func testCleanlyEndingCueIsNotTouched() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 0, endMs: 1_000,
                text: "This is fine.",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 1_100, endMs: 2_000,
                text: "And so is this.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(maxCharsPerLine: 42)
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // Both cues should be intact, possibly merged by absorbShort
        // since both fit in budget — but the fragment pass shouldn't
        // tear "And" off the second cue.
        let joined = out.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: " | ")
        XCTAssertTrue(
            joined.contains("This is fine.") && joined.contains("And so is this."),
            "Both complete sentences should survive intact. Got: \(joined)"
        )
    }

    /// A self-contained mini-sentence trailing another sentence
    /// ("Oh yes. Beautiful.") is NOT a fragment — both end cleanly.
    /// Don't move "Beautiful." forward into the next cue.
    func testCompleteTrailingMiniSentenceIsNotMoved() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 0, endMs: 1_500,
                text: "Oh yes. Beautiful.",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 1_600, endMs: 3_000,
                text: "Now back to the work at hand here.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(maxCharsPerLine: 42)
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // Whichever cue holds "Beautiful." it must still end with the
        // period — wasn't ripped of its terminator.
        let joined = out.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: " ")
        XCTAssertTrue(
            joined.contains("Beautiful."),
            "Complete mini-sentence should keep its period. Got: \(joined)"
        )
    }

    /// CLI iter5–9 regression: the LLM emitted
    ///   cue[13] = "with me. It is great to have"
    ///   cue[14] = "you. Go ahead and find a cadence"
    /// `rebalanceBadEnders` moved "to have" forward (cue[13] ended on
    /// "have", a soft bad-ender). Then `rebalanceBadStarters` saw cue
    /// [14] starting with "to" (bad starter) and tried moving leading
    /// words back. moveCount=3 would have moved "to have you." — the
    /// structurally-right answer — but the pass's bad-ender guard saw
    /// "you" (after stripping punctuation) in `badEnders` and rejected
    /// it. moveCount=4 then moved "to have you. Go" instead, dragging
    /// the start of the NEXT sentence ("Go") back too. Result:
    ///   "...have you. Go" + "ahead and find a cadence"
    /// The fix: a word ending in `.!?` is a SENTENCE TERMINATOR, not
    /// a bad ender — even when stripping punctuation reveals a
    /// function word. Skip the bad-ender check for those.
    func testBadStarterRespectsStrongPunctuationAtNewTail() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 30_880, endMs: 32_279,
                text: "Thanks for spending this 30 minutes",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 32_280, endMs: 34_040,
                text: "with me. It is great to have",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 34_150, endMs: 38_104,
                text: "you. Go ahead and find a cadence",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 38_200, endMs: 41_859,
                text: "somewhere between 80 and 90.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 42,
            maxLinesPerCue: 2,
            gapThresholdMs: 800
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        let normalized = out.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        let dump = normalized.enumerated()
            .map { "[\($0.offset)] \"\($0.element)\"" }
            .joined(separator: " | ")
        // "Go ahead" must end up adjacent in the SAME cue — that's the
        // user-visible win. Tolerate a line break between them (wrap).
        let goAheadAdjacent = normalized.contains { $0.contains("Go ahead") }
        XCTAssertTrue(
            goAheadAdjacent,
            "'Go ahead' should stay adjacent in one cue. Cues: \(dump)"
        )
        // No cue should END with the bare word "Go" (the pre-fix
        // failure mode).
        for (idx, text) in normalized.enumerated() {
            let lastToken = text.split(separator: " ").last.map(String.init) ?? ""
            XCTAssertNotEqual(
                lastToken, "Go",
                "Cue \(idx) ends with stranded 'Go'. Cues: \(dump)"
            )
        }
    }

    // MARK: - Cardinal + unit rebalance

    /// SRT 24 block 5/6: cue 5 ended with "four" and cue 6 started
    /// with "minute". The cardinal+unit pair should be reunited in
    /// the same cue so "four minute" reads as one phrase rather
    /// than spanning a boundary.
    ///
    /// Note: per SRT 35 feedback, 1-9 cardinals stay SPELLED (we no
    /// longer digitize "four minute" to "4 minute"). The cardinal+
    /// unit rebalance is still valuable on its own — keeping the
    /// pair adjacent is a readability win independent of the digit/
    /// spelled choice.
    func testCardinalAndUnitGetReunited() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 17_817, endMs: 21_186,
                text: "Let's get our hands to the handlebar, legs are moving because your four",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 21_187, endMs: 22_822,
                text: "minute warm-up starts right now.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0,
            normalizeNumbers: true
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        XCTAssertEqual(out.count, 2)
        // Cue 1 must NOT end in a bare cardinal.
        let last = out[0].text.split(separator: " ").last.map(String.init) ?? ""
        XCTAssertNotEqual(last.lowercased(), "four",
                          "Cue 1 still ends with 'four': \(out[0].text)")
        // Cue 2 (or whichever cue holds the pair after merging) must
        // contain "four" and "minute" adjacent. Tolerate the wrap
        // pass dropping a `\n` between cue lines.
        let normalized = out.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        let pairAdjacent = normalized.contains {
            $0.contains("four minute") || $0.contains("four-minute")
        }
        XCTAssertTrue(
            pairAdjacent,
            "Cardinal + unit pair not adjacent in any cue. Cues: \(normalized)"
        )
    }

    /// LLM iter2 (D41D14D8) cue 8/9: the chunk was "...because your
    /// 4 minute" / "warm-up starts right now." — same structural
    /// failure as SRT 24's "four / minute" but with a DIGIT cardinal
    /// (`4`) instead of the spelled-out form (`four`). The original
    /// `rebalanceCardinalUnitPairs` only checked the spelled-out
    /// cardinals set; this exercise pins the digit-form fix.
    func testDigitCardinalAndUnitGetReunited() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 17_817, endMs: 21_186,
                text: "legs are moving because your 4 minute",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 21_187, endMs: 22_822,
                text: "warm-up starts right now.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0,
            normalizeNumbers: true
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // The fix is "the `4` and `minute` end up in the SAME cue
        // and adjacent, regardless of which cue absorbs the other"
        // — pre-fix they sat on opposite sides of a cue boundary.
        // Treat a wrap-pass newline as whitespace; we care that no
        // *word* sits between them.
        let normalized = out.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        let dump = normalized.enumerated()
            .map { "[\($0.offset)] \"\($0.element)\"" }
            .joined(separator: " | ")
        let foundPair = normalized.contains { txt in
            txt.contains("4 minute") || txt.contains("4-minute")
        }
        XCTAssertTrue(
            foundPair,
            "No cue contains '4 minute' (or '4-minute') as adjacent tokens. Cues: \(dump)"
        )
    }

    /// SRT 25 cue 5/6: the cardinal+unit pass moved "four" forward
    /// from cue 5 to cue 6 (good), but that left "your" — a bad
    /// ender — stranded at the new tail of cue 5. Order fix
    /// (cardinal+unit BEFORE bad-ender) plus the bad-ender pass
    /// running second should reach in and rebalance "your" too.
    func testCardinalUnitFollowedByBadEnderGetsResolved() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 17_817, endMs: 21_186,
                text: "Let's get our hands to the handlebar, legs are moving because your four",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 21_187, endMs: 22_822,
                text: "minute warm-up starts right now.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0,
            normalizeNumbers: true
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // Cue 1's tail must not be a bad ender after both passes.
        let last = out[0].text.split(separator: " ").last.map(String.init) ?? ""
        let stripped = last.trimmingCharacters(in: .punctuationCharacters).lowercased()
        let badEnders: Set<String> = ["your", "the", "a", "of", "to", "and",
                                       "is", "are", "was", "were", "be"]
        XCTAssertFalse(
            badEnders.contains(stripped),
            "Cue 1 still ends with a bad ender '\(stripped)': \(out[0].text)"
        )
    }

    /// SRT 25 cue 26: cue ended with "I" with "into" and "it" right
    /// before it — chained bad enders. The pass needs to be willing
    /// to move 3 words to break the chain (leaving "Now before we
    /// jump" at the tail).
    func testChainedBadEndersGetResolvedByThreeWordMove() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 87_754, endMs: 89_521,
                text: "Now before we jump into it I",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 89_522, endMs: 91_423,
                text: "want to give you a little bit of a roadmap",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        let last = out[0].text.split(separator: " ").last.map(String.init) ?? ""
        let stripped = last.trimmingCharacters(in: .punctuationCharacters).lowercased()
        let badEnders: Set<String> = ["i", "it", "into", "the", "a", "of", "to", "and"]
        XCTAssertFalse(
            badEnders.contains(stripped),
            "Cue 1 still ends with a bad ender '\(stripped)': \(out[0].text)"
        )
    }

    // MARK: - Bad-starter rebalance (SRT 26 regressions)

    /// SRT 26 cue 26: cue starts with "of a roadmap…" — the leading
    /// "of" is a function word that reads better attached to the
    /// previous cue. Bad-starter pass should slide it (and maybe "a")
    /// back into cue N.
    func testBadStarterSlidesLeadingPrepositionBack() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 90_523, endMs: 92_458,
                text: "Now before we jump into it I want to give you a little bit",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 92_459, endMs: 95_095,
                text: "of a roadmap so you know exactly",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // Cue 2 should not start with the bare preposition any more.
        let firstStripped = out[1].text.split(separator: " ").first
            .map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
        let badStarters: Set<String> = ["of", "the", "a", "and", "or", "to", "in", "on"]
        XCTAssertFalse(
            badStarters.contains(firstStripped),
            "Cue 2 still starts with bad starter '\(firstStripped)': \(out[1].text)"
        )
    }

    /// SRT 28 cue 25/26: short fragment "Now before we jump" followed
    /// by "into it, I wanna give…". Bad-starter sees "into" and tries
    /// to move it back, but the 3-word ceiling can't clear the
    /// `into / it / I` bad-ender chain. Bumping to 4 lets the move
    /// land on "wanna" (clean tail) and leaves cue 26 starting on
    /// "give" (clean head).
    func testFourWordBadStarterMoveClearsBadEnderChain() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 88_088, endMs: 89_388,
                text: "Now before we jump",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 89_389, endMs: 91_724,
                text: "into it, I wanna give you a little bit of a roadmap so you know",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // Cue 1 should no longer be the 4-word fragment.
        let words1 = out[0].text.split(separator: " ").count
        XCTAssertGreaterThan(words1, 4,
                             "Cue 1 should have grown past 4 words; got: \(out[0].text)")
        // Cue 2 should not start with a bad starter.
        let firstStripped = out[1].text.split(separator: " ").first
            .map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
        let badStarters: Set<String> = ["into", "of", "the", "a", "to", "at"]
        XCTAssertFalse(badStarters.contains(firstStripped),
                       "Cue 2 should not start with bad starter; got: \(out[1].text)")
    }

    // MARK: - Soft bad-ender for transitive verbs

    /// SRT 26 cue 10/11: "It is great to have" / "you. Go ahead and find…"
    /// The verb "have" needs its object "you". Even though "have" is
    /// already a hard bad ender (auxiliary), the rebalance previously
    /// gave up because the prev cue would shrink to 11 chars (just
    /// under the old 12-char floor). The floor was loosened to 10
    /// so this case now resolves; if cue 10 ends with a non-bad-ender
    /// after the move, the test passes.
    func testSoftBadEnderAllowsShortPrevCueIfWellFormed() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 33_266, endMs: 34_100,
                text: "It is great to have",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 34_134, endMs: 38_104,
                text: "you. Go ahead and find a cadence somewhere between 80 and 90.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        // Cue 1's tail must not be "have" (the transitive verb) any more.
        let last = out[0].text.split(separator: " ").last.map(String.init) ?? ""
        let stripped = last.trimmingCharacters(in: .punctuationCharacters).lowercased()
        XCTAssertNotEqual(stripped, "have",
                          "Cue 1 still ends with 'have': \(out[0].text)")
    }

    // MARK: - Orphan threshold

    /// Pinned behavior: the orphan-merge fires on a 2-word cue
    /// (`words.count < minWords` where minWords=3), so 2-word
    /// reads like "Beautiful work." get absorbed by a neighbour
    /// when budget + gap allow. Tried bumping the *char* threshold
    /// (15 → 18) too but it collided with `enforceReadingSpeed`,
    /// which splits high-CPS cues into ~17-char pieces that the
    /// orphan-merge would then absorb right back (see
    /// `testGapPreferredSplitPicksLargestPause`). Char threshold
    /// stays at 15; the word-count check carries the load.
    func testOrphanThresholdAbsorbsTwoWordOrphan() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 167_400, endMs: 170_670,
                text: "Take a deep breath in and exhale.",
                speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 170_700, endMs: 171_141,
                text: "Beautiful work.",
                speakerId: nil
            )
        ]
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 0
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        XCTAssertEqual(out.count, 1, "2-word cue should be absorbed by orphan-merge")
    }

    // MARK: - Whisper hyphen artifact

    /// Pure text-level pass — joins `warm -up`, `four -minute`,
    /// `90 -degree` back into the intended hyphenated compound.
    func testCollapsesWhisperHyphenArtifacts() {
        XCTAssertEqual(
            ExportService.collapseWhisperHyphenArtifacts(in: "our warm -up starts"),
            "our warm-up starts"
        )
        XCTAssertEqual(
            ExportService.collapseWhisperHyphenArtifacts(in: "your four -minute warm -up"),
            "your four-minute warm-up"
        )
        XCTAssertEqual(
            ExportService.collapseWhisperHyphenArtifacts(in: "with a 90 -degree hold"),
            "with a 90-degree hold"
        )
    }

    /// A sentence-leading bullet/dash should not be touched.
    func testHyphenCollapseLeavesLeadingDashAlone() {
        XCTAssertEqual(
            ExportService.collapseWhisperHyphenArtifacts(in: "- bullet line"),
            "- bullet line"
        )
    }

    func testMergesAcrossSmallGapEvenWhenThresholdIsZero() async {
        let service = ExportService()
        let llmCues: [ExportService.SubtitleCue] = [
            ExportService.SubtitleCue(
                startMs: 485118, endMs: 486152,
                text: "Eighty two eighty", speakerId: nil
            ),
            ExportService.SubtitleCue(
                startMs: 486219, endMs: 491424,
                text: "five. Oh yeah.", speakerId: nil
            )
        ]
        // User's actual stored config from SRT 22.
        let config = SubtitleExportConfig(
            maxWordsPerCue: 12,
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            maxDurationMs: 3000,
            gapThresholdMs: 0,
            normalizeNumbers: true
        )
        let out = service.applyTimingPostProcessingForTesting(llmCues, config: config)
        XCTAssertEqual(out.count, 1, "Tiny tail cue should still merge with the user's gapThresholdMs=0 config")
        XCTAssertTrue(
            out[0].text.contains("82 85"),
            "Merged + normalized cue should read '82 85', got: \(out[0].text)"
        )
    }
}
