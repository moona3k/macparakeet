#!/usr/bin/env python3
"""Score CLI JSON against VoxConverse RTTM speaker counts / requested caps."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def unique_ids(values) -> list[str]:
    seen: list[str] = []
    for value in values:
        if value is None:
            continue
        if value not in seen:
            seen.append(value)
    return seen


def roster(doc: dict) -> dict[str, object]:
    speakers = doc.get("speakers") or []
    words = doc.get("wordTimestamps") or []
    segs = doc.get("diarizationSegments") or []
    roster_ids = unique_ids([s.get("id") for s in speakers])
    word_ids = unique_ids([w.get("speakerId") for w in words])
    seg_ids = unique_ids([s.get("speakerId") for s in segs])
    return {
        "roster": len(roster_ids),
        "word_speakers": len(word_ids),
        "segment_speakers": len(seg_ids),
        "labels": ",".join(s.get("label") or s.get("id") or "" for s in speakers),
    }


def word_smoothing_stats(doc: dict) -> dict[str, int]:
    speaker_ids = [word.get("speakerId") for word in doc.get("wordTimestamps") or []]
    isolated_flips = sum(
        speaker_ids[index] is not None
        and speaker_ids[index - 1] is not None
        and speaker_ids[index - 1] == speaker_ids[index + 1]
        and speaker_ids[index] != speaker_ids[index - 1]
        for index in range(1, len(speaker_ids) - 1)
    )

    nil_words = sum(speaker_id is None for speaker_id in speaker_ids)
    bounded_nil_words = 0
    index = 0
    while index < len(speaker_ids):
        if speaker_ids[index] is not None:
            index += 1
            continue
        end = index + 1
        while end < len(speaker_ids) and speaker_ids[end] is None:
            end += 1
        if (
            index > 0
            and end < len(speaker_ids)
            and speaker_ids[index - 1] is not None
            and speaker_ids[index - 1] == speaker_ids[end]
        ):
            bounded_nil_words += end - index
        index = end

    return {
        "isolated_flips": isolated_flips,
        "bounded_nil_words": bounded_nil_words,
        "nil_words": nil_words,
    }


def runs_for(role: str, rttm_n: int) -> list[tuple[str, int | None]]:
    runs: list[tuple[str, int | None]] = [("unconstrained", None)]
    if role.startswith("exact1"):
        runs.append(("exact1", 1))
    if role == "max2_ceiling":
        runs.append(("max2", 2))
    return runs


def pass_for(run: str, observed: int, rttm_n: int, cap: int | None) -> str:
    if run == "exact1":
        return "yes" if observed == 1 else "no"
    if run == "max2":
        return "yes" if observed <= 2 else "no"
    if run == "unconstrained":
        return "yes" if observed == rttm_n else f"mismatch({observed}!={rttm_n})"
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selected", type=Path, default=HERE / "selected_files.tsv")
    ap.add_argument("--results-dir", type=Path, required=True)
    ap.add_argument("--arm", required=True, help="baseline or candidate directory name")
    ap.add_argument(
        "--unconstrained-only",
        action="store_true",
        help="Score Auto roster only (issue #1046). Skip Exact/max cap runs.",
    )
    args = ap.parse_args()

    rows = list(csv.DictReader(args.selected.open(), delimiter="\t"))
    out_rows = []
    for row in rows:
        fid = row["file_id"]
        rttm_n = int(row["rttm_speakers"])
        role = row["role"]
        for run, cap in runs_for(role, rttm_n):
            if args.unconstrained_only and run != "unconstrained":
                continue
            path = args.results_dir / args.arm / f"{fid}.{run}.json"
            rec = {
                "arm": args.arm,
                "file_id": fid,
                "role": role,
                "run": run,
                "rttm_speakers": rttm_n,
                "cap": cap if cap is not None else "",
                "json_path": str(path),
                "exists": path.is_file(),
            }
            if path.is_file():
                doc = load_json(path)
                counts = roster(doc)
                rec.update(counts)
                if args.unconstrained_only:
                    rec.update(word_smoothing_stats(doc))
                observed = int(counts["roster"])
                rec["pass"] = pass_for(run, observed, rttm_n, cap)
            else:
                rec["roster"] = ""
                rec["pass"] = ""
            out_rows.append(rec)

    fields = [
        "arm",
        "file_id",
        "role",
        "run",
        "rttm_speakers",
        "cap",
        "roster",
        "word_speakers",
        "segment_speakers",
        "pass",
        *(["isolated_flips", "bounded_nil_words", "nil_words"] if args.unconstrained_only else []),
        "labels",
        "exists",
        "json_path",
    ]
    writer = csv.DictWriter(sys.stdout, fieldnames=fields, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for rec in out_rows:
        writer.writerow({k: rec.get(k, "") for k in fields})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
