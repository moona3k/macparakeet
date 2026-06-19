#!/usr/bin/env python3
"""Speed + memory micro-benchmark — steady-state RTFx, cold-start, peak RSS.

Separate from accuracy scoring (score.py): the full-set accuracy run reports
*batch* RTFx, where a one-time model load is amortized over thousands of files
and is also vulnerable to contention. This tool isolates the real per-engine
speed/memory profile, **one engine at a time, nothing else running**:

  - **cold start** = wall to the first transcript from a cold process
    (dominated by CoreML/ANE model load + first-run compile).
  - **steady RTFx** = audio_seconds / wall, with the one-time load removed.
    For macparakeet-cli engines we run the same prefix at two sizes (1 file vs
    N files) in fresh processes; the difference cancels the fixed load:
        steady = (audio_N - audio_1) / (wall_N - wall_1)
    For Cohere (FluidAudio CLI) we read its per-file rtfx and drop file 0.
  - **peak RSS** = `/usr/bin/time -l` "maximum resident set size" of the
    isolated child process (the whole CLI: Swift runtime + the loaded model).

Backends: macparakeet-cli (parakeet-v2/v3/unified, nemotron-en/multi, whisper)
and the FluidAudio CLI cohere-benchmark (cohere — not an integrated engine).

Usage:
    speed_bench.py --engine parakeet-v3 --cli /path/to/macparakeet-cli \
        --dataset-dir ~/asr-bench/LibriSpeech/test-clean --n 24 --out speed.jsonl
    speed_bench.py --engine cohere --fa /path/to/fluidaudiocli \
        --cohere-model ~/asr-bench/cohere-coreml/q8 --n 12 --out speed.jsonl
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

MP_ENGINES = {
    "parakeet-v2": ["--engine", "parakeet", "--parakeet-model", "v2"],
    "parakeet-v3": ["--engine", "parakeet", "--parakeet-model", "v3"],
    "parakeet-unified": ["--engine", "parakeet", "--parakeet-model", "unified"],
    "nemotron-en": ["--engine", "nemotron", "--nemotron-model", "english-1120ms"],
    "nemotron-multi": ["--engine", "nemotron", "--nemotron-model", "multilingual-1120ms"],
    "whisper": ["--engine", "whisper"],
}
_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size", re.MULTILINE)


def peak_rss_mb(stderr: str) -> float | None:
    m = _RSS_RE.search(stderr)
    return int(m.group(1)) / 1024 / 1024 if m else None  # macOS reports bytes


def audio_seconds(path: Path) -> float:
    from mutagen.flac import FLAC
    return float(FLAC(str(path)).info.length)


def time_l(cmd: list[str], env_extra: dict | None = None) -> tuple[float, str, int]:
    """Run under /usr/bin/time -l; return (wall_seconds, stderr, returncode)."""
    import os
    env = dict(os.environ)
    env["MACPARAKEET_TELEMETRY"] = "0"  # no network from the CLI under test
    if env_extra:
        env.update(env_extra)
    t0 = time.monotonic()
    res = subprocess.run(["/usr/bin/time", "-l", *cmd], text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    return time.monotonic() - t0, res.stderr, res.returncode


def run_mp(cli: Path, flags: list[str], files: list[Path], out_dir: Path):
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    cmd = [str(cli), "transcribe", *[str(f) for f in files],
           "--format", "transcript", "--output-dir", str(out_dir),
           *flags, "--speaker-detection", "off", "--no-history"]
    wall, stderr, rc = time_l(cmd)
    if rc != 0:
        raise SystemExit(f"macparakeet-cli exit {rc}\n{stderr[-800:]}")
    return wall, peak_rss_mb(stderr)


def measure_macparakeet(engine: str, cli: Path, files: list[Path], n: int) -> dict:
    flags = MP_ENGINES[engine]
    work = Path(tempfile.mkdtemp(prefix=f"speed-{engine}-"))
    try:
        # cold-start: fresh process, single file (load/compile dominates)
        w1, _ = run_mp(cli, flags, files[:1], work / "a")
        a1 = audio_seconds(files[0])
        # warm batch: fresh process, N files (model loads once, then N inferences)
        wN, rss = run_mp(cli, flags, files[:n], work / "b")
        aN = sum(audio_seconds(f) for f in files[:n])
        # guard a tiny denominator (measurement jitter) from exploding the ratio
        steady = (aN - a1) / (wN - w1) if (wN - w1) >= 0.05 else None
        return dict(engine=engine, method="mp-cli diff(1,N)", n_files=n,
                    cold_start_s=round(w1, 2), steady_rtfx=round(steady, 1) if steady else None,
                    peak_rss_mb=round(rss) if rss else None,
                    wall_1_s=round(w1, 2), wall_N_s=round(wN, 2),
                    audio_1_s=round(a1, 1), audio_N_s=round(aN, 1))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def measure_cohere(fa: Path, model_dir: Path, n: int) -> dict:
    work = Path(tempfile.mkdtemp(prefix="speed-cohere-"))
    out = work / "cohere.json"
    try:
        # --dataset librispeech matters: it defaults to fleurs, which would
        # silently measure a different dataset than the accuracy run.
        cmd = [str(fa), "cohere-benchmark", "--dataset", "librispeech",
               "--subset", "test-clean", "--model-dir", str(model_dir),
               "--max-files", str(n), "--output", str(out)]
        wall, stderr, rc = time_l(cmd)
        if rc != 0 or not out.exists():
            raise SystemExit(f"cohere-benchmark exit {rc}, json={out.exists()}\n{stderr[-800:]}")
        results = json.loads(out.read_text()).get("results", [])
        rtfx = [r["rtfx"] for r in results if r.get("rtfx")]
        cold = results[0].get("processingTime") if results else None
        steady = statistics.median(rtfx[1:]) if len(rtfx) > 1 else None
        rss = peak_rss_mb(stderr)
        return dict(engine="cohere", method="fluidaudio per-file (drop file0)", n_files=len(results),
                    cold_start_s=round(cold, 2) if cold else None,
                    steady_rtfx=round(steady, 1) if steady else None,
                    peak_rss_mb=round(rss) if rss else None,
                    total_wall_s=round(wall, 1))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, help="one of %s, cohere, or 'all'" % list(MP_ENGINES))
    ap.add_argument("--cli", type=Path, help="macparakeet-cli (for integrated engines)")
    ap.add_argument("--fa", type=Path, help="fluidaudiocli (for cohere)")
    ap.add_argument("--cohere-model", type=Path, help="cohere q8 model dir")
    ap.add_argument("--dataset-dir", type=Path, help="LibriSpeech test-clean dir (mp engines)")
    ap.add_argument("--n", type=int, default=24, help="warm-batch size")
    ap.add_argument("--out", type=Path, help="append the result JSON line here")
    args = ap.parse_args()

    files = []
    if args.dataset_dir:
        files = sorted(args.dataset_dir.expanduser().resolve().glob("*/*/*.flac"))

    engines = list(MP_ENGINES) + ["cohere"] if args.engine == "all" else [args.engine]
    out_records = []
    for eng in engines:
        print(f">>> measuring {eng} ...", flush=True)
        if eng == "cohere":
            rec = measure_cohere(args.fa.expanduser().resolve(),
                                 args.cohere_model.expanduser().resolve(), args.n)
        else:
            if not files:
                raise SystemExit("--dataset-dir required for macparakeet-cli engines")
            rec = measure_macparakeet(eng, args.cli.expanduser().resolve(), files, args.n)
        print("   " + json.dumps(rec))
        out_records.append(rec)
        if args.out:
            with args.out.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
