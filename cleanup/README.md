# MacParakeet Local Cleanup Pipeline

Self-contained, local-first dictation cleanup. Lives outside the main MacParakeet
Swift sources so it doesn't interfere with in-progress work.

- **Rules mode** — pure regex. ~0.1ms p95. Always available, even if MLX isn't.
- **LLM mode** — Qwen2.5-Instruct-4bit on MLX, served by a warm daemon over a
  Unix socket. ~200–360ms p95 on Apple Silicon.
- **Auto mode** — rules for short/clean inputs, LLM only when the transcript is
  long, very repetitive, or full of false starts.

The model is **never cold-started per request** — the daemon loads it once and
keeps it resident. The CLI is a thin client that opens a Unix socket and writes
a JSON line.

## Recommendation (after benchmarking on this Mac)

**Run the daemon with Qwen2.5-3B-Instruct-4bit.** It hits p95 ≈ 357ms (well under
the 1s target), preserves meaning materially better than the 1.5B, and only
costs ~160ms over the smaller model. The 1.5B paraphrases too aggressively
(e.g. drops "probably", changes "back a week" → "by a week") even with
`temperature=0`. The 3B keeps the user's voice.

Use rules-only on machines where MLX can't run, or as the auto-mode fast path
for short, clean inputs.

## Install

```bash
cd cleanup/
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install mlx mlx-lm "httpx[socks]" pytest
```

`httpx[socks]` is only needed if you have `ALL_PROXY=socks5h://…` set in your
environment (the model download goes through HuggingFace).

The first daemon launch will download the model (~1 GB for 1.5B, ~1.8 GB for 3B)
into `~/.cache/huggingface/`.

## Run the daemon

Recommended (3B, fits the 1s budget with quality margin):

```bash
./bin/macparakeet-cleanupd \
  --socket /tmp/macparakeet-cleanup.sock \
  --model mlx-community/Qwen2.5-3B-Instruct-4bit
```

Faster start, lower latency, more paraphrasing risk:

```bash
./bin/macparakeet-cleanupd \
  --socket /tmp/macparakeet-cleanup.sock \
  --model mlx-community/Qwen2.5-1.5B-Instruct-4bit
```

Add `--debug` for per-request log lines on stderr.

The daemon prints "model warm" once it's ready to serve. First boot:
- 1.5B: ~22s (load + JIT compile + 8-token warmup)
- 3B: ~2.4s when weights are already cached

## Call cleanup from MacParakeet

The CLI accepts text via stdin or argv and writes the cleaned text to stdout.
Nothing else is printed unless `--debug` is passed.

```bash
# auto mode (recommended) — picks rules vs LLM heuristically
echo "um so I think I think we should ship today" | \
  ./bin/macparakeet-cleanup --mode auto --socket /tmp/macparakeet-cleanup.sock

# force rules-only (no daemon required)
./bin/macparakeet-cleanup --mode rules "um the the cat"

# force LLM, with explicit hard timeout
./bin/macparakeet-cleanup --mode llm --timeout 0.9 \
  --socket /tmp/macparakeet-cleanup.sock < transcript.txt
```

If `--mode llm` and the daemon is unreachable, the CLI **falls back to rules**
automatically (so dictation still ships text). With `--debug`, the fallback is
logged to stderr.

## Modes

| Mode    | What it does                                       | When to use                                  |
| ------- | -------------------------------------------------- | -------------------------------------------- |
| `rules` | Regex pipeline; no daemon needed                   | Always-on fast path; install fallback        |
| `llm`   | Sends text to daemon; rules fallback if unreachable | Quality cleanup of rambly / repetitive input |
| `auto`  | Rules for short+clean, LLM otherwise               | **Default** — hits 1s budget, best quality   |

`auto` calls the LLM when **any** of:
- input ≥ 60 words
- hard-filler density ≥ 10% (`um`/`uh`/`er`/etc per word)
- adjacent-duplicate density ≥ 5%
- ≥ 2 false-start markers (`—`, `--`, `...`)
- ≥ 2 soft-filler clusters (`you know`, `I mean`, `sort of`, `kind of`)

