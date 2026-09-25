#!/usr/bin/env python3
"""Focused activity diagnostic tests; MDEVAL_PATH enables the pinned engine cases."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from analyze_activity import activity_coverage, analyze, analyze_condition, read_intervals, read_mapping, union
from score_diarization import run_mdeval


class ActivityTests(unittest.TestCase):
    def test_overlapping_predictions_do_not_inflate_coverage(self):
        result = activity_coverage(
            {("clip", "A"): [(0, 1)]},
            {("clip", "S1"): [(0, 0.8), (0.2, 1), (0, 0.8)]},
            {"clip": [(0, 1)]}, {("clip", "A"): "S1"},
        )
        bucket = result["activityIntervalBuckets"]["200msTo1s"]
        self.assertEqual(bucket["correctlyAttributedSeconds"], 1)
        self.assertEqual(bucket["atLeastHalfCoveredIntervals"], 1)
        self.assertEqual(union([(1, 2), (0, 1)]), [(0, 2)])

    def test_multiple_uem_regions_clip_reference_and_predictions(self):
        result = activity_coverage(
            {("clip", "A"): [(0, 10)]}, {("clip", "S1"): [(1.5, 4)]},
            {"clip": [(1, 2), (8, 9)]}, {("clip", "A"): "S1"},
        )
        bucket = result["activityIntervalBuckets"]["over1s"]
        self.assertEqual(bucket["intervals"], 1)
        self.assertEqual(bucket["referenceSeconds"], 2)
        self.assertEqual(bucket["correctlyAttributedSeconds"], 0.5)
        self.assertEqual(bucket["atLeastHalfCoveredIntervals"], 0)

    def test_exact_thresholds_tolerate_subtraction_roundoff(self):
        result = activity_coverage(
            {("clip", "A"): [(100, 100.2)]}, {("clip", "S1"): [(100, 100.1)]},
            {"clip": [(0, 101)]}, {("clip", "A"): "S1"},
        )
        bucket = result["activityIntervalBuckets"]["upTo200ms"]
        self.assertEqual(bucket["intervals"], 1)
        self.assertEqual(bucket["atLeastHalfCoveredIntervals"], 1)
        result = activity_coverage({("clip", "A"): [(0, 1e-10)]}, {}, {"clip": [(0, 1)]}, {})
        self.assertEqual(result["activityIntervalBuckets"]["upTo200ms"]["atLeastHalfCoveredIntervals"], 0)

    def test_unmapped_and_empty_predictions_have_zero_coverage(self):
        references = {("clip", "A"): [(0, 0.2)], ("clip", "B"): [(1, 2)]}
        result = activity_coverage(references, {}, {"clip": [(0, 3)]}, {})
        self.assertEqual(result["activityIntervalBuckets"]["upTo200ms"]["intervals"], 1)
        self.assertEqual(len(result["minoritySpeakers"]), 2)
        self.assertTrue(all(row["correctlyAttributedSeconds"] == 0 for row in result["minoritySpeakers"]))

    def test_minority_time_unions_overlapping_reference_annotations(self):
        result = activity_coverage(
            {("clip", "A"): [(0, 3), (1, 3)]}, {}, {"clip": [(0, 5)]}, {},
        )
        self.assertEqual(result["minoritySpeakers"][0]["referenceSeconds"], 3)
        self.assertEqual(result["activityIntervalBuckets"]["over1s"]["intervals"], 2)

    def test_missing_mapped_speaker_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "Mapped speaker absent"):
            activity_coverage({("clip", "A"): [(0, 1)]}, {}, {"clip": [(0, 1)]}, {("clip", "A"): "bad"})

    def test_mapping_missing_file_header_unknown_speaker_and_duplicates_fail(self):
        header = "File,Channel,RefSpeaker,SysSpeaker,isMapped,timeOverlap\n"
        references, predictions = {("clip", "A"): [(0, 1)]}, {("clip", "S1"): [(0, 1)]}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "mapping.csv"
            with self.assertRaises(FileNotFoundError):
                read_mapping(path, references, predictions)
            for body in ("", header + "clip,1,A,unknown,mapped,1\n",
                         header + "clip,1,A,S1,mapped,1\n" * 2):
                path.write_text(body)
                with self.subTest(body=body), self.assertRaises(ValueError):
                    read_mapping(path, references, predictions)
            path.write_text(header)
            self.assertEqual(read_mapping(path, references, {}), {})

    def test_empty_prediction_and_multiple_uem_rows_parse_but_missing_file_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "input"
            with self.assertRaises(FileNotFoundError):
                read_intervals(path, {"clip"})
            path.write_text("")
            self.assertEqual(read_intervals(path, {"clip"}), {})
            path.write_text("clip 1 0 1\nclip 1 0.5 2\nclip 1 3 4\n")
            self.assertEqual(read_intervals(path, {"clip"}, uem=True), {"clip": [(0, 2), (3, 4)]})
            path.write_text("unexpected 1 0 1\n")
            with self.assertRaisesRegex(ValueError, "Unexpected recording"):
                read_intervals(path, {"clip"}, uem=True)

    def test_missing_scores_and_wrong_provenance_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "No supported score"):
                analyze(root, root / "engine")
            (root / "ami-manual-scores.json").write_text(json.dumps({"scorer": {}, "manifestSHA256": "bad"}))
            with self.assertRaisesRegex(ValueError, "provenance mismatch"):
                analyze(root, root / "engine")


@unittest.skipUnless(os.environ.get("MDEVAL_PATH"), "Set MDEVAL_PATH for pinned NIST mapping tests")
class PinnedMappingTests(unittest.TestCase):
    def analyze_fixture(self, prediction: str, *, missing_reference=False, wrong_score=False, wrong_engine=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / "test"
            ref, pred, uem = [Path(str(prefix) + suffix) for suffix in (".reference.rttm", ".predicted.rttm", ".scoring.uem")]
            ref.write_text("SPEAKER clip 1 0 1 <NA> <NA> A <NA> <NA>\nSPEAKER clip 1 2 1 <NA> <NA> B <NA> <NA>\n")
            pred.write_text(prediction)
            uem.write_text("clip 1 0 4\n")
            engine = Path(os.environ["MDEVAL_PATH"])
            scores, _ = run_mdeval(engine, ref, pred, uem, {"clip"})
            saved = {"recordings": {"clip": scores["clip"]}, "aggregate": scores["ALL"], "recordingCount": 1}
            if missing_reference:
                ref.write_text("")
            if wrong_score:
                saved["aggregate"]["missSeconds"] += 1
            if wrong_engine:
                engine = root / "bad-engine"
                engine.write_text("not the pinned scorer")
            return analyze_condition(prefix, saved, {"clip"}, engine)

    def test_empty_prediction_keeps_all_reference_intervals(self):
        result = self.analyze_fixture("")
        self.assertEqual(result["activityIntervalBuckets"]["200msTo1s"]["intervals"], 2)
        self.assertEqual(result["activityIntervalBuckets"]["200msTo1s"]["correctlyAttributedSeconds"], 0)
        self.assertTrue(result["provenance"]["reproducedSavedScores"])

    def test_missing_pair_and_label_permutation_use_nist_mapping(self):
        result = self.analyze_fixture("SPEAKER clip 1 0 1 <NA> <NA> S2 <NA> <NA>\n")
        self.assertEqual(result["activityIntervalBuckets"]["200msTo1s"]["correctlyAttributedSeconds"], 1)
        result = self.analyze_fixture("SPEAKER clip 1 0 1 <NA> <NA> S2 <NA> <NA>\nSPEAKER clip 1 2 1 <NA> <NA> S1 <NA> <NA>\n")
        self.assertEqual(result["activityIntervalBuckets"]["200msTo1s"]["correctlyAttributedSeconds"], 2)

    def test_missing_reference_changed_score_and_unpinned_engine_fail(self):
        for kwargs in ({"missing_reference": True}, {"wrong_score": True}, {"wrong_engine": True}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.analyze_fixture("", **kwargs)

    def test_missing_expected_recording_fails_before_invoking_scorer(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "recording coverage"):
                analyze_condition(Path(temporary) / "test", {"recordings": {}, "recordingCount": 0},
                                  {"clip"}, Path(os.environ["MDEVAL_PATH"]))


if __name__ == "__main__":
    unittest.main()
