#!/usr/bin/env python3
"""Multilingual ASR scorer — WER for space-delimited languages, CER for CJK.

Consumes JSONL {"id","ref","hyp","lang","engine"} and, per (engine, lang),
reports the appropriate corpus metric:
  - **WER** (word edits / ref words) for space-delimited languages (en, ko, EU…)
  - **CER** (char edits / ref chars) for CJK (ja, zh/cmn) where word boundaries
    are not meaningful — the standard choice for those languages.

Normalization: Whisper `EnglishTextNormalizer` for English, `BasicTextNormalizer`
(lowercase + strip punctuation, language-agnostic) otherwise — applied identically
to ref and hyp, matching the Open ASR Leaderboard's multilingual track.

Usage:
    score_multi.py fleurs_*.jsonl
    score_multi.py --json out.json fleurs_*.jsonl
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
from collections import defaultdict

from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

_EN = EnglishTextNormalizer()
_BASIC = BasicTextNormalizer()
_CURLY = {"’": "'", "‘": "'", "“": '"', "”": '"', "，": ",", "。": ".", "、": ","}

# languages scored by character error rate (no reliable word boundaries / spacing).
# Korean is included: its spacing is inconsistent, so FLEURS Korean is conventionally
# character-scored — word-level WER is dominated by segmentation noise.
_CER_LANGS = {"ja", "ja_jp", "zh", "cmn", "cmn_hans_cn", "cmn_hant", "yue", "yue_hant_hk",
              "th", "th_th", "ko", "ko_kr"}


def lang_base(lang: str) -> str:
    return (lang or "").lower()


def is_cer(lang: str) -> bool:
    l = lang_base(lang)
    head = l.replace("-", "_").split("_")[0]  # ko_kr / zh-Hans / zho -> ko / zh / zho
    return l in _CER_LANGS or head in {"ja", "zh", "zho", "cmn", "yue", "th", "ko", "kor"}


def normalize(text: str, lang: str) -> str:
    for k, v in _CURLY.items():
        text = text.replace(k, v)
    if lang_base(lang).startswith("en"):
        return _EN(text)
    return _BASIC(text)


def tokens(text: str, lang: str) -> list[str]:
    n = normalize(text, lang)
    if is_cer(lang):
        return [c for c in n.replace(" ", "")]  # characters
    return n.split()


try:
    import jiwer

    _SPLIT = jiwer.Compose([jiwer.ReduceToListOfListOfWords()])

    def edits(ref: list[str], hyp: list[str]) -> tuple[int, int, int]:
        o = jiwer.process_words(" ".join(ref) or " ", " ".join(hyp) or " ",
                                reference_transform=_SPLIT, hypothesis_transform=_SPLIT)
        return o.insertions, o.deletions, o.substitutions
except Exception:
    def edits(ref: list[str], hyp: list[str]) -> tuple[int, int, int]:
        m, n = len(hyp), len(ref)
        dp = [[0] * (n + 1) for _ in range(m + 1)]
        for i in range(m + 1):
            dp[i][0] = i
        for j in range(n + 1):
            dp[0][j] = j
        for i in range(1, m + 1):
            for j in range(1, n + 1):
                dp[i][j] = dp[i - 1][j - 1] if hyp[i - 1] == ref[j - 1] else 1 + min(
                    dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
        i, j, ins, dele, sub = m, n, 0, 0, 0
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

    Each pair is (edits, ref_len); corpus rate = sum(edits)/sum(ref_len).
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
    ap.add_argument("--ci", type=int, default=0, metavar="N",
                    help="bootstrap N resamples for a 95%% CI on corpus WER/CER (0 = off)")
    ap.add_argument("--seed", type=int, default=1234, help="bootstrap RNG seed (determinism)")
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()

    groups: dict[tuple[str, str], dict] = defaultdict(
        lambda: dict(ins=0, dele=0, sub=0, ref=0, n=0, per=[], pairs=[]))
    for path in args.files:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                engine = r.get("engine", "engine?")
                lang = r.get("lang") or r.get("language") or "und"
                ref = tokens(r["ref"], lang)
                hyp = tokens(r.get("hyp") or "", lang)
                if not ref:
                    continue
                i, d, s = edits(ref, hyp)
                g = groups[(engine, lang)]
                g["ins"] += i; g["dele"] += d; g["sub"] += s
                g["ref"] += len(ref); g["n"] += 1
                g["per"].append((i + d + s) / len(ref))
                g["pairs"].append((i + d + s, len(ref)))

    rows = []
    ci_hdr = f" {'95% CI':>14s}" if args.ci else ""
    hdr = (f"{'engine':24s} {'lang':14s} {'metric':6s} {'files':>5s} {'err%':>7s}{ci_hdr} {'p90%':>6s}")
    print(hdr); print("-" * len(hdr))
    for (engine, lang), g in sorted(groups.items()):
        metric = "CER" if is_cer(lang) else "WER"
        err = (g["ins"] + g["dele"] + g["sub"]) / g["ref"] * 100 if g["ref"] else 0.0
        p90 = percentile(g["per"], 0.90) * 100
        ci = bootstrap_ci(g["pairs"], args.ci, args.seed)
        ci_str = f" [{ci[0]:5.2f},{ci[1]:5.2f}]" if ci else ""
        print(f"{engine:24s} {lang:14s} {metric:6s} {g['n']:5d} {err:7.2f}{ci_str} {p90:6.1f}")
        row = dict(engine=engine, lang=lang, metric=metric, files=g["n"], err=err)
        if ci:
            row["ci_low"], row["ci_high"] = ci
        rows.append(row)

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(rows, fh, indent=2)
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
