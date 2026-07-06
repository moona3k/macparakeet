---
name: macparakeet-stt
description: Use when the user asks to transcribe audio or video, inspect or manage MacParakeet meeting recordings, search prior dictations/transcripts, or give an AI agent local speech-to-text tools on Apple Silicon.
---

# MacParakeet STT

Use `macparakeet-cli` for local-first speech-to-text and meeting artifact
management on macOS Apple Silicon. STT and database access are local. Do not
send audio or transcripts to an LLM unless the user explicitly asks for an
LLM-backed prompt/summary and provides or has configured a provider.

## Startup Check

Run this before real work:

```bash
macparakeet-cli health --json
```

If it fails, report the `errorType`/message and stop. Do not guess that models,
FFmpeg, yt-dlp, or the database are ready. App-bundled CLI installs should
already have a signed yt-dlp helper seed; if `yt-dlp` is still missing and the
user wants media URL transcription, run
`macparakeet-cli health --repair-binaries` before retrying.

## Core Commands

```bash
macparakeet-cli spec --json
macparakeet-cli transcribe "<path-or-media-url>" --format json
macparakeet-cli transcribe "<path-or-media-url>" --format transcript --no-history
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
macparakeet-cli models download cohere-transcribe
macparakeet-cli models list --json
macparakeet-cli models select parakeet-v3 --json
macparakeet-cli config set parakeet-model v3 --json
macparakeet-cli transcribe "<path-or-media-url>" --engine whisper --language ko --format json
macparakeet-cli transcribe "<path-or-media-url>" --engine cohere --language ja --format json
macparakeet-cli transcribe "<path-or-media-url>" \
  --engine app-default \
  --parakeet-model app-default \
  --speaker-detection app-default \
  --mode app-default \
  --downloaded-audio app-default \
  --media-audio-quality app-default \
  --format json
macparakeet-cli config list --json
macparakeet-cli config set speech-engine parakeet --json
macparakeet-cli config set speaker-detection off --json
macparakeet-cli config set meeting-speaker-detection off --json
macparakeet-cli history transcriptions --json
macparakeet-cli history search-transcriptions "<query>" --json
macparakeet-cli history search "<query>" --json
macparakeet-cli meetings list --json
macparakeet-cli meetings show "<id-or-prefix-or-title>" --json
macparakeet-cli meetings transcript "<id-or-prefix-or-title>" --format json
macparakeet-cli meetings notes append "<id-or-prefix-or-title>" --text "<note>" --json
macparakeet-cli meetings results add "<id-or-prefix-or-title>" --name "Agent Notes" --stdin --json
macparakeet-cli meetings export "<id-or-prefix-or-title>" --format md --stdout
macparakeet-cli meetings export "<id-or-prefix-or-title>" --stdout --format json
```

Use `meetings` commands for Granola-style deterministic workflows: list
recordings, read transcripts, update notes, and export artifacts. These do not
summarize and do not require an LLM provider.

Only use prompt/LLM commands when the user asks for generated output:

```bash
macparakeet-cli prompts list --json
macparakeet-cli prompts run "<prompt-name>" \
  --transcription "<id-or-prefix-or-title>" \
  --provider "<provider>" --api-key-env "PROVIDER_API_KEY" --model "<model>" \
  --json
```

## Operating Rules

- Branch on process exit code first.
- Parse stdout as JSON for `--json` commands and for format-selecting commands
  when the command's documented JSON mode sends the payload to stdout. For
  `meetings export`, that mode is `--stdout --format json`; `--format json`
  without `--stdout` writes a JSON file and prints the path.
- Treat exit code `2` as invocation misuse; fix the command before retrying.
- Treat lookup ambiguity as normal; ask for or choose a more specific ID.
- Never delete user database records unless the user explicitly requests it.
- Prefer meeting ID or UUID prefix over title when mutating notes.
- Keep API keys in environment variables; do not put literal keys in commands.
- Use the full app-default group (`--engine app-default`,
  `--parakeet-model app-default`, `--speaker-detection app-default`,
  `--mode app-default`, `--downloaded-audio app-default`, and
  `--media-audio-quality app-default`) when you are intentionally checking
  GUI-default behavior. Pin explicit flags for reproducible agent tests.
- `config get speaker-detection` reports the saved file/URL app-default value,
  which is `on` for a fresh preference store. `config get
  meeting-speaker-detection` reports the saved meeting app-default value, also
  defaulting to `on`. Bare `transcribe` uses the file/URL value; meeting
  retranscription uses the meeting value when `--speaker-detection` is left at
  `app-default`. Pass `--speaker-detection on` or `off` to override it for one
  run. For known speaker counts, use per-run `--speaker-count`,
  `--speaker-min`, or `--speaker-max` instead of mutating the saved default.
