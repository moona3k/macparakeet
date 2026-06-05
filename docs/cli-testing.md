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
├── transcribe <input...> [options]      Transcribe files, folders, or media URLs
│   ├── --format text|transcript|json [--no-history]
│   └── --engine app-default|parakeet|whisper [--language <code>]
│       --parakeet-model app-default|v3|v2 [--output-dir DIR]
│       --speaker-detection app-default|on|off
│       [--speaker-count N | --speaker-min N [--speaker-max N] | --speaker-max N]
│       --youtube-audio-quality app-default|m4a|best-available
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
├── config                               Shared app/CLI preferences
│   ├── list
│   ├── get <key>
│   └── set <key> <value>
├── health [--repair-models] [--repair-binaries] [--json]
│                                         System health and model/helper status
├── models                               Speech model lifecycle
│   ├── list [--json]                    List selectable speech models
│   ├── select <model-id> [--json]       Set shared app/CLI speech default
│   ├── status [--json]                  Show model status
│   ├── download <model-id>              Download explicit model (Whisper)
│   ├── warm-up [--attempts]             Warm up speech model
│   ├── repair [--attempts]              Best-effort model repair
│   └── clear                            Delete cached models
├── vocab, flow                          Text processing pipeline (`flow` is deprecated)
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
├── quick-prompts                        Manage live meeting Ask quick prompts
│   ├── list [--pinned true|false] [--visible-only] [--json]
│   ├── show <id-or-label> [--json]
│   ├── add --label X (--prompt Y | --from-file path) [--group X] [--pinned] [--hidden]
│   ├── set <id-or-label> [--label X] [--prompt Y] [--group X] [--sort-order N] [--visible|--hidden]
│   ├── delete <id-or-label>
│   ├── pin <id-or-label> / unpin <id-or-label>
│   ├── restore-defaults [--id UUID]
│   └── export [--out path] [--pinned true|false] [--include-builtins] / import <path> [--mode merge|replace]
├── transforms                           Manage and run saved Transforms
│   ├── list [--json]
│   ├── show <id-or-name> [--json]
│   ├── run <id-or-name> --input FILE|- [--stream] [--json]
│   ├── create --name X (--prompt Y | --from-file path) [--shortcut opt+1] [--json]
│   ├── delete <id-or-name> [--json]
│   └── history {list,show,delete,clear} [--json]
├── meetings                             Inspect and manage local meeting recordings
│   ├── list [--limit] [--json]
│   ├── show <meeting> [--json]
│   ├── transcript <meeting> [--format text|json|srt|vtt]
│   ├── notes {get,set,append,clear} <meeting>
│   └── export <meeting> [--format md|json] [--stdout]
├── calendar
│   └── upcoming [--days N] [--filter link|participants|all] [--json]
├── meeting-vad-sim <audio> [--mode fixed|vad|both] [--json]
│                                         Dev replay of fixed vs VAD live chunking
└── feedback <message> [options]         Submit feedback
```

`flow` is a compatibility alias for `vocab` in the CLI 2.x line. Use `vocab` in new
scripts; the alias remains documented here only while the CLI still exposes it.

> **JSON output convention**: any query command marked `[--json]` emits a single
> JSON document on stdout (ISO-8601 dates, sorted keys, pretty-printed). Pipe to
> `jq` or any JSON tool. Side-effect commands generally print a confirmation line;
> a few newer meeting-note commands also accept `--json` for agent workflows.

> **Telemetry convention**: CLI telemetry uses the same opt-out preference as
> the GUI and does not change stdout/stderr contracts. After argument parsing
> succeeds, the root runner emits one privacy-safe `cli_operation` event with
> command, subcommand, outcome, duration, exit code, and low-cardinality error
> type. `transcribe` also includes coarse input kind and output format. Disable
> with `MACPARAKEET_TELEMETRY=0`, `DO_NOT_TRACK=1`, or
> `macparakeet-cli config set telemetry off`.

## Core Modes

### 1) App-Default Mode (recommended for behavior checks)

Uses app defaults for processing mode, speech engine, speaker detection, and
YouTube audio retention. This is the best CLI mode for checking GUI behavior
without controlling the GUI, but it is not full GUI parity: the CLI does not
exercise GUI-only windowing, playback, hotkeys, PDF/DOCX export, or optional
AI formatter output. Bare `transcribe` already follows the app-default speaker
detection setting; the explicit flag below keeps the behavior visible in test
commands.

```bash
swift run macparakeet-cli transcribe "<FILE_OR_MEDIA_URL>" \
  --engine app-default \
  --parakeet-model app-default \
  --speaker-detection app-default \
  --mode app-default \
  --downloaded-audio app-default \
  --youtube-audio-quality app-default
