#!/usr/bin/env python3
"""Qualify packaged Ask CLI against isolated synthetic recordings (stdlib only).

Example:
  python3 scripts/dev/ask_workspace_qualification.py --cli /path/to/macparakeet-cli \
    --output-dir /tmp/ask-qualification-new

The default mode explicitly opts in with --enable-ask-workspace and requires a
Debug CLI. The scripted loopback provider tests integration, not model intelligence.
Use --expect-disabled with a Release CLI to prove the workspace stays unavailable,
even with the developer flag, without opening its database or calling a provider.
Add --endpoint http://127.0.0.1:1234/v1 --model MODEL --provider lmstudio to
also run the evidence workflows against a real model. Remote endpoints require
--allow-remote; credentials are accepted only through --api-key-env NAME.
No models are downloaded. No app, microphone, existing database or preferences
are modified. SIGTERM recovery tests process interruption, not the GUI Stop button.
"""

import argparse
import contextlib
import http.server
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import uuid

A = "10000000-0000-4000-8000-000000000001"
B = "10000000-0000-4000-8000-000000000002"
TRANSCRIPTS = {
    A: "On September 1, the team approved the launch for October 10. Ada owns the release.",
    B: ("On September 8, the team discussed the launch. The previous October 10 date was provisional. "
        + "The team reviewed documentation, packaging, and support readiness. " * 160
        + "Final decision: the launch moved to October 24; Bea now owns the release."),
}
QUESTION = "How did the launch date change? State the latest date and who owns the release, with citations."
SCOPED_QUESTION = "What launch date and release owner are stated in the currently selected recording? Cite evidence."


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def normalize_revision_maps(value):
    """Swift encodes UUID-keyed dictionaries as unordered alternating key/value arrays."""
    if isinstance(value, list):
        return [normalize_revision_maps(item) for item in value]
    if isinstance(value, dict):
        result = {key: normalize_revision_maps(item) for key, item in value.items()}
        revisions = result.get("sourceRevisions")
        if isinstance(revisions, list):
            require(len(revisions) % 2 == 0, "invalid source revision map")
            result["sourceRevisions"] = dict(zip(revisions[::2], revisions[1::2]))
        return result
    return value


def decode_output(text):
    """Normal commands emit pretty JSON; --stream emits one JSON object per line."""
    try:
        return normalize_revision_maps(json.loads(text))
    except json.JSONDecodeError:
        return normalize_revision_maps([json.loads(line) for line in text.splitlines() if line.strip()])


def tool_evidence(messages):
    values = []
    for message in messages:
        content = message.get("content", "")
        if not content.startswith(("Tool search result: ", "Tool read result: ")):
            continue
        data = json.loads(content.split(" result: ", 1)[1])
        values.extend(data.get("matches", []) if isinstance(data, dict) else data)
    return values


def model_action(kind, tool_name="", **arguments):
    return {"kind": kind, "toolName": tool_name, "query": "",
            "sourceID": "", "start": 0, "limit": 0, **arguments}


class ScriptedProvider(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), ProviderHandler)
        self.reset()

    def reset(self, mode="answer", sources=(A, B)):
        self.mode = mode
        self.sources = sources
        self.requests = []
        self.arrived = threading.Event()
        self.release = threading.Event()

    @property
    def endpoint(self):
        return f"http://127.0.0.1:{self.server_port}/v1"

    def decision(self, messages):
        decisions = sum(not request.get("stream") for request in self.requests)
        if self.mode == "invalid" or (self.mode == "repair_arguments" and decisions == 1):
            return model_action("tool", "list_sources", start="invalid")
        if self.mode == "repair_kind" and decisions == 1:
            return model_action("unexpected")
        results = [m["content"] for m in messages if m.get("content", "").startswith("Tool ")]
        steps = [("list_sources", {}), ("search", {"query": "launch", "limit": 12})]
        steps += [("read", {"sourceID": source, "start": 0, "limit": 12}) for source in self.sources]
        if len(results) < len(steps):
            name, arguments = steps[len(results)]
            return model_action("tool", name, **arguments)
        return model_action("final")

    def answer(self, messages):
        if self.mode == "uncited":
            return "There is insufficient evidence to verify this answer."
        evidence = tool_evidence(messages)
        citations = {}
        for item in evidence:
            passage = item["passage"]
            source = passage["reference"]["sourceID"].upper()
            if source == A or ("October 24" in passage["text"] and "Bea" in passage["text"]):
                citations[source] = item["citation"]
        require(A in citations, "scripted model did not receive first source evidence")
        answer = f"The initial launch date was October 10 and Ada owned the release {citations[A]}."
        if B in self.sources:
            require(B in citations, "scripted model did not receive the late reversal")
            answer += f" The latest launch date is October 24 and Bea owns the release {citations[B]}."
        return answer


class ProviderHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Never log headers or credentials.

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            require(0 < length <= 1_000_000, "invalid request size")
            require(self.path == "/v1/chat/completions", "unexpected provider route")
            body = json.loads(self.rfile.read(length))
            self.server.requests.append({"stream": body.get("stream", False), "messages": body["messages"]})
            self.server.arrived.set()
            if self.server.mode == "stall":
                self.server.release.wait(60)
                return
            if self.server.mode == "failure":
                self.send_json({"error": {"message": "Synthetic provider failure", "type": "test"}}, 400)
                return
            if body.get("stream"):
                answer = self.server.answer(body["messages"])
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                for chunk in (answer[:len(answer)//2], answer[len(answer)//2:]):
                    data = {"model": "scripted", "choices": [{"index": 0, "delta": {"content": chunk}}]}
                    self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
                    self.wfile.flush()
                terminal = {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
                self.wfile.write(("data: " + json.dumps(terminal) + "\n\ndata: [DONE]\n\n").encode())
                self.wfile.flush()
            else:
                content = json.dumps(self.server.decision(body["messages"]))
                self.send_json({"model": "scripted", "choices": [{"message": {"role": "assistant", "content": content}, "finish_reason": "stop"}]})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception as error:
            self.server.requests.append({"fixture_error": str(error)})
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.send_json({"error": {"message": "Synthetic fixture rejected request"}}, 400)

    def send_json(self, body, status=200):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class Qualification:
    def __init__(self, args):
        self.args = args
        self.output = args.output_dir.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        require(not any(self.output.iterdir()), "output directory must be new or empty")
        self.db = self.output / "synthetic.sqlite"
        # Avoid accidentally inheriting provider credentials, proxy routing or model configuration.
        self.env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG") if key in os.environ}
        self.env.update(ASK_QUALIFICATION_FIXTURE_KEY="synthetic-not-secret", MACPARAKEET_TELEMETRY="0", MACPARAKEET_DEBUG_APP_STATE_DIR=str(self.output / "app-state"))
        self.secrets = []
        if args.api_key_env:
            secret = os.environ.get(args.api_key_env)
            require(bool(secret), "named API key environment variable is empty")
            self.env[args.api_key_env] = secret
            self.secrets.append(secret)
        digest = hashlib.sha256()
        with args.cli.open("rb") as binary:
            for chunk in iter(lambda: binary.read(1024 * 1024), b""):
                digest.update(chunk)
        binary_hash = digest.hexdigest()
        self.report = {"status": "running", "cli": str(args.cli.resolve()), "cli_sha256": binary_hash, "checks": [],
                       "evidence_boundary": "Synthetic CLI integration; no native UI, physical audio or production data. Scripted provider does not establish real-model quality."}
        self.sequence = 0

    def save(self, name, value):
        text = value if isinstance(value, str) else json.dumps(value, indent=2)
        for secret in self.secrets:
            text = text.replace(secret, "[REDACTED]")
        (self.output / name).write_text(text + "\n")

    def command(self, *args, enable=True):
        opt_in = ["--enable-ask-workspace"] if enable else []
        return [str(self.args.cli.resolve()), "ask", *map(str, args), *opt_in, "--database", str(self.db)]

    def invoke(self, label, *args, success=True, enable=True):
        self.sequence += 1
        prefix = f"{self.sequence:02d}-{label}"
        with subprocess.Popen(self.command(*args, enable=enable), env=self.env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=self.args.timeout)
            except subprocess.TimeoutExpired:
                self.stop(process)
                stdout, stderr = process.communicate(timeout=5)
                self.save(prefix + ".stdout", stdout)
                self.save(prefix + ".stderr", stderr)
                raise AssertionError(f"{label}: CLI exceeded {self.args.timeout}s") from None
            except BaseException:
                self.stop(process)
                raise
        self.save(prefix + ".stdout", stdout)
        self.save(prefix + ".stderr", stderr)
        require((process.returncode == 0) == success, f"{label}: unexpected exit {process.returncode}; see {prefix}.stdout/.stderr")
        return decode_output(stdout)

    @staticmethod
    def stop(process):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        # The helper belongs to the same test-owned process group, even if its parent exited first.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)

    def check(self, name, operation):
        start = time.monotonic()
        try:
            operation()
        except Exception as error:
            self.report["checks"].append({"name": name, "status": "failed", "error": str(error), "seconds": round(time.monotonic()-start, 2)})
            raise
        else:
            self.report["checks"].append({"name": name, "status": "passed", "seconds": round(time.monotonic()-start, 2)})

    def disabled(self, fixture):
        for enable in (False, True):
            for arguments in (("list",), ("send", A, "--revision", "0", "--question", QUESTION,
                                          *self.provider_flags(fixture))):
                label = f"disabled-{arguments[0]}-opt-in-{enable}"
                result = self.invoke(label, *arguments, success=False, enable=enable)
                require(isinstance(result, dict) and result.get("errorType") == "validation"
                        and "Ask workspace is disabled" in result.get("error", ""),
                        f"{label}: expected explicit feature-gate rejection")
                require(not list(self.output.glob("synthetic.sqlite*")), f"{label}: disabled command created database files")
                require(not fixture.requests, f"{label}: disabled command contacted provider")

    def seed(self):
        self.invoke("initialize", "list")
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            for index, (source, text) in enumerate(TRANSCRIPTS.items(), 1):
                date = f"2026-09-0{index} 12:00:00.000"
                db.execute("INSERT INTO transcriptions (id, createdAt, updatedAt, fileName, rawTranscript, cleanTranscript, status, sourceType) VALUES (?, ?, ?, ?, ?, ?, 'completed', 'meeting')",
                           (uuid.UUID(source).bytes, date, date, f"Synthetic launch meeting {index}", text, text))
        sources = self.invoke("sources", "sources")
        require({source["id"].upper() for source in sources} == {A, B}, "synthetic sources were not available")

    def provider_flags(self, fixture=None):
        if fixture:
            return ["--provider", "lmstudio", "--model", "scripted", "--base-url", fixture.endpoint, "--api-key-env", "ASK_QUALIFICATION_FIXTURE_KEY"]
        flags = ["--provider", self.args.provider, "--model", self.args.model, "--base-url", self.args.endpoint]
        if self.args.allow_remote:
            flags += ["--allow-remote"]
        if self.args.api_key_env:
            flags += ["--api-key-env", self.args.api_key_env]
        return flags

    def send(self, label, conversation, flags, question=QUESTION, success=True):
        events = self.invoke(label, "send", conversation["id"], "--revision", conversation["revision"],
                             "--question", question, "--stream", *flags, success=success)
        if isinstance(events, dict) and events.get("type") == "conversation":
            events = [events]
        require(isinstance(events, list), "send did not emit NDJSON events")
        require(events[-1].get("type") == "conversation", "stream lacked terminal conversation")
        final = events[-1]["conversation"]
        if success:
            require(any(event.get("type") == "activity" for event in events), "no tool activity streamed")
            require(any(event.get("type") == "text" for event in events), "no answer text streamed")
            require(final["messages"][-1]["status"] == "complete", "answer was not complete")
        persisted = self.invoke(label + "-reload", "show", final["id"])
        require(persisted == final, "answer changed when reloaded in a fresh CLI process")
        return final

    def evidence(self, reference):
        return self.invoke("evidence", "evidence", reference["sourceID"], "--source-revision", reference["sourceRevision"], "--segment", reference["segmentIndex"])

    def workflows(self, fixture=None):
        label = "scripted" if fixture else "real-model"
        flags = self.provider_flags(fixture)
        conversation = self.invoke(label + "-new", "new", "--source", A, B)
        conversation = self.invoke(label + "-draft", "draft", conversation["id"], "Unsent synthetic question", "--revision", conversation["revision"])
        require(self.invoke(label + "-draft-reload", "show", conversation["id"])["draft"] == "Unsent synthetic question", "draft did not persist")
        if fixture:
            fixture.reset()
        conversation = self.send(label + "-answer", conversation, flags)
        answer = conversation["messages"][-1]
        require("October 24" in answer["content"] and "Bea" in answer["content"], "answer missed late launch reversal or current owner")
        require({c["sourceID"].upper() for c in answer["citations"]} == {A, B}, "comparison did not cite both sources")
        for citation in answer["citations"]:
            require(self.evidence(citation)["status"] == "available", "citation was not resolvable")
        if fixture:
            read_messages = [message["content"] for request in fixture.requests
                             for message in request.get("messages", [])
                             if message.get("content", "").startswith("Tool read result: ")]
            require(read_messages and all("October 24" not in message for message in read_messages),
                    "late reversal unexpectedly fits in the first read page")
            self.save(label + "-provider-requests.json", fixture.requests)
            fixture.reset()
        conversation = self.send(label + "-followup", conversation, flags, "Who owns the latest release, and what is its date? Cite evidence.")
        require("October 24" in conversation["messages"][-1]["content"] and "Bea" in conversation["messages"][-1]["content"], "follow-up lost the latest decision")
        previous = conversation["messages"]
        conversation = self.invoke(label + "-scope", "select", conversation["id"], "--revision", conversation["revision"], "--source", A)
        require(conversation["messages"] == previous and len(conversation["sections"]) == 2, "source change lost history or failed to start a fresh section")
        if fixture:
            fixture.reset(sources=(A,))
        conversation = self.send(label + "-scoped-answer", conversation, flags, SCOPED_QUESTION)
        answer = conversation["messages"][-1]
        require("October 10" in answer["content"] and "Ada" in answer["content"], "scoped answer missed available facts")
        require("October 24" not in answer["content"] and "Bea" not in answer["content"], "removed-source facts leaked into scoped answer")
        require(answer["citations"] and all(c["sourceID"].upper() == A for c in answer["citations"]), "scoped answer cited an excluded source")
        if fixture:
            transmitted = json.dumps(fixture.requests)
            require(B not in transmitted.upper() and "October 24" not in transmitted and "Bea" not in transmitted, "removed-source content was sent to the provider")
            self.save(label + "-scoped-provider-requests.json", fixture.requests)
        citation = answer["citations"][0]
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE transcriptions SET cleanTranscript = ?, isTranscriptEdited = 1 WHERE id = ?", ("Synthetic correction: launch date is undecided.", uuid.UUID(A).bytes))
        require(self.evidence(citation)["status"] == "stale", "edited source citation did not become stale")
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE transcriptions SET cleanTranscript = ?, isTranscriptEdited = 0 WHERE id = ?", (TRANSCRIPTS[A], uuid.UUID(A).bytes))

    def consent(self, fixture):
        fixture.reset()
        conversation = self.invoke("consent-new", "new", "--source", A)
        self.invoke("consent-rejected", "send", conversation["id"], "--revision", conversation["revision"],
                    "--question", QUESTION, "--provider", "openaiCompatible", "--model", "scripted", "--base-url", fixture.endpoint, success=False)
        require(self.invoke("consent-reload", "show", conversation["id"]) == conversation, "consent rejection modified the conversation")
        require(not fixture.requests, "provider contacted before consent")

    def failure(self, fixture, mode):
        fixture.reset(mode=mode)
        conversation = self.invoke(mode + "-new", "new", "--source", A, B)
        conversation = self.send(mode, conversation, self.provider_flags(fixture), success=False)
        answer = conversation["messages"][-1]
        require(answer["status"] == ("incomplete" if mode == "uncited" else "failed"), "unexpected unsuccessful answer status")
        require(bool(answer.get("failureReason")) and not answer["citations"], "unsuccessful answer lacks a reason or kept citations")

    def repair(self, fixture):
        for mode in ("repair_arguments", "repair_kind"):
            fixture.reset(mode=mode)
            conversation = self.invoke(mode + "-new", "new", "--source", A, B)
            self.send(mode, conversation, self.provider_flags(fixture))
            decisions = [request for request in fixture.requests if not request.get("stream")]
            require(len(decisions) == 6, "malformed action did not receive exactly one repair attempt")
            self.save(mode + "-provider-requests.json", fixture.requests)
        self.failure(fixture, "invalid")
        require(len(fixture.requests) == 2, "repeated invalid action did not stop after two attempts")
        self.save("invalid-provider-requests.json", fixture.requests)

    def interruption(self, fixture):
        fixture.reset(mode="stall")
        conversation = self.invoke("interruption-new", "new", "--source", A)
        args = self.command("send", conversation["id"], "--revision", conversation["revision"], "--question", QUESTION, "--stream", *self.provider_flags(fixture))
        with (self.output / "interruption.stdout").open("w") as stdout, (self.output / "interruption.stderr").open("w") as stderr:
            process = subprocess.Popen(args, env=self.env, stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                require(fixture.arrived.wait(min(self.args.timeout, 30)), "interrupted run never contacted provider")
                running = self.invoke("running-show", "show", conversation["id"])
                require(running["messages"][-1]["status"] == "incomplete", "running placeholder missing")
                self.invoke("lease-rejection", "draft", running["id"], "Competing draft", "--revision", running["revision"], success=False)
                require(self.invoke("lease-rejection-reload", "show", running["id"]) == running, "rejected concurrent writer changed the conversation")
            finally:
                self.stop(process)
                fixture.release.set()
        interrupted = self.invoke("interrupted-show", "show", conversation["id"])
        require(interrupted["messages"][-1]["status"] == "incomplete", "process interruption falsely saved completion")
        # Let the real lease expire; never edit lease columns to manufacture recovery.
        deadline = time.monotonic() + 50
        while True:
            with contextlib.closing(sqlite3.connect(self.db)) as db, db:
                active = db.execute("SELECT runToken IS NOT NULL AND julianday(runLeaseUntil) > julianday('now') FROM ask_conversations WHERE id = ?", (uuid.UUID(conversation["id"]).bytes,)).fetchone()[0]
            if not active:
                break
            require(time.monotonic() < deadline, "interrupted run lease did not expire")
            time.sleep(1)
        fixture.reset(sources=(A,))
        recovered = self.send("recovered-answer", interrupted, self.provider_flags(fixture), SCOPED_QUESTION)
        require(recovered["messages"][-3]["status"] == "incomplete", "recovery erased the interrupted answer")

    def run(self):
        fixture = ScriptedProvider()
        thread = threading.Thread(target=fixture.serve_forever, daemon=True)
        thread.start()
        try:
            if self.args.expect_disabled:
                self.report["mode"] = "release-gate"
                self.check("Ask rejects default and developer opt-in before database or provider access",
                           lambda: self.disabled(fixture))
                self.report["real_model"] = {"status": "not_run"}
            else:
                self.check("isolated synthetic database", self.seed)
                if not self.args.real_only:
                    self.check("scripted tools, streaming, persistence, follow-up, scope and stale citations", lambda: self.workflows(fixture))
                    self.check("provider consent rejects before mutation or network", lambda: self.consent(fixture))
                    self.check("provider failure persists failed answer", lambda: self.failure(fixture, "failure"))
                    self.check("uncited answer remains incomplete", lambda: self.failure(fixture, "uncited"))
                    self.check("malformed action repair is bounded", lambda: self.repair(fixture))
                    self.check("concurrent lease exclusion and process-interruption recovery", lambda: self.interruption(fixture))
                if self.args.endpoint:
                    self.report["real_model"] = {"provider": self.args.provider, "model": self.args.model, "endpoint_host": urllib.parse.urlsplit(self.args.endpoint).hostname,
                                                 "qualification": "Small synthetic regression only; does not establish broad reasoning quality or native responsiveness."}
                    self.check("real-model evidence workflows", self.workflows)
                else:
                    self.report["real_model"] = {"status": "not_run"}
            self.report["status"] = "passed"
        except (Exception, KeyboardInterrupt) as error:
            self.report["status"] = "failed"
            self.report["error"] = str(error) or "Interrupted by caller"
        finally:
            fixture.release.set()
            fixture.shutdown()
            fixture.server_close()
            thread.join(timeout=2)
            self.save("last-scripted-provider-requests.json", fixture.requests)
            self.save("report.json", self.report)
        print(json.dumps({"status": self.report["status"], "report": str(self.output / "report.json")}))
        return 0 if self.report["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", required=True, type=Path, help="Prebuilt CLI with packaged Ask helper and Node runtime")
    parser.add_argument("--output-dir", required=True, type=Path, help="New or empty directory; retains synthetic DB and logs")
    parser.add_argument("--timeout", type=int, default=210, help="Maximum seconds per CLI invocation (default: 210)")
    parser.add_argument("--endpoint", help="Explicit OpenAI-compatible real-model endpoint including /v1")
    parser.add_argument("--model")
    parser.add_argument("--expect-disabled", action="store_true", help="Verify Release CLI rejects Ask with and without developer opt-in; no database is created")
    parser.add_argument("--real-only", action="store_true", help="Run only real-model evidence workflows, after separate scripted qualification")
    parser.add_argument("--provider", choices=("lmstudio", "openaiCompatible"), default="lmstudio")
    parser.add_argument("--allow-remote", action="store_true", help="Explicitly allow sending synthetic context to configured remote provider")
    parser.add_argument("--api-key-env", help="Environment variable containing real-provider credential; never a literal key")
    args = parser.parse_args()
    if not args.cli.is_file() or not os.access(args.cli, os.X_OK):
        parser.error("--cli must be an existing executable")
    if not 10 <= args.timeout <= 600:
        parser.error("--timeout must be 10...600 seconds")
    if bool(args.endpoint) != bool(args.model):
        parser.error("--endpoint and --model must be specified together")
    if args.expect_disabled and (args.endpoint or args.real_only or args.api_key_env or args.allow_remote):
        parser.error("--expect-disabled cannot be combined with real-model options")
    if args.real_only and not args.endpoint:
        parser.error("--real-only requires --endpoint and --model")
    if args.api_key_env and not args.endpoint:
        parser.error("--api-key-env requires --endpoint")
    if args.endpoint:
        url = urllib.parse.urlsplit(args.endpoint)
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
            parser.error("--endpoint must be an http(s) URL without credentials, query or fragment")
        local = url.hostname in ("127.0.0.1", "localhost", "::1")
        if (not local or args.provider == "openaiCompatible") and not args.allow_remote:
            parser.error("this provider requires explicit --allow-remote")
        if not local and url.scheme != "https":
            parser.error("remote endpoint requires https")
    try:
        return Qualification(args).run()
    except (AssertionError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
