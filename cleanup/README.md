# MacParakeet Local Cleanup Pipeline

Self-contained, local-first dictation cleanup. Lives outside the main MacParakeet
Swift sources so it doesn't interfere with in-progress work.

- **Rules mode** — pure regex. ~0.1ms p95. Always available, even if MLX isn't.
- **LLM mode** — Qwen2.5-Instruct-4bit on MLX, served by a daemon over a Unix
  socket. ~200–360ms p95 once the model is loaded.
- **Auto mode** — rules for short/clean inputs, LLM only when the transcript is
  long, very repetitive, or full of false starts.

**Zero configuration.** Just run the CLI. If the daemon isn't running, the CLI
auto-spawns it detached, warms it up, and routes the request. If the daemon
sees no activity for 30 minutes, it exits on its own. The next CLI call brings
it back. No launchd plist, no service to manage.

The daemon is **lazy**: on boot it binds the socket immediately and does **not**
load the model. The first cleanup request triggers an in-process load
(~2.4s on Apple Silicon with weights cached for the 3B), or a `--warmup`
request loads it asynchronously so a real cleanup arriving moments later
runs warm.

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

## Run the daemon (optional — CLI auto-spawns it)

You normally don't need to run the daemon yourself. The CLI does it for you.
But if you want to run it manually (debugging, custom flags), the launcher is:

```bash
./bin/macparakeet-cleanupd \
  --socket ~/Library/Application\ Support/MacParakeet/cleanup.sock \
  --model mlx-community/Qwen2.5-3B-Instruct-4bit
```

The default socket path is `~/Library/Application Support/MacParakeet/cleanup.sock`
(overridable with `MACPARAKEET_CLEANUP_SOCKET`). Both the auto-spawn and the
manual launch use the same path, so they're interchangeable.

Useful flags:

| Flag                    | Default | What                                                     |
| ----------------------- | ------- | -------------------------------------------------------- |
| `--idle-exit-seconds N` | `1800`  | Process exits after N seconds of no cleanup activity     |
| `--eager-load`          | off     | Load the model on boot (skip lazy load)                  |
| `--debug`               | off     | Per-request log lines on stderr                          |

Model load takes ~2.4s for the 3B on Apple Silicon when weights are cached.
The daemon's socket is up within a few hundred ms — the model load happens
asynchronously on first request or `--warmup`.

Logs from auto-spawned daemons go to `~/Library/Logs/MacParakeet/cleanupd.log`.

## Call cleanup from MacParakeet

The CLI accepts text via stdin or argv and writes the cleaned text to stdout.
Nothing else is printed unless `--debug` is passed. If the daemon isn't running
yet, the CLI auto-spawns it (logs to `~/Library/Logs/MacParakeet/cleanupd.log`).

```bash
# auto mode (recommended) — picks rules vs LLM heuristically; spawns if needed
echo "um so I think I think we should ship today" | \
  ./bin/macparakeet-cleanup --mode auto

# force rules-only (no daemon ever touched)
./bin/macparakeet-cleanup --mode rules "um the the cat"

# force LLM, with explicit hard timeout
./bin/macparakeet-cleanup --mode llm --timeout 0.9 < transcript.txt

# warmup (fire-and-forget) — spawns daemon if needed, returns in ~50ms while
# the model loads asynchronously
./bin/macparakeet-cleanup --warmup

# disable auto-spawn (CLI fails fast if daemon is unreachable, instead of
# starting one)
./bin/macparakeet-cleanup --mode llm --no-spawn < transcript.txt
```

When the CLI auto-spawns a daemon, it sends a warmup and bumps that one run's
timeout to 5s so the cold-load latency doesn't trip the normal 0.9s deadline.
Subsequent runs hit the warm daemon and respect the normal timeout.

If `--mode llm` and the daemon is unreachable (e.g. with `--no-spawn`), the
CLI **falls back to rules** automatically so dictation still ships text. With
`--debug`, the fallback is logged to stderr.

### Roadmap: split prompt and transcript in the MacParakeet config UI

Today MacParakeet's "LLM cleanup" feature sends a single concatenated string
(prompt + transcript) on stdin. The cleanup CLI uses its own internal prompt
and treats stdin as raw transcript, so the integration only works if the
caller sends *only* the transcript.

Future work in MacParakeet: split the LLM-cleanup config into two fields —
"system prompt" (sent via a flag like `--prompt-file`) and "transcript"
(sent on stdin). Then the user can swap prompts without touching the cleanup
CLI, and our daemon can be a generic local LLM endpoint instead of a
cleanup-specific one.

### Roadmap: pre-warm from MacParakeet on listening start

The cold-load penalty (~2.4s on the 3B) only matters on the **first** cleanup
after the daemon boots or after the 30-minute idle-exit. The daemon exposes a
`--warmup` endpoint that returns in ~50ms while the model loads asynchronously,
**and** the warmup call itself auto-spawns the daemon if it isn't running.

The natural integration: when MacParakeet enters the "listening" state for
dictation, it shells out (fire-and-forget) to:

```bash
/path/to/cleanup/bin/macparakeet-cleanup --warmup &
```

By the time the user finishes speaking and the transcript is ready for cleanup
(typically several seconds later), the model is already warm. This makes the
LLM cleanup path consistently sub-second from the user's perspective, even on
the first cleanup of the day.

Suggested call sites in `Sources/MacParakeet/`:
- Whenever the dictation hotkey fires (start of recording).
- Whenever a meeting recording stops and is queued for cleanup.

This is a small change to the Swift app — kept out of scope here so this
folder stays self-contained.

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

49 tests covering: filler removal, duplicate word/phrase removal, sentence
restarts, spacing/punctuation, capitalization, meaning preservation, CLI
stdin/argv behavior, LLM fallback when the daemon is missing, lazy load,
async warmup, idle-exit (process self-termination), the `--warmup` CLI flag,
and CLI auto-spawn (stale-socket cleanup, detached launch, no-op when alive).

## Files

```
cleanup/
├── bin/
│   ├── macparakeet-cleanup       # CLI client
│   └── macparakeet-cleanupd      # daemon launcher
├── macparakeet_cleanup/
│   ├── cli.py                    # argparse, stdin/argv, mode dispatch, fallback
│   ├── daemon.py                 # Unix socket server, lazy load, idle-exit
│   ├── spawn.py                  # detached daemon launch + ensure_daemon()
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

Cold-loading Qwen2.5-3B-4bit takes ~2.4s after weights are cached and ~22s for
1.5B on first JIT. Inference itself is ~150–350ms. Per-call subprocess startup
would dominate the latency budget; the daemon keeps the model resident
between requests so the CLI's marginal cost is just a Unix-socket round-trip
and a single generation. With auto-spawn + idle-exit + warmup, the daemon
appears when needed, stays cheap while you're idle, and exits when truly
unused — no service to manage.

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
