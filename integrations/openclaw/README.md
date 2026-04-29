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
> <https://docs.openclaw.ai/tools/clawhub> before publishing.

## What this skill provides

Local speech-to-text and transcription for an OpenClaw agent running on Apple
Silicon. Wraps `macparakeet-cli` so an OpenClaw skill can:

- Transcribe a local audio/video file.
- Transcribe a YouTube URL.
- Search the user's prior dictation/transcription history.
- Run a prompt against a transcription (action items, summary, etc.).

All execution is local on the Apple Neural Engine. No cloud STT.

## Install

```bash
# 1. Install MacParakeet from https://macparakeet.com
# 2. Make the bundled CLI available on $PATH
ln -s /Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli \
      /usr/local/bin/macparakeet-cli
# 3. Verify
macparakeet-cli --version   # 1.4.0
macparakeet-cli health --json
```

Requires macOS 14.2+ on Apple Silicon. The app bundle includes FFmpeg,
yt-dlp, and the CLI. First `transcribe` call downloads ~6 GB of CoreML models
to `~/Library/Application Support/MacParakeet/models/`. YouTube transcription
seeds the managed `yt-dlp` helper from the app bundle; `macparakeet-cli health
--repair-binaries` explicitly fetches the latest helper.

## Capabilities (CLI vocabulary)

| Capability | Command |
|---|---|
| Health probe (run at skill init) | `macparakeet-cli health --json` |
| Transcribe a file | `macparakeet-cli transcribe <path> --format json` |
| Transcribe a YouTube URL | `macparakeet-cli transcribe <url> --format json` |
| List recent transcriptions | `macparakeet-cli history transcriptions --json` |
| Search transcriptions | `macparakeet-cli history search-transcriptions "<query>" --json` |
| Search dictations | `macparakeet-cli history search "<query>" --json` |
| List prompts | `macparakeet-cli prompts list --json` |
| Run a prompt on a transcription | `macparakeet-cli prompts run <prompt-name> --transcription <id-or-name> --provider <p> --api-key-env KEY_ENV --model <m>` |

## Conventions

JSON to stdout when `--json` (or `--format json` for `transcribe`/`export`)
is set; human-readable errors to stderr; non-zero exit on failure. JSON
schemas are stable within a major CLI version (semver, see
[`CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md)). Lookup args accept full
UUID, UUID prefix (≥ 4 chars), or case-insensitive name.

For the full vocabulary, schema details, and privacy posture, see
[`../README.md`](../README.md).

## Illustrative SKILL.md sketch (for ClawHub publishers)

The file below is a starting point for someone publishing a ClawHub skill
that wraps `macparakeet-cli`. **Verify the current SKILL.md frontmatter
spec at <https://docs.openclaw.ai/tools/clawhub>** before publishing —
fields and validation rules may have evolved.

````markdown
---
name: macparakeet-stt
version: 1.4.0
author: <your-username>
description: Local Parakeet TDT speech-to-text on Apple Silicon. Wraps macparakeet-cli (GPL-3.0-or-later).
tags: [stt, transcription, voice, apple-silicon, local, parakeet]
requires:
  - platform: darwin
  - arch: arm64
  - macos: ">=14.2"
license: GPL-3.0-or-later
---

# macparakeet-stt

Local STT and transcription for an OpenClaw agent on Apple Silicon.
All execution local on the Apple Neural Engine; no cloud STT.

## Install

```bash
brew install moona3k/tap/macparakeet-cli
```

## Capabilities

(See the capabilities table at
https://github.com/moona3k/macparakeet/tree/main/integrations/openclaw)

## Privacy

STT runs on the ANE. No audio leaves the device. Optional cloud LLM
provider only when the user explicitly passes `--provider <cloud>`.
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
