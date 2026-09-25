#!/usr/bin/env python3
"""Score frozen diarizer JSON outputs with dscore's pinned NIST DER engine.

Uses only Python's standard library and Perl. This deliberately delegates speaker
mapping, overlap, UEM trimming, and all error-time computation to md-eval-22.pl;
it does not reimplement DER. Missing predictions are errors; explicit [] segment
arrays are valid predictions and retain the full reference scoring region.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import statistics
import subprocess
import tempfile
from pathlib import Path

DSCORE_REVISION = "e02f949ac6592279300a2c33d03daf9e0c12fd27"
MDEVAL_SHA256 = "872aa955cbc3d57e6d4fd6fe2e699791739c1cb716cc89105bb4717415b9400d"
MDEVAL_URL = f"https://raw.githubusercontent.com/nryant/dscore/{DSCORE_REVISION}/scorelib/md-eval-22.pl"
TOKEN = re.compile(r"^[A-Za-z0-9_.:-]+$")


def token(value: object, field: str) -> str:
    if not isinstance(value, str) or not TOKEN.fullmatch(value):
        raise ValueError(f"Invalid {field}: {value!r}")
    return value


def number(value: object, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{field} must be a finite number")
    return float(value)


def json_to_rttm(document: dict, recording_id: str) -> str:
    """Preserve overlapping speakers and short turns; apply no smoothing."""
    token(recording_id, "recording ID")
    segments = document.get("segments")
    if not isinstance(segments, list):
        raise ValueError("Prediction must contain an explicit segments array")
    rows = []
    for segment in segments:
        speaker = token(segment.get("speakerId"), "speakerId")
        start = number(segment.get("startMs"), "startMs") / 1000
        end = number(segment.get("endMs"), "endMs") / 1000
        if start < 0 or end <= start:
            raise ValueError(f"Invalid interval for {recording_id}: {start}..{end}")
        rows.append((start, end, speaker))
    return "".join(
        f"SPEAKER {recording_id} 1 {start:.6f} {end-start:.6f} <NA> <NA> {speaker} <NA> <NA>\n"
        for start, end, speaker in sorted(rows)
    )


def reference_text(path: Path, recording_id: str, reference_id: str, *, uem: bool) -> str:
    lines = []
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        id_index = 0 if uem else 1
        if len(fields) != (4 if uem else 10) or fields[id_index] != reference_id:
            raise ValueError(f"Unexpected reference row in {path}: {line}")
        if not uem and fields[0] != "SPEAKER":
            raise ValueError(f"Unsupported reference type in {path}: {fields[0]}")
        fields[id_index] = recording_id
        # Every selected input is one mono signal, irrespective of original mic.
        fields[1 if uem else 2] = "1"
        lines.append(" ".join(fields) + "\n")
    if not lines:
        raise ValueError(f"Empty {'UEM' if uem else 'reference'}: {path}")
    return "".join(lines)


def parse_mdeval(stdout: str, expected_ids: set[str]) -> dict[str, dict]:
    blocks = re.split(r"\*\*\* Performance analysis for Speaker Diarization for (.*?) \*\*\*", stdout)
    scores = {}
    names = {
        "referenceSpeakerSeconds": "SCORED SPEAKER TIME",
        "missSeconds": "MISSED SPEAKER TIME",
        "falseAlarmSeconds": "FALARM SPEAKER TIME",
        "confusionSeconds": "SPEAKER ERROR TIME",
    }
    for index in range(1, len(blocks), 2):
        file_id = blocks[index].removeprefix("f=")
        if file_id in scores:
            raise ValueError(f"Duplicate scorer result: {file_id}")
        values = {}
        for key, label in names.items():
            match = re.search(re.escape(label) + r"\s*=\s*([0-9.]+) secs", blocks[index + 1])
            if match is None:
                raise ValueError(f"Missing {label} in scorer result: {file_id}")
            values[key] = float(match.group(1))
        denominator = values["referenceSpeakerSeconds"]
        if denominator <= 0:
            raise ValueError(f"No reference speech scored for {file_id}")
        for component in ("miss", "falseAlarm", "confusion"):
            values[component + "Percent"] = 100 * values[component + "Seconds"] / denominator
        values["derPercent"] = sum(values[key + "Percent"] for key in ("miss", "falseAlarm", "confusion"))
        scores[file_id] = values
    if set(scores) != expected_ids | {"ALL"}:
        raise ValueError(f"Scorer coverage mismatch: expected {sorted(expected_ids)}, got {sorted(scores)}")
    return scores


def run_mdeval(md_eval: Path, reference: Path, prediction: Path, uem: Path,
               expected_ids: set[str]) -> tuple[dict, str]:
    if hashlib.sha256(md_eval.read_bytes()).hexdigest() != MDEVAL_SHA256:
        raise ValueError(f"Scorer does not match pinned dscore {DSCORE_REVISION}")
    result = subprocess.run(
        ["perl", str(md_eval), "-af", "-r", str(reference), "-s", str(prediction),
         "-u", str(uem), "-c", "0"],
        check=True, capture_output=True, text=True,
    )
    return parse_mdeval(result.stdout, expected_ids), result.stdout


def load_manifest(path: Path) -> list[dict]:
    records = json.loads(path.read_text())["recordings"]
    ids = [token(row["id"], "recording ID") for row in records]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("Manifest must contain unique, nonempty recording IDs")
    return records


def score_backend(records: list[dict], reference_root: Path, predictions: Path,
                  md_eval: Path, artifact_dir: Path) -> dict:
    missing = [row["id"] for row in records if not (predictions / (row["id"] + ".json")).is_file()]
    if missing:
        raise ValueError(f"Missing predictions ({len(missing)}): {', '.join(missing)}")
    artifact_dir.mkdir(parents=True, exist_ok=True)
    groups = {}
    metadata = {}
    for row in records:
        groups.setdefault((row["corpus"], row["condition"]), []).append(row)
    for (corpus, condition), group in sorted(groups.items()):
        reference, predicted, uem = [], [], []
        group_id = token(f"{corpus}_{condition}", "group ID")
        group_metadata = {}
        for row in group:
            recording_id = row["id"]
            document = json.loads((predictions / (recording_id + ".json")).read_text())
            predicted.append(json_to_rttm(document, recording_id))
            reference_id = row.get("referenceId", row["meetingId"])
            for suffix, source_key in (("rttm", "reference"), ("uem", "uem")):
                pinned_hash = row.get(source_key, {}).get("sha256")
                path = reference_root / (recording_id + "." + suffix)
                if pinned_hash and hashlib.sha256(path.read_bytes()).hexdigest() != pinned_hash:
                    raise ValueError(f"Reference differs from manifest hash: {path}")
            reference.append(reference_text(reference_root / (recording_id + ".rttm"), recording_id, reference_id, uem=False))
            uem.append(reference_text(reference_root / (recording_id + ".uem"), recording_id, reference_id, uem=True))
            reference_count = len({line.split()[7] for line in reference[-1].splitlines()})
            segment_count = len({segment["speakerId"] for segment in document["segments"]})
            group_metadata[recording_id] = {
                "meetingId": row["meetingId"],
                "predictedSpeakerCount": document.get("speakerCount"),
                "referenceSpeakerCount": reference_count,
                "segmentSpeakerCount": segment_count,
                "exactSpeakerCount": segment_count == reference_count,
                "absoluteSpeakerCountError": abs(segment_count - reference_count),
                "runtimeSeconds": document.get("runtimeSeconds"),
                "backend": document.get("backend"),
                "config": document.get("config"),
            }
        with tempfile.TemporaryDirectory(prefix="macparakeet-der-") as temporary:
            root = Path(temporary)
            for name, lines in (("reference.rttm", reference), ("predicted.rttm", predicted), ("scoring.uem", uem)):
                (root / name).write_text("".join(lines))
            scores, raw = run_mdeval(md_eval, root / "reference.rttm", root / "predicted.rttm", root / "scoring.uem", set(group_metadata))
            # Preserve exact scorer inputs and output, without audio/transcripts.
            for name in ("reference.rttm", "predicted.rttm", "scoring.uem"):
                (artifact_dir / f"{group_id}.{name}").write_bytes((root / name).read_bytes())
        (artifact_dir / f"{group_id}.md-eval.txt").write_text(raw)
        overall = scores.pop("ALL")
        for recording_id, values in scores.items():
            values.update(group_metadata[recording_id])
        metadata[group_id] = {
            "recordingCount": len(group), "uniqueMeetingCount": len({row["meetingId"] for row in group}),
            "aggregate": overall,
            "meanRecordingDERPercent": statistics.mean(row["derPercent"] for row in scores.values()),
            "medianRecordingDERPercent": statistics.median(row["derPercent"] for row in scores.values()),
            "exactSpeakerCountPercent": 100 * statistics.mean(row["exactSpeakerCount"] for row in scores.values()),
            "meanAbsoluteSpeakerCountError": statistics.mean(row["absoluteSpeakerCountError"] for row in scores.values()),
            "recordings": scores,
        }
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--predictions", action="append", required=True, metavar="BACKEND=DIRECTORY")
    parser.add_argument("--md-eval", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    records = load_manifest(args.manifest)
    report = {
        "scorer": {"repository": "nryant/dscore", "revision": DSCORE_REVISION, "engineSHA256": MDEVAL_SHA256,
                   "collarSeconds": 0, "overlapIncluded": True, "explicitUEM": True},
        "manifestSHA256": hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
        "backends": {},
    }
    for value in args.predictions:
        name, directory = value.split("=", 1)
        token(name, "backend name")
        if name in report["backends"]:
            raise ValueError(f"Duplicate backend: {name}")
        report["backends"][name] = score_backend(records, args.reference_root, Path(directory), args.md_eval,
                                                args.output.parent / (args.output.stem + "-artifacts") / name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
