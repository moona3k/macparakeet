import importlib.util
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "testing/native-library-e2e.py"
spec = importlib.util.spec_from_file_location("native_library_runner", path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class NativeRunnerBoundaryTests(unittest.TestCase):
    def test_account_guard_uses_uid_record_not_environment(self):
        with patch.dict(os.environ, {"USER": runner.ACCOUNT, "LOGNAME": runner.ACCOUNT}), \
                patch.object(runner.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="ordinary-user")):
            with self.assertRaisesRegex(RuntimeError, "dedicated"):
                runner.preflight(True)

    def test_timeout_stops_owned_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "descendant-survived"
            child = f"import time,pathlib;time.sleep(1);pathlib.Path({str(marker)!r}).write_text('survived')"
            parent = f"import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',{child!r}]);print('spawned',flush=True);time.sleep(30)"
            with (root / "command.log").open("w") as log:
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.run_owned([sys.executable, "-c", parent], cwd=root, env=os.environ.copy(),
                                     log=log, timeout=0.4)
            self.assertIn("spawned", (root / "command.log").read_text())
            time.sleep(1.1)
            self.assertFalse(marker.exists(), "build descendant escaped the command timeout")

    def test_command_nonzero_status_remains_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (root / "command.log").open("w") as log:
                with self.assertRaises(subprocess.CalledProcessError):
                    runner.run_owned([sys.executable, "-c", "raise SystemExit(7)"], cwd=root,
                                     env=os.environ.copy(), log=log, timeout=10)

    def test_command_success_stops_owned_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "descendant-survived"
            child = f"import time,pathlib;time.sleep(1);pathlib.Path({str(marker)!r}).write_text('survived')"
            parent = f"import subprocess,sys;subprocess.Popen([sys.executable,'-c',{child!r}])"
            with (root / "command.log").open("w") as log:
                runner.run_owned([sys.executable, "-c", parent], cwd=root, env=os.environ.copy(),
                                 log=log, timeout=10)
            time.sleep(1.1)
            self.assertFalse(marker.exists(), "success descendant escaped process-group cleanup")

    def test_command_failure_stops_owned_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "descendant-survived"
            child = f"import time,pathlib;time.sleep(1);pathlib.Path({str(marker)!r}).write_text('survived')"
            parent = f"import subprocess,sys;subprocess.Popen([sys.executable,'-c',{child!r}]);raise SystemExit(3)"
            with (root / "command.log").open("w") as log:
                with self.assertRaises(subprocess.CalledProcessError):
                    runner.run_owned([sys.executable, "-c", parent], cwd=root, env=os.environ.copy(),
                                     log=log, timeout=10)
            time.sleep(1.1)
            self.assertFalse(marker.exists(), "failed descendant escaped process-group cleanup")

    def test_wait_for_notes_returns_once_persisted(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "state" / "macparakeet.db"
            database.parent.mkdir(parents=True)
            seed = sqlite3.connect(database)
            seed.execute("CREATE TABLE transcriptions (id TEXT PRIMARY KEY, userNotes TEXT)")
            seed.execute("INSERT INTO transcriptions (id, userNotes) VALUES ('seed', 'before')")
            seed.commit()
            seed.close()

            def persist_after_delay():
                time.sleep(0.3)
                writer = sqlite3.connect(database)
                writer.execute("UPDATE transcriptions SET userNotes = ?", ("after",))
                writer.commit()
                writer.close()

            delayed_writer = threading.Thread(target=persist_after_delay)
            delayed_writer.start()
            try:
                runner.wait_for_notes(database, "after", timeout=5)
            finally:
                delayed_writer.join(timeout=5)

    def test_wait_for_notes_times_out_when_never_persisted(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "state" / "macparakeet.db"
            database.parent.mkdir(parents=True)
            seed = sqlite3.connect(database)
            seed.execute("CREATE TABLE transcriptions (id TEXT PRIMARY KEY, userNotes TEXT)")
            seed.execute("INSERT INTO transcriptions (id, userNotes) VALUES ('seed', 'before')")
            seed.commit()
            seed.close()
            with self.assertRaises(RuntimeError):
                runner.wait_for_notes(database, "after", timeout=0.3)

    def _standin_binary(self, directory):
        # ps reports the resolved executable image, which for a framework
        # Python build can differ from sys.executable's own realpath (it
        # re-execs into the framework's real binary, briefly reporting the
        # pre-exec launcher path first). Discover the settled image via a
        # short-lived probe, then copy it so this test's stand-in "app" never
        # collides with an unrelated process sharing the interpreter.
        probe = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(5)"])
        try:
            deadline = time.monotonic() + 1.5
            source = None
            while time.monotonic() < deadline:
                for pid, uid, command in runner.processes():
                    if pid == probe.pid and uid == os.getuid() and command.startswith("/"):
                        source = command
                time.sleep(0.02)
        finally:
            probe.kill()
            probe.wait()
        self.assertIsNotNone(source, "probe process never appeared in ps")
        binary = Path(directory) / "stand-in-app"
        shutil.copy2(source, binary)
        os.chmod(binary, 0o755)
        return binary

    def test_owned_matches_and_stop_terminate_exact_attributable_process(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = self._standin_binary(directory)
            process = subprocess.Popen([str(binary), "-c", "import time; time.sleep(30)"])
            reaper = threading.Thread(target=process.wait)
            reaper.start()
            try:
                deadline = time.monotonic() + 5
                matches = []
                while time.monotonic() < deadline:
                    matches = runner.owned_matches(binary)
                    if process.pid in matches:
                        break
                    time.sleep(0.05)
                self.assertEqual(matches, [process.pid])
                runner.stop(process.pid, binary)
            finally:
                reaper.join(timeout=5)
            self.assertNotIn(process.pid, [pid for pid, _, _ in runner.processes()])

    def test_cleanup_sweep_stops_every_attributable_candidate_when_ambiguous(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = self._standin_binary(directory)
            first = subprocess.Popen([str(binary), "-c", "import time; time.sleep(30)"])
            second = subprocess.Popen([str(binary), "-c", "import time; time.sleep(30)"])
            reapers = [threading.Thread(target=first.wait), threading.Thread(target=second.wait)]
            for reaper in reapers:
                reaper.start()
            try:
                deadline = time.monotonic() + 5
                matches = []
                while time.monotonic() < deadline:
                    matches = runner.owned_matches(binary)
                    if first.pid in matches and second.pid in matches:
                        break
                    time.sleep(0.05)
                self.assertEqual(sorted(matches), sorted([first.pid, second.pid]))
                for pid in matches:
                    runner.stop(pid, binary)
            finally:
                for reaper in reapers:
                    reaper.join(timeout=5)
            remaining = {pid for pid, _, _ in runner.processes()}
            self.assertNotIn(first.pid, remaining)
            self.assertNotIn(second.pid, remaining)


if __name__ == "__main__":
    unittest.main()
