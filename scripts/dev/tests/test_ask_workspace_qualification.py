import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import sqlite3
import uuid
from contextlib import closing
import threading
import unittest
import urllib.request
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "ask_workspace_qualification", Path(__file__).parents[1] / "ask_workspace_qualification.py"
)
qualification = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qualification)


class AskWorkspaceQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)

    def args(self):
        return argparse.Namespace(output_dir=self.output, api_key_env=None, cli=Path("/usr/bin/true"))

    def test_existing_output_is_rejected_without_touching_files(self):
        sentinel = self.output / "existing.sqlite"
        sentinel.write_text("user data")
        with self.assertRaisesRegex(AssertionError, "new or empty"):
            qualification.Qualification(self.args())
        self.assertEqual(sentinel.read_text(), "user data")
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_environment_is_explicit_and_credentials_are_redacted(self):
        args = self.args()
        args.api_key_env = "QUALIFICATION_TEST_KEY"
        with patch.dict("os.environ", {"QUALIFICATION_TEST_KEY": "private-test-value", "LM_API_TOKEN": "unrelated", "HTTP_PROXY": "http://private-proxy"}):
            harness = qualification.Qualification(args)
        self.assertNotIn("HTTP_PROXY", harness.env)
        self.assertNotIn("LM_API_TOKEN", harness.env)
        harness.save("redacted.json", {"error": "credential private-test-value"})
        self.assertNotIn("private-test-value", (self.output / "redacted.json").read_text())
        self.assertEqual(harness.db, self.output.resolve() / "synthetic.sqlite")

    def test_synthetic_seed_uses_grdb_uuid_blob_keys(self):
        harness = qualification.Qualification(self.args())
        with closing(sqlite3.connect(harness.db)) as db, db:
            db.execute("CREATE TABLE transcriptions (id BLOB PRIMARY KEY, createdAt TEXT, updatedAt TEXT, fileName TEXT, rawTranscript TEXT, cleanTranscript TEXT, status TEXT, sourceType TEXT)")
        with patch.object(harness, "invoke", side_effect=[[], [{"id": qualification.A}, {"id": qualification.B}]]):
            harness.seed()
        with closing(sqlite3.connect(harness.db)) as db:
            rows = db.execute("SELECT id, typeof(id) FROM transcriptions ORDER BY id").fetchall()
        self.assertEqual(rows, [(uuid.UUID(source).bytes, "blob") for source in (qualification.A, qualification.B)])

    def test_pretty_json_and_ndjson_decode(self):
        self.assertEqual(qualification.decode_output('{\n "revision": 1\n}'), {"revision": 1})
        events = [{"type": "text", "text": "x"}, {"type": "conversation", "conversation": {}}]
        self.assertEqual(qualification.decode_output("\n".join(map(json.dumps, events))), events)

    def test_uuid_revision_map_order_is_not_persistence_loss(self):
        first = {"messages": [{"sourceRevisions": ["a", "hash-a", "b", "hash-b"]}]}
        second = {"messages": [{"sourceRevisions": ["b", "hash-b", "a", "hash-a"]}]}
        self.assertEqual(qualification.decode_output(json.dumps(first)), qualification.decode_output(json.dumps(second)))
        second["messages"][0]["sourceRevisions"][1] = "changed-hash"
        self.assertNotEqual(qualification.decode_output(json.dumps(first)), qualification.decode_output(json.dumps(second)))

    def provider(self):
        server = qualification.ScriptedProvider()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def post(self, server, messages, stream=False):
        request = urllib.request.Request(server.endpoint + "/chat/completions",
                                         data=json.dumps({"messages": messages, "stream": stream}).encode(),
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.read().decode()

    def test_fixture_http_decision_and_sse_use_returned_citation(self):
        server = self.provider()
        server.reset(sources=(qualification.A,))
        decision = json.loads(self.post(server, [{"role": "user", "content": "Question"}]))
        action = json.loads(decision["choices"][0]["message"]["content"])
        self.assertEqual(action["toolName"], "list_sources")
        evidence = [{"citation": "[E7]", "passage": {"reference": {"sourceID": qualification.A}, "text": qualification.TRANSCRIPTS[qualification.A]}}]
        stream = self.post(server, [{"role": "user", "content": "Tool read result: " + json.dumps(evidence)}], stream=True)
        self.assertIn("[E7]", stream)
        self.assertIn('"finish_reason": "stop"', stream)
        self.assertIn("data: [DONE]", stream)
        self.assertTrue(server.arrived.is_set())

    def test_fixture_refuses_to_invent_evidence(self):
        server = self.provider()
        with self.assertRaisesRegex(AssertionError, "first source evidence"):
            server.answer([])

    def test_fixture_invalid_action_modes_are_bounded_by_request_count(self):
        server = self.provider()
        for mode in ("repair_arguments", "repair_kind"):
            server.reset(mode=mode)
            first = json.loads(self.post(server, []))
            second = json.loads(self.post(server, []))
            a = json.loads(first["choices"][0]["message"]["content"])
            b = json.loads(second["choices"][0]["message"]["content"])
            self.assertTrue(a["kind"] == "unexpected" or a["start"] == "invalid")
            self.assertEqual(b, {"kind": "tool", "toolName": "list_sources", "query": "", "sourceID": "", "start": 0, "limit": 0})
        server.reset(mode="invalid")
        for _ in range(2):
            response = json.loads(self.post(server, []))
            self.assertEqual(json.loads(response["choices"][0]["message"]["content"])["start"], "invalid")


if __name__ == "__main__":
    unittest.main()