```

### 2) Deterministic Mode (recommended for CI/agent reproducibility)

Explicitly pins behavior.

```bash
swift run macparakeet-cli transcribe "<FILE_OR_MEDIA_URL>" \
  --engine parakeet \
  --parakeet-model v3 \
  --speaker-detection off \
  --mode raw \
  --downloaded-audio delete \
  --youtube-audio-quality m4a
```

Or clean mode with retained downloads:

```bash
swift run macparakeet-cli transcribe "<FILE_OR_MEDIA_URL>" \
  --engine parakeet \
  --parakeet-model v3 \
  --speaker-detection on \
  --mode clean \
  --downloaded-audio keep \
  --youtube-audio-quality best-available
```

`--youtube-audio-quality app-default` follows the GUI setting. `m4a` matches
the app's default compatibility-first selector. `best-available` asks `yt-dlp`
for the best audio stream and then lets the normal conversion pipeline prepare
the STT input.

### Speech Engine Selection

Parakeet remains the no-flag default for semver stability and ignores
`--language`. Within Parakeet, v3 is the multilingual default and v2 is the
English-only opt-in. Use `--parakeet-model app-default|v3|v2` for a single run,
or `config set parakeet-model v2` / `models select parakeet-v2` to persist it.
Use `--engine app-default` when you want the CLI to follow the GUI's saved
speech engine, Parakeet model, and Whisper language defaults. Use Whisper
explicitly for languages outside Parakeet coverage after downloading the local
Whisper model:

```bash
swift run macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB

swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --engine whisper \
  --language ko
```

`--language auto` or omitting `--language` lets Whisper detect the language.
When `--engine app-default` resolves to Whisper, an explicit `--language`
overrides the saved Whisper language for that invocation. When `--engine
whisper` is explicit, pass `--language` explicitly if you do not want
auto-detect; the saved Whisper language is only used by `--engine app-default`.

### Speaker Diarization

Speaker detection follows the saved app/CLI preference by default. A fresh
preference store resolves to `off`, matching the GUI default. Pin a run with
the explicit option, or use the legacy alias to force it off:

```bash
swift run macparakeet-cli transcribe "<FILE>" --speaker-detection on
swift run macparakeet-cli transcribe "<FILE>" --speaker-count 2
swift run macparakeet-cli transcribe "<FILE>" --speaker-min 2 --speaker-max 4
swift run macparakeet-cli transcribe "<FILE>" --speaker-detection off
swift run macparakeet-cli transcribe "<FILE>" --no-diarize
```

`--speaker-count`, `--speaker-min`, and `--speaker-max` are per-run
constraints. They imply speaker detection when `--speaker-detection` is left at
`app-default`, and they cannot be combined with `--speaker-detection off` or
`--no-diarize`. Use `--speaker-count` for an exact count, or `--speaker-min`
and/or `--speaker-max` for bounds; values must be positive, and
`--speaker-min` cannot exceed `--speaker-max`.

`config get speaker-detection` reports the saved app-default value used by
bare `transcribe` and by `--speaker-detection app-default`.

### Shared Config

`config` writes the same UserDefaults suite the GUI reads. This lets agents set
up deterministic or app-default state before running a smoke test. Treat it as
pre-run setup: a running GUI may cache some settings until relaunch or an
in-app change.

```bash
swift run macparakeet-cli config list
swift run macparakeet-cli config set processing-mode raw
swift run macparakeet-cli config set speech-engine whisper
swift run macparakeet-cli config set parakeet-model v3
swift run macparakeet-cli config set whisper-language ko
swift run macparakeet-cli config set speaker-detection off
swift run macparakeet-cli config set save-transcription-audio off
swift run macparakeet-cli config set youtube-audio-quality m4a
```

Supported keys: `telemetry`, `processing-mode`, `speech-engine`,
`parakeet-model`, `whisper-language`, `speaker-detection`,
`save-transcription-audio`, `youtube-audio-quality`. Underscore aliases such as
`youtube_audio_quality` are accepted on input; JSON output uses canonical
hyphenated keys.

### Output Formats

```bash
# Plain text output (default)
swift run macparakeet-cli transcribe "<FILE>"

