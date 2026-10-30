#!/usr/bin/env python3
"""Word attribution scorer tests: merger parity with SpeakerMergerTests, reference turns and scoring."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from score_word_attribution import Label, Turn, best_mapping, label_words, merge, merge_turns, score


def words(*spans):
    return [{"startMs": start, "endMs": end} for start, end in spans]


def segments(*spans):
    return [{"speakerId": spk, "startMs": start, "endMs": end} for spk, start, end in spans]


class MergerParityTests(unittest.TestCase):
    """Each case mirrors a SpeakerMergerTests case."""
    flip_words = words((0, 400), (400, 480), (480, 900))
    flip_segments = segments(("S1", 0, 400), ("S2", 400, 480), ("S1", 480, 900))

    def test_isolated_one_word_flip_inherits_neighbor_speaker(self):
        self.assertEqual(merge(self.flip_words, self.flip_segments, "app"), ["S1", "S1", "S1"])

    def test_keep_policy_keeps_the_one_word_turn(self):
        self.assertEqual(merge(self.flip_words, self.flip_segments, "keep"), ["S1", "S2", "S1"])

    def test_two_word_flip_is_not_smoothed(self):
        result = merge(words((0, 300), (300, 600), (600, 900), (900, 1200)),
                       segments(("S1", 0, 300), ("S2", 300, 900), ("S1", 900, 1200)), "app")
        self.assertEqual(result, ["S1", "S2", "S2", "S1"])

    def test_nil_gap_between_the_same_speaker_inherits_that_speaker(self):
        spans = words((0, 400), (1200, 1400), (1600, 1800), (2500, 2900))
        segs = segments(("S1", 0, 1000), ("S1", 2000, 4000))
        self.assertEqual(merge(spans, segs, "raw"), ["S1", None, None, "S1"])
        self.assertEqual(merge(spans, segs, "app"), ["S1", "S1", "S1", "S1"])
        self.assertEqual(merge(spans, segs, "keep"), ["S1", "S1", "S1", "S1"])

    def test_word_in_gap_between_different_speakers_stays_nil(self):
        result = merge(words((0, 500), (1500, 2000), (3000, 3500)),
                       segments(("S1", 0, 1000), ("S2", 2500, 4000)), "app")
        self.assertEqual(result, ["S1", None, "S2"])

    def test_speaker_flips_at_transcript_edges_are_not_smoothed(self):
        result = merge(words((0, 300), (300, 600), (600, 900), (900, 1200)),
                       segments(("S2", 0, 300), ("S1", 300, 900), ("S2", 900, 1200)), "app")
        self.assertEqual(result, ["S2", "S1", "S1", "S2"])

    def test_tie_breaking_earlier_segment_wins(self):
        result = merge(words((0, 100), (90, 210)), segments(("S1", 0, 150), ("S2", 150, 210)), "raw")
        self.assertEqual(result, ["S1", "S1"])

    def test_no_segments_keeps_existing_speaker(self):
        spans = [{"startMs": 0, "endMs": 100, "speakerId": "S1"}]
        self.assertEqual(merge(spans, [], "app"), ["S1"])


class ReferenceTests(unittest.TestCase):
    def test_touching_intervals_of_one_speaker_form_one_turn(self):
        turns = merge_turns([Turn(0, 500, "A"), Turn(500, 900, "A"), Turn(1000, 1200, "A")])
        self.assertEqual(turns, [Turn(0, 900, "A"), Turn(1000, 1200, "A")])
        labels = label_words(words((400, 600)), turns, [(0, 2000)])
        self.assertEqual(labels, [Label("A", 0, 1)])

    def test_words_touching_two_speakers_or_outside_the_uem_are_not_scored(self):
        turns = merge_turns([Turn(0, 1000, "A"), Turn(900, 2000, "B")])
        labels = label_words(words((100, 300), (950, 1050), (1500, 1700), (2100, 2200)), turns, [(0, 1600)])
        self.assertEqual(labels[0].speaker, "A")
        self.assertEqual(labels[1:], [None, None, None])

    def test_turn_length_counts_all_words_of_the_turn(self):
        turns = merge_turns([Turn(0, 1000, "A"), Turn(950, 1100, "B"), Turn(1500, 1700, "A")])
        labels = label_words(words((100, 300), (900, 1000), (1550, 1650)), turns, [(0, 2000)])
        self.assertEqual(labels[0], Label("A", 0, 2))
        self.assertIsNone(labels[1])
        self.assertEqual(labels[2], Label("A", 2, 1))


class ScoringTests(unittest.TestCase):
    def test_mapping_maximizes_total_agreement(self):
        mapping = best_mapping({("S1", "A"): 10, ("S1", "B"): 9, ("S2", "A"): 9})
        self.assertEqual(mapping, {"S1": "B", "S2": "A"})

    def test_separate_one_word_turns_are_not_merged_across_a_skipped_word(self):
        labels = [Label("A", 0, 1), None, Label("A", 2, 1)]
        result = score(labels, ["S1", "S2", "S1"])
        self.assertEqual(result["words"]["1"], 2)
        self.assertEqual(result["correct"]["1"], 2)

    def test_spurious_switches_stay_within_one_turn(self):
        labels = [Label("A", 0, 2), Label("A", 0, 2), Label("A", 1, 1)]
        result = score(labels, ["S1", "S2", "S1"])
        self.assertEqual(result["spurious"], 1)
        self.assertEqual(score([Label("A", 0, 1), Label("A", 1, 1)], ["S1", "S2"])["spurious"], 0)

    def test_a_fixed_mapping_scores_policies_on_the_same_terms(self):
        labels = [Label("A", 0, 3), Label("A", 0, 3), Label("A", 0, 3)]
        self.assertEqual(score(labels, ["S2", "S2", "S2"])["correct"]["all"], 3)
        self.assertEqual(score(labels, ["S2", "S2", "S2"], {"S1": "A"})["correct"]["all"], 0)

    def test_nil_words_count_as_wrong(self):
        result = score([Label("A", 0, 2), Label("A", 0, 2)], ["S1", None])
        self.assertEqual(result["correct"]["all"], 1)
        self.assertEqual(result["nil"], 1)


if __name__ == "__main__":
    unittest.main()
