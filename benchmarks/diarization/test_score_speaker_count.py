#!/usr/bin/env python3
"""Correctness tests for issue #1046 word-assignment metrics."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))

from score_speaker_count import word_smoothing_stats


def document(*speaker_ids: str | None) -> dict:
    return {
        "wordTimestamps": [
            {"word": f"w{index}", "speakerId": speaker_id}
            for index, speaker_id in enumerate(speaker_ids)
        ]
    }


class WordSmoothingStatsTests(unittest.TestCase):
    def test_counts_isolated_flip_between_matching_speakers(self) -> None:
        self.assertEqual(
            word_smoothing_stats(document("S1", "S2", "S1"))["isolated_flips"],
            1,
        )

    def test_does_not_count_flip_between_nil_neighbors(self) -> None:
        self.assertEqual(
            word_smoothing_stats(document(None, "S2", None))["isolated_flips"],
            0,
        )

    def test_counts_all_words_in_same_speaker_bounded_nil_run(self) -> None:
        self.assertEqual(
            word_smoothing_stats(document("S1", None, None, "S1")),
            {
                "isolated_flips": 0,
                "bounded_nil_words": 2,
                "nil_words": 2,
            },
        )

    def test_excludes_edges_and_different_speaker_nil_runs(self) -> None:
        self.assertEqual(
            word_smoothing_stats(
                document(None, "S1", None, "S2", None)
            ),
            {
                "isolated_flips": 0,
                "bounded_nil_words": 0,
                "nil_words": 3,
            },
        )


if __name__ == "__main__":
    unittest.main()
