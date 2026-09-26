"""Failure-path checks for the subprocess smoke driver (no product binary)."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("cli-persistence-smoke.py")
SPEC = importlib.util.spec_from_file_location("cli_persistence_smoke", SCRIPT)
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.executable = self.root / "fake-cli"
        self.database = self.root / "smoke.sqlite"

    def fake_cli(self, body):
        self.executable.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
        self.executable.chmod(0o755)

    def test_wrong_exit_includes_stderr(self):
        self.fake_cli("import sys\nprint('broken', file=sys.stderr)\nsys.exit(3)\n")
        with self.assertRaisesRegex(AssertionError, "broken"):
            SMOKE.run_json(self.executable, self.database, {}, "collections", "list")

    def test_invalid_json_includes_stdout(self):
        self.fake_cli("print('not JSON')\n")
        with self.assertRaisesRegex(AssertionError, "not JSON"):
            SMOKE.run_json(self.executable, self.database, {}, "collections", "list")

    def test_timeout_reports_command(self):
        self.fake_cli("import time\ntime.sleep(2)\n")
        original = SMOKE.COMMAND_TIMEOUT_SECONDS
        SMOKE.COMMAND_TIMEOUT_SECONDS = 0.05
        self.addCleanup(setattr, SMOKE, "COMMAND_TIMEOUT_SECONDS", original)
        with self.assertRaisesRegex(AssertionError, "CLI timed out"):
            SMOKE.run_json(self.executable, self.database, {}, "collections", "list")


if __name__ == "__main__":
    unittest.main()
