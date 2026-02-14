# CLI Testing Guide

Use `macparakeet-cli` for fast, repeatable testing of core transcription and text-processing flows.

## Build Once

```bash
swift build --product macparakeet-cli
```

## Canonical Dev App Launch

Always launch the GUI from repo source when validating new UI work:

```bash
scripts/dev/run_app.sh
```

This script builds the latest debug binary, stops stale `/Applications`/`dist` app processes, and launches the current workspace build with build identity metadata.

## Core Modes

### 1) GUI-Parity Mode (recommended for behavior checks)

Uses app defaults for processing mode and YouTube audio retention.

```bash
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --mode app-default \
  --downloaded-audio app-default
```

### 2) Deterministic Mode (recommended for CI/agent reproducibility)

Explicitly pins behavior.

```bash
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --mode raw \
  --downloaded-audio delete
```

Or clean mode with retained downloads:

```bash
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --mode clean \
  --downloaded-audio keep
```

AI refinement mode (formal/email/code) with local Qwen3-8B:

```bash
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --mode formal \
  --downloaded-audio app-default
```

## Entitlements/Trial Gating Parity

Enable this only when validating license/trial behavior:

```bash
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --enforce-entitlements
```

Without `--enforce-entitlements`, the CLI runs core transcription without GUI gating.

## Useful Supporting Commands

### CLI health check

```bash
swift run macparakeet-cli health
swift run macparakeet-cli health --repair-models --repair-attempts 3
```

### Local model lifecycle commands

```bash
# Non-invasive status (does not force downloads)
swift run macparakeet-cli models status

# Status for one model
swift run macparakeet-cli models status --target stt
swift run macparakeet-cli models status --target llm

# Warm-up (single attempt by default; `--target all` attempts both models before returning)
swift run macparakeet-cli models warm-up --target all

# Repair (best-effort retry; default 3 attempts, sequential for `--target all`)
swift run macparakeet-cli models repair --target all
swift run macparakeet-cli models repair --target llm --attempts 5
```

### List recent dictations/transcriptions

```bash
swift run macparakeet-cli history dictations --limit 20
swift run macparakeet-cli history transcriptions --limit 20
```

### Search dictation history

```bash
swift run macparakeet-cli history search "keyword" --limit 20
```

### Text pipeline checks

```bash
swift run macparakeet-cli flow process "your text"
swift run macparakeet-cli flow words list
swift run macparakeet-cli flow snippets list
```

### Local LLM checks

```bash
swift run macparakeet-cli llm smoke-test --stats
swift run macparakeet-cli models warm-up --target llm
swift run macparakeet-cli llm generate "Summarize this paragraph in one sentence: ..."
swift run macparakeet-cli llm refine formal "quick unpolished draft"
swift run macparakeet-cli llm command "Translate to Spanish" "Hello, how are you?"
swift run macparakeet-cli llm chat "What are the main decisions?"
swift run macparakeet-cli llm chat "What blockers were mentioned?" \
  --transcript-file /path/to/transcript.txt \
  --stats
```

- If LLM commands report `Local AI runtime unavailable` with `default.metallib`, MLX shader resources are missing. Build/run with Xcode or `xcodebuild`, or run the packaged app so `mlx-swift_Cmlx.bundle` is present.
- For file/URL transcription from `swift run`, FFmpeg can come from your shell `PATH` in development. If needed, set `MACPARAKEET_FFMPEG_PATH=/absolute/path/to/ffmpeg`.

## Notes

- CLI validates core service behavior (STT, conversion, pipeline, persistence) but does **not** validate GUI-only flows (windowing/menu bar, hotkey overlay, accessibility-driven paste UX).
- Transcript chat GUI MVP is verified manually from the transcript detail screen:
  - Open any completed transcript in the app
  - Ask a question in the right-side chat panel
  - Confirm response appears in-thread
  - Confirm `Cmd+Return` sends from the composer
  - Confirm delivered assistant responses can be copied via the copy icon
  - For long transcripts, confirm bounded-context behavior still returns a response
  - Switch between transcripts and confirm threads remain isolated
  - Force an error (for example, temporarily break local model runtime) and confirm inline retry path
- For isolated testing, use a temporary DB:

```bash
swift run macparakeet-cli transcribe "<FILE>" --database /tmp/macparakeet-dev.db
```
