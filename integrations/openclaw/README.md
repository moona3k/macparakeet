# MacParakeet for OpenClaw

> Thin OpenClaw-flavored entry point. The canonical integration story
> (vocabulary, JSON schemas, privacy posture, conventions) lives in
> [`../README.md`](../README.md). The CLI semver contract is at
> [`../../Sources/CLI/CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md).
>
> **Schema note:** ClawHub publishes skills via a `SKILL.md` file with
> frontmatter (not `SOUL.md` — that's a different agent registry,
> onlycrabs.ai). The illustrative SKILL.md sketch below is a starting
> point only; verify the current frontmatter spec at
> <https://docs.openclaw.ai/clawhub/skill-format> before publishing.

## What this skill provides

Local speech-to-text and transcription for an OpenClaw agent running on Apple
Silicon. Wraps `macparakeet-cli` so an OpenClaw skill can:

- Transcribe a local audio/video file.
- Transcribe a media URL.
- Transcribe an Apple Podcasts link or freetext podcast search.
- Search the user's prior dictation/transcription history.
- Inspect meeting recordings and store external meeting results.
- Run a prompt against a transcription (action items, summary, etc.).

Speech-to-text execution is local on Apple Silicon. Parakeet, Nemotron, and
Cohere use FluidAudio/CoreML; Whisper uses WhisperKit. No cloud STT.

## Install

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli --version   # confirm the installed release
macparakeet-cli health --json
```

Requires macOS 14.2+ on Apple Silicon. The Homebrew formula installs FFmpeg
and yt-dlp as runtime dependencies. Parakeet, Nemotron, and Cohere CoreML
model caches are managed by FluidAudio; WhisperKit model downloads live under
`~/Library/Application Support/MacParakeet/models/stt/whisper/`.

If MacParakeet.app is already installed, the bundled CLI is also available at
`/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli`.

## Capabilities (CLI vocabulary)

| Capability | Command |
|---|---|
| Health probe (run at skill init) | `macparakeet-cli health --json` |
| Discover core contract | `macparakeet-cli spec --json` |
| Transcribe a file | `macparakeet-cli transcribe <path> --format json` |
| Transcribe a media URL | `macparakeet-cli transcribe <url> --format json` |
| Transcribe a podcast | `macparakeet-cli transcribe --podcast "Lex Fridman episode 400" --format json` |
| Use GUI/default preferences | `macparakeet-cli transcribe <path> --engine app-default --parakeet-model app-default --speaker-detection app-default --mode app-default --downloaded-audio app-default --media-audio-quality app-default --format json` |
| Inspect/select speech models | `macparakeet-cli models list --json` / `macparakeet-cli models select parakeet-v3 --json` / `macparakeet-cli models select parakeet-v2 --json` / `macparakeet-cli models select nemotron-multilingual-1120ms --json` / `macparakeet-cli models select cohere-transcribe --json` |
| Download optional speech models | `macparakeet-cli models download nemotron-multilingual-1120ms` / `macparakeet-cli models download cohere-transcribe` / `macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB` |
| Configure shared defaults | `macparakeet-cli config set speaker-detection off --json`; `macparakeet-cli config set parakeet-model v3 --json`; `macparakeet-cli config set speech-engine nemotron --json`; `macparakeet-cli config set cohere-language ja --json` |
| List recent transcriptions | `macparakeet-cli history transcriptions --json` |
| Search transcriptions | `macparakeet-cli history search-transcriptions "<query>" --json` |
| Search dictations | `macparakeet-cli history search "<query>" --json` |
| List meetings | `macparakeet-cli meetings list --json` |
| Read meeting transcript | `macparakeet-cli meetings transcript <id-or-title> --format json` |
| Materialize meeting artifact folder | `macparakeet-cli meetings artifact <id-or-title> --json` |
| Store generated meeting output | `macparakeet-cli meetings results add <id-or-title> --name "Agent Notes" --stdin --json` |
| List prompts | `macparakeet-cli prompts list --json` |
| Run a prompt on a transcription | `macparakeet-cli prompts run <prompt-name> --transcription <id-or-name> --provider <p> --api-key-env KEY_ENV --model <m> --json` |

## Conventions

JSON to stdout when `--json` (or `--format json` for `transcribe`/`export`)
is set; human-readable errors to stderr; non-zero exit on failure. JSON
schemas are stable within a major CLI version (semver, see
[`CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md)). Lookup args accept full
UUID, UUID prefix (>= 4 chars), or case-insensitive name. Prompt and LLM
wrappers should pass `--json` when the skill expects an envelope.

Cohere is a batch-only accuracy engine. It can be used for dictation final
transcription, file transcription, and meeting finalization, but it has no live
dictation preview, no meeting live-preview chunks, and no word timestamps or
speaker labels. The ~2.1 GB model must be downloaded explicitly before
`--engine cohere`, `models select cohere-transcribe`, or app-default Cohere
transcription will run; normal transcription paths do not implicitly download
it.

For the full vocabulary, schema details, and privacy posture, see
[`../README.md`](../README.md).

## Illustrative SKILL.md sketch (for ClawHub publishers)

The file below is a starting point for someone publishing a ClawHub skill
that wraps `macparakeet-cli`. **Verify the current SKILL.md frontmatter
spec at <https://docs.openclaw.ai/clawhub/skill-format>** before publishing —
fields and validation rules may have evolved.

````markdown
---
name: macparakeet-stt
version: <published-cli-version>
author: <your-username>
description: >
  Local speech-to-text and meeting artifact access on Apple Silicon. Wraps
  macparakeet-cli.
tags: [stt, transcription, voice, apple-silicon, local, parakeet, cohere]
metadata:
  openclaw:
    requires:
      bins:
        - macparakeet-cli
    install:
      - kind: brew
        formula: moona3k/tap/macparakeet-cli
        bins: [macparakeet-cli]
    envVars:
      - name: ANTHROPIC_API_KEY
        required: false
        description: Optional Anthropic key for LLM-backed prompt runs.
      - name: OPENAI_API_KEY
        required: false
        description: Optional OpenAI key for LLM-backed prompt runs.
      - name: GEMINI_API_KEY
        required: false
        description: Optional Gemini key for LLM-backed prompt runs.
      - name: OPENROUTER_API_KEY
        required: false
        description: Optional OpenRouter key for LLM-backed prompt runs.
      - name: LM_API_TOKEN
        required: false
        description: Optional LM Studio API token.
    os: ["macos"]
    homepage: https://github.com/moona3k/macparakeet/tree/main/integrations/openclaw
---

# macparakeet-stt

Local STT and transcription for an OpenClaw agent on Apple Silicon.
All speech recognition runs locally; no cloud STT.

## Install

```bash
brew install moona3k/tap/macparakeet-cli
```

## Capabilities

Run `macparakeet-cli health --json` before work and parse stdout as JSON for
`--json` / `--format json` commands. Use deterministic meeting commands for
meeting artifacts, and use prompt/LLM commands only when the user explicitly
asks for generated output.

## Privacy

STT runs on the ANE. No audio leaves the device. Optional cloud LLM
provider calls happen only when the user explicitly asks for prompt/summary
generation and configures or passes a provider.
````

To publish:

```bash
clawhub skill publish ./macparakeet-stt
```

## Status

Pending publication to ClawHub. Tracking via
<https://github.com/moona3k/macparakeet/issues> with the `integration`
label. The brew tap (host binary install path) is already live at
<https://github.com/moona3k/homebrew-tap>.
