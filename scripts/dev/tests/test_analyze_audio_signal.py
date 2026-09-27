import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave


SCRIPT = Path(__file__).resolve().parents[1] / "analyze_audio_signal.py"
SPEC = importlib.util.spec_from_file_location("analyze_audio_signal", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class AudioSignalAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "input.wav"

    def write_audio(self, frames, channels=1):
        with wave.open(str(self.path), "wb") as audio:
            audio.setnchannels(channels)
            audio.setsampwidth(2)
            audio.setframerate(8000)
            audio.writeframes(struct.pack(f"<{len(frames)}h", *frames))

    def test_silence_has_null_levels_and_exact_duration(self):
        self.write_audio([0] * 12_000)
        result = MODULE.analyze(self.path)
        self.assertEqual(result["decoded_frames"], 12_000)
        self.assertEqual(result["exact_zero_frames"], 12_000)
        self.assertEqual(result["longest_exact_zero_run_seconds"], 1.5)
        self.assertIsNone(result["rms_dbfs"])
        self.assertIsNone(result["peak_dbfs"])
        self.assertEqual([w["frames"] for w in result["windows"]], [8000, 4000])

    def test_bursts_do_not_hide_a_long_silent_middle(self):
        self.write_audio([1000] * 4000 + [0] * 16_000 + [1000] * 4000)
        result = MODULE.analyze(self.path)
        self.assertEqual(result["longest_exact_zero_run_seconds"], 2)
        self.assertEqual(result["exact_zero_frames"], 16_000)
        self.assertEqual([w["exact_zero_frames"] for w in result["windows"]], [4000, 8000, 4000])
        self.assertIsNotNone(result["peak_dbfs"])

    def test_right_channel_and_inverse_stereo_are_not_silence(self):
        for frame in ([0, 8192], [8192, -8192]):
            with self.subTest(frame=frame):
                self.write_audio(frame * 8000, channels=2)
                result = MODULE.analyze(self.path)
                self.assertEqual(result["channels"], 2)
                self.assertEqual(result["decoded_frames"], 8000)
                self.assertEqual(result["exact_zero_frames"], 0)
                self.assertEqual(result["longest_exact_zero_run_seconds"], 0)
                self.assertAlmostEqual(result["peak_dbfs"], -12.0412, places=3)

    def test_quiet_nonzero_is_not_digital_silence(self):
        self.write_audio([1] * 8000)
        result = MODULE.analyze(self.path)
        self.assertEqual(result["exact_zero_frames"], 0)
        self.assertAlmostEqual(result["rms_dbfs"], -90.309, places=3)

    def test_cli_emits_only_measurements_and_leaves_input_unchanged(self):
        self.write_audio([1000] * 8000)
        before = self.path.read_bytes()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.path)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["decoded_frames"], 8000)
        self.assertNotIn(str(self.path), result.stdout)
        self.assertEqual(self.path.read_bytes(), before)

    def test_corrupt_and_missing_inputs_fail_without_success_json(self):
        self.path.write_bytes(b"not audio")
        for path in [self.path, self.path.with_name("missing.wav")]:
            with self.subTest(path=path):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_truncated_audio_fails_after_a_valid_header(self):
        self.write_audio([1000] * 16_000)
        self.path.write_bytes(self.path.read_bytes()[:-8000])
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.path)], capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