# JSON output (full Transcription object)
swift run macparakeet-cli transcribe "<FILE>" --format json

# Transcript-only stdout for pipes
swift run macparakeet-cli transcribe "<FILE>" --format transcript

# Transient transcription: no completed row in Library/history
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" --format transcript --no-history

# Batch mode: writes one transcript file per resolved input
swift run macparakeet-cli transcribe lecture1.m4a lectures/ \
  --output-dir Transcripts \
  --format transcript
```

`--format transcript` prints only `cleanTranscript` when present, otherwise
`rawTranscript`. Status and progress messages stay on stderr, so stdout can be
piped directly into `pbcopy`, `grep`, `tee`, or a local LLM command.

`--no-history` uses the same transcription pipeline without retaining a completed
history row. For YouTube inputs, downloaded audio is temporary regardless of
the shared audio-retention default.

## Model Selection

```bash
swift run macparakeet-cli models list
swift run macparakeet-cli models list --json
swift run macparakeet-cli models select parakeet-v3
swift run macparakeet-cli models select parakeet-v2
swift run macparakeet-cli models download parakeet-v2
swift run macparakeet-cli models select whisper-large-v3-v20240930-turbo-632MB
```

`models list` reports the selectable speech engines MacParakeet exposes today:
Parakeet v3, Parakeet v2, and the configured WhisperKit variant. `models select`
writes the same shared default used by the GUI and `transcribe --engine
app-default`; Whisper selection requires the local Whisper model to be
downloaded first.

## Retained Entitlements Parity

Use this only when exercising the same entitlement check path the GUI uses:

```bash
swift run macparakeet-cli transcribe "<FILE_OR_YOUTUBE_URL>" \
  --enforce-entitlements
```

On the current branch, the app is effectively unlocked, so
`--enforce-entitlements` should still pass unless you are explicitly validating
retained purchase activation code.

## Export

Export a transcription by its UUID or UUID prefix of at least 4 characters. Supported formats: txt, markdown, srt, vtt, json.

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

IDs support UUID prefix matching with at least 4 characters (e.g., `3a7b` matches `3a7b1234-...`).

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
swift run macparakeet-cli health --repair-binaries
```

`health --json` is a non-mutating readiness probe: it can report an existing
managed or app-bundled `yt-dlp`, but it does not install or update helper
binaries. `health --repair-binaries` explicitly fetches the latest managed
`yt-dlp` copy. App-bundled CLI installs include a signed `yt-dlp` seed so
media URL transcription works without a first-use helper download.

## Meetings

Meeting commands operate on `sourceType = meeting` transcriptions. `<meeting>` accepts a UUID, UUID prefix, or exact title.

```bash
swift run macparakeet-cli meetings list --limit 10
swift run macparakeet-cli meetings show <meeting> --json
swift run macparakeet-cli meetings transcript <meeting> --format srt

swift run macparakeet-cli meetings notes get <meeting>
swift run macparakeet-cli meetings notes append <meeting> --text "**Action:** follow up"
cat notes.md | swift run macparakeet-cli meetings notes set <meeting> --stdin --json

swift run macparakeet-cli meetings export <meeting> --format md --stdout
```

