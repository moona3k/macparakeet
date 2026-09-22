import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "query_audio_diagnostics", Path(__file__).parents[1] / "query_audio_diagnostics.py"
)
diagnostics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostics)


class QueryAudioDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "dictation-audio.log"

    def write(self, content):
        self.path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)

    def test_quoted_values_and_legacy_lines_remain_structured_strings(self):
        self.write('2026-09-06T01:00:00.123Z capture_failed reason="no usable buffers" frames=001 enabled=false\n')

        result = diagnostics.query_log(self.path)

        self.assertEqual(result["status"], "available")
        self.assertEqual(result["records"][0]["fields"], {
            "reason": "no usable buffers", "frames": "001", "enabled": "false",
        })
        self.assertNotIn("raw", result["records"][0])

    def test_timestamp_order_filters_entire_tail_and_counts_before_limit(self):
        self.write(
            "2026-09-06T03:00:00Z capture_stop frames=3\n"
            "2026-09-06T01:00:00Z capture_stop frames=1\n"
            "2026-09-06T02:00:00Z capture_stop frames=2\n"
        )

        result = diagnostics.query_log(
            self.path, since=diagnostics.parse_timestamp("2026-09-06T02:00:00Z"), limit=1
        )

        self.assertEqual(result["matched_records"], 2)
        self.assertEqual(result["returned_records"], 1)
        self.assertEqual(result["event_counts"], {"capture_stop": 2})
        self.assertEqual(result["records"][0]["fields"]["frames"], "3")

    def test_event_and_process_filters_are_conjunctive(self):
        self.write(
            "2026-09-06T00:00:00Z capture_start process_session=run-a\n"
            "2026-09-06T00:00:01Z capture_stop process_session=run-a\n"
            "2026-09-06T00:00:02Z capture_stop process_session=run-b\n"
            "2026-09-06T00:00:03Z capture_stop\n"
        )

        result = diagnostics.query_log(self.path, events=["capture_stop", "capture_failed"], process_session="run-a")

        self.assertEqual(result["event_counts"], {"capture_stop": 1})
        self.assertEqual(result["scan"]["parsed_records"], 4)

    def test_bounded_tail_discards_partial_utf8_and_unfinished_newest_line(self):
        complete = "2026-09-06T00:00:01Z capture_stop frames=480\n"
        unfinished = "2026-09-06T00:00:02Z capture_star"
        self.write("old " + "é" * 100 + "\n" + complete + unfinished)
        budget = len((complete + unfinished).encode()) + 4

        result = diagnostics.query_log(self.path, max_scan_bytes=budget)

        self.assertTrue(result["scan"]["truncated"])
        self.assertLessEqual(result["scan"]["bytes_read"], budget)
        self.assertEqual(result["scan"]["incomplete_lines"], 2)
        self.assertEqual(result["scan"]["discarded_partial_end_bytes"], len(unfinished))
        self.assertEqual(result["event_counts"], {"capture_stop": 1})
        self.assertEqual(result["scan"]["unparsed_lines"], 0)

    def test_exact_tail_boundary_keeps_complete_newest_line(self):
        complete = "2026-09-06T00:00:01Z capture_stop\n"
        self.write("old event\n" + complete)

        result = diagnostics.query_log(self.path, max_scan_bytes=len(complete) + 1)

        self.assertEqual(result["event_counts"], {"capture_stop": 1})
        self.assertEqual(result["scan"]["incomplete_lines"], 0)

    def test_tail_starting_at_record_first_byte_keeps_that_record(self):
        complete = "2026-09-06T00:00:01Z capture_stop\n"
        self.write("old event\n" + complete)

        result = diagnostics.query_log(self.path, max_scan_bytes=len(complete))

        self.assertEqual(result["event_counts"], {"capture_stop": 1})
        self.assertEqual(result["scan"]["incomplete_lines"], 0)
        self.assertEqual(result["scan"]["discarded_partial_start_bytes"], 0)

    def test_atomic_replacement_during_read_is_reported(self):
        self.write("2026-09-06T00:00:01Z capture_stop\n")
        replacement = self.path.with_suffix(".replacement")
        replacement.write_text("2026-09-06T00:00:02Z capture_start\n")
        original_fstat = os.fstat
        checks = 0

        def replace_before_final_check(descriptor):
            nonlocal checks
            checks += 1
            if checks == 2:
                replacement.replace(self.path)
            return original_fstat(descriptor)

        with patch.object(diagnostics.os, "fstat", side_effect=replace_before_final_check):
            result = diagnostics.query_log(self.path)

        self.assertTrue(result["scan"]["changed_during_read"])
        self.assertEqual(result["event_counts"], {"capture_stop": 1})

    def test_path_disappearance_during_read_preserves_evidence_and_reports_change(self):
        self.write("2026-09-06T00:00:01Z capture_stop\n")
        original_fstat = os.fstat
        checks = 0

        def remove_before_final_check(descriptor):
            nonlocal checks
            checks += 1
            if checks == 2:
                self.path.unlink()
            return original_fstat(descriptor)

        with patch.object(diagnostics.os, "fstat", side_effect=remove_before_final_check):
            result = diagnostics.query_log(self.path)

        self.assertEqual(result["status"], "available")
        self.assertTrue(result["scan"]["changed_during_read"])
        self.assertEqual(result["event_counts"], {"capture_stop": 1})

    def test_malformed_records_and_fields_are_counted_without_raw_output(self):
        self.write(
            b"unstructured private text\n"
            b'2026-09-06T00:00:00Z capture_failed reason="unclosed\n'
            b"2026-09-06T00:00:01Z capture_stop frames=1 stray frames=2\n"
            b"\xff\n"
        )

        result = diagnostics.query_log(self.path)

        self.assertEqual(result["scan"]["unparsed_lines"], 3)
        self.assertEqual(result["scan"]["unparsed_field_tokens"], 1)
        self.assertEqual(result["scan"]["duplicate_fields"], 1)
        self.assertNotIn("unstructured private text", str(result))
        self.assertEqual(result["records"][0]["fields"]["frames"], "2")

    def test_missing_empty_unparseable_and_no_matches_are_explicit(self):
        self.assertEqual(diagnostics.query_log(self.path)["status"], "missing")
        self.write("")
        self.assertEqual(diagnostics.query_log(self.path)["status"], "empty")
        self.write("invalid\n")
        self.assertEqual(diagnostics.query_log(self.path)["status"], "unparseable")
        self.write("2026-09-06T00:00:00Z capture_start\n")
        self.assertEqual(diagnostics.query_log(self.path, events=["other"])["status"], "no_matches")

    def test_nonregular_input_is_rejected_without_blocking(self):
        os.mkfifo(self.path)
        self.assertEqual(diagnostics.query_log(self.path)["status"], "unreadable")

    def test_default_path_honors_explicit_and_debug_environment(self):
        with patch.dict(os.environ, {"MACPARAKEET_DEBUG_APP_STATE_DIR": "/tmp/debug"}, clear=True):
            self.assertEqual(diagnostics.default_log_path(), Path("/tmp/debug/logs/dictation-audio.log"))
            with patch.dict(os.environ, {"MACPARAKEET_AUDIO_DIAGNOSTICS_LOG_PATH": "/tmp/chosen.log"}):
                self.assertEqual(diagnostics.default_log_path(), Path("/tmp/chosen.log"))

    def test_naive_timestamps_and_unbounded_limits_are_rejected(self):
        with self.assertRaises(ValueError):
            diagnostics.parse_timestamp("2026-09-06T00:00:00")
        for limit in [0, 1001]:
            with self.assertRaises(ValueError):
                diagnostics.query_log(self.path, limit=limit)

    def test_command_outputs_json_and_preserves_the_source(self):
        content = "2026-09-06T00:00:00Z capture_stop frames=480\n"
        self.write(content)
        modified = self.path.stat().st_mtime_ns
        output = io.StringIO()

        with redirect_stdout(output):
            exit_code = diagnostics.main(["--path", str(self.path), "--event", "capture_stop", "--limit", "1"])

        self.assertEqual(exit_code, 0)
        self.assertEqual(json.loads(output.getvalue())["event_counts"], {"capture_stop": 1})
        self.assertEqual(self.path.read_text(), content)
        self.assertEqual(self.path.stat().st_mtime_ns, modified)


if __name__ == "__main__":
    unittest.main()
