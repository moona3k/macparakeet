#!/usr/bin/env python3
"""Benchmark harness for the cleanup pipeline.

Runs 15+ messy dictation samples through each available mode and prints
p50/p95 latency plus before/after quality examples. Reports whether each
mode meets the 1s end-to-end target.

Modes tested:
  - rules:    deterministic (in-process)
  - llm-1.5b: Qwen2.5-1.5B-Instruct-4bit via daemon on socket
  - llm-3b:   Qwen2.5-3B-Instruct-4bit via daemon on socket (if running)

Usage:
  python3 bench_cleanup.py
  python3 bench_cleanup.py --socket-1.5b /tmp/m-1.5b.sock --socket-3b /tmp/m-3b.sock
  python3 bench_cleanup.py --quick   # subset, faster
"""

from __future__ import annotations

import argparse
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from macparakeet_cleanup.protocol import send_request  # noqa: E402
from macparakeet_cleanup.rules import clean_rules  # noqa: E402


SAMPLES: list[str] = [
    # 1 — short with simple fillers
    "um so I think we should probably uh ship the build today",
    # 2 — duplicate words
    "the the the meeting is at three thirty",
    # 3 — phrase repeat
    "I think I think we need to push the deadline back a week",
    # 4 — sentence restart with comma
    "can you, can you send me the link when you get a chance",
    # 5 — you know cluster
    "you know, the thing about this, you know, is that we're way behind schedule",
    # 6 — long rambly
    "okay so um basically what I want to do is uh I want to refactor the auth "
    "module because, you know, it's been getting kind of messy and I think I "
    "think we should we should probably split it into like three smaller files "
    "and then um yeah just clean up the imports while we're at it",
    # 7 — false starts (em-dashes)
    "the proposal — actually no — the spec doc has the right framing for this",
    # 8 — soft repetitive
    "hey can you grab me a coffee, just an americano, no milk no sugar thanks",
    # 9 — mid-sentence "like" should be preserved
    "I'm looking for something like Notion but lighter weight",
    # 10 — heavy filler density
    "um uh er like I mean we should um ship it ah and uh see what happens",
    # 11 — names + numbers must survive
    "tell Sarah the standup got moved to 9:15 and the demo is at 2 PM",
    # 12 — capitalization fix
    "i went to the store and i bought milk and i'm going home now",
    # 13 — punctuation spacing
    "first thing,second thing.third thing? yes",
    # 14 — restart with three-word prefix
    "we need to we need to update the deployment scripts before friday",
    # 15 — long with multiple repetitions
    "so the thing is, the thing is, we've been we've been working on this for "
    "I mean for like two months now and uh we still haven't shipped",
    # 16 — empty-ish (whitespace + filler only) — edge case
    "um uh hm",
    # 17 — already-clean input (should be near-noop)
    "Reschedule the design review to Thursday at 3 PM.",
    # 18 — question
    "uh wait, do you actually do you actually need this by friday or can it slip",
]


def percentile(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f, c = int(k), min(int(k) + 1, len(xs) - 1)
    if f == c:
        return xs[f]
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def bench_rules(samples: list[str]) -> tuple[list[float], list[str]]:
    times = []
    outs = []
    for s in samples:
        t0 = time.perf_counter()
        out = clean_rules(s)
        times.append((time.perf_counter() - t0) * 1000)
        outs.append(out)
    return times, outs


def bench_llm(samples: list[str], socket_path: str, *, max_tokens: int = 150,
              timeout: float = 5.0) -> tuple[list[float], list[str]]:
    times = []
    outs = []
    for s in samples:
        t0 = time.perf_counter()
        try:
            out = send_request(socket_path, s, max_tokens=max_tokens, timeout=timeout)
        except Exception as e:
            out = f"<error: {e}>"
        times.append((time.perf_counter() - t0) * 1000)
        outs.append(out)
    return times, outs


def daemon_alive(socket_path: str) -> bool:
    """Quick liveness check by sending a tiny request."""
    try:
        send_request(socket_path, "hi", max_tokens=4, timeout=3.0)
        return True
    except Exception:
        return False


def report(name: str, times: list[float]) -> None:
    if not times:
        print(f"  {name:<10}  (no data)")
        return
    p50 = percentile(times, 0.50)
    p95 = percentile(times, 0.95)
    mean = statistics.mean(times)
    meets_1s = "✓" if p95 < 1000 else "✗"
    print(f"  {name:<10}  p50={p50:7.1f}ms  p95={p95:7.1f}ms  mean={mean:7.1f}ms  "
          f"<1s p95: {meets_1s}")


def show_examples(samples: list[str], outs_by_mode: dict[str, list[str]],
                  indices: list[int]) -> None:
    print("\nQuality examples (before / after):")
    print("=" * 78)
    for i in indices:
        if i >= len(samples):
            continue
        print(f"\n[#{i+1}] INPUT:")
        print(f"  {samples[i]}")
        for mode, outs in outs_by_mode.items():
            if i < len(outs):
                print(f"  → {mode:<10}: {outs[i]}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--socket-1.5b", dest="sock_1_5",
                   default="/tmp/macparakeet-cleanup-1.5b.sock")
    p.add_argument("--socket-3b", dest="sock_3",
                   default="/tmp/macparakeet-cleanup-3b.sock")
    p.add_argument("--quick", action="store_true",
                   help="run on first 8 samples only")
    p.add_argument("--warmup", type=int, default=2,
                   help="warmup runs before timing each mode (excluded from stats)")
    args = p.parse_args()

    samples = SAMPLES[:8] if args.quick else SAMPLES

    print(f"Running benchmark on {len(samples)} samples "
          f"({args.warmup} warmup runs each).\n")

    outs_by_mode: dict[str, list[str]] = {}

    # Rules
    print("== rules ==")
    bench_rules(samples[: args.warmup])  # warmup
    times, outs = bench_rules(samples)
    outs_by_mode["rules"] = outs
    report("rules", times)

    # 1.5B
    print("\n== llm-1.5b ==")
    if daemon_alive(args.sock_1_5):
        # Warmup (exclude first responses).
        bench_llm(samples[: args.warmup], args.sock_1_5)
        times, outs = bench_llm(samples, args.sock_1_5)
        outs_by_mode["llm-1.5b"] = outs
        report("llm-1.5b", times)
    else:
        print(f"  daemon not reachable at {args.sock_1_5}; skipping")

    # 3B
    print("\n== llm-3b ==")
    if daemon_alive(args.sock_3):
        bench_llm(samples[: args.warmup], args.sock_3)
        times, outs = bench_llm(samples, args.sock_3)
        outs_by_mode["llm-3b"] = outs
        report("llm-3b", times)
    else:
        print(f"  daemon not reachable at {args.sock_3}; skipping")

    # Quality examples — pick a spread.
    show_examples(samples, outs_by_mode, indices=[0, 2, 5, 6, 11, 14])

    print("\nTarget: p95 < 1000ms end-to-end.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