## Calendar

Calendar commands inspect the same EventKit pipeline used by the calendar auto-start/reminder code, which is enabled (`AppFeatures.calendarEnabled = true`). This CLI surface remains useful for headless verification. Calendar permission must already be granted through the GUI calendar permission surface, a previous grant, or macOS Settings — the CLI is a separate TCC identity and won't prompt on its own.

```bash
swift run macparakeet-cli calendar upcoming --days 1 --filter link
swift run macparakeet-cli calendar upcoming --days 7 --filter all --json
```

## Speech Model Lifecycle

```bash
# Non-invasive status (does not force downloads)
swift run macparakeet-cli models status

# Explicit Parakeet / Whisper downloads
swift run macparakeet-cli models download parakeet-v3
swift run macparakeet-cli models download parakeet-v2
swift run macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB

# Warm-up (single attempt by default)
swift run macparakeet-cli models warm-up

# Repair (best-effort retry; default 3 attempts)
swift run macparakeet-cli models repair
swift run macparakeet-cli models repair --attempts 5

# Delete one downloaded model (frees its disk space; leaves the rest)
swift run macparakeet-cli models delete parakeet-v2
swift run macparakeet-cli models delete whisper-large-v3-v20240930-turbo-632MB
swift run macparakeet-cli models delete parakeet-v3 --force   # override the in-use guard

# Delete the entire cached speech + speaker stack
swift run macparakeet-cli models clear
```

`models warm-up` and `models repair` prepare the selected Parakeet build plus
the diarization speech stack. Whisper is downloaded explicitly with
`models download`. `models delete <id>` removes a single model — one Parakeet
build or the Whisper variant — and protects the active model plus Parakeet's
configured build unless `--force` is passed; `models clear` still wipes
everything.

## Text Pipeline

```bash
swift run macparakeet-cli vocab process "your text"
swift run macparakeet-cli vocab process "your text" --copy   # also copies to clipboard

swift run macparakeet-cli vocab words list
swift run macparakeet-cli vocab words add "macparakeet" "MacParakeet"
swift run macparakeet-cli vocab words add "hmm"              # vocabulary anchor (no replacement)
swift run macparakeet-cli vocab words delete <ID>

swift run macparakeet-cli vocab snippets list
swift run macparakeet-cli vocab snippets add "my signature" "Best regards, Daniel"
swift run macparakeet-cli vocab snippets edit <ID> --trigger "my signature" --expansion "Best regards, Daniel Moon"
swift run macparakeet-cli vocab snippets delete <ID>
```

## LLM Commands

All LLM commands require `--provider`; `--api-key` is required only for providers
that need one. Ollama, LM Studio, OpenAI-compatible local endpoints, and Local
CLI can run without an API key; LM Studio also accepts an optional API token
when its server-side authentication is enabled.

### Supported Providers

| Provider | Default Model | API Key Required |
|----------|--------------|-----------------|
| `anthropic` | claude-sonnet-4-6 | Yes |
| `openai` | gpt-4.1 | Yes |
| `openai-compatible` | user-selected endpoint/model | Optional |
| `gemini` | gemini-2.5-flash | Yes |
| `openrouter` | anthropic/claude-sonnet-4 | Yes |
| `ollama` | qwen3.5:4b | No (local) |
| `lmstudio` | user-selected in LM Studio | Optional (local) |
| `cli` | N/A (tool decides) | No (tool manages auth) |

### Test Connection

```bash
swift run macparakeet-cli llm test-connection \
  --provider openai --api-key-env OPENAI_API_KEY
```

### Summarize

```bash
swift run macparakeet-cli llm summarize transcript.txt \
  --provider anthropic --api-key-env ANTHROPIC_API_KEY

# Stream output token-by-token
swift run macparakeet-cli llm summarize transcript.txt \
  --provider anthropic --api-key-env ANTHROPIC_API_KEY --stream

# Read from stdin
echo "Long text..." | swift run macparakeet-cli llm summarize - \
  --provider anthropic --api-key-env ANTHROPIC_API_KEY
```

