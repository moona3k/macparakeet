#!/usr/bin/env python3
"""Paired bootstrap CI on the WER/CER *difference* between two engines.

Engines transcribe the SAME utterances, so their errors are correlated. The
statistically correct test for "is A better than B" is a paired bootstrap on the
per-utterance delta — NOT whether the two engines' independent marginal CIs
overlap (overlap is over-conservative and under-detects real differences). We
resample utterances (the paired unit) with replacement and report the 95% CI of
corpus_error(A) - corpus_error(B). If the CI excludes 0, the difference is
significant. Deterministic for a fixed seed.

Routes WER (space-delimited langs) vs CER (ko/ja/zh) by --lang, reusing
score_multi's tokenizer so it matches the scorers exactly.

Usage:
    paired_delta.py a.jsonl b.jsonl --lang en
    paired_delta.py cohere__fleurs.jsonl whisper__ja_jp.jsonl --lang ja_jp
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score_multi  # noqa: E402


def paired_bootstrap(rows: list[tuple[int, int, int]], n_boot: int, seed: int,
                     alpha: float = 0.05) -> tuple[float, float | None, float | None]:
    """rows = (edits_A, edits_B, ref_len) per shared utterance. Returns
    (point, lo, hi) for corpus_error(A) - corpus_error(B) in %, resampling whole
    utterances with replacement. Deterministic for a fixed seed."""
    def delta(sample) -> float:
        sa = sum(r[0] for r in sample)
        sb = sum(r[1] for r in sample)
        sr = sum(r[2] for r in sample)
        return (sa - sb) / sr * 100 if sr else 0.0
    point = delta(rows)
    if not rows or n_boot <= 0:
        return point, None, None
    # explicit randrange loop (not random.choices) so committed CIs stay stable
    rng = random.Random(seed)
    m = len(rows)
    samples = sorted(delta([rows[rng.randrange(m)] for _ in range(m)]) for _ in range(n_boot))
    return point, score_multi.percentile(samples, alpha / 2), score_multi.percentile(samples, 1 - alpha / 2)


def load(path: str, lang: str) -> dict[str, dict]:
    out: dict[str, dict] = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if lang and r.get("lang") and r["lang"] != lang:
                continue
            out[r["id"]] = r
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file_a")
    ap.add_argument("file_b")
    ap.add_argument("--lang", default="en")
    ap.add_argument("--ci", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()

    A, B = load(args.file_a, args.lang), load(args.file_b, args.lang)
    ids = sorted(set(A) & set(B))
    if not ids:
        raise SystemExit("no shared utterance ids between the two files")

    rows = []  # (edits_A, edits_B, ref_len) per shared utterance
    for i in ids:
        ref = score_multi.tokens(A[i]["ref"], args.lang)
        if not ref:
            continue
        ha = score_multi.tokens(A[i].get("hyp") or "", args.lang)
        hb = score_multi.tokens(B[i].get("hyp") or "", args.lang)
        rows.append((sum(score_multi.edits(ref, ha)), sum(score_multi.edits(ref, hb)), len(ref)))

    point, lo, hi = paired_bootstrap(rows, args.ci, args.seed)
    m = len(rows)
    metric = "CER" if score_multi.is_cer(args.lang) else "WER"
    verdict = "SIGNIFICANT (A better)" if hi < 0 else \
              "SIGNIFICANT (B better)" if lo > 0 else "tie (CI spans 0)"
    a_name, b_name = Path(args.file_a).stem, Path(args.file_b).stem
    print(f"{a_name} - {b_name}  [{args.lang} {metric}, n={m}]: "
          f"Δ={point:+.2f}  95% CI [{lo:+.2f}, {hi:+.2f}]  -> {verdict}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
