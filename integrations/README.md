# Integrations -- using `macparakeet-cli` from your agent

> If you are a *coding agent working in this repo*, read
> [`/AGENTS.md`](../AGENTS.md) instead. This directory is for agents (and the
> people running them) that want to *call* `macparakeet-cli` to add local STT
> to their stack.

## Scope of the CLI

The CLI is a first-class automation surface, **not a GUI mirror.** It intentionally
does not replicate every affordance the .app provides -- it exposes the parts
that map cleanly to headless automation, agent invocation, and scriptable
testing.

### In scope

- **Local transcription** -- audio, video, and YouTube to text, with engine
  selection (Parakeet / Whisper) and per-invocation language hints.
- **Scriptable shared defaults** -- `config get|set|list` over the same
  preference suite the GUI reads (`com.macparakeet.MacParakeet`). CLI-only
  installs work; a later GUI install picks up the same values.
- **Stable JSON / read surfaces** -- every read-only command emits JSON with
  schemas pinned to the major CLI version. Failure envelopes carry a stable
  `errorType` so agents can branch deterministically.
- **Model and binary health** -- `health` probes Parakeet / Whisper model
  readiness, database accessibility, FFmpeg, and yt-dlp without mutating state.
- **Persisted history** -- list, search, and inspect prior dictations and
  transcriptions via the shared SQLite database.
- **Prompt and meeting inspection** -- list and run prompt library entries
  against transcriptions; list, show, transcript, notes append, prompt-result
  write-back, and export meeting recordings.
- **Headless verification hooks** -- agents can drive deterministic runs (pin
  all flags) or smoke-test GUI-default behavior with the explicit
  `app-default` flag group.

### Out of scope (by design)

- **Interactive dictation** -- live mic capture, push-to-talk, the global
  hotkey, and the dictation overlay are GUI surfaces. The CLI does not record
  from the microphone.
- **Live meeting UI** -- the Notes / Transcript / Ask three-tab live panel,
  the floating meeting pill, and live recording controls are GUI-only. The CLI
  inspects meeting artifacts after the fact.
- **Onboarding, settings UI, library grids, sounds, overlays** -- none of these
  have automation analogues; they remain in the .app.

The principle: if a use case can be automated, scripted, or driven by an agent,
the CLI should support it through a stable contract. If it requires a user
sitting at a keyboard, it lives in the .app.

## What `macparakeet-cli` gives your agent

- **Local Parakeet TDT speech-to-text** at ~155x realtime on Apple Silicon,
  with v3 multilingual default and v2 English-only opt-in
  with ~2.5% WER, running on the Neural Engine. No cloud, no API keys, no
  per-minute charges.
- **Audio + video file transcription** -- accepts MP3 / WAV / MP4 / MOV /
  WebM / etc. via the bundled FFmpeg.
- **Media URL transcription** via yt-dlp, including YouTube and other public
  media URLs supported by yt-dlp. The standalone Homebrew install uses
  Homebrew's `yt-dlp`; the app bundle can seed a signed helper into
  MacParakeet's Application Support folder before first media URL use.
- **Persistent SQLite memory layer** -- everything transcribed is queryable
  later: dictation history, transcriptions, prompt outputs.
- **Shared app/CLI preferences** -- agents can set speech engine, processing
  mode, speaker detection, audio retention, YouTube audio quality, and
  telemetry without driving the GUI.
- **Prompt library + LLM-backed summarization** -- bring your own provider
  (OpenAI, Anthropic, Ollama, LM Studio, OpenAI-compatible local, or a
  configured CLI subprocess), or skip the LLM entirely and consume raw
  transcripts.
- **Machine-readable output** -- read-only query commands use `--json`,
  format-selecting commands use `--format json`, and LLM/prompt commands use
  `--json` for structured envelopes (see
  [`../Sources/CLI/CHANGELOG.md`](../Sources/CLI/CHANGELOG.md) for the
  contract).

## Install

**Recommended for agents/headless Macs:**

```bash
brew install moona3k/tap/macparakeet-cli
macparakeet-cli --version
macparakeet-cli health --json
```

