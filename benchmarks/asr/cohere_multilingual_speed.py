#!/usr/bin/env python3
"""Measure one English, German, Japanese, and Chinese Cohere fixture.

Each language is run in a fresh process with one copied input, then with a
configurable repeated batch. The single-input wall time is process-cold
first-transcript latency. The wall-time slope between the single input and the
repeated batch estimates warm per-file transcription time while amortizing
process and model-load variance. Peak RSS comes from the repeated process.

No language hint is passed. A result is valid only for the owned runtime and
adapter combination that provides the automatic multilingual behavior required
by ADR-035.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import wave
from pathlib import Path
from contextlib import contextmanager

_ROOT = Path(__file__).resolve().parents[2]
_METADATA_TIMEOUT = 60.0
_VERIFY_TIMEOUT = 120.0

_LANGUAGES = ("en", "de", "ja", "zh")
_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size", re.MULTILINE)
_AFINFO_DURATION_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?) sec,", re.MULTILINE)
_DEFAULT_RELEASE_MANIFEST = Path(__file__).with_name(
    "cohere_transcribe_cpp_release.json"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def load_release_manifest(path: Path) -> dict:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot load release manifest {path}: {error}") from error

    if manifest.get("schema_version") != 1:
        raise SystemExit("unsupported Cohere benchmark release manifest schema")
    runtime = manifest.get("runtime")
    model = manifest.get("model")
    fixtures = manifest.get("fixtures")
    if not isinstance(runtime, dict) or not isinstance(model, dict):
        raise SystemExit("release manifest must contain runtime and model objects")
    if not isinstance(fixtures, dict) or set(fixtures) != set(_LANGUAGES):
        raise SystemExit(
            f"release manifest fixtures must be exactly {', '.join(_LANGUAGES)}"
        )

    runtime_fields = (
        "repository",
        "commit",
        "release_tag",
        "release_url",
        "artifact_filename",
        "artifact_sha256",
        "attestation_predicate_type",
    )
    model_fields = ("repository", "revision", "filename", "size_bytes", "sha256")
    for field in runtime_fields:
        if not runtime.get(field):
            raise SystemExit(f"release manifest runtime.{field} is required")
    for field in model_fields:
        if not model.get(field):
            raise SystemExit(f"release manifest model.{field} is required")
    if runtime.get("release_immutable") is not True:
        raise SystemExit("release manifest must require an immutable release")

    for language in _LANGUAGES:
        fixture = fixtures[language]
        if not isinstance(fixture, dict):
            raise SystemExit(f"release manifest fixture {language} must be an object")
        for field in ("id", "sha256", "expected_transcript"):
            if not fixture.get(field):
                raise SystemExit(
                    f"release manifest fixture {language}.{field} is required"
                )
    return manifest


def positive_seconds(value: str) -> float:
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("timeout must be a finite positive number")
    return seconds


def run_process(
    command: list[str],
    description: str,
    *,
    timeout: float = _METADATA_TIMEOUT,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    """Bound the entire command group, including time's transcription child."""
    try:
        process = subprocess.Popen(
            command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, start_new_session=True,
        )
    except OSError as error:
        raise SystemExit(f"{description} could not start: {error}") from error
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException as error:
        # Killing only /usr/bin/time would leave the model process running.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            # A descendant that detached itself may still hold these pipes.
            process.stdout.close()
            process.stderr.close()
            process.wait(timeout=5)
        if isinstance(error, subprocess.TimeoutExpired):
            raise SystemExit(f"{description} timed out after {timeout:g} seconds") from error
        raise
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def checked_output(command: list[str], description: str, **options) -> str:
    process = run_process(command, description, **options)
    if process.returncode != 0:
        raise SystemExit(
            f"{description} failed with exit {process.returncode}:\n"
            f"{process.stderr[-2000:]}"
        )
    return process.stdout.strip()


def command_json(command: list[str], description: str) -> dict:
    raw = checked_output(command, description)
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SystemExit(f"{description} returned invalid JSON: {error}") from error
    if not isinstance(payload, dict):
        raise SystemExit(f"{description} returned an unexpected JSON value")
    return payload


