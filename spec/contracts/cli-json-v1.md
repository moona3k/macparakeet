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
- `macparakeet-cli spec --json` is the installed binary's machine-readable
  command catalog, with `cliVersion`, per-command `readOnly`/`jsonMode`,
  arguments, options, output summaries, and supported config keys. It is not
  a JSON Schema for each payload or a side-effect sandbox. Family-level
  `readOnly: false` can include a non-repairing default invocation (`health`);
  read commands may still initialize directories or migrate an older supported
  schema when opening the database.
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
  Listing may refresh outdated derived transcript segments before checking
  card freshness; it does not generate cards or call an LLM. The catalog's
  read classification is not a guarantee of zero database writes.
- `cards generate --json` returns selection and progress counts, nullable
  prompt/completion/total token totals, explicit `estimatedCostUSD: null`, and
  per-recording failures. Human progress remains on stderr. Any failed item
  makes the command exit `1` after emitting the aggregate report.
  Token accumulators that overflow remain `null` for the rest of the batch;
  later receipts cannot restart a misleading partial total. An individual
  receipt whose component sum overflowed also makes the batch total unknown.
  An explicit receipt total takes precedence; when it is absent and both
  component counts exist, their checked sum contributes to the batch total.
  For `--stale`, `selected` is the prefiltered missing/stale subset, not every
  completed transcription. Successful backfills also rebuild `cards_fts`.
- `--envelope` success output uses `{ ok, command, data, meta }` and does not
  change an existing command's plain `--json` success shape.
- Commands that expose both `--json` and `--envelope` reject the combination.
- JSON object keys are camelCase. The one exception is the `transforms` family
  (`is_built_in`, `created_at`), which predates this convention; its keys are
  frozen for v1 and would only change at a major boundary. New commands use
  camelCase.
- `prompts list/show --json` prompt objects, and prompt objects returned by
  `prompts set --json`, include additive optional `inferenceSettings`. When
  present it is an object with optional `temperature`, `topP`, `topK`, and
  `maxTokens`, plus `thinkingMode` (`providerDefault`, `enabled`,
  or `disabled`) and optional `reasoningEffort` (`low`, `medium`, `high`, or
  `xhigh`). Reasoning effort is normalized away unless thinking is enabled.
  This value records the prompt's request; it does not prove
  that every field is supported by the provider selected for a later run.
- The same prompt JSON objects include additive Boolean
  `includeMeetingNotes`, the result prompt's automatic meeting-notes context
  preference. Its default is `false`. The `--include-meeting-notes` flag on
  `prompts set <prompt>` enables it and `--no-include-meeting-notes` disables
  it; the flags are mutually exclusive and rejected for Transform prompts.
  Explicit `{{userNotes}}` custom-template substitution remains
  independent of this preference.
- Version-aware prompt JSON adds `activeVersionId`, `activeVersionNumber`, optional `modelOverride`,
  optional canonical provenance, and optional
  deletion metadata without removing existing prompt fields. `prompts history
  --json` returns an array of immutable version objects with `id`, `promptId`,
  `versionNumber`, `content`, optional `inferenceSettings`, optional
  `modelOverride`, `origin`, optional `changeNote`, and `createdAt`. `prompts
  show --version N --json` returns the selected version rather than silently
  substituting the active version. `prompts diff --json` returns prompt/from/to
  identity, deterministic Markdown source hunks, and structured changed
  settings/model values. Restore and soft-delete mutators return the resolved
  affected prompt object; restore creates a new version and never rewrites an
  old one. The new version's `createdAt` and the prompt's `updatedAt` record
  the restoration time.
- `prompts set --label LABEL --available|--unavailable` updates one active
  label rule. `--all-labels` updates only the fallback for transcriptions with
  no matching explicit label rule, across all sources; it preserves label
  exceptions. Adding the first label rule preserves the previous implicit
  available fallback; use `--all-labels --unavailable` to restrict unmatched
  transcriptions. `--json` returns the saved label policy (`id`, `promptId`,
  `scopeKind`, optional `labelId`, `isAvailable`, `createdAt`, `updatedAt`).
  Availability is independent of auto-run: configure automatic execution
  separately with `--source SOURCE --auto-run|--no-auto-run`. The obsolete
  fork flags `--meeting-type` and `--all-meeting-types` fail with replacement
  guidance because their former type-scoped semantics cannot be represented
  faithfully by label availability. They never write inactive legacy policies.
- `prompts run` checks label availability before provider execution for every
  transcription source, using the same rules as the app. No label targets means
  available everywhere; when targeted, at least one transcription label must
  match. Legacy meeting-type policies do not control runtime availability.
  Hidden and non-result prompts remain unavailable. Source-scoped auto-run
  settings do not prevent a manually requested run of an available prompt.
- A prompt model override is passed to the selected provider, which validates
  its model identifiers and aliases during generation. Model discovery results
  are not an exhaustive allow-list. For the Local CLI provider, an override
  differing from the configured model is rejected before command execution:
  changing a model string cannot reconfigure its command template.
