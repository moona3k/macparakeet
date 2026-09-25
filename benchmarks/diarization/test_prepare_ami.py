#!/usr/bin/env python3
"""Ensure source audio duration and reference scoring extent stay independent."""
from __future__ import annotations

import sys
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts"))
from prepare_ami import validate_audio


class AudioDurationTests(unittest.TestCase):
    def fixture(self, root: Path):
        path = root / "clip.wav"
        frames = 18624  #1.164seconds; scoring UEM remains1second.
        with wave.open(str(path), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"\0" * frames * 2)
        row = {"id": "ami_example_sdm", "durationSeconds": 1.0,
               "audio": {"channels": 1, "sampleWidthBytes": 2, "sampleRate": 16000,
                         "frameCount": frames, "bytes": path.stat().st_size, "durationSeconds": 1.164}}
        return path, row

    def test_accepts_frozen_longer_audio_without_modifying_audio_or_uem(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, row = self.fixture(Path(temporary))
            original = path.read_bytes()
            result = validate_audio(path, row)
            self.assertEqual(result["durationSeconds"], 1.164)
            self.assertEqual(result["uemEndSeconds"], 1.0)
            self.assertAlmostEqual(result["durationDifferenceFromUEMSeconds"], 0.164)
            self.assertEqual(row["durationSeconds"], 1.0)
            self.assertEqual(path.read_bytes(), original)

    def test_rejects_changed_source_duration_instead_of_widening_tolerance(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, row = self.fixture(Path(temporary))
            row["audio"]["frameCount"] = 16000
            with self.assertRaisesRegex(ValueError, "frameCount mismatch"):
                validate_audio(path, row)

    def test_rejects_truncated_data_even_when_header_still_claims_expected_frames(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, row = self.fixture(Path(temporary))
            path.write_bytes(path.read_bytes()[:-100])
            with self.assertRaisesRegex(ValueError, "bytes mismatch"):
                validate_audio(path, row)


if __name__ == "__main__":
    unittest.main()