def native_environment(package: Path, artifact: Path) -> dict[str, str]:
    # A developer's dyld override must not substitute another measured runtime.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("DYLD_")}
    environment["MACPARAKEET_TRANSCRIBE_CPP_PACKAGE_PATH"] = str(package)
    environment["MACPARAKEET_TRANSCRIBE_CPP_ARTIFACT_ZIP"] = str(artifact)
    environment["MACPARAKEET_TELEMETRY"] = "0"
    return environment


def adapter_commit() -> str:
    changes = checked_output(
        ["git", "-C", str(_ROOT), "status", "--porcelain", "--untracked-files=all",
         "--", "Package.swift", "Package.resolved", "Sources",
         "scripts/dist/verify_transcribe_cpp_release.sh",
         "scripts/dist/transcribe_cpp_release_pins.sh",
         "benchmarks/asr/cohere_transcribe_cpp_release.json",
         "benchmarks/asr/cohere_multilingual_speed.py"],
        "adapter source verification",
    )
    if changes:
        raise SystemExit("commit adapter source, package, and verifier changes before benchmarking")
    return checked_output(
        ["git", "-C", str(_ROOT), "rev-parse", "HEAD"], "adapter commit lookup",
    )


def verify_native_package(environment: dict[str, str]) -> None:
    checked_output(
        [str(_ROOT / "scripts/dist/verify_transcribe_cpp_release.sh")],
        "native package/artifact verification", env=environment, timeout=_VERIFY_TIMEOUT,
    )


@contextmanager
def build_verified_cli(package: Path, artifact: Path, build_timeout: float):
    """Build in an empty scratch tree; never trust an independently supplied CLI."""
    environment = native_environment(package, artifact)
    commit = adapter_commit()
    verify_native_package(environment)
    with tempfile.TemporaryDirectory(prefix="cohere-verified-build-") as temporary:
        scratch = Path(temporary).resolve()
        build = ["swift", "build", "--package-path", str(_ROOT),
                 "--scratch-path", str(scratch), "--configuration", "release",
                 "--arch", "arm64", "--force-resolved-versions"]
        checked_output(
            [*build, "--product", "macparakeet-cli"], "verified CLI build",
            env=environment, timeout=build_timeout,
        )
        binary_directory = checked_output(
            [*build, "--show-bin-path"], "verified CLI build path", env=environment,
        )
        cli = (Path(binary_directory) / "macparakeet-cli").resolve()
        if not cli.is_relative_to(scratch) or not cli.is_file() or not os.access(cli, os.X_OK):
            raise SystemExit("build did not produce an executable CLI in its fresh scratch tree")
        linkage = checked_output(["/usr/bin/otool", "-L", str(cli)], "Cohere CLI linkage")
        if "@rpath/CTranscribe.framework/" not in linkage:
            raise SystemExit("built CLI does not link the verified Cohere framework")
        verify_native_package(environment)
        if adapter_commit() != commit:
            raise SystemExit("adapter source changed during the CLI build")
        digest = sha256_file(cli)
        yield cli, {
            "method": "fresh_release_build_from_verified_package",
            "adapter_commit": commit,
            "cli_sha256": digest,
            "architecture": "arm64",
        }, environment
        if sha256_file(cli) != digest or adapter_commit() != commit:
            raise SystemExit("measured CLI or adapter source changed during benchmarking")
        verify_native_package(environment)


