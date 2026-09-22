#!/usr/bin/env python3
"""Exercise an already-built DEBUG CLI against owned synthetic data and HTTP.

No builds, GUI, audio, shared configuration writes, Keychain or external provider
requests. An empty, caller-owned output directory is required. The transcription
fixture is inserted with SQLite and prompt inference settings are seeded through
`prompts set`; neither is evidence of GUI editing.
"""
import argparse
import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import threading
import traceback
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--expected-cli-version", default="4.0.0")
    args = parser.parse_args()
    args.cli = args.cli.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise SystemExit("Refusing to reuse a nonempty evidence directory")
    state_dir = args.output / "app-state"
    fixed_home = args.output / "foundation-home"
    fixed_home.mkdir()
    database = state_dir / "macparakeet.db"
    env = dict(os.environ)
    env.update({
        "MACPARAKEET_DEBUG_APP_STATE_DIR": str(state_dir),
        "CFFIXED_USER_HOME": str(fixed_home),
        "MACPARAKEET_TELEMETRY": "0",
        "DO_NOT_TRACK": "1",
        "MACPARAKEET_DEBUG_SQL": "0",
    })
    records = []
    requests = []
    active = {"scenario": "success"}
    streamed = threading.Event()
    release_stream = threading.Event()
    output = "## QA result\n\n- Synthetic provider response."
    settings = {
        "temperature": 0.25, "topP": 0.85, "topK": 24,
        "maxTokens": 256, "thinkingMode": "enabled", "reasoningEffort": "low",
    }

    def write_json(path, value):
        def encode_blob(value):
            if isinstance(value, bytes):
                return str(uuid.UUID(bytes=value)) if len(value) == 16 else value.hex()
            raise TypeError(type(value).__name__)
        path.write_text(json.dumps(value, indent=2, sort_keys=True, default=encode_blob) + "\n")

    def check(condition, message):
        if not condition:
            raise AssertionError(message)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                self.respond()
            except (BrokenPipeError, ConnectionResetError):
                pass  # Expected when the owned CLI is canceled.

        def respond(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            scenario = active["scenario"]
            requests.append({
                "scenario": scenario, "path": self.path, "body": payload,
                "authorizationPresent": self.headers.get("Authorization") is not None,
            })
            write_json(args.output / "requests.json", requests)
            if scenario in ("auth", "rate_limit", "invalid_json"):
                status = {"auth": 401, "rate_limit": 429, "invalid_json": 200}[scenario]
                body = b"not-json" if scenario == "invalid_json" else json.dumps({
                    "error": {"message": "Synthetic authentication failure" if status == 401 else "Synthetic rate limit"}
                }).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if not payload["stream"]:
                body = json.dumps({
                    "model": "qa-model",
                    "choices": [{"message": {"content": output}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18},
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def frame(value):
                encoded = value if isinstance(value, str) else json.dumps(value)
                self.wfile.write(("data: " + encoded + "\n\n").encode())
                self.wfile.flush()

            if scenario == "empty_stream":
                return
            frame({"model": "qa-model", "choices": [{"delta": {"content": output}}]})
            streamed.set()
            if scenario == "cancel":
                release_stream.wait(20)
                return
            if scenario == "stream_error":
                frame({"error": {"message": "Synthetic provider failure"}})
                return
            if scenario == "lenient_eof":
                return
            frame({
                "model": "qa-model", "choices": [{"delta": {}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18},
            })
            frame("[DONE]")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/v1"
    provider = ["--provider", "openaiCompatible", "--base-url", endpoint, "--model", "qa-model"]
    metadata = {
        "candidateSource": args.candidate, "binary": str(args.cli),
        "expectedCLIVersion": args.expected_cli_version,
        "binarySHA256": hashlib.file_digest(args.cli.open("rb"), "sha256").hexdigest(),
        "binaryMTime": args.cli.stat().st_mtime,
        "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "database": str(database), "stateDir": str(state_dir),
        "foundationHome": str(fixed_home), "endpoint": endpoint,
        "fixtureSetup": "CLI creates schema/prompt and seeds prompt settings; direct SQLite inserts synthetic transcription",
    }
    write_json(args.output / "metadata.json", metadata)

    def run(name, arguments, expected=0, json_output=False, scenario="success"):
        active["scenario"] = scenario
        command = [str(args.cli)] + arguments
        result = subprocess.run(command, env=env, cwd=args.output, capture_output=True, timeout=25)
        (args.output / (name + ".stdout")).write_bytes(result.stdout)
        (args.output / (name + ".stderr")).write_bytes(result.stderr)
        record = {"name": name, "arguments": arguments, "exitCode": result.returncode, "expectedExitCode": expected}
        records.append(record)
        write_json(args.output / "commands.json", records)
        check(result.returncode == expected, f"{name}: expected exit {expected}, got {result.returncode}: {result.stderr.decode(errors='replace')} {result.stdout.decode(errors='replace')}")
        if json_output:
            return json.loads(result.stdout)
        return result.stdout.decode()

    def saved_rows(db=database):
        with sqlite3.connect(db) as connection:
            connection.row_factory = sqlite3.Row
            return [dict(row) for row in connection.execute(
                "SELECT id, transcriptionId, promptName, content, inferenceSettingsSnapshot FROM summaries ORDER BY rowid"
            )]

    def prompt_run(extra):
        return ["prompts", "run", "QA receipt", "--transcription", "qa-synthetic.wav", "--database", str(database)] + provider + extra

    try:
        check(run("version", ["--version"]).strip() == args.expected_cli_version, "Unexpected CLI version")
        spec = run("spec", ["spec", "--json"], json_output=True)
        check(spec["cliVersion"] == args.expected_cli_version, "Spec version mismatch")
        run("initialize", ["prompts", "list", "--json", "--database", str(database)], json_output=True)
        run("add-prompt", ["prompts", "add", "--name", "QA receipt", "--content", "Summarize only the synthetic QA text.", "--database", str(database)])
        text_file = args.output / "synthetic.txt"
        text_file.write_text("The synthetic QA team agreed to verify local exports. No personal information is present.\n")
        with sqlite3.connect(database) as connection:
            connection.row_factory = sqlite3.Row
            write_json(args.output / "schema-before.json", {
                name: [dict(row) for row in connection.execute(f"PRAGMA table_info({name})")]
                for name in ("transcriptions", "prompts", "summaries")
            })
            prompt_id = connection.execute("SELECT id FROM prompts WHERE name = ?", ("QA receipt",)).fetchone()[0]
            fixture_uuid = uuid.uuid4()
            if isinstance(prompt_id, bytes):
                identifier = fixture_uuid.bytes
            else:
                identifier = str(fixture_uuid)
                if prompt_id == prompt_id.upper():
                    identifier = identifier.upper()
            now = "2026-09-07T12:00:00.000Z"
            connection.execute(
                "INSERT INTO transcriptions (id, createdAt, updatedAt, fileName, rawTranscript, cleanTranscript, status, sourceType, isFavorite, recoveredFromCrash, isTranscriptEdited) VALUES (?, ?, ?, ?, ?, ?, 'completed', 'file', 0, 0, 0)",
                (identifier, now, now, "qa-synthetic.wav", text_file.read_text(), text_file.read_text()),
            )

        run("seed-settings", ["prompts", "set", "QA receipt", "--temperature", "0.25", "--top-p", "0.85", "--top-k", "24",
                              "--max-tokens", "256", "--thinking-mode", "enabled", "--reasoning-effort", "low", "--database", str(database)])
        prompt = run("prompt-show", ["prompts", "show", "QA receipt", "--json", "--database", str(database)], json_output=True)
        check(prompt["inferenceSettings"] == settings, "Settings do not round-trip")
        summary = run("summarize-json", ["llm", "summarize", str(text_file)] + provider + ["--json"], json_output=True)
        check(summary["effectiveSettings"] == {"temperature": 0.7, "thinkingMode": "providerDefault"}, "Summarize baseline receipt differs")
        check(summary["output"] == output and summary["usage"]["totalTokens"] == 18, "Summarize payload mismatch")
        check(requests[-1]["body"]["temperature"] == 0.7, "Summarize request mismatch")
        result = run("prompt-json", prompt_run(["--json"]), json_output=True)
        check(result["effectiveSettings"] == settings, "Prompt receipt differs")
        body = requests[-1]["body"]
        check({key: body[key] for key in ("temperature", "top_p", "top_k", "max_tokens")} == {
            "temperature": 0.25, "top_p": 0.85, "top_k": 24, "max_tokens": 256,
        }, "Prompt request numeric settings differ")
        check(body["chat_template_kwargs"] == {"enable_thinking": True, "reasoning_effort": "low"}, "Thinking settings differ")
        check(len(saved_rows()) == 1 and json.loads(saved_rows()[0]["inferenceSettingsSnapshot"]) == settings, "Stored receipt differs")
        stream = run("prompt-stream", prompt_run(["--stream"]))
        check(stream.strip() == output, "Stream output differs")
        check(len(saved_rows()) == 2 and json.loads(saved_rows()[-1]["inferenceSettingsSnapshot"]) == settings, "Stream did not persist receipt")
        for scenario, error_type in (("auth", "auth"), ("rate_limit", "rate_limit"), ("invalid_json", "invalid_response")):
            before = saved_rows()
            failure = run("prompt-" + scenario, prompt_run(["--json"]), expected=1, json_output=True, scenario=scenario)
            check(failure["ok"] is False and failure["errorType"] == error_type, "Failure envelope mismatch: " + scenario)
            check(saved_rows() == before, "Failure changed saved results: " + scenario)
        for scenario in ("stream_error", "empty_stream"):
            before = saved_rows()
            run("prompt-" + scenario, prompt_run(["--stream"]), expected=1, scenario=scenario)
            check(saved_rows() == before, "Failed stream changed saved results: " + scenario)
        before = saved_rows()
        run("prompt-lenient-eof", prompt_run(["--stream"]), scenario="lenient_eof")
        check(len(saved_rows()) == len(before) + 1, "Compatible clean EOF did not persist")

        before = saved_rows()
        active["scenario"] = "cancel"
        streamed.clear()
        command = [str(args.cli)] + prompt_run(["--stream"])
        process = subprocess.Popen(command, env=env, cwd=args.output, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            check(streamed.wait(10), "Server did not emit content before cancellation")
            check(process.poll() is None, "CLI exited before cancellation")
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=10)
        finally:
            release_stream.set()
            if process.poll() is None:
                process.kill()
                process.communicate()
        (args.output / "prompt-cancel.stdout").write_bytes(stdout)
        (args.output / "prompt-cancel.stderr").write_bytes(stderr)
        exit_code = 128 - process.returncode if process.returncode < 0 else process.returncode
        records.append({"name": "prompt-cancel", "arguments": command[1:], "exitCode": process.returncode, "shellExitCode": exit_code, "expectedShellExitCode": 130})
        check(exit_code == 130, f"Cancellation returned {exit_code}")
        check(saved_rows() == before, "Canceled stream changed saved results")

        hidden = run("hide-prompt", ["prompts", "set", "QA receipt", "--hidden", "--json", "--database", str(database)], json_output=True)
        check(hidden["inferenceSettings"] == settings, "Hide lost settings")
        visible = run("show-prompt", ["prompts", "set", "QA receipt", "--visible", "--json", "--database", str(database)], json_output=True)
        check(visible["inferenceSettings"] == settings, "Show lost settings")
        write_json(args.output / "saved-results.json", saved_rows())

        legacy = state_dir / "synthetic-v028.db"
        with sqlite3.connect(database) as source, sqlite3.connect(legacy) as target:
            source.backup(target)
        with sqlite3.connect(legacy) as connection:
            original_text = connection.execute("SELECT id, rawTranscript FROM transcriptions").fetchall()
            original_results = connection.execute("SELECT id, content FROM summaries ORDER BY rowid").fetchall()
            for column in ("audioTrackOrdinal", "meetingCaptureReport"):
                connection.execute(f"ALTER TABLE transcriptions DROP COLUMN {column}")
            connection.execute("DELETE FROM grdb_migrations WHERE identifier IN (?, ?)", (
                "v0.29-transcription-audio-track", "v0.30-meeting-capture-report",
            ))
            write_json(args.output / "legacy-before.json", {
                "method": "Synthetic pre-v0.29 transcription columns reconstructed from owned current fixture; the v0.31 legacy prompt column is not reconstructed because v0.36 removed it and cannot rerun; not produced by an old binary",
                "migrations": [row[0] for row in connection.execute("SELECT identifier FROM grdb_migrations ORDER BY rowid")],
                "transcriptionCount": len(original_text), "resultCount": len(original_results),
            })
        run("legacy-upgrade", ["prompts", "list", "--json", "--database", str(legacy)], json_output=True)
        with sqlite3.connect(legacy) as connection:
            check(connection.execute("SELECT id, rawTranscript FROM transcriptions").fetchall() == original_text, "Migration changed transcript")
            check(connection.execute("SELECT id, content FROM summaries ORDER BY rowid").fetchall() == original_results, "Migration changed results")
            active_settings = connection.execute(
                "SELECT v.inferenceSettings FROM prompts p JOIN prompt_versions v ON v.id = p.activeVersionId WHERE p.name = 'QA receipt'"
            ).fetchone()[0]
            check(json.loads(active_settings) == settings, "Migration changed versioned prompt settings")
            check("inferenceSettings" not in [row[1] for row in connection.execute("PRAGMA table_info(prompts)")], "Removed legacy prompt column reappeared")
            check(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "Integrity check failed")
            check(connection.execute("PRAGMA foreign_key_check").fetchall() == [], "Foreign keys failed")
            write_json(args.output / "legacy-after.json", {
                "migrations": [row[0] for row in connection.execute("SELECT identifier FROM grdb_migrations ORDER BY rowid")],
                "preservedTranscriptions": len(original_text), "preservedResults": len(original_results),
                "versionedPromptSettings": settings, "legacyPromptColumnAbsent": True, "integrity": "ok", "foreignKeyViolations": [],
            })
        check(all(not request["authorizationPresent"] for request in requests), "Unexpected authentication header")
        outcome = {"status": "pass", "commands": len(records), "providerRequests": len(requests)}
    except Exception as error:
        outcome = {"status": "fail", "error": str(error), "traceback": traceback.format_exc(), "commands": len(records)}
        raise
    finally:
        release_stream.set()
        server.shutdown()
        server.server_close()
        write_json(args.output / "commands.json", records)
        write_json(args.output / "requests.json", requests)
        write_json(args.output / "result.json", outcome)
        print(json.dumps(outcome, indent=2))


if __name__ == "__main__":
    main()
