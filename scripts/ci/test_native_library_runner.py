import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
