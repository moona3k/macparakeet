#!/usr/bin/env python3
"""Boundary tests plus optional real pinned md-eval contract tests.

Run: MDEVAL_PATH=/path/md-eval-22.pl python3 -m unittest discover \
    -s benchmarks/diarization -p test_score_diarization.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from score_diarization import json_to_rttm, load_manifest, parse_mdeval, run_mdeval, score_backend


class ConversionTests(unittest.TestCase):
    def test_overlap_and_brief_reply_are_preserved(self):
        output = json_to_rttm({"segments": [
            {"speakerId": "S1", "startMs": 0, "endMs": 1000},
            {"speakerId": "S2", "startMs": 500, "endMs": 550},
        ]}, "clip")
        self.assertIn("0.500000 0.050000", output)
        self.assertEqual(len(output.splitlines()), 2)

    def test_explicit_empty_is_valid_but_missing_segments_is_not(self):
        self.assertEqual(json_to_rttm({"segments": []}, "clip"), "")
        with self.assertRaises(ValueError):
            json_to_rttm({}, "clip")

    def test_rejects_invalid_intervals_and_injected_speaker_ids(self):
        for changes in ({"endMs": 0}, {"startMs": -1}, {"startMs": float("nan")},
                        {"speakerId": "S1\nSPEAKER bad"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                json_to_rttm({"segments": [{"speakerId": "S1", "startMs": 0, "endMs": 1000, **changes}]}, "clip")

    def test_missing_expected_prediction_fails_before_scoring(self):
        with tempfile.TemporaryDirectory() as temporary, patch("score_diarization.run_mdeval") as score:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "Missing predictions"):
                score_backend([{"id": "expected"}], root, root, root / "md-eval", root / "out")
            score.assert_not_called()

    def test_incomplete_scorer_output_fails(self):
        with self.assertRaisesRegex(ValueError, "coverage mismatch"):
            parse_mdeval("", {"expected"})

    def test_duplicate_manifest_ids_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.json"
            path.write_text(json.dumps({"recordings": [{"id": "same"}, {"id": "same"}]}))
            with self.assertRaisesRegex(ValueError, "unique"):
                load_manifest(path)

    def test_scorer_failure_is_not_treated_as_partial_success(self):
        engine = os.environ.get("MDEVAL_PATH")
        if not engine:
            self.skipTest("MDEVAL_PATH not provided")
        with patch("score_diarization.subprocess.run", side_effect=subprocess.CalledProcessError(1, "perl")):
            with self.assertRaises(subprocess.CalledProcessError):
                run_mdeval(Path(engine), Path("ref"), Path("sys"), Path("uem"), {"clip"})


@unittest.skipUnless(os.environ.get("MDEVAL_PATH"), "Set MDEVAL_PATH for actual pinned engine contract tests")
class RealScorerTests(unittest.TestCase):
    def score(self, reference, prediction, end=3):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "ref").write_text(json_to_rttm({"segments": reference}, "clip"))
            (root / "sys").write_text(json_to_rttm({"segments": prediction}, "clip"))
            (root / "uem").write_text(f"clip 1 0 {end}\n")
            return run_mdeval(Path(os.environ["MDEVAL_PATH"]), root / "ref", root / "sys", root / "uem", {"clip"})[0]["clip"]

    def test_empty_prediction_is_100_percent_missed_speech(self):
        result = self.score([{"speakerId": "A", "startMs": 0, "endMs": 1000}], [])
        self.assertEqual(result["derPercent"], 100)
        self.assertEqual(result["missSeconds"], 1)

    def test_speaker_name_permutation_is_not_an_error(self):
        result = self.score(
            [{"speakerId": "A", "startMs": 0, "endMs": 1000}, {"speakerId": "B", "startMs": 1000, "endMs": 2000}],
            [{"speakerId": "S2", "startMs": 0, "endMs": 1000}, {"speakerId": "S1", "startMs": 1000, "endMs": 2000}],
        )
        self.assertEqual(result["derPercent"], 0)

    def test_overlap_miss_and_trailing_silence_false_alarm_are_counted(self):
        result = self.score(
            [{"speakerId": "A", "startMs": 0, "endMs": 1000}, {"speakerId": "B", "startMs": 500, "endMs": 1000}],
            [{"speakerId": "S1", "startMs": 0, "endMs": 2000}],
        )
        self.assertEqual(result["referenceSpeakerSeconds"], 1.5)
        self.assertEqual(result["missSeconds"], 0.5)
        self.assertEqual(result["falseAlarmSeconds"], 1)
        self.assertEqual(result["derPercent"], 100)

    def test_explicit_uem_excludes_only_outside_the_scoring_region(self):
        result = self.score(
            [{"speakerId": "A", "startMs": 0, "endMs": 1000}],
            [{"speakerId": "S1", "startMs": 0, "endMs": 2000}], end=1,
        )
        self.assertEqual(result["derPercent"], 0)


if __name__ == "__main__":
    unittest.main()