def validate_release_metadata(
    manifest: dict,
    artifact_sha256: str,
    release: dict,
    attestation: dict,
) -> None:
    runtime = manifest["runtime"]
    if release.get("isImmutable") is not True:
        raise SystemExit("GitHub release is not immutable")
    if release.get("tagName") != runtime["release_tag"]:
        raise SystemExit("GitHub release tag does not match the checked-in manifest")
    if release.get("targetCommitish") != runtime["commit"]:
        raise SystemExit("GitHub release commit does not match the checked-in manifest")
    if release.get("url", "").lower() != runtime["release_url"].lower():
        raise SystemExit("GitHub release URL does not match the checked-in manifest")

    assets = release.get("assets")
    if not isinstance(assets, list):
        raise SystemExit("GitHub release asset metadata is missing")
    expected_asset = next(
        (
            asset
            for asset in assets
            if asset.get("name") == runtime["artifact_filename"]
        ),
        None,
    )
    if expected_asset is None:
        raise SystemExit("the pinned XCFramework archive is missing from the release")
    if expected_asset.get("digest") != f"sha256:{artifact_sha256}":
        raise SystemExit("GitHub release asset digest does not match the local archive")

    verification = attestation.get("verificationResult")
    statement = verification.get("statement") if isinstance(verification, dict) else None
    if not isinstance(statement, dict):
        raise SystemExit("release attestation statement is missing")
    if statement.get("predicateType") != runtime["attestation_predicate_type"]:
        raise SystemExit("release attestation predicate type does not match the manifest")
    predicate = statement.get("predicate")
    if not isinstance(predicate, dict):
        raise SystemExit("release attestation predicate is missing")
    if predicate.get("repository", "").lower() != runtime["repository"].lower():
        raise SystemExit("release attestation repository does not match the manifest")
    if predicate.get("tag") != runtime["release_tag"]:
        raise SystemExit("release attestation tag does not match the manifest")
    subjects = statement.get("subject")
    if not isinstance(subjects, list):
        raise SystemExit("release attestation subjects are missing")

    artifact_subject = next(
        (
            subject
            for subject in subjects
            if subject.get("name") == runtime["artifact_filename"]
        ),
        None,
    )
    if artifact_subject is None or artifact_subject.get("digest", {}).get(
        "sha256"
    ) != artifact_sha256:
        raise SystemExit("release attestation does not bind the pinned archive digest")
    commit_subject = next(
        (
            subject
            for subject in subjects
            if subject.get("digest", {}).get("sha1") == runtime["commit"]
            and subject.get("uri", "").lower()
            == (
                f"pkg:github/{runtime['repository']}@{runtime['release_tag']}"
            ).lower()
        ),
        None,
    )
    if commit_subject is None:
        raise SystemExit("release attestation does not bind the pinned runtime commit")


def verify_release_provenance(manifest: dict, artifact_zip: Path) -> str:
    runtime = manifest["runtime"]
    artifact = artifact_zip.expanduser().resolve()
    if not artifact.is_file():
        raise SystemExit(f"XCFramework archive does not exist: {artifact}")
    if artifact.name != runtime["artifact_filename"]:
        raise SystemExit(
            f"XCFramework archive must be named {runtime['artifact_filename']}"
        )
    artifact_sha256 = sha256_file(artifact)
    if artifact_sha256 != runtime["artifact_sha256"]:
        raise SystemExit(
            "XCFramework archive checksum does not match the checked-in manifest"
        )

    release = command_json(
        [
            "gh",
            "release",
            "view",
            runtime["release_tag"],
            "--repo",
            runtime["repository"],
            "--json",
            "tagName,isImmutable,targetCommitish,url,assets",
        ],
        "GitHub immutable-release lookup",
    )
    attestation = command_json(
        [
            "gh",
            "release",
            "verify",
            runtime["release_tag"],
            "--repo",
            runtime["repository"],
            "--format",
            "json",
        ],
        "GitHub release attestation verification",
    )
    validate_release_metadata(manifest, artifact_sha256, release, attestation)
    return artifact_sha256


def validate_fixture(manifest: dict, language: str, path: Path) -> dict:
    expected = manifest["fixtures"][language]
    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected["sha256"]:
        raise SystemExit(
            f"{language} fixture checksum mismatch for {expected['id']}: "
            f"expected {expected['sha256']}, got {actual_sha256}"
        )
    return expected


def validate_transcripts(
    language: str,
    phase: str,
    transcripts: list[str],
    expected: str,
) -> None:
    expected_sha256 = sha256_text(expected)
    for index, transcript in enumerate(transcripts, start=1):
        if transcript != expected:
            raise SystemExit(
                f"{language} {phase} transcript {index} did not match "
                f"reference SHA-256 {expected_sha256}; "
                f"got {sha256_text(transcript)}"
            )


