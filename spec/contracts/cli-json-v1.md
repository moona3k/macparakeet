# CLI JSON v1

> Status: ACTIVE - public automation contract for `macparakeet-cli`.

## Purpose

`macparakeet-cli` is the stable automation surface for local scripts, coding
agents, and external tools. JSON modes must remain machine-readable on stdout,
with human progress/status kept off stdout.

## Producers

- `CLIHelpers.printJSON`
- `CLIHelpers.printEnvelope`
- `CLIHelpers.emitJSONOrRethrow`
- Commands that expose JSON-on-stdout modes through `--json`, `--format json`,
  or `--envelope`
- `SpecCommand`

## Consumers

- Local shell scripts and `jq` pipelines.
- Coding-agent integrations.
- Smoke and support workflows.
- `integrations/README.md` users calling `macparakeet-cli` from outside this
  repo.

## Stable Conventions

- JSON payloads are written to stdout for the command's documented JSON stdout
  mode.
- Export-style commands can also write JSON files. For those commands,
  `--format json` alone may write a file and print the path; use the command's
  documented stdout mode from `macparakeet-cli spec --json` when a caller needs
  parseable JSON on stdout. For `meetings export`, that mode is
  `--stdout --format json`.
- Human progress/status is written to stderr.
- JSON uses ISO-8601 dates, sorted keys, and pretty printing through the shared
  encoder.
- `macparakeet-cli spec --json` is the machine-readable command catalog.
- `search --json` returns an array of segment hits with `transcriptionId`,
  `title`, ISO-8601 `recordedAt`, `source`, `seq`, nullable `startMs` and
  `speaker`, `snippet`, and nullable `rank`. CJK substring-fallback hits use
  `rank: null`. Local-file `title` values use an explicit title override when
  present, otherwise the original media filename; transcript-derived opening
  words do not replace the source filename.
- For `search --since/--until`, a bare `yyyy-MM-dd` is interpreted in the
  user's local calendar and time zone: `--since` starts at local midnight and
  `--until` includes the full local day. Full ISO-8601 timestamps with `Z` or
  an explicit offset retain that stated zone.
- `transcript --json` returns one object with transcription metadata and an
  ordered `segments` array. Segment objects contain `seq`, nullable timing and
  speaker fields, `text`, and `segmenterVersion`. Its Local-file `title` follows
  the same override-then-original-filename rule as search results.
- `transcribe --format json` may include nullable `audioTrackOrdinal` on its
  `Transcription` object. It is zero-based and non-null only when a local-file
  audio stream was selected explicitly; this additive field does not change
  stdout/stderr or envelope shapes.
- `cards list --json` returns an array; `--ndjson` returns the same card objects
  one compact object per line. Each object has exactly `transcriptionId`,
  `title`, `date`, nullable `durationMs`, `source`, nullable `attendees`, the
  six provenance fields (`cardSchemaVersion`, `transcriptHash`,
  `segmenterVersion`, `promptVersion`, `model`, `generatedAt`), `synopsis`,
  `topics`, `decisions`, and `actions`. Nullable citation/owner/attendee fields
  are explicit `null`. File/URL decision and action arrays are empty. Cards
  whose transcript hash, segmenter version, prompt version, or card schema
  version is stale are suppressed; list output contains current cards only.
  Local-file card titles follow the same override-then-original-filename rule.
- `cards generate --json` returns selection and progress counts, nullable
  prompt/completion/total token totals, explicit `estimatedCostUSD: null`, and
  per-recording failures. Human progress remains on stderr. Any failed item
  makes the command exit `1` after emitting the aggregate report.
  For `--stale`, `selected` is the prefiltered missing/stale subset, not every
  completed transcription. Successful backfills also rebuild `cards_fts`.
- `--envelope` success output uses `{ ok, command, data, meta }` and does not
  change an existing command's plain `--json` success shape.
- Commands that expose both `--json` and `--envelope` reject the combination.
- JSON object keys are camelCase. The one exception is the `transforms` family
  (`is_built_in`, `created_at`), which predates this convention; its keys are
  frozen for v1 and would only change at a major boundary. New commands use
  camelCase.
- `meetings show --json` and `meetings transcript --format json` expose
  `transcriptSegments` when the meeting row has durable segments. Each segment
  contains `id`, `startMs`, `endMs`, `speakerId`, `speakerLabel`, `text`, and
  `wordRange.startIndex` / `wordRange.endIndexExclusive` into the same payload's
  `wordTimestamps` array. Callers that need stable citations should prefer
  these persisted segments over re-segmenting words.
