# CLI Testing Guide

> Status: **ACTIVE** - CLI testing guide for core services

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

## Complete Command Reference

```
macparakeet-cli
├── transcribe <input> [options]         Transcribe a file or YouTube URL
├── history                              View and manage history
│   ├── dictations [--limit]             List recent dictations (default)
│   ├── transcriptions [--limit]         List recent transcriptions
│   ├── search <query> [--limit]         Search dictation history
│   ├── search-transcriptions <query> [--limit]  Search transcriptions by keyword
│   ├── delete-dictation <id>            Delete a dictation by ID
│   ├── delete-transcription <id>        Delete a transcription by ID
│   ├── favorites                        List favorite transcriptions
│   ├── favorite <id>                    Mark a transcription as favorite
│   └── unfavorite <id>                  Remove from favorites
├── export <id> [options]                Export a transcription to file
├── stats                                Show voice stats dashboard
├── health [--repair-models]             System health and model status
├── models                               Speech model lifecycle
│   ├── status                           Show model status
│   ├── warm-up [--attempts]             Warm up speech model
│   ├── repair [--attempts]              Best-effort model repair
│   └── clear                            Delete cached models
├── flow                                 Text processing pipeline
│   ├── process <text> [--copy]          Run clean text processing
│   ├── words {list,add,delete}          Manage custom words
│   └── snippets {list,add,delete}       Manage text snippets
├── llm                                  LLM provider commands
│   ├── test-connection                  Test provider connectivity
│   ├── summarize <input>                Summarize text via LLM
│   ├── chat <input> --question          Ask about a transcript
│   └── transform <input> --prompt       Apply custom LLM transform
└── feedback <message> [options]         Submit feedback
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

### Speaker Diarization

Diarization runs by default when transcribing. Disable with:

```bash
swift run macparakeet-cli transcribe "<FILE>" --no-diarize
```

### Output Formats

```bash
# Plain text output (default)
swift run macparakeet-cli transcribe "<FILE>"

# JSON output (full Transcription object)
swift run macparakeet-cli transcribe "<FILE>" --format json
```

## Legacy Entitlements Parity

Use this only when exercising the same entitlement check path the GUI uses:

```bash
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --enforce-entitlements
```

On the current branch, the app is effectively unlocked, so `--enforce-entitlements` should still pass unless you are explicitly validating legacy licensing code.

## Export

Export a transcription by its UUID (or UUID prefix). Supported formats: txt, markdown, srt, vtt, json.

```bash
# List transcriptions to find the ID
swift run macparakeet-cli history transcriptions

# Export to various formats
swift run macparakeet-cli export <ID> --format txt --output transcript.txt
swift run macparakeet-cli export <ID> --format srt --output subtitles.srt
swift run macparakeet-cli export <ID> --format vtt
swift run macparakeet-cli export <ID> --format markdown
swift run macparakeet-cli export <ID> --format json

# Print to stdout instead of writing a file
swift run macparakeet-cli export <ID> --format srt --stdout
```

If `--output` is omitted, the file is written to the current directory with an auto-generated name.

**Note:** PDF and DOCX export require AppKit and are only available in the GUI.

## Stats

```bash
swift run macparakeet-cli stats
```

Shows dictation stats (total, words, duration, WPM, streak, equivalents) and transcription counts.

## History Management

### List and Search

```bash
swift run macparakeet-cli history dictations --limit 20
swift run macparakeet-cli history transcriptions --limit 20
swift run macparakeet-cli history search "keyword" --limit 20
swift run macparakeet-cli history search-transcriptions "keyword" --limit 20
```

### Delete

```bash
swift run macparakeet-cli history delete-dictation <ID>
swift run macparakeet-cli history delete-transcription <ID>
```

IDs support UUID prefix matching (e.g., `3a7b` matches `3a7b1234-...`).

### Favorites

```bash
swift run macparakeet-cli history favorites
swift run macparakeet-cli history favorite <ID>
swift run macparakeet-cli history unfavorite <ID>
```

## Health Check

```bash
swift run macparakeet-cli health
swift run macparakeet-cli health --repair-models --repair-attempts 3
```

## Speech Model Lifecycle

```bash
# Non-invasive status (does not force downloads)
swift run macparakeet-cli models status

