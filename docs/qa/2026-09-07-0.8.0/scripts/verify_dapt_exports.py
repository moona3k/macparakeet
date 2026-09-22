#!/usr/bin/env python3
"""Export owned synthetic records with an existing CLI; validate locally.

Run with the BBC validator virtualenv's Python (xmlschema dependency required).
No application builds/tests, audio, GUI or transcript uploads occur here.
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
import xmlschema


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--validator", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", required=True)
    args = parser.parse_args()
    args.cli = args.cli.resolve(strict=True)
    args.validator = args.validator.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise SystemExit("Refusing to reuse nonempty evidence directory")
    state = args.output / "state"
    database = state / "macparakeet.db"
    fixed_home = args.output / "foundation-home"
    fixed_home.mkdir()
    env = dict(os.environ)
    env.update({"MACPARAKEET_DEBUG_APP_STATE_DIR": str(state), "CFFIXED_USER_HOME": str(fixed_home),
                "MACPARAKEET_TELEMETRY": "0", "DO_NOT_TRACK": "1", "MACPARAKEET_DEBUG_SQL": "0"})
    commands = []

    def write_json(name, value):
        (args.output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def check(condition, message):
        if not condition:
            raise AssertionError(message)

    def run(name, command, cwd=args.output):
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, timeout=35)
        (args.output / (name + ".stdout")).write_bytes(result.stdout)
        (args.output / (name + ".stderr")).write_bytes(result.stderr)
        commands.append({"name": name, "command": command, "exitCode": result.returncode})
        write_json("commands.json", commands)
        check(result.returncode == 0, f"{name} exit {result.returncode}: {result.stderr.decode(errors='replace')}")
        return result.stdout.decode()

    def cli(name, command):
        return run(name, [str(args.cli)] + command + ["--database", str(database)])

    def word(text, start, end, speaker=None):
        value = {"word": text, "startMs": start, "endMs": end, "confidence": 0.97}
        if speaker:
            value["speakerId"] = speaker
        return value

    fixtures = [
        {"name": "timed-speaker", "text": "Olá & bem-vindos. Resposta <final>.", "language": "pt-BR",
         "words": [word("Olá", 0, 400, "S1"), word("&", 400, 500, "S1"), word("bem-vindos.", 500, 1000, "S1"), word("Resposta", 1500, 2000, "S2"), word("<final>.", 2000, 2400, "S2")],
         "speakers": [{"id": "S1", "label": "Ana & Co."}, {"id": "S2", "label": "Bob <Lead>"}], "duration": 2400, "edited": False},
        {"name": "timed-no-speaker", "text": "Hello world.", "language": "en",
         "words": [word("Hello", 250, 600), word("world.", 600, 1100)], "speakers": None, "duration": 1100, "edited": False},
        {"name": "untimed-edited", "text": "Edited text & <review>.", "language": None,
         "words": [word("Stale", 100, 800, "S1")], "speakers": [{"id": "S1", "label": "Legacy roster"}], "duration": 60000, "edited": True},
    ]
    cli("initialize", ["prompts", "list", "--json"])
    now = "2026-09-07T12:00:00.000Z"
    with sqlite3.connect(database) as db:
        for fixture in fixtures:
            identifier = uuid.uuid4()
            fixture["id"] = str(identifier).upper()
            db.execute(
                "INSERT INTO transcriptions (id, createdAt, updatedAt, fileName, rawTranscript, cleanTranscript, wordTimestamps, speakers, language, durationMs, status, sourceType, isFavorite, recoveredFromCrash, isTranscriptEdited) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'completed', 'file', 0, 0, ?)",
                (identifier.bytes, now, now, fixture["name"] + ".wav", "Stale" if fixture["edited"] else fixture["text"], fixture["text"], json.dumps(fixture["words"]), json.dumps(fixture["speakers"]) if fixture["speakers"] else None, fixture["language"], fixture["duration"], fixture["edited"]),
            )
    write_json("fixtures.json", fixtures)
    version = run("validator-python-version", [sys.executable, "--version"])
    frozen = run("validator-dependencies", [sys.executable, "-m", "pip", "freeze"])
    validator_sha = run("validator-git-sha", ["git", "rev-parse", "HEAD"], args.validator).strip()
    binary_sha = hashlib.file_digest(args.cli.open("rb"), "sha256").hexdigest()
    schema_path = args.validator / "src/schemas/xsd/dapt/dapt.xsd"
    schema = xmlschema.XMLSchema(str(schema_path), allow="local")
    metadata = {
        "candidateSource": args.candidate, "binarySHA256": binary_sha,
        "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "validatorSHA": validator_sha, "python": version.strip(), "dependencies": frozen.splitlines(),
        "schemaPath": str(schema_path), "schemaSHA256": hashlib.sha256(schema_path.read_bytes()).hexdigest(),
        "fixtureSetup": "Synthetic rows inserted directly into a CLI-created owned SQLite schema",
    }
    write_json("metadata.json", metadata)
    ns = {"tt": "http://www.w3.org/ns/ttml", "ttm": "http://www.w3.org/ns/ttml#metadata"}
    rows = []
    for fixture in fixtures:
        name = fixture["name"]
        for form, extension in (("dapt", "dapt.xml"), ("markdown", "md"), ("srt", "srt"), ("json", "json")):
            destination = args.output / (name + "." + extension)
            cli(name + "-" + form, ["export", fixture["id"], "--format", form, "--output", str(destination)])
            check(destination.exists(), "Missing " + str(destination))
        xml_file = args.output / (name + ".dapt.xml")
        stdout = cli(name + "-dapt-stdout", ["export", fixture["id"], "--format", "dapt", "--stdout"])
        check(stdout.strip() == xml_file.read_text().strip(), "DAPT stdout/file differ")
        errors = [str(error) for error in schema.iter_errors(str(xml_file))]
        write_json(name + "-xsd.json", {"valid": not errors, "errors": errors})
        check(not errors, f"DAPT XSD rejected {name}: {errors}")
        root = ET.parse(xml_file).getroot()
        events = root.findall("tt:body/tt:div", ns)
        agents = root.findall("tt:head/tt:metadata/ttm:agent", ns)
        content = " ".join("".join(event.itertext()).strip() for event in events)
        check(content == fixture["text"], "XML text changed")
        if fixture["edited"]:
            check(len(events) == 1 and "begin" not in events[0].attrib and "end" not in events[0].attrib, "Edited DAPT invented timing")
            check(not agents, "Edited DAPT invented speaker attribution")
            check(root.attrib["{http://www.w3.org/XML/1998/namespace}lang"] == "und", "Unknown language not und")
        else:
            check(all("begin" in event.attrib and "end" in event.attrib for event in events), "Aligned timing lost")
            check(len(agents) == (2 if name == "timed-speaker" else 0), "Agent count incorrect")
        markdown = (args.output / (name + ".md")).read_text()
        srt = (args.output / (name + ".srt")).read_text()
        exported = json.loads((args.output / (name + ".json")).read_text())
        check(exported["cleanTranscript"] == fixture["text"], "JSON transcript changed")
        check(exported["wordTimestamps"] == fixture["words"], "JSON word metadata changed")
        check(exported["isTranscriptEdited"] == fixture["edited"], "JSON edit state changed")
        for sentence in fixture["text"].split(". "):
            check(sentence in markdown and sentence in srt, "Markdown/SRT text missing")
        if name == "timed-no-speaker":
            check("00:00:00,250 --> 00:00:01,100" in srt, "SRT timing changed")
        if name == "untimed-edited":
            check("Stale" not in markdown and "Stale" not in srt, "Edited export used stale words")
        validator = args.validator / ".venv/bin/validate-ttml"
        validation_file = args.output / (name + "-bbc.json")
        run(name + "-bbc", [str(validator), "-flavour", "dapt", "-ttml_in", str(xml_file), "-results_out", str(validation_file), "-json"])
        validation = json.loads(validation_file.read_text())
        counts = collections.Counter(str(row["status"]) for row in validation)
        rows.append({"fixture": name, "xsd": "pass", "bbc": "pass", "bbcStatusCounts": dict(counts), "exportPreservation": "pass"})
        write_json("result.json", {"status": "in-progress", "fixtures": rows})
    check(hashlib.file_digest(args.cli.open("rb"), "sha256").hexdigest() == binary_sha, "CLI changed during run")
    result = {"status": "pass", "fixtures": rows, "commands": len(commands), "cliInvocations": 16}
    write_json("result.json", result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
