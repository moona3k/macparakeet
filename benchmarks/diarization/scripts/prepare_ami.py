#!/usr/bin/env python3
"""Fetch pinned AMI test references and optionally one official mono WAV.

Default downloads annotations/scorer only. Pass --recording ami_ES2004a_mhm
to acquire one recording, run every backend on it, then release that scratch
WAV before acquiring the next. Audio and manifests never enter the app library.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import urllib.request
import wave
from pathlib import Path

from score_diarization import MDEVAL_SHA256, MDEVAL_URL, load_manifest

DEFAULT_MANIFEST = Path(__file__).resolve().parent.parent / "manifests" / "ami-test.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path, expected_hash: str | None = None) -> None:
    if destination.is_file():
        if expected_hash is not None and sha256(destination) != expected_hash:
            raise ValueError(f"Existing file differs from pinned content: {destination}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "MacParakeet-diarization-comparison"})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as target:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                target.write(chunk)
        if expected_hash is not None and sha256(temporary) != expected_hash:
            raise ValueError(f"Downloaded content differs from pinned hash: {url}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def audio_hash(row: dict) -> str:
    """Scored recordings are pinned bytes; header metadata alone is not identity."""
    pinned = row["audio"].get("sha256")
    if not pinned:
        raise ValueError(f"Frozen audio hash missing for {row['id']}")
    return pinned


def validate_audio(path: Path, row: dict) -> dict:
    """Validate the frozen WAV header separately from the reference UEM extent.

    Four official IS1009 distant-mic recordings extend slightly beyond their
    headset-derived UEMs. Preserve both the original WAV and original UEM; do not
    trim, pad, or shift either to force equal lengths.
    """
    with wave.open(str(path), "rb") as audio:
        observed = {
            "channels": audio.getnchannels(),
            "sampleRate": audio.getframerate(),
            "sampleWidthBytes": audio.getsampwidth(),
            "frameCount": audio.getnframes(),
            "bytes": path.stat().st_size,
        }
    expected = row["audio"]
    for field, value in observed.items():
        if field not in expected:
            raise ValueError(f"Frozen WAV metadata missing {field} for {row['id']}")
        if value != expected[field]:
            raise ValueError(f"Audio {field} mismatch for {row['id']}: {value} != {expected[field]}")
    duration = observed["frameCount"] / observed["sampleRate"]
    if duration != expected["durationSeconds"]:
        raise ValueError(f"Frozen duration disagrees with WAV frames for {row['id']}")
    return {
        **observed,
        "durationSeconds": duration,
        "uemEndSeconds": row["durationSeconds"],
        "durationDifferenceFromUEMSeconds": duration - row["durationSeconds"],
        "timeAlignmentPolicy": "Original WAV origin and original UEM preserved; no trimming, padding, or shifting",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--recording", help="Only this recording's references and WAV; otherwise references only")
    args = parser.parse_args()
    records = load_manifest(args.manifest)
    if args.recording:
        records = [row for row in records if row["id"] == args.recording]
        if not records:
            parser.error("Recording is not in the frozen manifest")
    download(MDEVAL_URL, args.root / "tools" / "md-eval-22.pl", MDEVAL_SHA256)
    for row in records:
        for suffix, key in (("rttm", "reference"), ("uem", "uem")):
            source = row[key]
            download(source["url"], args.root / "references" / (row["id"] + "." + suffix), source["sha256"])
        if args.recording:
            path = args.root / "audio" / (row["id"] + ".wav")
            download(row["audio"]["url"], path, audio_hash(row))
            audio_metadata = validate_audio(path, row)
            evidence = {"id": row["id"], "url": row["audio"]["url"], "sha256": row["audio"]["sha256"],
                        **audio_metadata,
                        "channelSelection": row["audio"]["channelSelection"]}
            evidence_path = args.root / "audio-metadata" / (row["id"] + ".json")
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
            print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
