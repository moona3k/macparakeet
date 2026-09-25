#!/usr/bin/env python3
"""Optional mapped reference activity interval coverage, using saved DER artifacts.

Run after score_diarization.py. This is not DER, conversational turn recall, word
accuracy, or a precision measure: extra predicted activity is not penalized here.
Intervals follow the reference annotations (often words in forced alignment).
No audio, inference, downloads, or third-party Python packages are needed.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import csv
import hashlib
import json
import math
import subprocess
import tempfile
from pathlib import Path

from score_diarization import DSCORE_REVISION, MDEVAL_SHA256, number, parse_mdeval, token

MANIFESTS = {
    "ami-manual": "ami-test.json",
    "ami-forced": "ami-test-forced-alignment.json",
    "alimeeting": "alimeeting-test.json",
}
SCORER = {
    "repository": "nryant/dscore", "revision": DSCORE_REVISION,
    "engineSHA256": MDEVAL_SHA256, "collarSeconds": 0,
    "overlapIncluded": True, "explicitUEM": True,
}
BUCKETS = ("upTo200ms", "200msTo1s", "over1s")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def union(intervals: list[tuple[float, float]]) -> list[tuple[float, float]]:
    result = []
    for start, end in sorted(intervals):
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(end, result[-1][1]))
        else:
            result.append((start, end))
    return result


def clip(start: float, end: float, regions: list[tuple[float, float]]) -> list[tuple[float, float]]:
    return [(max(start, a), min(end, b)) for a, b in regions if a < end and b > start]


def overlap(start: float, end: float, merged: list[tuple[float, float]]) -> float:
    """Intersect with already unioned, sorted intervals without double counting."""
    index = max(0, bisect.bisect_left(merged, (start,)) - 1)
    total = 0.0
    while index < len(merged) and merged[index][0] < end:
        a, b = merged[index]
        total += max(0.0, min(end, b) - max(start, a))
        index += 1
    return total


def read_intervals(path: Path, expected_ids: set[str], *, uem: bool = False) -> dict:
    result = collections.defaultdict(list)
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        if len(fields) != (4 if uem else 10) or (not uem and fields[0] != "SPEAKER"):
            raise ValueError(f"Invalid {'UEM' if uem else 'RTTM'} row in {path}: {line}")
        ident, channel = fields[:2] if uem else fields[1:3]
        if ident not in expected_ids or channel != "1":
            raise ValueError(f"Unexpected recording/channel in {path}: {ident}/{channel}")
        start, second = map(float, fields[2:4] if uem else fields[3:5])
        end = second if uem else start + second
        if not all(math.isfinite(v) for v in (start, end)) or start < 0 or end <= start:
            raise ValueError(f"Invalid interval in {path}: {line}")
        key = ident if uem else (ident, token(fields[7], "speaker"))
        result[key].append((start, end))
    return {key: union(values) if uem else sorted(values) for key, values in result.items()}


def read_mapping(path: Path, references: dict, predictions: dict) -> dict:
    """Absent mappings are valid for unpaired speakers, including empty hypotheses."""
    assignments, used_system, pairs = {}, set(), set()
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != ["File", "Channel", "RefSpeaker", "SysSpeaker", "isMapped", "timeOverlap"]:
            raise ValueError(f"Missing or invalid mapping header: {path}")
        for row in reader:
            reference = (row["File"], row["RefSpeaker"])
            system = (row["File"], row["SysSpeaker"])
            pair = (reference, system)
            if reference not in references or system not in predictions or row["Channel"] != "1":
                raise ValueError(f"Mapping contains unknown speaker or channel: {row}")
            if row["isMapped"] not in ("mapped", "notmapped") or pair in pairs:
                raise ValueError(f"Invalid or duplicate mapping row: {row}")
            if number(float(row["timeOverlap"]), "mapping overlap") < 0:
                raise ValueError(f"Negative mapping overlap: {row}")
            pairs.add(pair)
            if row["isMapped"] == "mapped":
                if reference in assignments or system in used_system:
                    raise ValueError("Speaker mapping is not one-to-one")
                assignments[reference] = row["SysSpeaker"]
                used_system.add(system)
    return assignments


def activity_coverage(references: dict, predictions: dict, regions: dict, assignments: dict) -> dict:
    predicted = {
        key: union([piece for a, b in segments for piece in clip(a, b, regions[key[0]])])
        for key, segments in predictions.items()
    }
    buckets = {key: {"intervals": 0, "referenceSeconds": 0.0,
                     "correctlyAttributedSeconds": 0.0, "atLeastHalfCoveredIntervals": 0}
               for key in BUCKETS}
    speaker_stats, totals = {}, collections.defaultdict(float)
    for (ident, speaker), segments in sorted(references.items()):
        mapped = assignments.get((ident, speaker))
        if mapped is not None and (ident, mapped) not in predicted:
            raise ValueError(f"Mapped speaker absent from predictions: {ident}/{mapped}")
        hypothesis = predicted.get((ident, mapped), [])
        clipped = []
        for start, end in segments:
            pieces = clip(start, end, regions[ident])
            duration = sum(b - a for a, b in pieces)
            if not duration:
                continue
            clipped.extend(pieces)
            covered = sum(overlap(a, b, hypothesis) for a, b in pieces)
            key = BUCKETS[0] if duration <= 0.2 + 1e-9 else (BUCKETS[1] if duration <= 1 + 1e-9 else BUCKETS[2])
            bucket = buckets[key]
            bucket["intervals"] += 1
            bucket["referenceSeconds"] += duration
            bucket["correctlyAttributedSeconds"] += covered
            bucket["atLeastHalfCoveredIntervals"] += covered > 0 and covered + 1e-9 >= duration / 2
        # Minority membership uses unioned speaker-time, not overlapping annotation rows.
        merged = union(clipped)
        seconds = sum(b - a for a, b in merged)
        if seconds:
            matched = sum(overlap(a, b, hypothesis) for a, b in merged)
            speaker_stats[(ident, speaker)] = (seconds, matched)
            totals[ident] += seconds
    return {
        "activityIntervalBuckets": buckets,
        "minoritySpeakers": [
            {"id": ident, "speaker": speaker, "referenceSeconds": seconds,
             "correctlyAttributedSeconds": matched}
            for (ident, speaker), (seconds, matched) in speaker_stats.items()
            if seconds < 4 or seconds < 0.04 * totals[ident]
        ],
        "minorityDefinition": "<4 seconds OR <4% of unioned reference speaker-time for recording",
    }


def validate_scores(actual: dict, saved: dict) -> None:
    for ident, values in actual.items():
        expected = saved["aggregate"] if ident == "ALL" else saved["recordings"][ident]
        for name in ("referenceSpeakerSeconds", "missSeconds", "falseAlarmSeconds", "confusionSeconds"):
            if not math.isclose(values[name], number(expected[name], name), abs_tol=1e-6, rel_tol=0):
                raise ValueError(f"Artifacts do not reproduce saved score: {ident}/{name}")


def analyze_condition(prefix: Path, saved: dict, expected_ids: set[str], md_eval: Path) -> dict:
    if set(saved["recordings"]) != expected_ids or saved["recordingCount"] != len(expected_ids):
        raise ValueError("Saved score recording coverage differs from manifest")
    paths = {name: Path(str(prefix) + "." + suffix) for name, suffix in (
        ("reference", "reference.rttm"), ("prediction", "predicted.rttm"), ("uem", "scoring.uem"))}
    references = read_intervals(paths["reference"], expected_ids)
    predictions = read_intervals(paths["prediction"], expected_ids)
    regions = read_intervals(paths["uem"], expected_ids, uem=True)
    if {key[0] for key in references} != expected_ids or set(regions) != expected_ids:
        raise ValueError("Reference/UEM coverage differs from manifest")
    if sha256(md_eval) != MDEVAL_SHA256:
        raise ValueError("Scorer does not match pinned dscore engine")
    with tempfile.TemporaryDirectory(prefix="macparakeet-activity-") as temporary:
        mapping = Path(temporary) / "mapping.csv"
        result = subprocess.run(
            ["perl", str(md_eval), "-af", "-r", str(paths["reference"]), "-s", str(paths["prediction"]),
             "-u", str(paths["uem"]), "-c", "0", "-M", str(mapping)],
            check=True, capture_output=True, text=True,
        )
        validate_scores(parse_mdeval(result.stdout, expected_ids), saved)
        assignments = read_mapping(mapping, references, predictions)
        diagnostic = activity_coverage(references, predictions, regions, assignments)
        diagnostic["provenance"] = {
            "recordingCount": len(expected_ids), "reproducedSavedScores": True,
            "artifactSHA256": {name: sha256(path) for name, path in paths.items()},
            "mappingSHA256": sha256(mapping),
        }
    return diagnostic


def analyze(results: Path, md_eval: Path) -> dict:
    protocols = {}
    for protocol, filename in MANIFESTS.items():
        score_path = results / f"{protocol}-scores.json"
        if not score_path.exists():
            continue
        data = json.loads(score_path.read_text())
        manifest = Path(__file__).resolve().parent.parent / "manifests" / filename
        if data["scorer"] != SCORER or data["manifestSHA256"] != sha256(manifest):
            raise ValueError(f"Scorer protocol or manifest provenance mismatch: {score_path}")
        groups = collections.defaultdict(set)
        for row in json.loads(manifest.read_text())["recordings"]:
            groups[f'{row["corpus"]}_{row["condition"]}'].add(row["id"])
        if not data["backends"]:
            raise ValueError(f"No scored backends: {score_path}")
        backends, reference_hashes = {}, {}
        for backend, conditions in data["backends"].items():
            token(backend, "backend")
            if set(conditions) != set(groups):
                raise ValueError(f"Condition coverage differs from manifest: {backend}")
            backends[backend] = {}
            for condition, saved in conditions.items():
                token(condition, "condition")
                prefix = results / f"{protocol}-scores-artifacts" / backend / condition
                diagnostic = analyze_condition(prefix, saved, groups[condition], md_eval)
                hashes = diagnostic["provenance"]["artifactSHA256"]
                identity = (hashes["reference"], hashes["uem"])
                if identity != reference_hashes.setdefault(condition, identity):
                    raise ValueError(f"Reference/UEM differs between backends: {protocol}/{condition}")
                backends[backend][condition] = diagnostic
        protocols[protocol] = {"scoreSHA256": sha256(score_path), "manifestSHA256": sha256(manifest), "backends": backends}
    if not protocols:
        raise ValueError(f"No supported score reports found in {results}")
    return {
        "metric": "Mapped reference activity interval coverage",
        "note": "Not DER, conversational turn recall, word accuracy, or precision. Extra predicted activity is not penalized. "
                "NIST global mapping is reused; coverage uses original RTTM times within unioned UEM regions. "
                "Each annotated reference interval is counted once using its total retained duration, even across UEM gaps. "
                "Overlapping reference intervals remain separate in interval buckets; minority speaker-time uses their union. "
                "Forced-aligned intervals may be individual words. Protocols must be interpreted separately.",
        "scorer": SCORER,
        "missingProtocols": sorted(set(MANIFESTS) - set(protocols)),
        "protocols": protocols,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--md-eval", type=Path, required=True)
    parser.add_argument("--output", type=Path, help="Default: RESULTS/activity-diagnostics.json")
    args = parser.parse_args()
    report = analyze(args.results, args.md_eval)
    output = args.output or args.results / "activity-diagnostics.json"
    output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