def parse_fixture(value: str) -> tuple[str, Path]:
    language, separator, raw_path = value.partition("=")
    if not separator or language not in _LANGUAGES:
        raise argparse.ArgumentTypeError("fixture must be en|de|ja|zh=/absolute/path")
    path = Path(raw_path).expanduser().resolve()
    if not path.is_file():
        raise argparse.ArgumentTypeError(f"fixture does not exist: {path}")
    return language, path


def command_output(command: list[str]) -> str:
    process = run_process(command, "system metadata lookup")
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

    afinfo = run_process(["/usr/bin/afinfo", "-b", str(path)], "audio duration lookup")
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


def run_cli(
    cli: Path, source: Path, count: int, *, timeout: float,
    environment: dict[str, str],
) -> tuple[float, float, list[str]]:
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
        started = time.monotonic()
        process = run_process(
            command, "Cohere transcription", timeout=timeout, env=environment,
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
    parser.add_argument(
        "--package-path", type=Path, required=True,
        help="Clean pinned transcribe.cpp bindings/swift checkout with verified XCFramework.",
    )
    parser.add_argument("--build-timeout", type=positive_seconds, default=1800.0)
    parser.add_argument("--transcription-timeout", type=positive_seconds, default=900.0)
    parser.add_argument("--fixture", type=parse_fixture, action="append", required=True)
    parser.add_argument("--artifact-zip", type=Path, required=True)
    parser.add_argument(
        "--warm-repetitions",
        type=int,
        default=12,
        help="Number of copies in the repeated process used for the warm slope.",
    )
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    release_manifest_path = _DEFAULT_RELEASE_MANIFEST
    release_manifest = load_release_manifest(release_manifest_path)
    verified_artifact_sha256 = verify_release_provenance(
        release_manifest,
        arguments.artifact_zip,
    )

    fixtures = dict(arguments.fixture)
    missing = set(_LANGUAGES) - set(fixtures)
    extra_count = len(arguments.fixture) - len(fixtures)
    if missing or extra_count:
        raise SystemExit(
            f"provide exactly one fixture for each of {', '.join(_LANGUAGES)}"
        )

    if arguments.warm_repetitions < 2:
        raise SystemExit("--warm-repetitions must be at least 2")

    # Reject incorrect fixtures before the comparatively expensive fresh build.
    for language, fixture in fixtures.items():
        validate_fixture(release_manifest, language, fixture)
    with build_verified_cli(
        arguments.package_path.expanduser().resolve(),
        arguments.artifact_zip.expanduser().resolve(),
        arguments.build_timeout,
    ) as (cli, build_receipt, environment):
        records = []
        for language in _LANGUAGES:
            fixture = fixtures[language]
            fixture_reference = validate_fixture(
                release_manifest,
                language,
                fixture,
            )
            expected_transcript = fixture_reference["expected_transcript"]
            duration = audio_seconds(fixture)
            cold_wall, _, cold_transcripts = run_cli(
                cli, fixture, 1, timeout=arguments.transcription_timeout, environment=environment,
            )
            validate_transcripts(
                language,
                "cold",
                cold_transcripts,
                expected_transcript,
            )
            repeated_wall, peak_rss_mb, repeated_transcripts = run_cli(
                cli,
                fixture,
                arguments.warm_repetitions,
                timeout=arguments.transcription_timeout, environment=environment,
            )
            validate_transcripts(
                language,
                "warm",
                repeated_transcripts,
                expected_transcript,
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
                    "fixture_id": fixture_reference["id"],
                    "fixture_sha256": fixture_reference["sha256"],
                    "reference_transcript_sha256": sha256_text(expected_transcript),
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
        "build_receipt": build_receipt,
        "engine": "cohere",
        "backend": "transcribe.cpp",
        "runtime_commit": release_manifest["runtime"]["commit"],
        "artifact_sha256": verified_artifact_sha256,
        "artifact_release_tag": release_manifest["runtime"]["release_tag"],
        "artifact_release_url": release_manifest["runtime"]["release_url"],
        "artifact_release_immutable": True,
        "release_attestation_verified": True,
        "release_attestation_predicate_type": release_manifest["runtime"][
            "attestation_predicate_type"
        ],
        "model_revision": release_manifest["model"]["revision"],
        "model_sha256": release_manifest["model"]["sha256"],
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
