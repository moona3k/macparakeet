# Changelog -- macparakeet-cli

All notable changes to the **`macparakeet-cli` surface** are documented here.

This file tracks the CLI specifically -- the commands, flags, output schemas,
and exit codes that scripted callers (shell scripts, CI pipelines, AI agents)
depend on. App-level changes ship through Sparkle and are documented in the
appcast at <https://macparakeet.com/appcast.xml>.

The format is based on [Keep a Changelog](https://keepachangelog.com), and the
CLI adheres to [Semantic Versioning](https://semver.org).

## Compatibility policy

The CLI surface is a public contract. We follow semver:

- **MAJOR** -- any change that breaks scripted callers: removed commands,
  renamed flags, removed JSON fields, changed exit-code meanings, changed
  default behavior of an existing flag.
- **MINOR** -- additive changes: new commands, new flags, new optional JSON
  fields, new exit codes for new error classes.
- **PATCH** -- bug fixes, output formatting tweaks that preserve schema,
  documentation, performance work.

When we deprecate a command or flag, the old name keeps working for **at least
one minor release** with a clear `--help` notice and a CHANGELOG callout. New
names are added first; old names are removed only at a MAJOR boundary.

JSON output schemas are part of the contract: top-level shape (array vs
object), field names, and field types are stable within a major version. We
may add new optional fields in a minor release.

### Exit codes

The CLI uses a small set of exit codes. They are part of the public contract;
new error classes get new minor-version codes, never silent reuse.

| Code | Meaning |
|------|---------|
| `0`  | Success. |
| `1`  | Runtime failure -- the command attempted its work and the work failed. Examples: LLM provider call returned an error, transcription failed, database read/write error, network unreachable. The command writes a one-line stderr message describing the failure. |
| `2`  | Validation/misuse -- the invocation itself was malformed before the command did any real work. Examples: unknown provider, missing required flag, malformed input file, unsupported `--format` value. ArgumentParser produces this for unknown flags as well. |
| `130` | Interrupted by `SIGINT` (Ctrl-C). Inherits Unix convention; downstream agents should treat this as cancellation, not failure. |

After argument parsing succeeds, `--json` output never goes to stderr
regardless of exit code. When `--json` is passed, both success and post-parse
failure print a JSON object to stdout; the exit code remains the source of
truth for branching.

### `--json` failure envelope

Any command that accepts `--json` emits this envelope on stdout when the
command fails *after argument parsing succeeds* — provider error, missing
input, lookup miss, runtime exception, etc.:

```json
{
  "ok": false,
  "error": "human-readable message",
  "errorType": "auth"
}
```

`errorType` is a low-cardinality stable string. Current values: `auth`,
`config`, `connection`, `context`, `input_empty`, `input_missing`,
`import_schema`, `invalid_response`, `lookup`, `model`, `provider`,
`rate_limit`, `runtime`, `streaming`, `truncated`, `validation`. New error
classes get new values in minor releases; existing values are stable within a
major.

Stderr stays plain text for human-only progress / status (e.g. "Saved
PromptResult abc12345"), so piping `--json` stdout through `jq` is safe.

**Parse-time / `validate()` failures** (unknown flags, missing required
flags, mutually-exclusive flag combinations like `--json` with `--stream`)
happen before the command starts running and surface through
ArgumentParser's plain-text stderr path with exit code `2`. Downstream
agents that branch on `errorType` should also handle the parse-error case
by checking exit code first: `2` = misuse, `1` = runtime, `0` = success.

## [Unreleased]

## [2.6.0] -- 2026-05-31

### Added

- `models delete <id>` removes a single downloaded model — one Parakeet build
  (`parakeet-v2` / `parakeet-v3`) or the Whisper variant (`whisper-*`) — freeing
  its disk space while leaving every other model in place. Contrast with
  `models clear`, which still wipes the whole local speech/speaker stack.
- The active model is protected, and Parakeet's configured build is protected
  even while Whisper is active: `models delete` refuses it with a validation
  error (exit `2`) so a delete can't silently force a re-download. Pass
  `--force` to delete it anyway.
- Deleting a model that isn't downloaded is a no-op that prints a short note and
  exits `0`.

## [2.5.0] -- 2026-05-30

### Added

- Parakeet now exposes both model builds: the multilingual `v3` (default) and
  the English-only `v2`. v2 is a touch faster on English and never mis-detects
  English speech as another language (the v3 auto-detect failure behind issues
  #311 and #398).
- `config set parakeet-model v3|v2` (also `multilingual`/`english` aliases) and
  `config get parakeet-model` persist the shared GUI/CLI Parakeet build
  preference. Listed in `config list`.
- `transcribe --parakeet-model app-default|v3|v2` overrides the Parakeet build
  for a single run; `app-default` follows the saved preference. Ignored for
  Whisper.
- `models list` now lists both Parakeet builds (`parakeet-v3`, `parakeet-v2`)
  with their per-build install state and approximate size. `models select
  parakeet-v2` (also `parakeet:v2` / `parakeet-english`) persists the build.
  `models warm-up` / `repair` / `status` now operate on the selected build
  instead of always defaulting to v3.
- `models download parakeet-v2` / `parakeet-v3` (and bare `parakeet` for the
  selected build) pre-fetches a Parakeet build without selecting it, alongside
  the existing `whisper-*` download path.
- `transcribe` now accepts **multiple inputs** and an **`--output-dir`**. Pass
  several file paths, a folder (recursively expanded to its supported audio/
  video files), and/or YouTube URLs, or a shell glob like `*.m4a`. With more
  than one resolved input, or whenever `--output-dir` is set, the command runs
  in batch mode: it transcribes each input in sequence and writes one transcript
  per input to the output directory (`<source-name>.txt`, or `.json` for
  `--format json`), defaulting to the current directory when `--output-dir` is
  omitted. Existing files are never overwritten (a `-2`, `-3`, … suffix is
  added).
- Batch mode is **continue-on-error**: a failed input prints a `✗` line to
  stderr and is counted; the run proceeds. The process exits non-zero with a
  one-line summary (`N input(s) failed to transcribe (M succeeded).`) if any
  input failed, and `0` when all succeed.

### Unchanged (back-compat)

- A **single input with no `--output-dir`** behaves exactly as before: the
  transcript is written to stdout in the chosen `--format`, progress goes to
  stderr, and the `--json` success/failure envelope contract is preserved. No
  flags were renamed or removed; this is an additive minor release.

### Changed

- `models list` now returns **two** Parakeet rows (`parakeet-v3`, `parakeet-v2`)
  instead of one. Callers that assumed a single Parakeet entry, or that read the
  Parakeet id as the literal `"parakeet"`, should switch to selecting by the
  `selected` flag / the new ids. The bare `parakeet` id still works in
  `models select` (keeps the persisted build). JSON field names and types are
  unchanged.
- `models list` Parakeet `size` now reports the real ~465 MB per-build download
  footprint (previously an inaccurate "6 GB" placeholder).

## [2.4.0] -- 2026-05-29

### Added

- `meeting-vad-sim <audio>` (dev tool) replays the meeting live-preview
  chunking path on an audio file and compares the fixed 5s strategy against VAD
  speech-boundary chunking (`--mode fixed|vad|both`). Reports chunk boundaries,
  per-ingest latency, and the realtime factor used to decide whether VAD can run
  inline in the capture task. `--json`, `--all-chunks`, and `--batch-ms`
  supported. Headless verification for the VAD-guided live chunking work; does
  not exercise live capture or the GUI.
- LLM-backed commands now expose `--allow-insecure-http` for intentional
  non-loopback `http://` endpoints on non-local providers.
- `spec --json` prints a machine-readable CLI contract for agents and scripts,
  including JSON conventions, exit codes, and supported automation commands.
- `meetings results list|add` exposes saved meeting PromptResults through the
  CLI. `add` stores externally generated output as a `PromptResult` without
  invoking an LLM, preserving the meeting transcript as the canonical object.
- `meetings list --json`, `meetings show --json`, and `meetings export --format json`
  now include `hasPromptResults` and `promptResultCount`, and Markdown exports
  include the same count in metadata, so agents can tell whether structured
  meeting outputs already exist before fetching result rows.
- `llm` commands using `--provider lmstudio` now honor optional LM Studio API
  tokens via `--api-key`, `--api-key-env`, or `LM_API_TOKEN`.
- `vocab snippets edit <id> --trigger ... --expansion ...` updates an existing
  text snippet without deleting/recreating it.

### Changed

- CLI telemetry now lives in the root runner instead of the `transcribe`
  command, so every successfully parsed command emits one privacy-safe
  `cli_operation` event. `transcribe` keeps its extra coarse input/output
  metadata; other commands report only command path, outcome, duration, exit
  code, and error type.
- `transcribe` now defaults `--speaker-detection` to `app-default`, so bare
  CLI transcription follows the saved GUI/CLI speaker-detection preference.
  Use `--speaker-detection on` to force diarization for one run, or
  `--speaker-detection off` / `--no-diarize` to force it off.
- CLI LLM base URL validation now matches the GUI safety model: `https://`
  remains allowed everywhere, `http://` remains allowed for loopback and local
  providers, and non-local providers require `--allow-insecure-http` before
  sending prompt content or API keys over cleartext HTTP. When the override is
  used, the CLI writes a warning to stderr so stdout stays machine-readable.
  Existing scripts that intentionally target a non-loopback HTTP endpoint can
  keep that behavior by adding the explicit flag.

## [2.3.1] -- 2026-05-19

### Changed

- Patch release for the standalone Homebrew channel. No command, flag, JSON
  schema, or exit-code changes from 2.3.0; the release artifact is rebuilt
  from latest `main` after the STT-language telemetry/data-model update.

## [2.3.0] -- 2026-05-16

### Changed

- `flow` command renamed to `vocab`. All subcommands move:
  `flow words` → `vocab words`, `flow snippets` → `vocab snippets`,
  `flow process` → `vocab process`. `flow vocabulary export/import/schema`
  flattened to `vocab export/import/schema`. The old `flow` command remains as
  a deprecated alias for this minor release, including the legacy
  `flow vocabulary export/import/schema` forms, and will be removed at the next
  major CLI version.

### Added

- `transforms list / show / run / create / delete` — new subcommand tree
  for managing user-defined Transforms (ADR-022). Same surface that the
  GUI's Transforms tab edits, headlessly accessible so agent operators
  can provision a fresh device, run a saved prompt against arbitrary
  text from CI, and verify the dispatch table without launching the
  app.
  - `transforms list [--json]` — lists Transforms with their bound
    shortcuts in human-readable rows or a JSON array.
  - `transforms show <id|name> [--json]` — prints the prompt body and
    the bound shortcut.
  - `transforms run <id|name> --input FILE|- [--stream] [--json]` —
    invokes the saved prompt body via the user's configured LLM
    provider. Distinct from `llm transform --prompt "..."`, which
    takes an ad-hoc prompt string.
  - `transforms create --name --prompt|--from-file [--shortcut "opt+1"]
    [--json]` — headless install of a new Transform.
    Shortcut format: `opt+1`, `cmd+shift+P`, etc. Refuses bare-key
    bindings (must include a modifier).
  - `transforms delete <id|name> [--json]` — deletes a custom
    Transform. Built-ins are protected.
  - `transforms list/show/create --json` use a snake-cased `TransformDTO`
    payload (`id`, `name`, `shortcut`, `is_built_in`,
    `prompt`, `created_at`, `updated_at`). `transforms run --json`
    emits the LLM result envelope, and `transforms delete --json` emits
    `{deleted,id,name}`.
- `transforms history list / show / delete / clear` — read/manage the
  local Transform run history that the GUI's Transforms tab also surfaces.
  Each completed Transform run records input, output, source app, capture
  and replacement paths, and timing. Local-only; agents can use it to
  verify what the dispatch table just produced without launching the app.
  - `transforms history list [--limit N] [--json]` — newest first; default
    limit 20.
  - `transforms history show <id-prefix> [--json]` — full input/output for
    one row. ID prefixes must be at least 4 hex chars; `--json` maps
    invalid-prefix errors to `errorType: "validation"`, missing-row to
    `errorType: "lookup"`.
  - `transforms history delete <id-prefix> [--json]` / `transforms history
    clear [--json]` — single-row delete and bulk clear. `--json` emits
    `{ok, id}` / `{ok, deleted_count}` respectively.
  - JSON payloads use a snake-cased `TransformHistoryDTO`
    (`id`, `transform_id`, `transform_name`, `input_text`, `output_text`,
    `source_app_bundle_id`, `source_app_name`, `capture_path`,
    `replacement_path`, `llm_elapsed_ms`, `total_elapsed_ms`,
    `created_at`, `updated_at`).

### Fixed

- YouTube transcriptions captured under `--youtube-audio-quality
  best-available` (or the GUI's "Best available" mode) now play through
  the in-app audio scrubber. AVFoundation on macOS has no native WebM or
  Opus decoder, so the saved file used to fail silently on `AVPlayer.play()`
  while the video panel still worked (it re-extracts a streamable URL via
  yt-dlp). The transcription pipeline now transcodes the saved audio to
  `.m4a` (AAC 192k, faststart) in a background task after STT completes,
  writing through a unique temp path before the atomic commit so the
  post-STT path and the lazy on-open migration can race safely on the
  same source. The source webm is removed only after the database update
  succeeds. Existing webm-backed transcriptions migrate lazily on next
  open. Recognized unplayable extensions: `webm`, `weba`, `opus`, `ogg`,
  `mkv`. No CLI flag change — `--youtube-audio-quality best-available`
  keeps its measured WER advantage (issue #237). Skipped when
  `--downloaded-audio delete` or the GUI's audio retention is off, since
  the saved file is being discarded anyway.

### Added

- `transcribe --format transcript` prints only the final transcript text to
  stdout, with progress/status still isolated on stderr. This keeps the
  existing human `--format text` view intact while giving shell pipelines a
  clean `pbcopy`, `grep`, `tee`, or local-LLM input mode.
- `transcribe --no-history` runs file/URL transcription without saving a
  completed transcription row to MacParakeet history. For YouTube inputs,
  downloaded audio is treated as temporary even when the shared app default is
  to retain transcription audio.
- `models list` and `models select <id>` provide user-facing aliases over the
  shared speech-engine defaults. `models list` shows Parakeet plus the
  configured WhisperKit variant with installed/selected state; `models select`
  writes the same default that `config set speech-engine` writes, and validates
  Whisper model availability before switching.
- `transcribe --engine app-default` resolves the speech engine and Whisper
  language from the same saved defaults used by the GUI, while preserving
  Parakeet as the no-flag CLI default.
- `transcribe --speaker-detection app-default|on|off` lets agents choose
  GUI-default speaker detection or pin diarization explicitly. The no-flag
  CLI default remains `on`; `--no-diarize` continues to work as a
  compatibility alias for `--speaker-detection off`.
- `config get|set|list` now covers the shared app/CLI transcription defaults
  agents need for deterministic setup: `processing-mode`, `speech-engine`,
  `whisper-language`, `speaker-detection`, `save-transcription-audio`, and
  `youtube-audio-quality`. Config keys accept underscore aliases on input and
  JSON output uses the canonical hyphenated key names.

## [2.1.0] -- 2026-05-10

### Added

- `transcribe --youtube-audio-quality app-default|m4a|best-available`
  lets callers choose between the app default, an m4a-first selector for
  Apple-friendly saved audio files, and yt-dlp's best available source stream,
  which may save WebM/Opus files.

## [2.0.0] -- 2026-05-03

### Added — `quick-prompts`

- `quick-prompts` manages live meeting Ask tab shortcuts: `list`, `show`,
  `add`, `set`, `delete`, `pin`, `unpin`, `restore-defaults`, `export`, and
  `import`.
- `quick-prompts pin <id|prefix|label>` — pin to the after-response strip.
  Pinning is unbounded; overflow is handled visually by the strip's
  horizontal scroll with edge-fade affordance.
- `quick-prompts unpin <id|prefix|label>` — unpin from the strip.
- `quick-prompts add --pinned` — create a custom prompt already pinned.
- Group labels are valid on every prompt; they control empty-state and
  sparkle-menu grouping only.
- Hidden quick prompts cannot stay pinned: `set --hidden` auto-unpins a pinned
  row, and `pin` auto-shows a hidden row.
- `quick-prompts list --pinned <true|false>` — filter list by pin state.
- `quick-prompts export --pinned <true|false>` — filter export by pin state.
- Quick-prompt import/export uses bundle schema **v1**
  (`macparakeet.quick_prompts/1`) with `isPinned: Bool` per prompt. There is
  no `kind` bundle schema because this surface has not shipped publicly yet.

### Added

- `import_schema` `errorType` value for malformed quick-prompts import files
  (e.g. wrong `schema`, unsupported `version`, JSON parse failure).
- `flow vocabulary export`, `flow vocabulary import`, and `flow vocabulary
  schema` commands for round-trip backup of the combined vocabulary (custom
  words + text snippets). `import` supports `--policy skip|replace`,
  `--dry-run`, `--json`, and stdin (omit `--input`); `export` writes to
  stdout when `--output` is omitted. `schema` prints an LLM-friendly spec
  (or `--json` structured form) so a local coding agent can generate valid
  bundles. Bundle format is versioned (`macparakeet.vocabulary` v1).

### Fixed

- `transcribe --format json` and `export --format json --stdout` now emit the
  documented JSON failure envelope for post-parse failures.

## [1.4.0] -- 2026-04-28

### Added

- LLM-backed commands now accept `--api-key-env NAME`; hosted providers also
  read `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, and
  `OPENROUTER_API_KEY` directly.
- `config` command namespace for users who only install the CLI (no GUI):
  `macparakeet-cli config get telemetry`, `config set telemetry on|off`, and
  `config list`. Values persist in the same UserDefaults suite the GUI reads
  (`com.macparakeet.MacParakeet`), so a later GUI install picks them up.
- `transcribe` now honors `DO_NOT_TRACK=1` (industry-standard, also honored
  by Homebrew, GitLab, VS Code) and auto-disables telemetry in CI environments
  (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `BUILDKITE`, `CIRCLECI`, `TRAVIS`,
  `JENKINS_URL`, `TF_BUILD`, `TEAMCITY_VERSION` set to a truthy value). The
  CI auto-disable can be overridden with `MACPARAKEET_TELEMETRY=1` for
  developers smoke-testing telemetry from a CI shell. `MACPARAKEET_TELEMETRY=0`
  remains the explicit per-process kill switch.

### Fixed

- Applied the `--json` failure-envelope contract consistently across read-only
  CLI surfaces such as history, stats, prompts, calendar, flow vocabulary, and
  model status.
- `prompts run --json` now emits a single JSON object even when saving the
  generated `PromptResult` fails.
- CLI deletion now removes app-owned dictation audio, YouTube audio, and
  meeting recording folders before deleting their database rows. If managed
  audio cleanup fails, deletion fails visibly instead of leaving app-owned
  audio behind silently.
- Local transcription and export output paths now expand `~`; export also
  creates parent directories and sanitizes default file names.
- App-bundled CLI installs now include a signed `yt-dlp` helper seed. YouTube
  transcription seeds the managed App Support helper from the bundle before
  falling back to network install, while `health --json` remains non-mutating
  and `health --repair-binaries` explicitly fetches the latest helper.

## [1.3.0] -- 2026-04-26

### Added

- `transcribe` accepts `--engine parakeet|whisper` (default `parakeet`) and
  `--language <code>` for Whisper language hints. The `--engine` flag is
  per-invocation and does not mutate the GUI's Speech Recognition setting.
- `transcribe --format json` may include an optional top-level `language`
  field on successful output when the active engine detects or confirms a
  language. This is additive; existing fields and defaults are unchanged.
- `models download <variant>` recognizes Whisper model identifiers such as
  `whisper-large-v3-v20240930-turbo-632MB` and stores them under MacParakeet's
  Whisper model cache.
- `meetings` command namespace for deterministic, local meeting objects:
  `meetings list`, `meetings show`, `meetings transcript`,
  `meetings notes get|set|append|clear`, and `meetings export`.
  These commands expose meeting recordings without requiring any LLM provider:
  metadata, notes, transcript text, timestamp formats, and Markdown/JSON
  exports are all local database reads/writes.
- `transcribe` now initializes the shared telemetry client and emits a
  privacy-safe `cli_operation` product-health event after execution. This does
  not change stdout, stderr, JSON schemas, or exit codes; it follows the GUI
  telemetry preference and the CLI opt-out controls documented above.

### Fixed

- `prompts run` now renders `{{userNotes}}` and `{{transcript}}` with the same
  prompt assembly path used by the GUI, and stores `userNotesSnapshot` on saved
  prompt results. This restores GUI/CLI parity for notes-steered meeting
  prompts while keeping LLM invocation explicitly under `prompts`.
- Meeting retranscription now preserves durable user-authored meeting notes.
- `health --json` is now a non-mutating readiness probe for helper binaries:
  it reports whether `yt-dlp` is installed without downloading or updating it.
  Use `health --repair-binaries` to explicitly install/update helper binaries.
- UUID prefix lookup now enforces the documented minimum prefix length of
  four characters before matching database records by ID prefix.

## [1.2.0] -- 2026-04-26

### Added

- `--json` output mode for the LLM commands (`llm summarize`, `llm chat`,
  `llm transform`, `prompts run`) and `llm test-connection`. Emits a
  structured envelope so agents can read `{output, provider, model,
  usage: {promptTokens, completionTokens, totalTokens}, stopReason,
  latencyMs}` directly rather than regexing prose. Token field names
  match the OpenAI convention. `usage` is omitted when the provider
  doesn't surface it (`localCLI`; some `openaiCompatible` servers).
  `stopReason` is pass-through — provider-native vocabulary
  (`end_turn`, `length`, `STOP`, `done_reason`, etc.) is surfaced
  verbatim. `test-connection --json` returns
  `{ok: true, provider, model, latencyMs}` on success and the standard
  `--json` failure envelope (see top of file) on failure. All `--json`
  commands now share that failure envelope so downstream agents see one
  of two shapes — never a mix of JSON success and plain-text failure.

### Not yet supported

- `--json` combined with `--stream` is rejected at argument validation
  with a clear error. NDJSON streaming (`{type: "delta"}` lines
  followed by a `{type: "final"}` envelope) is a planned follow-up.

## [1.1.0] -- 2026-04-26

### Added

- `flow process --database <path>` can now run the clean text-processing
  pipeline against an explicit SQLite database, matching the testability and
  agent-workflow override already used by other `flow` commands.

### Fixed

- `feedback` and direct `llm` commands now write validation and provider
  errors to stderr instead of stdout.
- `transcribe --format` now rejects unsupported values during argument parsing
  instead of silently falling back to text output.
- `transcribe` now awaits STT runtime shutdown on both success and error paths.

## [1.0.1] -- 2026-04-26

End-to-end validation of the brew-installed 1.0.0 binary surfaced a
single stdout-pollution bug in `transcribe`. Fixed below; no other
behavior change.

### Fixed

- `transcribe --format json` emitted a `Transcribing <file>...` (or
  `Converting`/`Downloading`/`Identifying speakers`/`Finalizing` for
  YouTube URLs) progress line on **stdout** before the JSON payload,
  which broke `transcribe ... --format json | jq .` for any scripted
  caller. Progress messages now go to stderr (matching the existing
  pattern in `prompts run` and the documented "JSON only to stdout"
  contract from `integrations/README.md`). New `printErr(_:)` helper
  in `CLIHelpers.swift` codifies the channel.

### Compatibility notes

- The progress messages are still emitted; they just go to stderr now.
  Human callers using the human-readable `--format txt` (default) are
  unaffected — stderr still surfaces in the terminal.
- Scripted callers that were relying on the progress message appearing
  on stdout (unlikely; it was a polling-style "..." line) need to read
  stderr instead.

## [1.0.0] -- 2026-04-25

First release of the CLI as a versioned public surface. The CLI has existed
since v0.1 of the MacParakeet app and powered AI-assisted testing through
v0.4--v0.6. With the prompts subcommand and JSON sweep landing in
[PR #138](https://github.com/moona3k/macparakeet/pull/138), the surface is
complete enough to commit to. This release marks that commitment.

### Added

- `prompts` subcommand: `list` / `show` / `add` / `set` / `delete` /
  `restore-defaults` / `run`. UUID-or-name lookup with prefix matching, error
  surfacing for ambiguous prefixes, refusal to delete built-ins. `prompts run`
  invokes any LLM provider configured via `--provider --api-key --model`.
  ([PR #138](https://github.com/moona3k/macparakeet/pull/138))
- `--json` flag on read-only commands: `history dictations`,
  `history transcriptions`, `history search`, `history search-transcriptions`,
  `history favorites`, `stats`, `flow words list`, `flow snippets list`,
  `health`, `models status`. Convention: ISO-8601 datetimes, pretty-printed
  output, sorted keys, top-level array for list commands and object for
  single-record / status commands. Matches the existing `calendar upcoming
  --json` shape.
  ([PR #138](https://github.com/moona3k/macparakeet/pull/138))
- `flow words list --source manual|learned|all` filter. Default `all`.
  Surfaces the source distinction (user-typed vs vocabulary-learned) that the
  schema has carried for two releases but the CLI hadn't exposed.
  ([PR #138](https://github.com/moona3k/macparakeet/pull/138))

### Changed

- Command abstract reframed from "internal developer CLI" to a public surface.
  The CLI is now positioned as the canonical Swift-native interface to
  Parakeet TDT on Apple Silicon, with the macOS app as one consumer of it.
  Strategic context: `plans/active/cli-as-canonical-parakeet-surface.md`.

### Compatibility notes

- Pre-1.0 callers are unaffected. Every existing command and flag retains its
  prior behavior; the version bump signals "stability commitment going
  forward," not a breaking-change cliff.
- The CLI ships inside the `MacParakeet.app` bundle today
  (`MacParakeet.app/Contents/MacOS/macparakeet-cli`). Standalone install via
  Homebrew tap is on the roadmap (see plan above) and will not change command
  semantics.
- **`--format json` (transcribe, export) vs `--json` (read-only queries)**
  is deliberate, not a bug. `transcribe` and `export` carry a `--format`
  selector because they emit one of several formats (`transcribe`: text / json;
  `export`: txt / markdown / srt / vtt / json); `--json` on read-only query commands is a binary flag because
  their output shape is conceptually fixed -- it's either JSON or human.
  Unifying this would be a major-version breaking change; we are not doing
  that in 1.0.