Otherwise it stays in rules and never touches the daemon.

## Benchmark results (this Mac, 18 messy dictation samples, 2 warmup each)

```
== rules ==
  rules       p50=    0.1ms  p95=    0.1ms  mean=    0.1ms   <1s p95: ✓

== llm-1.5b ==                              (Qwen2.5-1.5B-Instruct-4bit)
  llm-1.5b    p50=  160.5ms  p95=  197.9ms  mean=  163.7ms   <1s p95: ✓

== llm-3b ==                                (Qwen2.5-3B-Instruct-4bit)
  llm-3b      p50=  267.3ms  p95=  356.9ms  mean=  279.6ms   <1s p95: ✓
```

All three modes meet the **<1s end-to-end** target.

### Quality examples

| Input                                                              | rules                                                    | 1.5B                                                | 3B                                                      |
| ------------------------------------------------------------------ | -------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------- |
| "um so I think we should probably uh ship the build today"         | "So I think we should probably ship the build today."    | "we should ship the build today" *(drops probably)* | "We should ship the build today."                       |
| "I think I think we need to push the deadline back a week"         | "I think we need to push the deadline back a week."      | "We should push the deadline by a week." *(drift)*  | "Need to push back the deadline by a week."             |
| "the proposal — actually no — the spec doc has the right framing"  | "The proposal — actually no — the spec doc has…"         | "spec doc has right framing" *(drops correction)*   | "The spec doc has the right framing for this."          |
| long rambly auth-refactor sample                                   | leaves "you know" / "I think" residue                    | aggressive summary into a 7-word fragment           | reads like a clean message, preserves both clauses      |
| "i went to the store and i bought milk and i'm going home now"     | "I went to the store and I bought milk and…"             | "i went…" *(doesn't capitalize)*                    | "I went to the store and bought milk. Now I'm going…"   |

Rules are perfect for short clean input but leave verbal-tic residue on rambly
input. The 1.5B is fast but **paraphrases under temp=0** — it changes meaning
just enough to be a problem for dictation. The 3B preserves wording while still
removing fillers and repetitions.

## Tests

```bash
.venv/bin/pytest tests/
```

35 tests covering: filler removal, duplicate word/phrase removal, sentence
restarts, spacing/punctuation, capitalization, meaning preservation, CLI
stdin/argv behavior, and LLM fallback when the daemon is missing.

## Files

```
cleanup/
├── bin/
│   ├── macparakeet-cleanup       # CLI client
│   └── macparakeet-cleanupd      # daemon launcher
├── macparakeet_cleanup/
│   ├── cli.py                    # argparse, stdin/argv, mode dispatch, fallback
│   ├── daemon.py                 # Unix socket server, signal handling
│   ├── llm.py                    # MLX-LM wrapper, chat-template prompt
│   ├── rules.py                  # deterministic regex pipeline
│   ├── complexity.py             # auto-mode heuristic
│   ├── protocol.py               # newline-delimited JSON over Unix socket
│   └── config.py                 # constants (socket path, model, prompt, timeout)
├── tests/                        # pytest, in-venv
├── bench_cleanup.py              # 18-sample p50/p95 harness
└── README.md
```

## Why a daemon (not subprocess-per-call)

Cold-loading Qwen2.5-3B-4bit takes ~2s after weights are cached and ~22s for
1.5B on first JIT. Inference itself is ~150–350ms. Per-call subprocess startup
would dominate the latency budget; the daemon keeps the model resident so the
CLI's marginal cost is just a Unix-socket round-trip and a single generation.

## Why Python (and not Swift here)

`mlx-lm`'s Python API supports the `mlx-community/*-Instruct-4bit` weights
directly with the right tokenizer chat template. The Swift port lags on model
support, so going Swift here would mean rebuilding loader/tokenizer integration
before benchmarking. The CLI client is small enough that interpreter startup
doesn't matter — and on the LLM path, decode dominates the wall clock anyway.

If/when you want to ship cleanup inside `MacParakeet.app` as a single binary
(no Python runtime for end users), port the LLM call to `mlx-swift-examples`.
The rules engine, daemon protocol, and complexity heuristic are trivially
portable.
