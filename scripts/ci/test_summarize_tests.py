#!/usr/bin/env python3
"""CLI tests for summarize-tests.py, using SwiftPM xUnit shapes."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("summarize-tests.py")


class SummaryCLITests(unittest.TestCase):
    def run_summary(self, xml=None, log=None):
        with tempfile.TemporaryDirectory() as directory:
            xml_path = Path(directory) / "swift-tests.xml"
            if xml is not None:
                xml_path.write_text(xml, encoding="utf-8")
            command = [sys.executable, str(SCRIPT), str(xml_path)]
            if log is not None:
                log_path = Path(directory) / "swift-test.log"
                log_path.write_text(log, encoding="utf-8")
                command.append(str(log_path))
            return subprocess.run(command, capture_output=True, text=True, check=False)

    def test_xctest_shape_and_safe_case_names(self):
        result = self.run_summary(
            """<?xml version="1.0" encoding="UTF-8"?>
<testsuites><testsuite name="MacParakeetTests" errors="0" tests="3" failures="1" time="12.4">
  <testcase classname="AudioTests" name="testSlow|&lt;script&gt;" time="8.25" />
  <testcase classname="AudioTests" name="testFast" time="0.10" />
  <testcase classname="AudioTests" name="testFailure" time="4.05"><failure message="failed" /></testcase>
</testsuite></testsuites>"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Cases in xUnit XML: **3**; failures: **1**; errors: **0**", result.stdout)
        self.assertIn("Skipped: not reported", result.stdout)
        self.assertIn("Sum of 3 case durations: **12.40s**", result.stdout)
        self.assertIn("not wall time", result.stdout)
        self.assertIn("AudioTests.testSlow&#124;&lt;script&gt;", result.stdout)
        self.assertNotIn("<script>", result.stdout)
        self.assertLess(result.stdout.index("testSlow"), result.stdout.index("testFailure"))

    def test_swift_testing_shape_and_separate_log_summary(self):
        result = self.run_summary(
            """<testsuites><testsuite name="TestResults" errors="0" tests="1" failures="0" skipped="0" time="0.3">
<testcase classname="exampleTests" name="example()" time="0.1" />
</testsuite></testsuites>""",
            "◇ Test run started.\n✔ Test run with 1 test in 0 suites passed after 0.42 seconds.\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Cases in xUnit XML: **1**", result.stdout)
        self.assertIn("Skipped (suite report): **0**", result.stdout)
        self.assertIn("Swift Testing (separate log summary", result.stdout)
        self.assertIn("1 test passed after 0.42s", result.stdout)

    def test_missing_and_malformed_xml_fail(self):
        missing = self.run_summary()
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("cannot read xUnit XML", missing.stderr)
        malformed = self.run_summary("<testsuites><testsuite>")
        self.assertNotEqual(malformed.returncode, 0)
        self.assertIn("cannot read xUnit XML", malformed.stderr)

    def test_empty_report_fails(self):
        result = self.run_summary("<testsuites><testsuite tests='0' /></testsuites>")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contains no testcase", result.stderr)

    def test_invalid_duration_fails_and_missing_duration_is_disclosed(self):
        for invalid in ("NaN", "-1", "garbage", "Infinity"):
            with self.subTest(invalid=invalid):
                result = self.run_summary(
                    f"<testsuite><testcase name='bad' time='{invalid}' /></testsuite>"
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid testcase time", result.stderr)
        missing = self.run_summary("<testsuite><testcase name='untimed' /></testsuite>")
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertIn("Cases without a duration: **1**", missing.stdout)


if __name__ == "__main__":
    unittest.main()
