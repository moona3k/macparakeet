#!/usr/bin/env python3
"""Reproduce history projection mismatch using only a new synthetic database.

No database argument is accepted: every invocation creates its own temporary
state root and SQLite file. This runs only local history/correction/read/export
commands. It does not invoke health, preferences, credentials, capture, models,
providers, or networking. The installed CLI may read ordinary preferences;
MACPARAKEET_DEBUG_APP_STATE_DIR does not isolate UserDefaults/Keychain.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import uuid

MEETING = "11111111-1111-4111-8111-111111111111"
SEGMENT_A = "22222222-2222-4222-8222-222222222222"
SEGMENT_B = "33333333-3333-4333-8333-333333333333"
ORIGINAL = "originaltoken two. three four."
CORRECTED_LINE = "correctedtoken first."
CORRECTED = CORRECTED_LINE + " three four."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=shutil.which("macparakeet-cli"))
    parser.add_argument("--report", type=Path, default=Path(__file__).with_suffix(".json"))
    args = parser.parse_args()
    if not args.cli:
        raise SystemExit("Installed macparakeet-cli not found; no commands run.")
    binary = Path(args.cli).resolve(strict=True)
    report = {
        "schema": "macparakeet-history-projection-repro/v1",
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_review_baseline": "79cf1ca928b53c3853a99f6832c197d664dcdd78",
        "executable_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "evidence_lane": "Installed CLI executable; no build from reviewed source",
        "safety": {
            "fresh_temporary_state_root": True,
            "explicit_temporary_database_on_every_data_command": True,
            "telemetry_disabled": True,
            "fixtures_only": True,
            "preferences_or_keychain_commands": False,
            "capture_model_provider_or_network_commands": False,
            "temporary_state_removed_after_run": True,
            "limits": "Environment override isolates app paths, not UserDefaults or Keychain. These commands do not mutate preferences/keys; no preference values are captured.",
        },
        "commands": [],
        "fixture_basis": "Tests/CLITests/MeetingsCommandTests.swift timed edit and speaker rename fixtures; installed CLI initializes its own schema",
    }
    with tempfile.TemporaryDirectory(prefix="macparakeet-history-projection-") as directory:
        state = Path(directory).resolve()
        database = state / "fixture.sqlite"
        environment = os.environ.copy()
        environment.update(MACPARAKEET_DEBUG_APP_STATE_DIR=str(state), MACPARAKEET_TELEMETRY="0")

        def invoke(arguments, data=True):
            argv = [str(binary), *arguments]
            if data:
                argv += ["--database", str(database)]
            result = subprocess.run(argv, cwd=state, env=environment, capture_output=True, text=True, timeout=30)
            # Only synthetic JSON/help/version output is recorded. stderr is not
            # retained, avoiding incidental process diagnostics in the artifact.
            output = result.stdout.replace(str(state), "<temporary-state>")
            receipt = {
                "argv": ["macparakeet-cli", *arguments, *(["--database", "<temporary-state>/fixture.sqlite"] if data else [])],
                "exit_code": result.returncode,
                "stderr_present": bool(result.stderr),
            }
            report["commands"].append(receipt)
            if result.returncode:
                raise RuntimeError(f"Command failed with exit {result.returncode}: {arguments[0:3]}; synthetic JSON response: {output}")
            try:
                parsed = json.loads(output)
            except json.JSONDecodeError:
                parsed = output.strip()
            def redact(value):
                if isinstance(value, str):
                    return value.replace(str(state), "<temporary-state>").replace(directory, "<temporary-state>")
                if isinstance(value, list):
                    return [redact(item) for item in value]
                if isinstance(value, dict):
                    return {key: redact(item) for key, item in value.items()}
                return value
            parsed = redact(parsed)
            receipt["stdout"] = parsed
            return parsed

        report["installed_cli_version"] = invoke(["--version"], data=False)
        for command in (["history", "transcriptions"], ["meetings", "corrections", "edit-line"],
                        ["meetings", "corrections", "rename"], ["export"]):
            help_text = invoke([*command, "--help"], data=False)
            if "--database" not in help_text:
                raise RuntimeError(f"Command does not support an explicit database: {command}")
        initial = invoke(["history", "transcriptions", "--json"])
        if initial != []:
            raise RuntimeError("Fresh fixture database unexpectedly contains rows; stopping.")

        words = [
            {"word": "originaltoken", "startMs": 0, "endMs": 100, "confidence": 1, "speakerId": "S1"},
            {"word": "two.", "startMs": 120, "endMs": 220, "confidence": 1, "speakerId": "S1"},
            {"word": "three", "startMs": 2000, "endMs": 2100, "confidence": 1, "speakerId": "S1"},
            {"word": "four.", "startMs": 2120, "endMs": 2220, "confidence": 1, "speakerId": "S1"},
        ]
        segments = [
            {"id": SEGMENT_A, "startMs": 0, "endMs": 220, "speakerId": "S1", "speakerLabel": "Alice",
             "text": "originaltoken two.", "wordRange": {"startIndex": 0, "endIndexExclusive": 2}},
            {"id": SEGMENT_B, "startMs": 2000, "endMs": 2220, "speakerId": "S1", "speakerLabel": "Alice",
             "text": "three four.", "wordRange": {"startIndex": 2, "endIndexExclusive": 4}},
        ]
        fixture = {
            "id": uuid.UUID(MEETING).bytes, "createdAt": "2026-10-31 00:00:00.000", "updatedAt": "2026-10-31 00:00:00.000",
            "fileName": "Projection fixture", "durationMs": 2220,
            "meetingArtifactFolderPath": str(state / "fixture-meeting"),
            "rawTranscript": ORIGINAL, "cleanTranscript": ORIGINAL,
            "wordTimestamps": json.dumps(words), "speakers": json.dumps([{"id": "S1", "label": "Alice"}]),
            "speakerCount": 1, "transcriptSegments": json.dumps(segments),
            "sourceType": "meeting", "status": "completed", "isFavorite": 1,
        }
        with sqlite3.connect(database) as connection:
            if connection.execute("SELECT COUNT(*) FROM transcriptions").fetchone()[0] != 0:
                raise RuntimeError("Fixture database was not empty.")
            columns = {row[1] for row in connection.execute("PRAGMA table_info(transcriptions)")}
            if not fixture.keys() <= columns:
                raise RuntimeError("Installed schema does not support the synthetic fixture.")
            connection.execute(
                "INSERT INTO transcriptions (" + ",".join(fixture) + ") VALUES (" + ",".join("?" for _ in fixture) + ")",
                list(fixture.values()),
            )
        before = invoke(["meetings", "transcript", MEETING, "--format", "json"])
        revision = before["speakerCorrectionRevision"]
        if revision != 0:
            raise RuntimeError("Fresh fixture has unexpected correction state.")
        edited = invoke(["meetings", "corrections", "edit-line", MEETING, "--segment", SEGMENT_A,
                         "--text", CORRECTED_LINE, "--expected-revision", str(revision), "--json"])
        renamed = invoke(["meetings", "corrections", "rename", MEETING, "--speaker", "S1", "--label", "Alicia",
                          "--expected-revision", str(edited["speakerCorrectionRevision"]), "--json"])
        if renamed["speakerCorrectionRevision"] != 2:
            raise RuntimeError("Corrections did not commit the expected revisions.")
        history = invoke(["history", "transcriptions", "--json"])
        favorites = invoke(["history", "favorites", "--json"])
        search = invoke(["history", "search-transcriptions", "correctedtoken", "--json"])
        title_search = invoke(["history", "search-transcriptions", "Projection fixture", "--json"])
        show = invoke(["meetings", "show", MEETING, "--json"])
        export = invoke(["export", MEETING, "--format", "json", "--stdout"])
        export_text = invoke(["export", MEETING, "--format", "txt", "--stdout"])
        with sqlite3.connect(database) as connection:
            journal = connection.execute("SELECT operation,sequence FROM speaker_corrections ORDER BY sequence").fetchall()
            state_revision = connection.execute("SELECT revision FROM speaker_correction_states WHERE transcriptionId=?", (uuid.UUID(MEETING).bytes,)).fetchone()[0]
        report["correction_journal"] = [{"operation": operation, "sequence": sequence} for operation, sequence in journal]
        report["persisted_correction_revision"] = state_revision
        projections = {"meetings_show": show, "export_json": export}
        comparisons = {}
        for name, rows in {"history_transcriptions": history, "history_favorites": favorites,
                           "history_search_corrected_token": search, "history_search_title": title_search}.items():
            if len(rows) != 1 or rows[0]["id"] != MEETING:
                raise RuntimeError(f"Expected one synthetic row from {name}.")
            row = rows[0]
            comparisons[name] = {
                "cleanTranscript": row.get("cleanTranscript"),
                "speaker_label": row.get("speakers", [{}])[0].get("label"),
                "first_segment_text": row.get("transcriptSegments", [{}])[0].get("text"),
                "returns_original_text": row.get("cleanTranscript") == ORIGINAL,
                "returns_original_speaker_label": row.get("speakers", [{}])[0].get("label") == "Alice",
            }
        for name, row in projections.items():
            comparisons[name] = {
                "cleanTranscript": row.get("cleanTranscript"),
                "speaker_label": row.get("speakers", [{}])[0].get("label"),
                "first_segment_text": row.get("transcriptSegments", [{}])[0].get("text"),
                "speakerCorrectionRevision": row.get("speakerCorrectionRevision"),
                "returns_corrected_text": row.get("cleanTranscript") == CORRECTED,
                "returns_corrected_speaker_label": row.get("speakers", [{}])[0].get("label") == "Alicia",
            }
        report["comparisons"] = comparisons
        report["text_export_contains_correction"] = CORRECTED_LINE in export_text
        report["reproduced"] = (
            all(comparisons[name]["returns_original_text"] and comparisons[name]["returns_original_speaker_label"]
                for name in comparisons if name.startswith("history_"))
            and all(comparisons[name]["returns_corrected_text"] and comparisons[name]["returns_corrected_speaker_label"]
                    for name in projections)
            and report["text_export_contains_correction"]
        )
        report["conclusion"] = (
            "Installed CLI returns automatic text/speaker labels from history transcriptions, favorites and search, including a search matched by corrected text. meetings show and export return the committed effective corrections."
            if report["reproduced"] else
            "Expected mismatch was not fully reproduced; inspect synthetic command receipts and comparisons."
        )
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"installed_cli_version": report["installed_cli_version"], "reproduced": report["reproduced"],
                      "comparisons": report["comparisons"], "report": str(args.report)}, indent=2))


if __name__ == "__main__":
    main()
