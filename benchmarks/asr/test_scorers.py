#!/usr/bin/env python3
"""Correctness tests for the ASR scorers — run: python3 test_scorers.py

Verifies the metric math (WER/CER edit counting, corpus aggregation), the
normalizer contract we depend on (number/contraction/British folding, curly
apostrophes, CJK char-tokenization + spacing robustness), and bootstrap CI
determinism — against hand-computed values and an independent Levenshtein.

Pure-Python, no pytest. Exits non-zero on any failure.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import score
import score_multi
import paired_delta

_fails: list[str] = []


def check(name: str, got, want) -> None:
    if got == want:
        print(f"  ok   {name}")
    else:
        _fails.append(name)
        print(f"  FAIL {name}: got {got!r} want {want!r}")


def approx(name: str, got: float, want: float, tol: float = 1e-9) -> None:
    if abs(got - want) <= tol:
        print(f"  ok   {name} ({got:.4f})")
    else:
        _fails.append(name)
        print(f"  FAIL {name}: got {got!r} want {want!r}")


def ref_levenshtein(a: list[str], b: list[str]) -> int:
    """Independent total edit distance, to cross-check edit_counts (I+D+S)."""
    m, n = len(a), len(b)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, n + 1):
            cur = dp[j]
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
            prev = cur
    return dp[n]


def corpus_wer(pairs: list[tuple[list[str], list[str]]], edit_counts) -> float:
    """Corpus WER = sum(edits)/sum(ref words) — mirrors score.main()."""
    edits = refs = 0
    for hyp, ref in pairs:
        i, d, s = edit_counts(hyp, ref)
        edits += i + d + s
        refs += len(ref)
    return edits / refs * 100 if refs else 0.0


# --- 1. edit-count polarity (insertions/deletions/substitutions) ----------
def test_edit_counts():
    print("edit_counts polarity (hyp, ref):")
    ec = score.edit_counts
    check("perfect", ec(["a", "b", "c"], ["a", "b", "c"]), (0, 0, 0))
    check("one substitution", ec(["a", "x", "c"], ["a", "b", "c"]), (0, 0, 1))
    check("one deletion (missing from hyp)", ec(["a", "c"], ["a", "b", "c"]), (0, 1, 0))
    check("one insertion (extra in hyp)", ec(["a", "b", "c", "d"], ["a", "b", "c"]), (1, 0, 0))
    check("empty hyp = all deletions", ec([], ["a", "b", "c"]), (0, 3, 0))


# --- 2. cross-check total edits vs independent Levenshtein -----------------
def test_total_edits_match_levenshtein():
    print("edit_counts total == independent Levenshtein:")
    cases = [
        (["the", "cat"], ["the", "dog"]),
        (["a", "b", "c", "d"], ["a", "x", "c"]),
        (["one", "two", "three"], ["one", "three", "four", "five"]),
        ([], ["a"]),
        (["a", "b", "c"], []),
        (list("kitten"), list("sitting")),  # classic: distance 3
    ]
    for hyp, ref in cases:
        got = sum(score.edit_counts(hyp, ref))
        want = ref_levenshtein(hyp, ref)
        check(f"total({hyp}|{ref})", got, want)
    check("kitten/sitting distance", sum(score.edit_counts(list("kitten"), list("sitting"))), 3)


# --- 3. WER via canonical + simple normalizer -----------------------------
def test_wer_end_to_end():
    print("WER end-to-end:")
    simple = score.make_normalizer("simple")
    canon = score.make_normalizer("canonical")
    # 1 substitution in a 6-word reference = 16.667%
    approx("simple 1-sub/6", corpus_wer(
        [(simple("the dog sat on the mat"), simple("the cat sat on the mat"))],
        score.edit_counts), 100 / 6)
    # corpus != mean: utt1 fully wrong (1 word), utt2 perfect (9 words) -> 1/10 = 10%
    pairs = [(simple("y"), simple("x")),
             (simple("a b c d e f g h i"), simple("a b c d e f g h i"))]
    approx("corpus aggregation (1/10)", corpus_wer(pairs, score.edit_counts), 10.0)
    # canonical normalizer folds equivalents -> 0 WER
    approx("number-word folding (twenty==20)", corpus_wer(
        [(canon("i have 20 apples"), canon("i have twenty apples"))], score.edit_counts), 0.0)
    approx("contraction folding (don't==do not)", corpus_wer(
        [(canon("i do not go"), canon("i don't go"))], score.edit_counts), 0.0)
    approx("British->American (colour==color)", corpus_wer(
        [(canon("the color"), canon("the colour"))], score.edit_counts), 0.0)


# --- 4. normalizer contract (token-level) ---------------------------------
def test_normalizer_contract():
    print("normalizer contract:")
    canon = score.make_normalizer("canonical")
    simple = score.make_normalizer("simple")
    check("number word", canon("twenty"), canon("20"))
    check("contraction", canon("don't"), canon("do not"))
    check("abbreviation Mr.", canon("Mr. Smith"), canon("mister smith"))
    check("British spelling", canon("colour"), canon("color"))
    # curly apostrophe pre-pass: curly and straight must be identical (and both
    # become "it is"). Without the pre-pass the curly form degrades to "it s".
    check("curly == straight apostrophe", canon("it’s"), canon("it's"))
    check("curly apostrophe -> contraction", canon("it’s"), ["it", "is"])
    check("simple keeps intra-word apostrophe", simple("don't"), ["don't"])
    check("simple strips edge apostrophes/punct", simple("'Quoted,'"), ["quoted"])
    # the simple normalizer must also fold curly apostrophes (else contractions
    # split and WER inflates) — same contract as canonical.
    check("simple folds curly apostrophe", simple("don’t"), simple("don't"))
    check("simple curly -> single token", simple("don’t"), ["don't"])


# --- 5. CER for CJK + Korean ----------------------------------------------
def test_cer():
    print("CER (CJK + Korean):")
    check("is_cer ja", score_multi.is_cer("ja"), True)
    check("is_cer ja_jp", score_multi.is_cer("ja_jp"), True)
    check("is_cer zh/cmn", score_multi.is_cer("cmn_hans_cn"), True)
    check("is_cer ko", score_multi.is_cer("ko"), True)
    check("is_cer ko_kr", score_multi.is_cer("ko_kr"), True)
    check("is_cer en (WER)", score_multi.is_cer("en"), False)
    check("is_cer de (WER)", score_multi.is_cer("de"), False)
    check("is_cer zho (639-3)", score_multi.is_cer("zho"), True)
    check("is_cer zh-Hans", score_multi.is_cer("zh-Hans"), True)
    check("is_cer kor (639-3)", score_multi.is_cer("kor"), True)
    # char tokenization + spacing robustness
    check("CJK char tokens", score_multi.tokens("我喜欢", "zh"),
          ["我", "喜", "欢"])
    check("CER strips spaces", score_multi.tokens("我 喜 欢", "zh"),
          score_multi.tokens("我喜欢", "zh"))
    # hand-computed CER: 我喜欢音乐 -> 我喜欢声音 = 2 edits / 5 chars = 40%
    ref = score_multi.tokens("我喜欢音乐", "ja")
    hyp = score_multi.tokens("我喜欢声音", "ja")
    i, d, s = score_multi.edits(ref, hyp)
    approx("ja CER 2/5=40%", (i + d + s) / len(ref) * 100, 40.0)
    # Korean: 안녕하세요 -> 안녕히세요 = 1 edit / 5 = 20%
    ref = score_multi.tokens("안녕하세요", "ko")
    hyp = score_multi.tokens("안녕히세요", "ko")
    i, d, s = score_multi.edits(ref, hyp)
    approx("ko CER 1/5=20%", (i + d + s) / len(ref) * 100, 20.0)
    # English inside the multilingual scorer is WER (space tokens)
    check("en uses word tokens", score_multi.tokens("the cat", "en_us"), ["the", "cat"])


# --- 6. bootstrap CI determinism + sanity ---------------------------------
def test_bootstrap():
    print("bootstrap CI:")
    pairs = [(1, 10), (0, 8), (3, 12), (2, 9), (0, 11), (4, 7), (1, 6), (0, 10)]
    a = score.bootstrap_ci(pairs, 500, seed=1234)
    b = score.bootstrap_ci(pairs, 500, seed=1234)
    check("deterministic (same seed)", a, b)
    check("off when n_boot=0", score.bootstrap_ci(pairs, 0, seed=1234), None)
    check("off when empty", score.bootstrap_ci([], 500, seed=1234), None)
    point = sum(e for e, _ in pairs) / sum(r for _, r in pairs) * 100
    lo, hi = a
    check("point estimate within CI", lo <= point <= hi, True)
    check("lo <= hi", lo <= hi, True)
    # zero-error corpus -> zero-width CI at 0
    check("all-correct CI is (0,0)", score.bootstrap_ci([(0, 5), (0, 7)], 200, seed=1), (0.0, 0.0))
    check("score_multi bootstrap matches score", score_multi.bootstrap_ci(pairs, 500, 1234),
          score.bootstrap_ci(pairs, 500, 1234))


def test_paired_bootstrap():
    print("paired bootstrap (engine-vs-engine delta):")
    # A consistently better (1 vs 3 edits / 10 words) -> Δ = -20pt, CI all negative
    rows = [(1, 3, 10)] * 50
    p, lo, hi = paired_delta.paired_bootstrap(rows, 500, seed=1234)
    approx("paired point estimate (A-B)", p, -20.0)
    check("paired CI excludes 0 (A better)", hi < 0, True)
    # identical engines -> Δ = 0, zero-width CI
    rows2 = [(2, 2, 10), (0, 0, 8), (1, 1, 5)]
    p2, lo2, hi2 = paired_delta.paired_bootstrap(rows2, 500, seed=1234)
    approx("paired identical -> 0", p2, 0.0)
    check("paired identical CI is (0,0)", (round(lo2, 6), round(hi2, 6)), (0.0, 0.0))
    check("paired deterministic (same seed)",
          paired_delta.paired_bootstrap(rows, 300, 7), paired_delta.paired_bootstrap(rows, 300, 7))
    check("paired off when n_boot=0", paired_delta.paired_bootstrap(rows, 0, 1)[1], None)


def main() -> int:
    for t in (test_edit_counts, test_total_edits_match_levenshtein, test_wer_end_to_end,
              test_normalizer_contract, test_cer, test_bootstrap, test_paired_bootstrap):
        t()
    print()
    if _fails:
        print(f"FAILED {len(_fails)}: {', '.join(_fails)}")
        return 1
    print("all scorer tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
