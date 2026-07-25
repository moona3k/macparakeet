#!/usr/bin/env python3
"""Measure one English, German, Japanese, and Chinese Cohere fixture.

Each language is run in a fresh process with one copied input, then with a
configurable repeated batch. The single-input wall time is process-cold
first-transcript latency. The wall-time slope between the single input and the
repeated batch estimates warm per-file transcription time while amortizing
process and model-load variance. Peak RSS comes from the repeated process.

No language hint is passed. A result is valid only for the owned runtime and
adapter combination that provides the automatic multilingual behavior required
by ADR-029.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import wave
from pathlib import Path

_LANGUAGES = ("en", "de", "ja", "zh")
_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size", re.MULTILINE)
_AFINFO_DURATION_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?) sec,", re.MULTILINE)


def parse_fixture(value: str) -> tuple[str, Path]:
    language, separator, raw_path = value.partition("=")
    if not separator or language not in _LANGUAGES:
        raise argparse.ArgumentTypeError("fixture must be en|de|ja|zh=/absolute/path")
    path = Path(raw_path).expanduser().resolve()
    if not path.is_file():
        raise argparse.ArgumentTypeError(f"fixture does not exist: {path}")
    return language, path


def command_output(command: list[str]) -> str:
    process = subprocess.run(
        command,
        text=True,
        capture_output=True,
        check=False,
    )
    return process.stdout.strip() if process.returncode == 0 else "unknown"


def benchmark_environment() -> dict[str, str | int]:
    memory = command_output(["/usr/sbin/sysctl", "-n", "hw.memsize"])
    return {
        "chip": command_output(
            ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]
        ),
        "memory_bytes": int(memory) if memory.isdigit() else 0,
        "architecture": command_output(["/usr/bin/uname", "-m"]),
        "macos_version": command_output(["/usr/bin/sw_vers", "-productVersion"]),
        "macos_build": command_output(["/usr/bin/sw_vers", "-buildVersion"]),
    }


def audio_seconds(path: Path) -> float:
    if path.suffix.lower() == ".wav":
        try:
            with wave.open(str(path), "rb") as audio:
                return audio.getnframes() / float(audio.getframerate())
        except (OSError, wave.Error, ZeroDivisionError):
            pass

    afinfo = subprocess.run(
        ["/usr/bin/afinfo", "-b", str(path)],
        text=True,
        capture_output=True,
        check=False,
    )
    if afinfo.returncode == 0:
        match = _AFINFO_DURATION_RE.search(afinfo.stdout)
        if match is not None:
            return float(match.group(1))

    try:
        from mutagen import File

        audio = File(str(path))
        if audio is None or audio.info is None:
            raise ValueError("unsupported audio metadata")
        return float(audio.info.length)
    except Exception as error:
        raise SystemExit(f"cannot read duration for {path}: {error}") from error


def run_cli(cli: Path, source: Path, count: int) -> tuple[float, float, list[str]]:
    work = Path(tempfile.mkdtemp(prefix=f"cohere-{source.stem}-{count}-"))
    try:
        inputs: list[Path] = []
        for index in range(count):
            copied = work / f"{source.stem}-{index + 1}{source.suffix}"
            shutil.copy2(source, copied)
            inputs.append(copied)

        output = work / "output"
        output.mkdir()
        command = [
            "/usr/bin/time",
            "-l",
            str(cli),
            "transcribe",
            *[str(path) for path in inputs],
            "--engine",
            "cohere",
            "--speaker-detection",
            "off",
            "--no-history",
            "--format",
            "transcript",
            "--output-dir",
            str(output),
        ]
        environment = dict(os.environ)
        environment["MACPARAKEET_TELEMETRY"] = "0"
        started = time.monotonic()
        process = subprocess.run(
            command,
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        wall = time.monotonic() - started
        if process.returncode != 0:
            raise SystemExit(
                f"Cohere benchmark failed with exit {process.returncode}:\n"
                f"{process.stderr[-2000:]}"
            )

        match = _RSS_RE.search(process.stderr)
        if match is None:
            raise SystemExit("macOS peak RSS was not present in /usr/bin/time output")
        peak_rss_mb = int(match.group(1)) / 1024 / 1024

        transcripts = [
            path.read_text(encoding="utf-8").strip()
            for path in sorted(output.glob("*.txt"))
        ]
        if len(transcripts) != count or any(not text for text in transcripts):
            raise SystemExit(
                f"expected {count} non-empty transcript files, got {len(transcripts)}"
            )
        return wall, peak_rss_mb, transcripts
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--fixture", type=parse_fixture, action="append", required=True)
    parser.add_argument("--runtime-commit", required=True)
    parser.add_argument("--artifact-sha256", required=True)
    parser.add_argument(
        "--warm-repetitions",
        type=int,
        default=12,
        help="Number of copies in the repeated process used for the warm slope.",
    )
    parser.add_argument(
        "--model-revision",
        default="dfa4adebb64f3076b7b6b90b721275cc069cb421",
    )
    parser.add_argument(
        "--model-sha256",
        default="14d02f1ad6dd77b3a60f82639879012c3adb4fe25c50a5a47a2c4c661daf1558",
    )
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    fixtures = dict(arguments.fixture)
    missing = set(_LANGUAGES) - set(fixtures)
    extra_count = len(arguments.fixture) - len(fixtures)
    if missing or extra_count:
        raise SystemExit(
            f"provide exactly one fixture for each of {', '.join(_LANGUAGES)}"
        )

    cli = arguments.cli.expanduser().resolve()
    if not cli.is_file():
        raise SystemExit(f"CLI does not exist: {cli}")
    if arguments.warm_repetitions < 2:
        raise SystemExit("--warm-repetitions must be at least 2")

    records = []
    for language in _LANGUAGES:
        fixture = fixtures[language]
        duration = audio_seconds(fixture)
        cold_wall, _, cold_transcripts = run_cli(cli, fixture, 1)
        repeated_wall, peak_rss_mb, repeated_transcripts = run_cli(
            cli,
            fixture,
            arguments.warm_repetitions,
        )
        warm_wall = (repeated_wall - cold_wall) / (
            arguments.warm_repetitions - 1
        )
        if warm_wall <= 0:
            raise SystemExit(
                f"invalid warm estimate for {language}: "
                f"({repeated_wall} - {cold_wall}) / "
                f"({arguments.warm_repetitions} - 1)"
            )
        records.append(
            {
                "language": language,
                "fixture": str(fixture),
                "audio_seconds": duration,
                "cold_first_transcript_seconds": cold_wall,
                "warm_transcription_seconds": warm_wall,
                "realtime_factor": warm_wall / duration,
                "realtime_multiple": duration / warm_wall,
                "peak_rss_mb": peak_rss_mb,
                "cold_transcript": cold_transcripts[0],
                "warm_transcripts": repeated_transcripts,
            }
        )

    payload = {
        "engine": "cohere",
        "backend": "transcribe.cpp",
        "runtime_commit": arguments.runtime_commit,
        "artifact_sha256": arguments.artifact_sha256,
        "model_revision": arguments.model_revision,
        "model_sha256": arguments.model_sha256,
        "automatic_language_detection": True,
        "warm_repetitions": arguments.warm_repetitions,
        "environment": benchmark_environment(),
        "methodology": {
            "cold": "fresh process and fresh native model/context; OS file cache not purged",
            "warm": "per-file wall-time slope from the repeated process",
            "peak_rss": "maximum resident set size of the repeated process",
        },
        "measurements": records,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
