#!/usr/bin/env python3
"""Gold-standard ASR scorer for cross-model comparison.

Consumes JSONL records of the form:
    {"id": "...", "ref": "...", "hyp": "...",
     "dataset": "test-clean", "engine": "parakeet-unified",
     "audio_s": 12.3, "proc_s": 0.11}   # audio_s/proc_s optional (for RTFx)

Scores every record through ONE normalizer so cross-engine numbers are
apples-to-apples (the whole point — see the Open ASR Leaderboard methodology).

Default normalizer: Whisper EnglishTextNormalizer (the community standard the
HF Open ASR Leaderboard and NVIDIA/NeMo model cards use). `--simple` falls back
to the dependency-light normalizer (lowercase, strip punct, keep intra-word
apostrophes) for environments without `whisper-normalizer`.

Reports, grouped by (engine, dataset):
  - corpus WER  = sum(S+D+I) / sum(ref words)   (the standard aggregate)
  - per-utterance distribution: mean / median / p90 / failure-rate (WER > 20%)
  - RTFx = sum(audio_s) / sum(proc_s), plus median per-file RTFx, when timing present
And per engine: macro-average WER across datasets (each dataset weighted equally).

Usage:
    score.py run1.jsonl run2.jsonl ...            # engine/dataset read from records
    score.py --label parakeet-v2:test-clean a.jsonl   # override when records lack fields
    score.py --simple ...                          # dependency-free normalizer
    score.py --json out.json ...                   # also emit machine-readable summary
"""
from __future__ import annotations

import argparse
import json
import random
import re
import statistics
import sys
from collections import defaultdict

# --- normalizers -----------------------------------------------------------

_PUNCT = re.compile(r"[^\w\s']", flags=re.UNICODE)
_APOS = re.compile(r"(^'+|'+$)")
_CURLY = {"’": "'", "‘": "'", "“": '"', "”": '"'}


def _simple_tokens(text: str) -> list[str]:
    for k, v in _CURLY.items():  # fold curly quotes first, like the canonical path
        text = text.replace(k, v)
    text = _PUNCT.sub(" ", text.lower())
    out = []
    for tok in text.split():
        tok = _APOS.sub("", tok)
        if tok:
            out.append(tok)
    return out


def make_normalizer(mode: str):
    if mode == "simple":
        return _simple_tokens
    from whisper_normalizer.english import EnglishTextNormalizer

    canon = EnglishTextNormalizer()

    def _canonical_tokens(text: str) -> list[str]:
        for k, v in _CURLY.items():
            text = text.replace(k, v)
        return canon(text).split()

    return _canonical_tokens


# --- edit distance ---------------------------------------------------------
# NOTE: the total edits (I+D+S) are canonical and path-independent; the
# individual I/D/S split can differ between the jiwer and pure-Python paths when
# multiple equal-cost alignments exist (different tie-breaking). Every reported
# metric (WER, p90, failure-rate, CI) uses the total, so they are unaffected.

try:
    import jiwer

    _SPLIT = jiwer.Compose([jiwer.ReduceToListOfListOfWords()])

    def edit_counts(hyp: list[str], ref: list[str]) -> tuple[int, int, int]:
        # feed already-normalized, space-joined tokens; passthrough transform
        out = jiwer.process_words(
            " ".join(ref) or " ",
            " ".join(hyp) or " ",
            reference_transform=_SPLIT,
            hypothesis_transform=_SPLIT,
        )
        return out.insertions, out.deletions, out.substitutions

except Exception:  # pragma: no cover - jiwer optional, fall back to pure-python DP

    def edit_counts(hyp: list[str], ref: list[str]) -> tuple[int, int, int]:
        m, n = len(hyp), len(ref)
        dp = [[0] * (n + 1) for _ in range(m + 1)]
        for i in range(m + 1):
            dp[i][0] = i
        for j in range(n + 1):
            dp[0][j] = j
        for i in range(1, m + 1):
            for j in range(1, n + 1):
                if hyp[i - 1] == ref[j - 1]:
                    dp[i][j] = dp[i - 1][j - 1]
                else:
                    dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
        i, j = m, n
        ins = dele = sub = 0
        while i > 0 or j > 0:
            if i > 0 and j > 0 and hyp[i - 1] == ref[j - 1]:
                i, j = i - 1, j - 1
            elif i > 0 and j > 0 and dp[i][j] == dp[i - 1][j - 1] + 1:
                sub += 1; i, j = i - 1, j - 1
            elif i > 0 and dp[i][j] == dp[i - 1][j] + 1:
                ins += 1; i -= 1
            elif j > 0 and dp[i][j] == dp[i][j - 1] + 1:
                dele += 1; j -= 1
            else:
                break
        return ins, dele, sub


# --- scoring ---------------------------------------------------------------

