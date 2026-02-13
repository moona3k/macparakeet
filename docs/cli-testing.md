# CLI Testing Guide

Use `macparakeet-cli` for fast, repeatable testing of core transcription and text-processing flows.

## Build Once

```bash
swift build --product macparakeet-cli
```

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
swift run macparakeet-cli llm generate "Summarize this paragraph in one sentence: ..."
swift run macparakeet-cli llm refine formal "quick unpolished draft"
swift run macparakeet-cli llm command "Translate to Spanish" "Hello, how are you?"
swift run macparakeet-cli llm chat "What are the main decisions?"
swift run macparakeet-cli llm chat "What blockers were mentioned?" \
  --transcript-file /path/to/transcript.txt \
  --stats
```

## Notes

- CLI validates core service behavior (STT, conversion, pipeline, persistence) but does **not** validate GUI-only flows (windowing/menu bar, hotkey overlay, accessibility-driven paste UX).
- For isolated testing, use a temporary DB:

```bash
swift run macparakeet-cli transcribe "<FILE>" --database /tmp/macparakeet-dev.db
```
