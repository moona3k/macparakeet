# Integrations -- using `macparakeet-cli` from your agent

> If you are a *coding agent working in this repo*, read
> [`/AGENTS.md`](../AGENTS.md) instead. This directory is for agents (and the
> people running them) that want to *call* `macparakeet-cli` to add local STT
> to their stack.

Examples describe the current development contract (CLI 3.2), not a
promise about an older stable or Homebrew binary. Check `--version` and
`spec --json` first; [release channels](../spec/README.md#release-channels-and-feature-flags)
distinguish published binaries from the development source.

## Scope of the CLI

The CLI is a first-class automation surface, **not a GUI mirror.** It intentionally
does not replicate every affordance the .app provides -- it exposes the parts
that map cleanly to headless automation, agent invocation, and scriptable
testing.

### In scope

- **Local transcription** -- audio/video files, folders, public media URLs,
  Apple Podcasts links/searches, and YouTube to text, with engine selection
  (Parakeet / Nemotron / Cohere / Whisper) and per-invocation language hints.
- **Scriptable shared defaults** -- `config get|set|list` over the same
  preference suite the GUI reads (`com.macparakeet.MacParakeet`). CLI-only
  installs work; a later GUI install picks up the same values.
- **Stable JSON / read surfaces** -- every read-only command emits JSON with
  schemas pinned to the major CLI version. Failure envelopes carry a stable
  `errorType` so agents can branch deterministically.
- **Model and binary health** -- `health --json` reports model readiness,
  database accessibility, FFmpeg, and yt-dlp without mutating state. Repair
  flags explicitly warm/download local caches; missing application directories
  are reported rather than created by the probe.
- **Persisted history and knowledge retrieval** -- list/search prior
  dictations and transcriptions, retrieve cited transcript segments, and
  inspect current knowledge cards from the shared SQLite database. Card
  generation is a separate, provider-backed write.
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
  the floating meeting pill, live recording controls, and in-flight
  post-stop transcription abort/delete confirmation are GUI-only. The CLI
  inspects meeting artifacts after the fact.
- **Onboarding, settings UI, library grids, sounds, overlays** -- none of these
  have automation analogues; they remain in the .app.

The principle: if a use case can be automated, scripted, or driven by an agent,
the CLI should support it through a stable contract. If it requires a user
sitting at a keyboard, it lives in the .app.

## What `macparakeet-cli` gives your agent

- **Local Parakeet speech-to-text** on Apple Silicon, with v3 for English plus
  supported European languages, v2 for English timestamped transcripts, and
  Unified for readable English timestamped transcripts. Runs on the Neural Engine.
  No cloud, no API keys, no per-minute charges.
- **Audio + video file transcription** -- accepts MP3 / WAV / MP4 / MOV /
  WebM / etc. via the bundled FFmpeg, with sequential folder/multi-file batch
  output.
- **Media URL transcription** via yt-dlp for public media URLs, plus native
  Apple Podcasts link resolution and freetext Apple Podcasts search through
  `transcribe --podcast`. The standalone Homebrew install uses Homebrew's
  `yt-dlp`; the app bundle can seed a signed helper into MacParakeet's
  Application Support folder before first media URL use.
- **Persistent SQLite memory layer** -- saved transcriptions, dictations, and
  prompt outputs remain queryable; private/no-history operations deliberately
  do not retain transcript content.
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
Parakeet, Nemotron, and Cohere CoreML caches are managed by FluidAudio.
WhisperKit model downloads live under
`~/Library/Application Support/MacParakeet/models/stt/whisper/`.

**Bundled app alternative:** after installing
[MacParakeet](https://macparakeet.com), the same CLI surface is available at:

```bash
/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli --help
```

MacParakeet deliberately does not modify your shell configuration or install
files into package-manager directories. If you want the bundled executable
under the shorter `macparakeet-cli` command, use the Homebrew installation
above or configure your own shell alias, PATH entry, or symlink. First check
whether another copy is already available:

```bash
command -v macparakeet-cli
```

The Homebrew CLI and the app-bundled CLI are released independently, so their
versions can differ. Use `command -v macparakeet-cli` and
`macparakeet-cli --version` to confirm which executable Terminal will run. Do
not replace a Homebrew-managed link with an app-managed link.

## Why Apple Silicon specifically

The supported runtime is macOS 14.2+ on Apple Silicon (M1 or newer), where
Parakeet uses CoreML/Apple Neural Engine. The CLI does not support Linux/x86
VPS deployment or offer a CPU fallback there. A headless Apple Silicon Mac is
the deployment target; it still needs local model setup and any selected
external provider/helper configuration.

## Common commands (the agent vocabulary)

The commands below show the machine-readable flag each command expects:
`--json` for fixed-shape query/envelope commands, `--format json` for
format-selecting commands. Schemas are stable per
[`../Sources/CLI/CHANGELOG.md`](../Sources/CLI/CHANGELOG.md).

Discover the installed command catalog before constructing an invocation.
Each entry describes its path, arguments/options, `jsonMode`, `readOnly`
classification, and output summary. It is not a JSON Schema for every payload
or a sandbox: a command family may be marked mutating because some options
write, and query startup can still create directories or migrate supported
database schemas. Use `--help` for additional setup/helper details:

```bash
macparakeet-cli spec --json
```

### Health probe (run at agent init)

```bash
macparakeet-cli health --json
```

Reports model readiness, database accessibility, and binary dependencies
(FFmpeg, yt-dlp). Without repair flags it does not install/update helpers,
download models, migrate/create the database, or create application
directories. Inspect the report's component statuses and `paths`,
not only its exit code: an uninstalled optional model does not block a local
database search. Repair only a prerequisite for the requested operation, with
user authorization; `health --repair-binaries` can fetch a managed helper.

`database.status` is one of `ok`, `missing`, `schema_skew`, or `error`.
`schema_skew` means the shared database was migrated by a newer MacParakeet
app than this CLI build understands; upgrade `macparakeet-cli` and retry
rather than treating it as a database fault.

### Safe automation and isolation

- Start with `--version`, `spec --json`, then the health report and the
  narrowest relevant read. Never repair, regenerate, clear, or delete merely
  because a component is missing.
- Normal CLI calls share the user's database, preferences, model caches, and
  artifact paths with the app. `config set` and `models select` change shared
  defaults; prefer per-invocation flags for reproducible work.
- `--database PATH` selects a database only where advertised. It does not
  isolate preferences, Keychain, models, downloads, or the audio/artifact paths
  stored in copied rows. Never run destructive commands against a copied
  production database that still points to original user files.
- For source-build smoke work, a **DEBUG** binary with
  `MACPARAKEET_DEBUG_APP_STATE_DIR` set to an absolute test-owned directory
  redirects app-support/artifact paths and speech/speaker model caches.
  Release binaries ignore this override. It does **not** redirect the shared
  UserDefaults suite or Keychain; avoid configuration writes, or use a
  disposable macOS account when full user-state isolation is required.
- `--no-history` avoids completed transcript retention, not all I/O. Transcribe
  can still initialize a database, use models/helpers, and emit telemetry.
  `MACPARAKEET_TELEMETRY=0` disables telemetry for one invocation without
  changing shared preferences; it is not a network sandbox.
- `search-reindex` writes derived indexes; `cards generate` additionally calls
  the configured LLM. `meetings artifact` refreshes files from SQLite, while
  notes/results commands modify user-visible records. Treat these as writes,
  not read-only inspection. Do not manually edit generated sidecars as though
  they were canonical database records.
- Query classification does not guarantee zero writes: database startup can
  initialize/migrate supported storage, and `cards list` can refresh outdated
  derived transcript segments before checking card freshness. It does not
  generate cards or call an LLM. Use the non-mutating default health probe
  when deciding whether it is safe to open a database.

### Transcribe a file

```bash
macparakeet-cli transcribe /path/to/audio.mp3 --format json
```

For shell pipelines where stdout should contain only transcript text:

```bash
macparakeet-cli transcribe /path/to/audio.mp3 --format transcript
macparakeet-cli transcribe /path/to/audio.mp3 --format transcript --no-history | pbcopy
```

For a local container with multiple embedded audio streams, select one with a
one-based track number. The choice is persisted with saved history and reused
by retranscription:

```bash
macparakeet-cli transcribe /path/to/episode.mkv --audio-track 2 --format json
```

`--audio-track` works for local files and folders only; media URLs and podcast
inputs reject it rather than pretending to control a remote/download stream.

To write a subtitle or structured DAPT transcript directly, use
`--format srt|vtt|dapt` with an `--output-dir` (one command, no separate
`export` step):

```bash
macparakeet-cli transcribe /path/to/audio.mp3 --format vtt --output-dir .
# -> ./audio.vtt   (same renderer as `export --format vtt`)
macparakeet-cli transcribe /path/to/interview.mp3 --format dapt --output-dir .
# -> ./interview.dapt.xml
```

A single input without `--output-dir` prints the selected document to stdout,
so you can also redirect it:
`macparakeet-cli transcribe interview.mp3 --format dapt > interview.dapt.xml`.
DAPT preserves word timing and speaker attribution when they are aligned with
the transcript. Current display labels become character aliases; if the
optional label roster is incomplete, stored anonymous IDs such as `S2` remain
anonymous aliases. If diarization is off or unavailable, DAPT omits character
agents; if word timing is unavailable, it emits a valid untimed original
transcript rather than inventing timing or attribution.

To re-export something already in your library, list it and export by id:

```bash
macparakeet-cli history transcriptions          # note the subcommand; lists ids
macparakeet-cli export <id> --format dapt
```

To rerun STT for an existing saved item without creating a new library row,
use `retranscribe`. It requires retained source audio and an explicit
`--update` confirmation because it replaces transcript-derived fields on the
existing record:

```bash
macparakeet-cli retranscribe <id-or-prefix-or-title> --update --json
macparakeet-cli retranscribe <id> --kind meeting --update --engine cohere --language ja --envelope
```

`retranscribe` resolves dictations by UUID/prefix, transcriptions by
UUID/prefix or exact name, and meetings by UUID/prefix or exact title. Auto
resolution fails if the identifier matches more than one saved record; retry
with a full UUID, or a longer UUID prefix for prefix matches. Use
`--kind dictation|transcription|meeting` only to disambiguate cross-kind matches. It
supports the same speech-engine, model, language, and processing-mode flags as
`transcribe`; speaker-detection flags apply only to saved transcriptions and
meetings.

`--no-history` avoids retaining the completed transcription in the shared
MacParakeet history. For media URL and podcast inputs, downloaded audio is
temporary when `--no-history` is set.

Parakeet is the default local engine for compatibility with existing scripts:
use v3 for English plus supported European languages, v2 for English timestamped
transcripts, or Unified for readable English with word timestamps. Use Nemotron
Beta when streaming preview matters, Whisper for broad-language
files/media/retranscription, and Cohere only for local batch plain text with an
explicit language.

Nemotron, Cohere, and Whisper require local model downloads before first use:

```bash
macparakeet-cli models download nemotron-multilingual-1120ms
macparakeet-cli models download cohere-transcribe
macparakeet-cli models download whisper-large-v3-v20240930-turbo-632MB
```

Agents can inspect and switch the shared default speech model:

```bash
macparakeet-cli models list --json
macparakeet-cli models select parakeet-v3 --json
macparakeet-cli models select parakeet-v2 --json
macparakeet-cli models select nemotron-multilingual-1120ms --json
macparakeet-cli models select cohere-transcribe --json
macparakeet-cli models select whisper-large-v3-v20240930-turbo-632MB --json
```

```bash
macparakeet-cli transcribe /path/to/spanish.mp3 --engine nemotron --language auto --format json
macparakeet-cli transcribe /path/to/japanese.m4a --engine cohere --language ja --format json
macparakeet-cli transcribe /path/to/korean.mp3 --engine whisper --language ko --format json
```

To test the same defaults a user selected in the GUI, make every app-default
read explicit. Bare `transcribe` already follows the saved file/URL
speaker-detection preference, while `retranscribe --kind meeting` follows the
saved meeting speaker-detection preference when left at app-default. The full
flag group below also opts into saved speech-engine, processing,
audio-retention, and YouTube-quality defaults. This does not exercise GUI-only
UI, playback, hotkey, export, or optional AI formatter output.

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
macparakeet-cli config set nemotron-language auto
macparakeet-cli config set whisper-language ko
macparakeet-cli config set cohere-language ja
macparakeet-cli config set processing-mode raw
macparakeet-cli config set speaker-detection off
macparakeet-cli config set meeting-speaker-detection off
macparakeet-cli config set save-transcription-audio off
macparakeet-cli config set youtube-audio-quality m4a
```

`--engine whisper` uses Whisper with auto-detected language unless `--language`
is passed. `--engine cohere` uses the saved Cohere language unless `--language`
is passed, because Cohere has no auto-detect. Saved engine-specific languages
are used when `--engine app-default` resolves to that engine.

### Transcribe a media URL

```bash
macparakeet-cli transcribe "https://www.facebook.com/reel/..." --format json
```

### Transcribe a podcast

```bash
macparakeet-cli transcribe "https://podcasts.apple.com/us/podcast/example/id123456789?i=987654321" --format json
macparakeet-cli transcribe --podcast "Lex Fridman episode 400" --format json
```

### Look up past transcriptions

```bash
macparakeet-cli history transcriptions --json
macparakeet-cli history search-transcriptions "design review" --json
```

### Search the transcript knowledge layer

```bash
macparakeet-cli search '"cache busting" OR sparkle*' --json
macparakeet-cli search 'decision AND parser' --source meeting --speaker Dana --limit 20 --json
macparakeet-cli search '重要な会議' --since 2026-01-01 --json
```

`search` returns citation-ready segment hits with recording metadata, `seq`,
optional `startMs`/speaker, a character-safe snippet, and FTS rank. FTS5 phrase,
prefix, and `AND`/`OR` syntax passes through unchanged. Han/Kana/Thai queries
automatically use an exact substring fallback and return `rank: null`.
Bare `yyyy-MM-dd` values use the user's local day (`--since` at its start,
`--until` through its end); timestamps with `Z` or an explicit offset retain
that zone.

If an upgraded library lacks the segment index, explicitly authorize one
deterministic local rebuild (a database write, not a provider call):

```bash
macparakeet-cli search-reindex --json
```

Drill into either a meeting or file/URL transcription without loading the
whole transcript:

```bash
macparakeet-cli transcript <id> --around 00:12:30 --window 30s --json
macparakeet-cli transcript <id> --around-seq 18 --context 2 --json
```

Legacy/no-timing rows remain searchable. Their segments have `startMs: null`,
so sequence-based context is the precise citation path; timestamp reads degrade
to the first sequence context instead of failing.

### Scan and backfill knowledge cards

Cards are compact, regenerable index entries for deciding which transcript to
open and where to verify candidate decisions/actions:

```bash
macparakeet-cli cards list --since 2026-01-01 --source meeting --json
macparakeet-cli cards list --limit 1000 --ndjson
macparakeet-cli cards generate --stale --json
macparakeet-cli cards generate <id-or-prefix> --json
```

`cards list` joins title, recording date, nullable duration, source, and
nullable calendar attendees from the canonical transcription row; those fields
are not duplicated in card storage. Meeting cards can include cited candidate
decisions/actions. File and URL cards always return empty decision/action
arrays. Stale cards are suppressed rather than returned with obsolete citation
ranges. Treat extracted decisions/actions as routing hints and verify them with
`transcript --around-seq` before asserting them as facts.

Use `cards list` to route across recordings, `search` for concrete phrases, and
`transcript` for evidence. Include the recording ID/title and segment sequence
(plus timestamp when available) in citations. Dictations use the separate
`history search` path; segment/card retrieval is not a cross-mode Ask endpoint.

Card generation uses the provider already opted into in MacParakeet Settings.
Progress and per-recording token counts go to stderr. JSON stdout reports
aggregate prompt/completion/total tokens; `estimatedCostUSD` is explicitly
`null` because model pricing is not available as a reliable local contract.
`--stale` is idempotent across the transcript hash, prompt version, card schema
version, and segmenter version. A failed regeneration keeps the prior card,
appears in the aggregate report, and makes the command exit `1`.
The `selected` count for `--stale` is the SQL-prefiltered stale/missing subset;
the backfill also rebuilds the card FTS index for integrity recovery.

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
macparakeet-cli meetings artifact <id> --json
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

`meetings artifact` is the stable folder contract for local meeting sessions.
It refreshes the session folder from SQLite and returns paths to:

- `manifest.json` — schema, meeting metadata, and file index
- `meeting.md` — deterministic Markdown view with local frontmatter, notes,
  transcript, prompt-result index, and artifact paths
- `transcript.json` — transcript text, timestamps, speakers, diarization
- `notes.md` — user-authored notes when present
- `prompt-results.json` and `prompt-results/*.md` — saved generated outputs

The snapshot, `manifest.meeting`, and `transcript.json` can carry
`meetingCaptureReport`. `quality: "partial"` describes retained audio, not a
failed transcription: partial audio can have `status: "completed"`. An absent
legacy report means unknown, not healthy. The candidate's `silent` system
status survives recovery when coverage stays sufficient and means exact-zero
written system signal under the qualified conditions in the
[artifact contract](../spec/contracts/meeting-artifacts-v1.md); it is not a
quiet-audio threshold or evidence that no remote speaker spoke. A `silent`
status alone does not make `quality` partial — a fully captured self-note or
other one-sided recording reports `quality: "healthy"`; coverage shortfall,
interruption, capture failure, or unavailable media still do.

`meetings export <id> --format md --stdout` uses the same Markdown shape as
`meeting.md` without refreshing unrelated files. For machine-readable paths,
use `meetings artifact <id> --json` (`markdownPath`) or
`meetings export <id> --stdout --format json` (`artifactMarkdownPath`).

Future meeting sessions are stored under the configured artifact root:

```bash
macparakeet-cli config get meeting-artifacts-folder
macparakeet-cli config set meeting-artifacts-folder ~/Documents/MacParakeet/Meetings
macparakeet-cli config set meeting-artifacts-folder default
```

For post-meeting local automation, configure a disabled-by-default hook. The
hook path must be an absolute executable path; MacParakeet runs it without a
shell, sends a `meeting.completed` JSON event on stdin, times out, and writes
`automation-hook-result.json` back into the meeting folder.

```bash
macparakeet-cli config set meeting-hook-path /absolute/path/to/hook
macparakeet-cli config set meeting-hook-timeout 20
macparakeet-cli config set meeting-hook-enabled on
```

Meeting commands that support `--envelope` return an opt-in success envelope:

```json
{
  "ok": true,
  "command": "meetings artifact",
  "data": {},
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-06-13T00:00:00Z",
    "warnings": []
  }
}
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
  "errorType": "provider",
  "fix": "Check provider configuration and retry.",
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-06-13T00:00:00Z",
    "warnings": []
  }
}
```

`errorType` is a stable low-cardinality string; `fix` and `meta` are optional.
Branch on the exit code, then classify the error with
`Sources/CLI/CHANGELOG.md`. A potentially transient provider error
(`rate_limit`, `connection`, `streaming`) does not by itself authorize replaying
a mutating command. Check whether partial output or saved results already
exist before retrying; fix `auth`, `model`, input, lookup, and validation
problems rather than retrying them unchanged.

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

The reusable skill lives at
[`integrations/skill/macparakeet-stt/SKILL.md`](skill/macparakeet-stt/SKILL.md).
Use that file directly when packaging MacParakeet for Codex, Claude Code,
OpenClaw, Hermes, or another local agent framework.

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
  format-selecting commands take `--format json` because they emit one of
  several formats (txt / markdown / srt / vtt / dapt / json). Commands that
  normally write files, such as `meetings export`, also require `--stdout` when
  you want JSON on stdout. The split is deliberate -- see
  `Sources/CLI/CHANGELOG.md` for the compatibility note.
- **Lookups:** records that take an `<id-or-name>` argument accept full UUID,
  UUID prefix (>= 4 chars), or case-insensitive name. Ambiguous prefixes
  produce a `.ambiguous` error; missing records produce `.notFound`.
- **Privacy:** speech inference and database queries run locally, but an entire
  CLI invocation is not necessarily network-free. Network paths include model
  downloads/warm-up/repair, helper repair, media URL and podcast directory/RSS/
  enclosure downloads, explicitly configured LLM calls (including
  `cards generate`, prompt/Transform execution, and cloud-backed Local CLI
  commands), explicit feedback submission, and CLI telemetry below.
  The app also checks Sparkle updates and unconditionally refreshes Discover's
  public feed at launch, independently of telemetry; the CLI does not launch
  that feed refresh. No captured audio is sent to an LLM by MacParakeet.
  CLI telemetry emits a single privacy-safe
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
  full event catalog and the structured-error privacy contract. For read-only
  local audio-log JSON queries from a source checkout, see
  [the diagnostic query guide](../docs/local-audio-diagnostics-query.md).
- **Concurrency:** the STT scheduler reserves one slot for dictation and shares
  a second slot for meeting/batch work **within a process** (ADR-016).
  Multi-file batches are sequential. Separate CLI processes do not share that
  in-memory scheduler or a cross-process model lock; callers must bound their
  own concurrency rather than assuming the app serializes separate binaries.

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