- `meetings show --json` meeting objects can include optional `startContext`
  for meeting rows. When present it contains `triggerKind`, `sourceMode`, and
  optional `frontmostApplication` (`bundleIdentifier`, `localizedName`).
- `meetings show --json` and `meetings export --stdout --format json` may
  include `calendarEventSnapshot` for meeting recordings started from, or
  probably overlapping, a calendar event. The field is additive and local-only;
  attendee and organizer names/emails are user data and must not be mirrored
  into telemetry.
- `meetings show --json` and `meetings export --stdout --format json` include
  additive artifact path fields for meeting rows when the session folder can be
  resolved: `artifactMarkdownPath` points to `meeting.md`, and optional
  `rawMicrophoneAudioPath`, `cleanedMicrophoneAudioPath`,
  `rawSystemAudioPath`, and `playbackAudioPath` point to retained meeting
  audio artifacts.
- `meetings artifact --json` and `--envelope` return additive
  `MeetingArtifactSnapshot` fields `markdownPath`, optional
  `rawMicrophoneAudioPath`, optional `cleanedMicrophoneAudioPath`, optional
  `rawSystemAudioPath`, optional `playbackAudioPath`, and optional
  `meetingCaptureReport`. An absent report, including on legacy recordings,
  means capture quality is unknown rather than healthy. The same refresh also
  writes `meeting.md`.
- `meetings export --format md --stdout` emits the same Markdown shape as the
  materialized `meeting.md`; use `--stdout --format json` when the caller needs
  parseable JSON on stdout.
- Recognition-time custom vocabulary boosting does not add JSON fields in v1.
  For Parakeet TDT `v3` and `v2`, enabled `vocab words` entries with no
  replacement text may improve the returned transcript text before downstream
  processing. Unsupported engines and empty vocabularies keep the previous
  unboosted path; human `vocab words list` support text is not a JSON
  contract.
- Destructive local mutators that advertise `--json` return a single success
  object with `ok: true` plus affected IDs, counts, or model/cache names. Use
  `macparakeet-cli spec --json` for each command's documented JSON mode and
  output summary.

## Failure Envelope

After argument parsing succeeds, JSON-aware command failures emit this shape on
stdout:

- `ok`: always `false`
- `error`: human-readable message
- `errorType`: stable low-cardinality string
- `fix`: optional actionable hint
- `meta`: optional object with `schemaVersion`, `generatedAt`, and `warnings`

The process exit code remains the source of truth for branching. The envelope
explains why the command failed.

## Exit Codes

- `0`: success
- `1`: runtime failure after work was attempted
- `2`: validation or invocation misuse
- `130`: interrupted by SIGINT

Parse-time and `validate()` failures happen before command `run()` and may
surface through ArgumentParser's plain-text stderr path. Downstream automation
must check the exit code first and not require a JSON envelope for parse-time
misuse.

## Non-Stable Fields

- `meta.generatedAt` changes on every envelope.
- Human-readable `error` and `fix` copy can improve when `errorType` and exit
  code semantics stay stable.
- The command catalog can add commands, options, fields, and new `errorType`
  values in minor releases.

## Versioning And Compatibility

The current CLI spec schema is `macparakeet.cli.spec` v1. Additive catalog
fields are v1-compatible. Removing a stable catalog entry such as a command,
option, or configuration key is a breaking CLI-surface change and requires a
new CLI major even when the catalog envelope stays schema v1. Removing or
renaming failure-envelope fields, changing exit-code meanings, or moving
JSON-mode status text to stdout is also breaking and requires explicit
version/changelog treatment.

## Tests that enforce this

- `SpecCommandTests`
- `LLMJSONOutputTests`
- `MeetingsCommandTests`
- `MeetingVADSimCommandTests`
- `TranscribeCommandTests`
- `ConfigCommandTests`
- `HistoryCommandTests`
- `ModelLifecycleCommandTests`
- `QuickPromptsCommandTests`
- `TransformsCommandTests`
- `SearchCommandTests`
- `CardsCommandTests`
- `VocabCommandTests`

Focused coverage pins spec conventions, failure-envelope fields, exit code
entries, JSON wrapper failure envelopes, JSON validation exit-code
normalization, agent-facing meeting commands including durable transcript
segments and additive artifact paths, command-level JSON failure envelopes, and
`--json`/`--envelope` mutual exclusion.

## When this changes

Update this file, `Sources/CLI/CHANGELOG.md`, `docs/cli-testing.md`,
`integrations/README.md` if external callers are affected, and the focused CLI
tests in the same PR.
