#!/usr/bin/env python3
"""Drive macparakeet-cli over a LibriSpeech subset for one engine and emit
scorer-ready JSONL ({id, ref, hyp, dataset, engine, audio_s, proc_s}).

This is the uniform Tier-0 path: every *integrated* engine is exercised through
the real shipping CLI (`transcribe --output-dir`, so CoreML/E5RT stdout
diagnostics cannot contaminate hypotheses), and every engine's hypotheses are
scored by the same canonical scorer (`score.py`). Pair the emitted JSONL with:

    score.py engineA.jsonl engineB.jsonl ...

Engines (`--engine` value -> macparakeet-cli flags):
    parakeet-v2 / v3 / unified   -> --engine parakeet --parakeet-model {v2,v3,unified}
    nemotron-en                  -> --engine nemotron --nemotron-model nemotron-english-1120ms
    nemotron-multi               -> --engine nemotron --nemotron-model nemotron-multilingual-1120ms
    whisper                      -> --engine whisper

RTFx note: proc_s is the batch wall-clock (incl. one-time model load) amortized
across files proportional to audio length, so the scorer's RTFx column reflects
realistic batch throughput. A separate speed micro-benchmark (warmup + median-
of-N + peak RSS) is for headline speed claims.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ENGINES = {
    "parakeet-v2": ["--engine", "parakeet", "--parakeet-model", "v2"],
    "parakeet-v3": ["--engine", "parakeet", "--parakeet-model", "v3"],
    "parakeet-unified": ["--engine", "parakeet", "--parakeet-model", "unified"],
    "nemotron-en": ["--engine", "nemotron", "--nemotron-model", "english-1120ms"],
    "nemotron-multi": ["--engine", "nemotron", "--nemotron-model", "multilingual-1120ms"],
    "whisper": ["--engine", "whisper"],
}


def load_refs(dataset: Path) -> dict[str, str]:
    refs: dict[str, str] = {}
    for trans in sorted(dataset.glob("*/*/*.trans.txt")):
        for line in trans.read_text(encoding="utf-8").splitlines():
            if line.strip():
                utt, _, text = line.partition(" ")  # tolerate id-only lines
                refs[utt] = text
    return refs


def select(dataset: Path, refs: dict[str, str], limit: int | None, selection: str) -> list[Path]:
    files = [p for p in sorted(dataset.glob("*/*/*.flac")) if p.stem in refs]
    if limit is None or limit >= len(files):
        return files
    if selection == "first":
        return files[:limit]
    if limit == 1:
        return [files[0]]
    span = len(files) - 1
    return [files[round(i * span / (limit - 1))] for i in range(limit)]


def audio_seconds(path: Path) -> float | None:
    try:
        from mutagen.flac import FLAC

        return float(FLAC(str(path)).info.length)
    except Exception:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", type=Path, required=True)
    ap.add_argument("--dataset-dir", type=Path, required=True, help="LibriSpeech subset dir")
    ap.add_argument("--dataset-name", required=True, help="label, e.g. test-clean")
    ap.add_argument("--engine", required=True, choices=list(ENGINES))
    ap.add_argument("--records", type=Path, required=True)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--selection", choices=["first", "stride"], default="stride")
    ap.add_argument("--work-dir", type=Path)
    args = ap.parse_args()

    dataset = args.dataset_dir.expanduser().resolve()
    cli = args.cli.expanduser().resolve()
    refs = load_refs(dataset)
    files = select(dataset, refs, args.limit, args.selection)
    if not files:
        raise SystemExit(f"no .flac under {dataset}")

    work = (args.work_dir.expanduser().resolve() if args.work_dir
            else Path(tempfile.mkdtemp(prefix=f"mp-bench-{args.engine}-")))
    out_dir = work / "transcripts"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    cmd = [str(cli), "transcribe", *[str(p) for p in files],
           "--format", "transcript", "--output-dir", str(out_dir),
           *ENGINES[args.engine], "--speaker-detection", "off", "--no-history"]
    print(f"engine={args.engine} dataset={args.dataset_name} files={len(files)}")
    print(f"cmd: {' '.join(cmd[:1])} transcribe <{len(files)} files> {' '.join(cmd[-8:])}")
    t0 = time.monotonic()
    res = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    wall = time.monotonic() - t0
    (work / "stdout.log").write_text(res.stdout, encoding="utf-8")
    (work / "stderr.log").write_text(res.stderr, encoding="utf-8")
    if res.returncode != 0:
        raise SystemExit(f"macparakeet-cli exit {res.returncode}; see {work}/stderr.log")

    durations = {p.stem: audio_seconds(p) for p in files}
    total_audio = sum(d for d in durations.values() if d) or 0.0

    args.records.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with args.records.open("w", encoding="utf-8") as fh:
        for p in files:
            tx = out_dir / f"{p.stem}.txt"
            if not tx.exists():
                print(f"  WARN missing transcript: {tx.name}", file=sys.stderr)
                continue
            a = durations.get(p.stem)
            rec = {"id": p.stem, "ref": refs[p.stem],
                   "hyp": tx.read_text(encoding="utf-8").strip(),
                   "dataset": args.dataset_name, "engine": args.engine}
            if a:
                rec["audio_s"] = round(a, 3)
                rec["proc_s"] = round(wall * a / total_audio, 4) if total_audio else None
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            written += 1

    rtfx = total_audio / wall if wall else 0.0
    print(f"records={args.records} written={written}")
    print(f"wall={wall:.1f}s total_audio={total_audio:.1f}s overall_RTFx={rtfx:.1f}x")
    if not args.work_dir:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
