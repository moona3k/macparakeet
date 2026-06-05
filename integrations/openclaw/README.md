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
- Search the user's prior dictation/transcription history.
- Inspect meeting recordings and store external meeting results.
- Run a prompt against a transcription (action items, summary, etc.).

Speech-to-text execution is local on the Apple Neural Engine. No cloud STT.

## Install

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli --version   # confirm the installed release
macparakeet-cli health --json
```

Requires macOS 14.2+ on Apple Silicon. The Homebrew formula installs FFmpeg
and yt-dlp as runtime dependencies. Parakeet's CoreML cache is managed by
FluidAudio. WhisperKit model downloads live under
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
| Use GUI/default preferences | `macparakeet-cli transcribe <path> --engine app-default --parakeet-model app-default --speaker-detection app-default --mode app-default --downloaded-audio app-default --youtube-audio-quality app-default --format json` |
| Inspect/select speech models | `macparakeet-cli models list --json` / `macparakeet-cli models select parakeet-v3 --json` / `macparakeet-cli models select parakeet-v2 --json` |
| Configure shared defaults | `macparakeet-cli config set speaker-detection off --json`; `macparakeet-cli config set parakeet-model v3 --json` |
| List recent transcriptions | `macparakeet-cli history transcriptions --json` |
| Search transcriptions | `macparakeet-cli history search-transcriptions "<query>" --json` |
| Search dictations | `macparakeet-cli history search "<query>" --json` |
| List meetings | `macparakeet-cli meetings list --json` |
| Read meeting transcript | `macparakeet-cli meetings transcript <id-or-title> --format json` |
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
  Local Parakeet TDT speech-to-text and meeting artifact access on Apple
  Silicon. Wraps macparakeet-cli.
tags: [stt, transcription, voice, apple-silicon, local, parakeet]
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
All execution local on the Apple Neural Engine; no cloud STT.

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