- LLM result JSON envelopes include additive optional `effectiveSettings` with
  the same object shape. For `prompts run --json`, a present value is the
  normalized adapter receipt after provider/model filtering. Absence means no
  effective receipt is available; callers must not reinterpret it as raw
  upstream-provider defaults. Other LLM commands omit it because per-prompt
  settings do not apply to them.
- LLM receipts never infer a normal `stopReason` when the runtime supplies no
  finish reason. Local CLI omits `effectiveSettings`, because inference options
  are not passed to its command. Token usage may derive `totalTokens` from both
  component counts when the provider omits the total. A missing component or
  arithmetic overflow leaves the derived total unknown; available components
  remain unchanged. Explicit streaming
  provider errors fail the operation even after partial text; they do not
  produce a successful result receipt.
- `meetings results list|add --json` prompt-result objects include additive
  optional `inferenceSettingsSnapshot` with the same settings shape. When
  present it is the effective receipt stored with the result; imported results
  created by `meetings results add` omit it.
- Saved prompt-result JSON objects include additive Boolean
  `includeMeetingNotesSnapshot`, the automatic-context preference captured for
  that generation. `false` covers migrated and externally imported results.
  Nullable `userNotesSnapshot` contains the exact normalized, bounded notes
  value supplied to prompt assembly, not necessarily the full canonical note.
- Prompt-result objects may additionally include nullable `promptId`,
  `promptVersionId`, `providerSnapshot`, and `modelSnapshot`. Library-driven
  CLI/app generation populates those execution receipts. Historical and
  externally imported results may omit them; omission never means the current
  prompt/provider/model should be inferred.
- `meetings show --json` and `meetings transcript --format json` expose
  `transcriptSegments` when the meeting row has durable segments. Each segment
  contains `id`, `startMs`, `endMs`, `speakerId`, `speakerLabel`, `text`, and
  `wordRange.startIndex` / `wordRange.endIndexExclusive` into the same payload's
  `wordTimestamps` array. Callers that need stable citations should prefer
  these persisted segments over re-segmenting words.
- `export --format json`, `meetings show --json`, `meetings transcript
  --format json`, and `meetings export --stdout --format json` expose the
  effective speaker attribution. They include additive
  `speakerCorrectionsApplied` and `speakerCorrectionRevision` fields; revision
  `0` with `false` means the automatic baseline is active.
- `meetings show --json` meeting objects can include optional `startContext`
  for meeting rows. When present it contains `triggerKind`, `sourceMode`, and
  optional `frontmostApplication` (`bundleIdentifier`, `localizedName`).
- Meeting list/show/export/transcript JSON can include additive optional
  `meetingType` and `meetingLabels`. A meeting type object has `id`, `name`,
  optional `colorToken`, optional `iconName`, `sortOrder`, and `isArchived`;
  a label object omits `iconName` and otherwise uses the same organization
  fields. An absent/null type means unclassified; an empty labels array means
  no labels. `meetings types list --json` and `meetings labels list --json`
  return arrays of those objects. Classification mutation JSON returns the
  meeting id plus its resolved optional type and complete label array.
- `meetings list --type` and `--label` resolve a full UUID, an unambiguous UUID
  prefix, or an exact case-insensitive name before applying the filter in SQL.
  Multiple repeated filters use ANY semantics. `--unclassified` cannot be
  combined with `--type`. Archived types/labels remain resolvable for meetings
  that already use them but are excluded from default vocabulary lists.
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
  Materialization is a write to generated views, not read-only inspection.
- `meetings export --format md --stdout` emits the same Markdown shape as the
  materialized `meeting.md`; use `--stdout --format json` when the caller needs
  parseable JSON on stdout.
- Recognition-time custom vocabulary boosting does not add JSON fields in v1.
  For Parakeet TDT `v3` and `v2`, enabled `vocab words` entries with no
  replacement text may improve the returned transcript text before downstream
  processing **when recognition boosting is enabled**. Its shared preference
  defaults to off; adding vocabulary alone does not enable it. Unsupported
  engines and empty vocabularies keep the unboosted path; human
  `vocab words list` support text is not a JSON contract.
- Destructive local mutators that advertise `--json` return a single success
  object with `ok: true` plus affected IDs, counts, or model/cache names. Use
  `macparakeet-cli spec --json` for each command's documented JSON mode and
  output summary.
- Prompt and meeting-classification command names and option shapes are
  additive v1 surface: `prompts history`, version-aware `prompts show`,
  `prompts diff`, `prompts restore`, `prompts delete`, `prompts
  restore-deleted`, `meetings types`, `meetings labels`, `meetings classify`,
  and meeting list classification filters. Classification names and prompt
  content are local user data and never become telemetry dimensions.

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

`health --json` is a component report, not a single readiness verdict or a
failure envelope for each missing dependency. Inspect its statuses and paths.
Its database probe does not create/migrate the database; `schema_skew` calls
for upgrading the CLI, never resetting user data. Without repair flags it
does not download models/helpers or create application directories.

For the boundaries of `--database`, DEBUG state-root overrides, shared
preferences, and artifact mutations, use the
[integration isolation rules](../../integrations/README.md#safe-automation-and-isolation).

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
