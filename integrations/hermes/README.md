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
the local Parakeet TDT pipeline without any cloud STT dependency.

## Install (manual, today)

```bash
# 1. Install MacParakeet from https://macparakeet.com
# 2. Make the CLI available on $PATH
ln -s /Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli \
      /usr/local/bin/macparakeet-cli
# 3. Verify
macparakeet-cli --version   # 1.4.0
macparakeet-cli health --json
```

`brew install moona3k/tap/macparakeet-cli` is on the roadmap.

## Suggested skill bindings (sketch)

```yaml
# Illustrative -- adapt to your Hermes skill manifest format.
name: macparakeet
description: Local speech-to-text, transcription, and prompt automation
             on Apple Silicon. Powered by Parakeet TDT on the Neural Engine.
when_to_use:
  - User wants to transcribe a local audio/video file.
  - User wants to transcribe a YouTube URL.
  - User asks "what was said in <past meeting / dictation>?"
  - User asks for action items / summary from a recorded transcript.
commands:
  transcribe_file: macparakeet-cli transcribe "{path}" --format json
  transcribe_youtube: macparakeet-cli transcribe "{url}" --format json
  list_transcriptions: macparakeet-cli history transcriptions --json
  search_transcriptions: macparakeet-cli history search-transcriptions "{query}" --json
  search_dictations: macparakeet-cli history search "{query}" --json
  run_prompt: |
    macparakeet-cli prompts run "{prompt_id_or_name}" \
      --transcription {transcription_id} \
      --provider {provider} --api-key-env "{api_key_env}" --model "{model}"
  health: macparakeet-cli health --json
```

## Conventions

JSON to stdout when `--json` is set; human-readable errors to stderr;
non-zero exit on failure. JSON schemas are stable within a major CLI version
(semver, see [`CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md)). Lookup args
accept full UUID, UUID prefix (>= 4 chars), or case-insensitive name.

For the full vocabulary, schema details, and privacy posture, see
[`../README.md`](../README.md).

## Status

Submitted to `awesome-hermes-agent`: tracking via
<https://github.com/moona3k/macparakeet/issues> with the `integration` label.
