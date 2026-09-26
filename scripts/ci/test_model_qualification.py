import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[1] / "dev"


def load(name):
    spec = importlib.util.spec_from_file_location(name, DEV / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify = load("verify_release_demo").verify
qualification = load("model_qualification")


class ReleaseDemoEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.text = "This short local audio proves transcription and export."
        self.row = {"id": "fixture-id", "status": "completed", "rawTranscript": self.text,
                    "engine": "parakeet", "engineVariant": "v3"}
        self.write("transcribe.json", self.row)
        self.write("history.json", [self.row])
        (self.root / "export.md").write_text(f"# Fixture\n\n**[0:00]** {self.text}\n")

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def test_fresh_read_and_timestamped_export_pass(self):
        self.assertEqual(verify(self.root)["result"], "pass")

    def test_missing_or_duplicate_persisted_row_fails(self):
        for rows in ([], [self.row, self.row]):
            with self.subTest(rows=len(rows)):
                self.write("history.json", rows)
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    verify(self.root)

    def test_different_id_status_or_text_fails(self):
        for field, value in (("id", "wrong"), ("status", "failed"), ("rawTranscript", "wrong")):
            with self.subTest(field=field):
                self.write("history.json", [{**self.row, field: value}])
                with self.assertRaises(ValueError):
                    verify(self.root)

    def test_unrelated_nonempty_speech_fails(self):
        row = {**self.row, "rawTranscript": "A completely unrelated result."}
        self.write("transcribe.json", row)
        self.write("history.json", [row])
        (self.root / "export.md").write_text(row["rawTranscript"])
        with self.assertRaisesRegex(ValueError, "fixture content mismatch"):
            verify(self.root)

    def test_wrong_engine_or_variant_fails_even_with_correct_text(self):
        for field, value in (("engine", "whisper"), ("engineVariant", "v2")):
            with self.subTest(field=field):
                row = {**self.row, field: value}
                self.write("transcribe.json", row)
                self.write("history.json", [row])
                with self.assertRaisesRegex(ValueError, "selected Parakeet v3"):
                    verify(self.root)

    def test_nonempty_export_missing_transcript_fails(self):
        (self.root / "export.md").write_text("# Fixture\nSome unrelated body.")
        with self.assertRaisesRegex(ValueError, "does not contain"):
            verify(self.root)

    def test_accepts_one_missing_content_word(self):
        row = {**self.row, "rawTranscript": self.text.replace("short ", "")}
        self.write("transcribe.json", row)
        self.write("history.json", [row])
        (self.root / "export.md").write_text(row["rawTranscript"])
        self.assertEqual(len(verify(self.root)["matchedWords"]), 4)


class QualificationBoundaryTests(unittest.TestCase):
    def test_changed_missing_and_extra_model_bytes_fail_pinning(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            models = state / "FluidAudio" / "Models"
            models.mkdir(parents=True)
            asset = models / "model.bin"
            asset.write_bytes(b"accepted model")
            manifest = state / "pin.json"
            manifest.write_text(json.dumps({"model": "parakeet-v3", "files": qualification.model_files(state)}))
            qualification.verify_manifest(state, manifest)
            asset.write_bytes(b"different model")
            with self.assertRaisesRegex(ValueError, "differs"):
                qualification.verify_manifest(state, manifest)
            asset.unlink()
            with self.assertRaisesRegex(ValueError, "empty"):
                qualification.verify_manifest(state, manifest)
            asset.write_bytes(b"accepted model")
            (models / "unexpected.bin").write_bytes(b"new")
            with self.assertRaisesRegex(ValueError, "differs"):
                qualification.verify_manifest(state, manifest)

    def test_symlinked_model_cache_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root / "elsewhere"
            (external / "Models").mkdir(parents=True)
            (external / "Models" / "asset").write_text("model")
            state = root / "state"
            state.mkdir()
            (state / "FluidAudio").symlink_to(external, target_is_directory=True)
            with self.assertRaises(ValueError):
                qualification.model_files(state)

    def test_command_failure_and_timeout_are_not_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for script, timeout, error in (("raise SystemExit(7)", 5, ValueError),
                                            ("import time; time.sleep(30)", 0.1, subprocess.TimeoutExpired)):
                with self.subTest(script=script), self.assertRaises(error):
                    qualification.run_bounded([sys.executable, "-c", script], os.environ.copy(),
                                              root / "stdout", root / "stderr", timeout)

    @unittest.skipUnless(sys.platform == "darwin" and qualification.SANDBOX.exists(), "macOS sandbox required")
    def test_offline_profile_denies_a_real_socket(self):
        # Execute the consumer, not a textual assertion about the sandbox profile.
        probe = "import socket; socket.socket().bind(('127.0.0.1', 0))"
        control = subprocess.run([str(qualification.SANDBOX), "-p", "(version 1)(allow default)",
                                  sys.executable, "-c", probe], capture_output=True)
        self.assertEqual(control.returncode, 0, control.stderr)
        blocked = subprocess.run([str(qualification.SANDBOX), "-p", qualification.NETWORK_PROFILE,
                                  sys.executable, "-c", probe], capture_output=True)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn(b"PermissionError", blocked.stderr)
        self.assertIn(b"Operation not permitted", blocked.stderr)


if __name__ == "__main__":
    unittest.main()
