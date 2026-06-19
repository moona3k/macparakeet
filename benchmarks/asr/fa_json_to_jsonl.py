#!/usr/bin/env python3
"""Convert a FluidAudio CLI benchmark results JSON into scorer-ready JSONL.

Handles the per-file `results` array emitted by asr-benchmark / ja-benchmark /
cohere-benchmark, whose entries carry (at least) a filename, reference, and
hypothesis. Emits {id, ref, hyp, dataset, engine, audio_s?, proc_s?} so every
engine — FluidAudio-native or MacParakeet-integrated — is scored by the one
canonical scorer (score.py).

Usage:
    fa_json_to_jsonl.py results.json --engine cohere --dataset test-clean --out cohere__test-clean.jsonl
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def first(d: dict, *keys):
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("json_file", type=Path)
    ap.add_argument("--engine", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    data = json.loads(args.json_file.read_text(encoding="utf-8"))
    results = data.get("results") or data.get("files") or []
    n = 0
    with args.out.open("w", encoding="utf-8") as fh:
        for r in results:
            name = first(r, "fileName", "filename", "id", "name") or ""
            ref = first(r, "reference", "ref")
            hyp = first(r, "hypothesis", "hyp", "text")
            if ref is None or hyp is None:
                continue
            stem = Path(str(name)).stem or str(name)
            rec = {"id": stem, "ref": ref, "hyp": hyp,
                   "dataset": args.dataset, "engine": args.engine}
            audio = first(r, "audioLength", "audio_s", "duration", "audioDuration")
            proc = first(r, "processingTime", "proc_s")
            rtfx = first(r, "rtfx", "rtf")
            if audio and not proc and rtfx:
                proc = audio / rtfx if rtfx else None
            if audio:
                rec["audio_s"] = round(float(audio), 3)
            if proc:
                rec["proc_s"] = round(float(proc), 4)
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n += 1
    print(f"wrote {args.out} ({n} records, engine={args.engine}, dataset={args.dataset})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
