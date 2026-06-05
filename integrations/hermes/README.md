# MacParakeet skill for Hermes Agent

> Thin Hermes-flavored entry point. The canonical integration story lives in
> [`../README.md`](../README.md). The CLI semver contract is at
> [`../../Sources/CLI/CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md). The
> repo-root coding-agent guide is at [`/AGENTS.md`](../../AGENTS.md).
>
> The exact skill manifest format used by `awesome-hermes-agent` may evolve.
> Treat the YAML sketch below as illustrative and adapt to the published spec
> at registration time.

## What this skill provides

Local speech-to-text, transcription, and prompt automation for a Hermes Agent
running on Apple Silicon. Wraps `macparakeet-cli` so a Hermes skill can call
the local Parakeet TDT pipeline without any cloud STT dependency, inspect
meeting artifacts, and store externally generated meeting results.

## Install

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli --version   # confirm the installed release
macparakeet-cli health --json
```

If MacParakeet.app is already installed, the bundled CLI is also available at
`/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli`.
Parakeet's CoreML cache is managed by FluidAudio. WhisperKit model downloads
live under `~/Library/Application Support/MacParakeet/models/stt/whisper/`.

## Suggested skill bindings (sketch)

```yaml
# Illustrative -- adapt to your Hermes skill manifest format.
name: macparakeet
description: Local speech-to-text, transcription, and prompt automation
             on Apple Silicon. Powered by Parakeet TDT on the Neural Engine.
when_to_use:
  - User wants to transcribe a local audio/video file.
  - User wants to transcribe a media URL.
  - User asks "what was said in <past meeting / dictation>?"
  - User asks for action items / summary from a recorded transcript.
commands:
  spec: macparakeet-cli spec --json
  health: macparakeet-cli health --json
  transcribe_file: macparakeet-cli transcribe "{path}" --format json
  transcribe_media_url: macparakeet-cli transcribe "{url}" --format json
  transcribe_app_defaults: |
    macparakeet-cli transcribe "{path}" \
      --engine app-default \
      --parakeet-model app-default \
      --speaker-detection app-default \
      --mode app-default \
      --downloaded-audio app-default \
      --youtube-audio-quality app-default \
      --format json
  list_models: macparakeet-cli models list --json
  set_parakeet_model: macparakeet-cli config set parakeet-model "{v3_or_v2}" --json
  set_speaker_detection: macparakeet-cli config set speaker-detection "{value}" --json
  list_transcriptions: macparakeet-cli history transcriptions --json
  search_transcriptions: macparakeet-cli history search-transcriptions "{query}" --json
  search_dictations: macparakeet-cli history search "{query}" --json
  list_meetings: macparakeet-cli meetings list --json
  meeting_transcript: macparakeet-cli meetings transcript "{meeting_id_or_title}" --format json
  add_meeting_result: |
    macparakeet-cli meetings results add "{meeting_id_or_title}" \
      --name "{result_name}" --stdin --json
  run_prompt: |
    macparakeet-cli prompts run "{prompt_id_or_name}" \
      --transcription {transcription_id} \
      --provider {provider} --api-key-env "{api_key_env}" --model "{model}" \
      --json
```

## Conventions

JSON to stdout when `--json` is set, or when `--format json` is used for
format-selecting commands like `transcribe` and `meetings transcript`.
Human-readable errors go to stderr; commands exit non-zero on failure. JSON
schemas are stable within a major CLI version (semver, see
[`CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md)). Lookup args accept full
UUID, UUID prefix (>= 4 chars), or case-insensitive name.

Use `meetings` commands for deterministic local meeting workflows. Use
`prompts run` only when the user explicitly asks for generated output, and
include `--json` so Hermes receives the structured LLMResult envelope.

For the full vocabulary, schema details, and privacy posture, see
[`../README.md`](../README.md).

## Status

Submitted to `awesome-hermes-agent`: tracking via
<https://github.com/moona3k/macparakeet/issues> with the `integration` label.
