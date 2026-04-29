# Integrations -- using `macparakeet-cli` from your agent

> If you are a *coding agent working in this repo*, read
> [`/AGENTS.md`](../AGENTS.md) instead. This directory is for agents (and the
> people running them) that want to *call* `macparakeet-cli` to add local STT
> to their stack.

## What `macparakeet-cli` gives your agent

- **Local Parakeet TDT speech-to-text** at ~155x realtime on Apple Silicon
  with ~2.5% WER, running on the Neural Engine. No cloud, no API keys, no
  per-minute charges.
- **Audio + video file transcription** -- accepts MP3 / WAV / MP4 / MOV /
  WebM / etc. via the bundled FFmpeg.
- **YouTube transcription** via yt-dlp. The app bundle seeds a signed helper
  into MacParakeet's Application Support folder before first YouTube use.
- **Persistent SQLite memory layer** -- everything transcribed is queryable
  later: dictation history, transcriptions, prompt outputs.
- **Prompt library + LLM-backed summarization** -- bring your own provider
  (OpenAI, Anthropic, Ollama, LM Studio, OpenAI-compatible local, or a
  configured CLI subprocess), or skip the LLM entirely and consume raw
  transcripts.
- **JSON output everywhere** -- every read-only command supports `--json`
  with a stable schema (see
  [`../Sources/CLI/CHANGELOG.md`](../Sources/CLI/CHANGELOG.md) for the
  contract).

## Install