### Chat (Q&A about a transcript)

```bash
swift run macparakeet-cli llm chat transcript.txt \
  --provider openai --api-key-env OPENAI_API_KEY \
  --question "What were the key points?"
```

### Transform (custom instruction)

```bash
swift run macparakeet-cli llm transform transcript.txt \
  --provider anthropic --api-key-env ANTHROPIC_API_KEY \
  --prompt "Translate to Spanish"
```

### LM Studio Provider

```bash
# Test a local LM Studio server
swift run macparakeet-cli llm test-connection --provider lmstudio --model qwen3.5-27b

# Summarize via LM Studio's OpenAI-compatible endpoint
swift run macparakeet-cli llm summarize transcript.txt --provider lmstudio --model qwen3.5-27b

# Use an LM Studio API token when Require Authentication is enabled
swift run macparakeet-cli llm summarize transcript.txt --provider lmstudio --model qwen3.5-27b --api-key-env LM_API_TOKEN
```

### Common Options

All LLM commands accept these additional options:

- `--model <name>` — Override default model
- `--base-url <url>` — Custom API endpoint. HTTPS is required for
  non-local/non-loopback HTTP unless `--allow-insecure-http` is set.
- `--allow-insecure-http` — Permit intentional non-loopback `http://` for
  non-local providers. Emits a stderr warning because prompt content and API
  keys may cross the network without TLS.
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

## Transforms

`transforms` is the saved-prompt product surface from ADR-022. It operates on
text passed to the CLI directly; AX selection capture and in-place replacement
are GUI-only.

```bash
# Inspect built-ins and custom Transforms
swift run macparakeet-cli transforms list
swift run macparakeet-cli transforms show Polish --json

# Run a saved Transform against a file or stdin
swift run macparakeet-cli transforms run Polish --input draft.txt --json
echo "too long; didn't read" | swift run macparakeet-cli transforms run Distill --input -

# Create a custom Transform
swift run macparakeet-cli transforms create \
  --name "Terse" \
  --prompt "Rewrite the input in terse, direct prose. Return only the rewritten text." \
  --shortcut opt+4 \
  --json

# Inspect local run history
swift run macparakeet-cli transforms history list --json
swift run macparakeet-cli transforms history show <id-prefix>
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

# Show full content. <id-or-name> accepts UUID, UUID prefix of at least 4 characters, or exact name.
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
  --provider anthropic --api-key-env ANTHROPIC_API_KEY

# Stream output and skip persistence (preview-only)
swift run macparakeet-cli prompts run "Action Items & Decisions" \
  --transcription a3f7 \
  --provider openai --api-key-env OPENAI_API_KEY \
  --stream --no-store

# Add per-run instructions (mirrors the GUI's regenerate-with-extra flow)
swift run macparakeet-cli prompts run "Blog Post" \
  --transcription a3f7 \
  --provider anthropic --api-key-env ANTHROPIC_API_KEY \
  --extra "Tone: warm and direct. Audience: engineers."
```

`prompts run` writes the model output to **stdout** and the "Saved PromptResult X"
confirmation to **stderr**, so `> result.txt` captures only the prompt output.

## Quick Prompts

Quick prompts power the live meeting Ask tab shortcut pills. The CLI mirrors
the GUI model so agents can seed, pin, hide, export, and import those prompts
without launching the app.

```bash
swift run macparakeet-cli quick-prompts list --visible-only
swift run macparakeet-cli quick-prompts show "Catch me up"

swift run macparakeet-cli quick-prompts add \
  --label "Risks?" \
  --prompt "Identify risks, blockers, and open questions from the current meeting context." \
  --pinned

swift run macparakeet-cli quick-prompts pin "Risks?"
swift run macparakeet-cli quick-prompts set "Risks?" --group "CHALLENGE"
swift run macparakeet-cli quick-prompts export --out quick-prompts.json --include-builtins
swift run macparakeet-cli quick-prompts import quick-prompts.json --mode merge --json
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