# Warm-up (single attempt by default)
swift run macparakeet-cli models warm-up

# Repair (best-effort retry; default 3 attempts)
swift run macparakeet-cli models repair
swift run macparakeet-cli models repair --attempts 5

# Delete cached models
swift run macparakeet-cli models clear
```

## Text Pipeline

```bash
swift run macparakeet-cli flow process "your text"
swift run macparakeet-cli flow process "your text" --copy   # also copies to clipboard

swift run macparakeet-cli flow words list
swift run macparakeet-cli flow words add "macparakeet" "MacParakeet"
swift run macparakeet-cli flow words add "hmm"              # vocabulary anchor (no replacement)
swift run macparakeet-cli flow words delete <ID>

swift run macparakeet-cli flow snippets list
swift run macparakeet-cli flow snippets add "my signature" "Best regards, Daniel"
swift run macparakeet-cli flow snippets delete <ID>
```

## LLM Commands

All LLM commands require `--provider` and `--api-key` (except Ollama and Local CLI).

### Supported Providers

| Provider | Default Model | API Key Required |
|----------|--------------|-----------------|
| `anthropic` | claude-sonnet-4-6 | Yes |
| `openai` | gpt-4.1 | Yes |
| `gemini` | gemini-2.5-flash | Yes |
| `openrouter` | anthropic/claude-sonnet-4 | Yes |
| `ollama` | qwen3.5:4b | No (local) |
| `cli` | N/A (tool decides) | No (tool manages auth) |

### Test Connection

```bash
swift run macparakeet-cli llm test-connection \
  --provider openai --api-key sk-...
```

### Summarize

```bash
swift run macparakeet-cli llm summarize transcript.txt \
  --provider anthropic --api-key sk-ant-...

# Stream output token-by-token
swift run macparakeet-cli llm summarize transcript.txt \
  --provider anthropic --api-key sk-ant-... --stream

# Read from stdin
echo "Long text..." | swift run macparakeet-cli llm summarize - \
  --provider anthropic --api-key sk-ant-...
```

### Chat (Q&A about a transcript)

```bash
swift run macparakeet-cli llm chat transcript.txt \
  --provider openai --api-key sk-... \
  --question "What were the key points?"
```

### Transform (custom instruction)

```bash
swift run macparakeet-cli llm transform transcript.txt \
  --provider anthropic --api-key sk-ant-... \
  --prompt "Translate to Spanish"
```

### Common Options

All LLM commands accept these additional options:

- `--model <name>` — Override default model
- `--base-url <url>` — Custom API endpoint (http:// or https://)
- `--stream` — Stream response token-by-token (summarize, chat, transform)
- `--command <cmd>` — CLI command template (Local CLI provider only)

### Local CLI Provider

```bash
# Test a CLI tool
swift run macparakeet-cli llm test-connection --provider cli --command "claude -p --model haiku"

# Summarize via Claude Code
swift run macparakeet-cli llm summarize transcript.txt --provider cli --command "claude -p --model haiku"

# Use Codex
swift run macparakeet-cli llm summarize transcript.txt --provider cli --command "codex exec --model gpt-5.4-mini"

# Custom command
swift run macparakeet-cli llm chat transcript.txt --provider cli --command "my-tool --stdin" --question "Key points?"
```

## Feedback

```bash
swift run macparakeet-cli feedback "The export feature is great" --category feature
swift run macparakeet-cli feedback "Found a bug with..." --category bug --email user@example.com
```

Categories: `bug`, `feature`, `other` (default).

## Notes

- CLI validates core service behavior (STT, conversion, pipeline, persistence, export, LLM, history management) but does **not** validate GUI-only flows (windowing/menu bar, hotkey overlay, accessibility-driven paste UX, PDF/DOCX export, media playback).
- For isolated testing, use a temporary DB:

```bash
swift run macparakeet-cli transcribe "<FILE>" --database /tmp/macparakeet-dev.db
```

- For file/URL transcription from `swift run`, FFmpeg can come from your shell `PATH` in development. If needed, set `MACPARAKEET_FFMPEG_PATH=/absolute/path/to/ffmpeg`.