def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * pct
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def bootstrap_ci(pairs: list[tuple[int, int]], n_boot: int, seed: int,
                 alpha: float = 0.05) -> tuple[float, float] | None:
    """95% CI on corpus error rate by resampling utterances with replacement.

    Each pair is (edits, ref_len); corpus rate = sum(edits)/sum(ref_len). We
    resample whole utterances (the independent unit), so the interval reflects
    how much the ranking depends on which utterances happened to be in the set.
    Deterministic for a fixed seed.
    """
    if not pairs or n_boot <= 0:
        return None
    # explicit randrange loop (not random.choices) so committed CIs stay stable
    rng = random.Random(seed)
    m = len(pairs)
    samples = []
    for _ in range(n_boot):
        num = den = 0
        for _ in range(m):
            e, r = pairs[rng.randrange(m)]
            num += e
            den += r
        samples.append(num / den * 100 if den else 0.0)
    samples.sort()
    return percentile(samples, alpha / 2), percentile(samples, 1 - alpha / 2)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--normalizer", choices=["canonical", "simple"], default="canonical")
    ap.add_argument("--simple", action="store_true", help="alias for --normalizer simple")
    ap.add_argument("--label", help="engine:dataset to apply to records lacking those fields")
    ap.add_argument("--fail-threshold", type=float, default=0.20, help="per-utt WER above this = failure")
    ap.add_argument("--ci", type=int, default=0, metavar="N",
                    help="bootstrap N resamples for a 95%% CI on corpus WER (0 = off)")
    ap.add_argument("--seed", type=int, default=1234, help="bootstrap RNG seed (determinism)")
    ap.add_argument("--json", dest="json_out", help="write machine-readable summary JSON")
    args = ap.parse_args()

    mode = "simple" if (args.simple or args.normalizer == "simple") else "canonical"
    normalize = make_normalizer(mode)

    default_engine = default_dataset = None
    if args.label:
        default_engine, _, default_dataset = args.label.partition(":")

    # group[(engine, dataset)] = accumulator
    groups: dict[tuple[str, str], dict] = defaultdict(
        lambda: dict(ins=0, dele=0, sub=0, ref=0, n=0, audio=0.0, proc=0.0,
                     per_utt=[], rtfx=[], pairs=[])
    )

    for path in args.files:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                engine = rec.get("engine") or default_engine or "engine?"
                dataset = rec.get("dataset") or default_dataset or "dataset?"
                ref = normalize(rec["ref"])
                hyp = normalize(rec.get("hyp") or "")
                if not ref:
                    continue
                i, d, s = edit_counts(hyp, ref)
                g = groups[(engine, dataset)]
                g["ins"] += i; g["dele"] += d; g["sub"] += s
                g["ref"] += len(ref); g["n"] += 1
                g["per_utt"].append((i + d + s) / len(ref))
                g["pairs"].append((i + d + s, len(ref)))
                a, p = rec.get("audio_s"), rec.get("proc_s")
                if a and p:
                    g["audio"] += a; g["proc"] += p
                    g["rtfx"].append(a / p if p else 0.0)

    # report
    rows = []
    per_engine_datasets: dict[str, list[float]] = defaultdict(list)
    for (engine, dataset), g in sorted(groups.items()):
        errs = g["ins"] + g["dele"] + g["sub"]
        wer = errs / g["ref"] * 100 if g["ref"] else 0.0
        per_engine_datasets[engine].append(wer)
        pu = g["per_utt"]
        fail = sum(1 for w in pu if w > args.fail_threshold) / len(pu) * 100 if pu else 0.0
        rtfx = (g["audio"] / g["proc"]) if g["proc"] else None
        row = dict(
            engine=engine, dataset=dataset, files=g["n"], ref_words=g["ref"],
            wer=wer, I=g["ins"], D=g["dele"], S=g["sub"],
            mean=statistics.mean(pu) * 100 if pu else 0.0,
            median=statistics.median(pu) * 100 if pu else 0.0,
            p90=percentile(pu, 0.90) * 100,
            fail_rate=fail, rtfx=rtfx,
            median_rtfx=statistics.median(g["rtfx"]) if g["rtfx"] else None,
        )
        ci = bootstrap_ci(g["pairs"], args.ci, args.seed)
        if ci:
            row["ci_low"], row["ci_high"] = ci
        rows.append(row)

    print(f"normalizer = {mode}\n")
    ci_hdr = f" {'95% CI WER':>14s}" if args.ci else ""
    hdr = (f"{'engine':22s} {'dataset':12s} {'files':>5s} {'WER%':>7s}{ci_hdr} "
           f"{'p90%':>6s} {'fail%':>6s} {'RTFx':>7s}   I/D/S")
    print(hdr); print("-" * len(hdr))
    for r in rows:
        rtfx = f"{r['rtfx']:.1f}" if r["rtfx"] else "   -"
        ci = f" [{r['ci_low']:5.2f},{r['ci_high']:5.2f}]" if args.ci else ""
        print(f"{r['engine']:22s} {r['dataset']:12s} {r['files']:5d} {r['wer']:7.2f}{ci} "
              f"{r['p90']:6.1f} {r['fail_rate']:6.1f} {rtfx:>7s}   {r['I']}/{r['D']}/{r['S']}")

    print("\nmacro-average WER across datasets (per engine):")
    macro = {}
    for engine, wers in sorted(per_engine_datasets.items()):
        m = statistics.mean(wers)
        macro[engine] = m
        print(f"  {engine:22s} {m:6.2f}%   ({len(wers)} dataset(s))")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump({"normalizer": mode, "rows": rows, "macro": macro}, fh, indent=2)
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