**Today:** the CLI ships inside the macOS app bundle. After installing
[MacParakeet](https://macparakeet.com), the binary is at:

```bash
/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli --help
```

For convenience, symlink it onto your `$PATH`:

```bash
ln -s /Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli \
      /usr/local/bin/macparakeet-cli
```

**On the roadmap:** `brew install moona3k/tap/macparakeet-cli` for a
standalone install with no `.app` required. See
[`../plans/active/cli-as-canonical-parakeet-surface.md`](../plans/active/cli-as-canonical-parakeet-surface.md).

## Why Apple Silicon specifically

Parakeet TDT runs on the Apple Neural Engine via CoreML. That is the entire
performance story: 155x realtime, ~66 MB working memory per inference slot.
On VPS hosts without Apple Silicon (typical for cloud-deployed agent
daemons), Parakeet falls back to CPU and Whisper.cpp is competitive. **The
compelling deployment target is a Mac mini (M1+) running headless** as a
personal AI compute box -- unified memory, ANE, ~8W idle, silent.

## Common commands (the agent vocabulary)

Every command below produces JSON when `--json` is passed. Schemas are stable
per [`../Sources/CLI/CHANGELOG.md`](../Sources/CLI/CHANGELOG.md).

### Health probe (run at agent init)

```bash
macparakeet-cli health --json
```

Reports model readiness, database accessibility, and binary deps (FFmpeg,
yt-dlp). This is a non-mutating probe; it reports missing helper binaries but
does not install or update them. App-bundled CLI installs include a signed
yt-dlp helper seed for YouTube transcription; use
`macparakeet-cli health --repair-binaries` when you explicitly want to fetch
the latest managed helper binary.

### Transcribe a file

```bash
macparakeet-cli transcribe /path/to/audio.mp3 --format json
```

Parakeet is the default engine. Use Whisper per invocation for Korean or other
non-Parakeet languages:

Whisper requires a local model download before first use:

```bash
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
```

```bash
macparakeet-cli transcribe /path/to/korean.mp3 --engine whisper --language ko --format json
```

### Transcribe a YouTube video

```bash
macparakeet-cli transcribe "https://www.youtube.com/watch?v=..." --format json
```

### Look up past transcriptions

```bash
macparakeet-cli history transcriptions --json
macparakeet-cli history search-transcriptions "design review" --json
```

### Search past dictations

```bash
macparakeet-cli history dictations --json
macparakeet-cli history search "what did I say about" --json
```

### List or run a prompt against a transcription

```bash
macparakeet-cli prompts list --json
macparakeet-cli prompts run "Action items" \
  --transcription <id-or-prefix> \
  --provider anthropic \
  --api-key-env ANTHROPIC_API_KEY \
  --model claude-sonnet-4-6 \
  --json
```

`<id-or-prefix>` accepts a full UUID, a UUID prefix (>= 4 chars), or the
case-insensitive name. Ambiguous prefixes return a `.ambiguous` error so the
agent can re-prompt the user.

### Inspect meeting recordings

Meeting commands are deterministic local database operations. They do not
require an LLM provider.

```bash
macparakeet-cli meetings list --json
macparakeet-cli meetings show <id-or-prefix-or-title> --json
macparakeet-cli meetings transcript <id> --format text
macparakeet-cli meetings transcript <id> --format json
macparakeet-cli meetings notes get <id> --json
macparakeet-cli meetings notes append <id> --text "Decision: ship the parser"
macparakeet-cli meetings notes clear <id> --json
macparakeet-cli meetings export <id> --format md --stdout
```

Prompt and direct LLM JSON responses use an envelope with `output`, `provider`,
`model`, optional `usage`, optional `stopReason`, and `latencyMs`.

When a `--json` command fails *after argument parsing succeeds* (provider
error, missing input, lookup miss, runtime exception, etc.), stdout is a
structured failure envelope instead of the success shape:

```json
{
  "ok": false,
  "error": "Provider error: No models loaded.",
  "errorType": "provider"
}
```

`errorType` is a stable low-cardinality string. Branch on the exit code, then
use `errorType` to differentiate retryable failures (`rate_limit`,
`connection`, `streaming`) from permanent ones (`auth`, `model`,
`input_empty`, `lookup`, `validation`). Full taxonomy in
`Sources/CLI/CHANGELOG.md`.

Parse-time failures (unknown flags, missing required flags,
mutually-exclusive combos like `--json` with `--stream`) surface through
ArgumentParser's plain-text stderr path with exit code `2`. Always branch
on the exit code first.

## Use it as an agent skill

The clean integration shape is a thin skill wrapper around
`macparakeet-cli`, not a second transcription implementation. The skill's job
is to teach an agent when to call the CLI, how to parse the JSON envelopes, and
which operations are deterministic local database reads/writes.

Claude Code-style skills are a good template because they are just a directory
with a `SKILL.md` file: the frontmatter names when the skill should load, and
the body gives concise operating instructions. The same pattern ports to Codex,
OpenClaw, Hermes, or any agent framework that can shell out to local tools.

```text
macparakeet-stt/
  SKILL.md
```

````markdown
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
user wants YouTube transcription, run
`macparakeet-cli health --repair-binaries` before retrying.

## Core Commands

```bash
macparakeet-cli transcribe "<path-or-youtube-url>" --format json
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
macparakeet-cli transcribe "<path-or-youtube-url>" --engine whisper --language ko --format json
macparakeet-cli history transcriptions --json
macparakeet-cli history search-transcriptions "<query>" --json
macparakeet-cli history search "<query>" --json
macparakeet-cli meetings list --json
macparakeet-cli meetings show "<id-or-prefix-or-title>" --json
macparakeet-cli meetings transcript "<id-or-prefix-or-title>" --format json
macparakeet-cli meetings notes append "<id-or-prefix-or-title>" --text "<note>" --json
macparakeet-cli meetings export "<id-or-prefix-or-title>" --format md --stdout
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
- Parse stdout as JSON for `--json` / `--format json` commands.
- Treat exit code `2` as invocation misuse; fix the command before retrying.
- Treat lookup ambiguity as normal; ask for or choose a more specific ID.
- Never delete user database records unless the user explicitly requests it.
- Prefer meeting ID or UUID prefix over title when mutating notes.
- Keep API keys in environment variables; do not put literal keys in commands.
````

## Conventions

- **Exit codes:** `0` success, `1` runtime failure (work attempted and failed
  -- LLM error, DB error, transcription failure), `2` validation/misuse
  (malformed invocation -- unknown flag, missing required arg, unsupported
  `--format`), `130` SIGINT. After argument parsing succeeds, JSON output
  never goes to stderr regardless of code; parse-time failures still use
  ArgumentParser's plain-text stderr path. Full table in
  `Sources/CLI/CHANGELOG.md` "Exit codes" section.
- **API keys:** prefer provider env vars or `--api-key-env NAME`. Hosted
  providers read `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, and
  `OPENROUTER_API_KEY` directly. Avoid `--api-key sk-...`; command-line
  arguments can appear in shell history and process listings.
- **JSON flag shape:** read-only query commands take `--json` (a binary flag);
  `transcribe` and `export` take `--format json` because they emit one of
  several formats (txt / srt / vtt / json / docx / pdf). Both produce stable
  JSON schemas. The split is deliberate -- see
  `Sources/CLI/CHANGELOG.md` for the compatibility note.
- **Lookups:** records that take an `<id-or-name>` argument accept full UUID,
  UUID prefix (>= 4 chars), or case-insensitive name. Ambiguous prefixes
  produce a `.ambiguous` error; missing records produce `.notFound`.
- **Privacy:** STT and database access never touch the network. Network
  egress paths are: explicit helper repair (`health --repair-binaries`),
  YouTube downloads (yt-dlp), optional LLM provider calls (only when
  `prompts run` or `llm` targets a hosted provider, or when a configured
  Local CLI command contacts its own service), Sparkle update checks (app,
  not CLI), and a single privacy-safe
  `cli_operation` event per `transcribe` invocation, posted to the self-hosted
  endpoint at `https://macparakeet.com/api/telemetry`. The telemetry event
  ships only allowlisted invocation metadata (`operation_id`, `workflow_id`,
  `parent_operation_id`, `command`, `subcommand`, `outcome`,
  `duration_seconds`, `input_kind`, `output_format`, `json`, `exit_code`,
  `error_type`) — never the file path, URL, transcript, language value, or any
  user content (random per-process session UUID, no persistent identifier).
  Disable it any of four ways:
    - `MACPARAKEET_TELEMETRY=0` (per process)
    - `DO_NOT_TRACK=1` (industry-standard signal, also honored)
    - `macparakeet-cli config set telemetry off` (persists in the shared
      UserDefaults suite the GUI reads)
    - "Help improve MacParakeet" toggle in the GUI Settings → Privacy card

  Auto-disabled in CI environments (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`,
  `BUILDKITE`, `CIRCLECI`, `TRAVIS`, `JENKINS_URL`, `TF_BUILD`,
  `TEAMCITY_VERSION` — any one set to a truthy value). Override CI auto-
  disable with `MACPARAKEET_TELEMETRY=1`. See `docs/telemetry.md` for the
  full event catalog and the Worker-side PII redaction policy.
- **Concurrency:** the STT scheduler reserves one slot for dictation and
  shares a second slot for meeting / batch work (ADR-016). Multiple
  concurrent CLI calls share the background slot; expect serial transcription
  of multi-file batches.

## Per-ecosystem entry points

- **OpenClaw:** [`openclaw/README.md`](./openclaw/README.md)
- **Hermes Agent:** [`hermes/README.md`](./hermes/README.md)
- **Claude Code / Codex CLI / generic skill consumers:** use the
  Claude Code-style `SKILL.md` sketch above for external agents that call
  `macparakeet-cli`. Coding agents working inside this repository should read
  [`/AGENTS.md`](../AGENTS.md) instead.

## Reporting issues

Open an issue at <https://github.com/moona3k/macparakeet/issues> with the
`integration` label. Include the agent platform, the CLI version
(`macparakeet-cli --version`), and a minimal repro.
