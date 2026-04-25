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
│   ├── dictations [--limit] [--json]    List recent dictations (default)
│   ├── transcriptions [--limit] [--json]  List recent transcriptions
│   ├── search <query> [--limit] [--json]  Search dictation history
│   ├── search-transcriptions <query> [--limit] [--json]  Search transcriptions
│   ├── delete-dictation <id>            Delete a dictation by ID
│   ├── delete-transcription <id>        Delete a transcription by ID
│   ├── favorites [--json]               List favorite transcriptions
│   ├── favorite <id>                    Mark a transcription as favorite
│   └── unfavorite <id>                  Remove from favorites
├── export <id> [options]                Export a transcription to file
├── stats [--json]                       Show voice stats dashboard
├── health [--repair-models] [--json]    System health and model status
├── models                               Speech model lifecycle
│   ├── status [--json]                  Show model status
│   ├── warm-up [--attempts]             Warm up speech model
│   ├── repair [--attempts]              Best-effort model repair
│   └── clear                            Delete cached models
├── flow                                 Text processing pipeline
│   ├── process <text> [--copy]          Run clean text processing
│   ├── words {list,add,delete}          Manage custom words
│   │   └── list [--source manual|learned|all] [--json]
│   └── snippets {list,add,delete}       Manage text snippets
│       └── list [--json]
├── llm                                  LLM provider commands
│   ├── test-connection                  Test provider connectivity
│   ├── summarize <input>                Summarize text via LLM
│   ├── chat <input> --question          Ask about a transcript
│   └── transform <input> --prompt       Apply custom LLM transform
├── prompts                              Manage prompt library
│   ├── list [--filter all|visible|auto-run] [--json]
│   ├── show <id-or-name> [--json]
│   ├── add --name X (--content Y | --from-file path) [--auto-run]
│   ├── set <id-or-name> [--visible|--hidden] [--auto-run|--no-auto-run]
│   ├── delete <id-or-name>              Delete custom prompt (built-ins protected)
│   ├── restore-defaults                 Re-show all built-in prompts
│   └── run <id-or-name> --transcription <id> [--no-store] [--stream] [--extra ...]
└── feedback <message> [options]         Submit feedback
```

> **JSON output convention**: any query command marked `[--json]` emits a single
> JSON document on stdout (ISO-8601 dates, sorted keys, pretty-printed). Pipe to
> `jq` or any JSON tool. Side-effect commands (delete, favorite, etc.) print one
> confirmation line and don't accept `--json`.

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

All LLM commands require `--provider` and `--api-key` (except Ollama, LM Studio, and Local CLI).

### Supported Providers

| Provider | Default Model | API Key Required |
|----------|--------------|-----------------|
| `anthropic` | claude-sonnet-4-6 | Yes |
| `openai` | gpt-4.1 | Yes |
| `gemini` | gemini-2.5-flash | Yes |
| `openrouter` | anthropic/claude-sonnet-4 | Yes |
| `ollama` | qwen3.5:4b | No (local) |
| `lmstudio` | user-selected in LM Studio | No (local) |
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

### LM Studio Provider

```bash
# Test a local LM Studio server
swift run macparakeet-cli llm test-connection --provider lmstudio --model qwen3.5-27b

# Summarize via LM Studio's OpenAI-compatible endpoint
swift run macparakeet-cli llm summarize transcript.txt --provider lmstudio --model qwen3.5-27b
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

## Prompt Library

The prompt library powers multi-summary results in the GUI. The CLI lets you
seed test prompts, audit migration state, and exercise the summary write path
without launching the app.

### List, show, add

```bash
# Lists default to "all"; --filter narrows to visible-only or auto-run-only.
swift run macparakeet-cli prompts list
swift run macparakeet-cli prompts list --filter auto-run --json | jq '.[].name'

# Show full content. <id-or-name> accepts UUID, UUID prefix, or exact name.
swift run macparakeet-cli prompts show "Summary"
swift run macparakeet-cli prompts show A4882688

# Add a custom prompt. Body precedence: --content > --from-file > stdin.
swift run macparakeet-cli prompts add --name "Daily Notes" \
  --content "Extract action items grouped by person."
swift run macparakeet-cli prompts add --name "From File" --from-file ./prompt.md

# Pipe via stdin when both --content and --from-file are omitted.
cat ./prompt.md | swift run macparakeet-cli prompts add --name "Piped"
```

### Visibility / auto-run toggles

`set` accepts mutually exclusive flag pairs. Hidden implies not auto-run; auto-run
implies visible — these invariants are enforced.

```bash
swift run macparakeet-cli prompts set "Daily Notes" --auto-run
swift run macparakeet-cli prompts set "Daily Notes" --hidden
swift run macparakeet-cli prompts set "Summary" --no-auto-run
```

### Delete and restore

```bash
swift run macparakeet-cli prompts delete "Daily Notes"
swift run macparakeet-cli prompts restore-defaults   # re-shows hidden built-ins
```

Built-in prompts cannot be deleted; the CLI surfaces a clear error and suggests
`prompts set <name> --hidden` instead.

### Run a prompt against a transcription

`prompts run` calls the configured LLM provider with the prompt as system message
and the transcription text as input. By default it persists the result to the
`summaries` table so the GUI sees it on the next reload.

```bash
swift run macparakeet-cli prompts run "Summary" \
  --transcription <transcription-id> \
  --provider anthropic --api-key sk-ant-...

# Stream output and skip persistence (preview-only)
swift run macparakeet-cli prompts run "Action Items & Decisions" \
  --transcription a3f7 \
  --provider openai --api-key sk-... \
  --stream --no-store

# Add per-run instructions (mirrors the GUI's regenerate-with-extra flow)
swift run macparakeet-cli prompts run "Blog Post" \
  --transcription a3f7 \
  --provider anthropic --api-key sk-ant-... \
  --extra "Tone: warm and direct. Audience: engineers."
```

`prompts run` writes the model output to **stdout** and the "Saved PromptResult X"
confirmation to **stderr**, so `> result.txt` captures only the prompt output.

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
