import importlib.util
import json
import os
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

    def test_stalled_probe_and_decoder_are_terminated_without_success_json(self):
        self.write_audio([1000] * 8000)
        executables = Path(self.folder.name) / "bin"
        executables.mkdir()
        pid_file = Path(self.folder.name) / "child.pid"
        environment = dict(os.environ, PATH=f"{executables}{os.pathsep}{os.environ['PATH']}")
        probe_result = {"streams": [{"codec_name": "pcm_s16le", "sample_rate": "8000", "channels": 1}]}
        for stalled_stage in ["ffprobe", "ffmpeg"]:
            with self.subTest(stage=stalled_stage):
                for executable in ["ffprobe", "ffmpeg"]:
                    if executable == stalled_stage:
                        body = (
                            "import os, time\n"
                            f"open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
                            "time.sleep(60)\n"
                        )
                    else:
                        body = f"print({json.dumps(probe_result)!r})\n"
                    path = executables / executable
                    path.write_text(f"#!{sys.executable}\n{body}")
                    path.chmod(0o755)
                try:
                    result = subprocess.run(
                        [sys.executable, str(SCRIPT), str(self.path), "--timeout-seconds", "1"],
                        capture_output=True, text=True, env=environment, timeout=5,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    child_pid = int(pid_file.read_text())
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child_pid, 0)
                finally:
                    # Also retire the fixture if this regression fails.
                    if pid_file.exists():
                        try:
                            os.kill(int(pid_file.read_text()), 9)
                        except ProcessLookupError:
                            pass
                        pid_file.unlink()

    def test_invalid_deadlines_are_rejected(self):
        for deadline in [0, -1, float("inf"), float("nan")]:
            with self.subTest(deadline=deadline):
                with self.assertRaisesRegex(ValueError, "timeout must"):
                    MODULE.analyze(self.path, timeout_seconds=deadline)


if __name__ == "__main__":
    unittest.main()