This installs the standalone CLI plus its Homebrew-managed `ffmpeg` and
`yt-dlp` runtime dependencies. It does not require `MacParakeet.app`.
Parakeet's CoreML cache is managed by FluidAudio. WhisperKit model downloads
live under `~/Library/Application Support/MacParakeet/models/stt/whisper/`.

**Bundled app alternative:** after installing
[MacParakeet](https://macparakeet.com), the same CLI surface is available at:

```bash
/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli --help
```

For convenience, symlink it onto your `$PATH`:

```bash
ln -s /Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli \
      /usr/local/bin/macparakeet-cli
```

## Why Apple Silicon specifically

Parakeet TDT runs on the Apple Neural Engine via CoreML. That is the entire
performance story: 155x realtime, ~66 MB working memory per inference slot.
On VPS hosts without Apple Silicon (typical for cloud-deployed agent
daemons), Parakeet falls back to CPU and Whisper.cpp is competitive. **The
compelling deployment target is a Mac mini (M1+) running headless** as a
personal AI compute box -- unified memory, ANE, ~8W idle, silent.

## Common commands (the agent vocabulary)

The commands below show the machine-readable flag each command expects:
`--json` for fixed-shape query/envelope commands, `--format json` for
format-selecting commands. Schemas are stable per
[`../Sources/CLI/CHANGELOG.md`](../Sources/CLI/CHANGELOG.md).

Agents can discover the curated core automation surface at runtime. This spec
is intentionally agent-facing and does not list every setup/helper command in
this README:

```bash
macparakeet-cli spec --json
```

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

For shell pipelines where stdout should contain only transcript text:

```bash
macparakeet-cli transcribe /path/to/audio.mp3 --format transcript
macparakeet-cli transcribe /path/to/audio.mp3 --format transcript --no-history | pbcopy
```

`--no-history` avoids retaining the completed transcription in the shared
MacParakeet history. For YouTube inputs, downloaded audio is temporary when
`--no-history` is set.

Parakeet is the default engine for compatibility with existing scripts. Use
`--parakeet-model v2` or `config set parakeet-model v2` for the English-only
Parakeet build. Use Whisper per invocation for Korean or other non-Parakeet
languages:

Whisper requires a local model download before first use:

```bash
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
```

Agents can inspect and switch the shared default speech model:

```bash
macparakeet-cli models list --json
macparakeet-cli models select parakeet-v3 --json
macparakeet-cli models select parakeet-v2 --json
macparakeet-cli models select whisper-large-v3-v20240930-turbo-632MB --json
```

```bash
macparakeet-cli transcribe /path/to/korean.mp3 --engine whisper --language ko --format json
```

To test the same defaults a user selected in the GUI, make every app-default
read explicit. Bare `transcribe` already follows the saved speaker-detection
preference, but the full flag group below also opts into saved speech-engine,
processing, audio-retention, and YouTube-quality defaults. This does not
exercise GUI-only UI, playback, hotkey, export, or optional AI formatter output.

```bash
macparakeet-cli transcribe /path/to/audio.mp3 \
  --engine app-default \
  --parakeet-model app-default \
  --speaker-detection app-default \
  --mode app-default \
  --downloaded-audio app-default \
  --media-audio-quality app-default \
  --format json
```

For a specific file or recording where the speaker count is known, constrain
speaker detection per run instead of changing the saved default:

```bash
macparakeet-cli transcribe /path/to/interview.mp3 --speaker-count 2 --format json
macparakeet-cli transcribe /path/to/panel.mp3 --speaker-min 2 --speaker-max 4 --format json
```

Those constraint flags imply speaker detection when `--speaker-detection` is
left at `app-default`; they are rejected with `--speaker-detection off` or
`--no-diarize`. Use `--speaker-count` for an exact count, or `--speaker-min`
and/or `--speaker-max` for bounds.

Agents can also set those shared defaults without opening the GUI. Treat this
as pre-run setup: a running GUI may cache some settings until relaunch or an
in-app change.

```bash
macparakeet-cli config set speech-engine whisper
macparakeet-cli config set parakeet-model v3
macparakeet-cli config set whisper-language ko
macparakeet-cli config set processing-mode raw
macparakeet-cli config set speaker-detection off
macparakeet-cli config set save-transcription-audio off
macparakeet-cli config set youtube-audio-quality m4a
```

`--engine whisper` uses Whisper with auto-detected language unless `--language`
is passed. The saved Whisper language is used when `--engine app-default`
resolves to Whisper.

### Transcribe a media URL

```bash
macparakeet-cli transcribe "https://www.facebook.com/reel/..." --format json
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

### Manage live Ask quick prompts

Ask quick prompts are the lightweight chat shortcuts shown in the live meeting
Ask tab. Pinned prompts surface as compact after-response pills; every visible
prompt appears in the empty Ask state and sparkle menu. They are not persistent
transcript result templates.

```bash
macparakeet-cli quick-prompts list --json
macparakeet-cli quick-prompts list --pinned true --json
macparakeet-cli quick-prompts pin "Action items" --json
macparakeet-cli quick-prompts unpin "Tell me more" --json
macparakeet-cli quick-prompts set "Tell me more" --prompt "Expand with more detail from the meeting." --json
macparakeet-cli quick-prompts export --out ask-prompts.json --include-builtins --json
macparakeet-cli quick-prompts import ask-prompts.json --mode merge --dry-run --json
```

The bundle envelope is stable within the CLI major version:
`schema: "macparakeet.quick_prompts"`, `version: 1`. Each prompt carries
`isPinned: Bool` for after-response strip placement.

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
macparakeet-cli meetings results list <id> --json
macparakeet-cli meetings results add <id> \
  --name "Agent Notes" \
  --content "Decision: ship the parser" \
  --json
macparakeet-cli meetings export <id> --format md --stdout
```

Use `meetings notes` for user-authored notes. Use `meetings results add` for
externally generated summaries, decisions, action items, or other agent output;
those rows are stored as `PromptResult` records rather than overwriting
`userNotes`.

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
user wants media URL transcription, run
`macparakeet-cli health --repair-binaries` before retrying.

## Core Commands

```bash
macparakeet-cli spec --json
macparakeet-cli transcribe "<path-or-media-url>" --format json
macparakeet-cli transcribe "<path-or-media-url>" --format transcript --no-history
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
macparakeet-cli models list --json
macparakeet-cli models select parakeet-v3 --json
macparakeet-cli config set parakeet-model v3 --json
macparakeet-cli transcribe "<path-or-media-url>" --engine whisper --language ko --format json
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
macparakeet-cli history transcriptions --json
macparakeet-cli history search-transcriptions "<query>" --json
macparakeet-cli history search "<query>" --json
macparakeet-cli meetings list --json
macparakeet-cli meetings show "<id-or-prefix-or-title>" --json
macparakeet-cli meetings transcript "<id-or-prefix-or-title>" --format json
macparakeet-cli meetings notes append "<id-or-prefix-or-title>" --text "<note>" --json
macparakeet-cli meetings results add "<id-or-prefix-or-title>" --name "Agent Notes" --stdin --json
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
- Use the full app-default group (`--engine app-default`,
  `--parakeet-model app-default`, `--speaker-detection app-default`,
  `--mode app-default`, `--downloaded-audio app-default`, and
  `--media-audio-quality app-default`) when you are intentionally checking
  GUI-default behavior. Pin explicit flags for reproducible agent tests.
- `config get speaker-detection` reports the saved app-default value. Bare
  `transcribe` and `--speaker-detection app-default` use that value; pass
  `--speaker-detection on` or `off` to override it for one run. For known
  speaker counts, use per-run `--speaker-count`, `--speaker-min`, or
  `--speaker-max` instead of mutating the saved default.
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
- **Base URLs:** hosted/non-local providers require `https://` unless the
  endpoint is loopback. For intentional non-loopback `http://` testing, pass
  `--allow-insecure-http`; the CLI writes a stderr warning and keeps stdout
  machine-readable.
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
  media URL downloads (yt-dlp), optional LLM provider calls (only when
  `prompts run` or `llm` targets a hosted provider, or when a configured
  Local CLI command contacts its own service), Sparkle update checks (app,
  not CLI), and a single privacy-safe
  `cli_operation` event per successfully parsed CLI invocation, posted to the
  self-hosted endpoint at `https://macparakeet.com/api/telemetry`. The telemetry event
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
