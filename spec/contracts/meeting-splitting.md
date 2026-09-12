# Split and transcribe

> Status: Core service, CLI, and native lifecycle state are implemented.
> Native sheet integration and isolated-library runtime acceptance are complete.
> Shipping review and final focused regression verification are in progress.

## Purpose and ownership

Repair a saved recording spanning multiple meetings. The user-facing action
is **Split and transcribe**. Every part, including the first, is a new saved
meeting receiving its first transcription. The original long recording is
not shortened, replaced, retranscribed or deleted.

One shared Core operation serves the GUI and public CLI. It owns audio
creation and subsequent sequential processing as separate internal phases.
Callers do not sequence filesystem and database mutations themselves.

## Audio creation

- User-approved boundaries partition the entire validated audio duration into
  contiguous, independently owned files and fresh meeting identities.
- Old transcript timing, speaker assignments and text edits do not determine
  eligibility. Cuts may cross words. Never move a boundary silently.
- A saved part's duration describes its audio, not speech extent. Subsequent
  transcription preserves that known duration even for silence, short word
  timing coverage, or model timestamps beyond the audio end.
- The original row, audio, transcript, corrections, notes, results and citations
  remain unchanged. Deleting it or a sibling cannot damage another part.
- Publish all saved audio parts together or none. Capture fixed IDs in a small
  durable operation receipt; retry does not create duplicate meetings.
- Protect media preparation/publication against concurrent deletion and
  retention cleanup. Finish cancelling writers before releasing ownership.
- Interrupted unpublished output may be retried or explicitly discarded only
  when positively identified as belonging to the operation. Never remove
  unfamiliar files or recreate deleted committed children on retry.

## First transcription and enabled automation

- After audio publication, process the saved parts sequentially. Generate new
  transcripts and speaker labels from each part's audio; do not partition or
  copy the original transcript or introduce inherited speaker baselines.
- Do not copy parent notes, summaries, tasks, conversations, prompt results,
  calendar identity, classification or favorite state.
- Give each part normal enabled meeting completion treatment, including
  summaries where configured, using existing selection/provider/result paths.
  Disabled automation remains disabled. This permits generating new derived
  content; it does not permit copying the parent's derived content.
- Reuse existing processing code pragmatically. Its current internal
  `retranscribe` method name does not mean a child already has a transcript or
  that the original should be processed. Prefer clear saved-audio naming at
  the new shared boundary, without an unrelated global rename.
- No general automation framework or duplicate summary pipeline is required.
  If a specific enabled automation cannot be reused without disproportionate
  work, report that narrow limitation before weakening the promised behavior.
- Transcription/automation failure or cancellation leaves published audio
  available for retry on the same IDs. Preserve successful stages. Continue
  after an individual part fails; explicit cancellation stops further starts.
- Stop is cooperative, not an immediate runtime interruption. The existing
  speech pipeline may be awaiting a shared, non-cancellable CoreML model
  load. Keep operation and media ownership until that speech call drains;
  explain the wait instead of releasing protection while audio is still in
  use. Cancellation must not start the next part.
- Retry must not unnecessarily repeat completed automation. Do not promise
  exactly-once external side effects where the existing provider/hook cannot
  establish it. Surface uncertain delivery rather than silently duplicating it.

## Retention, privacy and presentation

The initial recording-date/retention anchor remains the original's date;
split-created time and ordinal are separate. Recheck current age-based expiry
before audio publication and honor normal retention during later processing.
Splitting grants no hidden grace period. The existing delete-immediately
preference remains a new-capture policy, not retroactive historical deletion.
If a retention sweep cannot acquire the media lease, it leaves the audio
untouched and remains due for the next existing sweep trigger. A failed sweep
must not advance the successful-sweep timestamp or defer retry for a day.
Invalidate a prior success on failure, including a forced preference-change
sweep, so its next foreground trigger is not suppressed by that older success.

Preview performs no writes. It explains independent storage, original
preservation, processing time, fresh transcripts/speaker labels, enabled
automation and retention. Existing provider/privacy settings apply; do not
silently enable network services or change them. Do not invent measured
per-part capture quality from full-recording counters.

Optimize manual entry for two or three parts with a simple way to add more.
Transcript context may help choose times but need not be preserved. The HTML
is historical reference, not a required layout or acceptance test. Show audio
creation separately from processing; after publication, Cancel does not mean
the new meetings were removed.

## Compatibility and verification

The additive CLI commands and Core boundary are described below. Operation
receipts use the v0.42 database migration. Older binaries cannot be assumed
to honor newly introduced mutation ownership; do not run mixed versions
against the same library while splitting.

Required tests cover audio ranges, source hashes, independent deletion,
all-or-none publication, interruption/retry, concurrent cleanup, sequential
first transcription, enabled/disabled automation, canonical-only audio,
partial processing success and read-only preview. Focused Core/CLI tests use
synthetic audio, real temporary databases and mocked speech/LLM providers;
they do not establish real-model or native UI acceptance.

### Implemented audio/lease foundation (U2a)

Full recording deletion goes through `TranscriptionDeletionCoordinator`.
For meetings, it holds the same media-mutation lease across sharing stop
preparation, content-key removal, asset removal and database row deletion.
A busy split lease leaves the recording and its sharing state untouched.
Once deletion starts, the existing sharing rule still applies: a later asset
cleanup failure does not undo the committed stop intent. The asset-cleanup
convenience deletion method delegates to this coordinator, so it cannot bypass
sharing cleanup or release the lease between the file and row phases.

The split service uses these focused audio and ownership primitives:

- `MeetingSplitSourceRange(startMs:endMs:)` is a plain `[startMs, endMs)`
  audio range with no transcript/speaker meaning.
  `MeetingSplitGeometry.ranges(durationMs:cutPointsMs:)` turns approved cut
  points into contiguous, gapless ranges, rejecting zero/terminal/
  out-of-range/duplicate/unordered cuts. See
  `Sources/MacParakeetCore/Services/MeetingSplit/MeetingSplitSourceRange.swift`.
- `MeetingSplitAudioExporter.export(sourceFolderURL:sourceAlignment:children:)`
  slices canonical playback plus whichever raw mic/system/cleaned-mic tracks
  are present and overlap each child's range into fresh AAC files at
  caller-owned destination folders; it never mutates the source, rejects a
  destination that overlaps the source folder, forwards cancellation into its
  decode/probe/write tasks, and rejects truncated re-encoded output instead of
  publishing a silently short file. `inspectSource(sourceFolderURL:)` is a
  read-only, no-write probe returning whole-timeline duration, on-disk size,
  and which optional tracks exist. See
  `Sources/MacParakeetCore/Services/MeetingSplit/MeetingSplitAudioExporter.swift`.
- `MeetingMediaMutationLease` is the cross-process advisory lock a split's
  media preparation/publication and saved-meeting audio deletion/retention
  cleanup both must hold; see its dedicated section in the
  [recovery/retention contract](meeting-recovery-retention.md#meeting-media-mutation-lease)
  for the full lock-file, ordering, and call-site contract.

### Implemented split service, ownership and CLI (U3)

`MeetingSplitService` (`Sources/MacParakeetCore/Services/MeetingSplit/MeetingSplitService.swift`)
is the one shared Core operation: `preview`, `createAndProcess`,
`resumeProcessing`, `operation(id:)`/`operations(sourceId:)`, `discard`, and
`operationOwnership(operationId:)`. The `meetings split
preview|create|status|resume|discard` CLI subcommands
(`Sources/CLI/Commands/MeetingSplitCommand.swift`) call exactly this API; a
native UI would call the same one.

- **Idempotency lookup before touching the source.** `createAndProcess`
  compares the caller's `sourceId`/`cutPointsMs`/`titles`/
  `expectedSourceIdentity` against any existing operation for
  `idempotencyKey` *before* fetching the source at all. A match against an
  already-`.committed` operation resumes only unfinished processing — this
  makes a same-key retry work after the original is deleted. Deleted children
  are skipped, not recreated. A mismatch throws `MeetingSplitServiceError.requestConflict`
  without requiring the source to exist either.
- **Opaque source identity.** Preview returns a sorted-JSON SHA-256 fingerprint
  of source identity and available audio track sizes/modification times.
  Pass the string unchanged to `expectedSourceIdentity` or CLI
  `--expected-identity`; no date parsing or lossy round-trip is required.
  Every creation attempt also revalidates the receipt's frozen fingerprint
  under the media lease, including retry after interrupted export.
- **Stable destinations.** The receipt freezes `destinationRootPath`.
  Resume, ownership and discard use that root even if the configured folder
  changes. Processing reads each child's persisted path. A destination
  inside the original is refused before creating any lock or output.
- **Operation ownership.** `MeetingSplitOperationLease`
  (`MeetingSplitOperationLease.swift`) is a nonblocking, per-`idempotencyKey`
  kernel `flock`, entirely separate from `MeetingMediaMutationLease`'s lock
  file. `createAndProcess`, `resumeProcessing` and `discard` all acquire it
  for their whole call (resume/discard resolve the key from the durable
  operation row first, then re-read that row under the lease), so the same
  operation is never processed by two callers at once; a second caller
  observes `MeetingSplitOperationLease.AcquisitionError.busy` immediately.
  Discard acquires both operation and media leases before removing positively
  owned unpublished output; it marks the receipt discarded only after cleanup
  succeeds. A busy lease leaves the receipt unchanged.
  `MeetingSplitOperationLease.isActivelyOwned(idempotencyKey:
  meetingRecordingsRootURL:)` and `MeetingSplitServicing.operationOwnership(
  operationId:)` are the ownership seam a later native startup reconciler
  should use instead of a bare capture-lock check.
- **Exclusive, positively-verified child folders.**
  `MeetingSplitChildFolderClaim` (`MeetingSplitChildFolderClaim.swift`) claims
  each child's destination folder. It never creates the marker file inside
  the final destination itself: it first builds a fully marked folder at a
  fresh, exclusively created sibling scratch path, then publishes it to
  the final destination with one exclusive atomic rename (`renamex_np` with
  `RENAME_EXCL`, which fails rather than overwriting an existing destination).
  This means the final path can never be observed half-claimed — created but
  not yet marked — after a crash between those two steps: it is either
  absent, or it is exactly this operation/child's own fully marked folder.
  When the final path already exists, it is reclaimed (removed and the
  scratch folder published in its place) only when it positively carries
  this *same* operation/child's own marker, i.e. an interrupted earlier
  attempt at this same claim. Discard, and any future retry, only ever
  removes a folder whose marker positively matches; unexpected existing
  content (a symlink, a folder with no marker or a different one) is left
  untouched and the private scratch folder is removed rather than left
  behind unpublished.
  Pre-existing scratch content is never removed merely because its name
  resembles an operation. A process crash before the rename can leave a
  small scratch directory containing at most the ownership marker, never
  audio. A fresh attempt uses another scratch name and cannot be blocked by
  that unmarked residue. There is no name-based cleanup sweep.
- **Pre-export snapshot, not a re-fetch.** `finishCreating` captures the
  source's `MeetingSplitSourceSnapshot` once, before export begins, and
  passes that exact snapshot to `MeetingSplitRepository.publish`; it never
  re-fetches "now" and compares it to itself. Cancellation is checked, and the
  source's continued existence reconfirmed, immediately before publication.
- **Processing.** Sequential per child: a durable `MeetingSplitChildStage`
  (`pendingTranscription` → `transcribing` → `transcribed` →
  `automationPending` → `automationCompleted`) plus an `outcome`
  (`none`/`failed`/`cancelled`) on `MeetingSplitRepository`. A child whose
  `rawTranscript` is already non-nil (including an empty, successfully-silent
  string) is never re-transcribed merely because the stage lagged behind a
  crash. A deleted child is skipped, never recreated. One child's failure
  does not stop later children; explicit cancellation stops starting further
  children. Successful work stays intact; unstarted and failed first
  transcriptions become visibly retryable rather than remaining "processing".
  A transcript persisted just before interruption remains successful even if
  the operation's stage update lagged behind it. If any error escapes this
  per-child handling (for example a fatal, non-cancellation repository fault),
  every not-yet-finished sibling is still settled best-effort, but truthfully:
  a genuine `CancellationError` marks them `.cancelled`, while anything else
  marks them `.failed` with that same error's message — a real fault is never
  relabeled as a deliberate stop — and the original error always propagates
  to the caller regardless.
- **CLI specifics.** `create --dry-run` uses the same read-only,
  non-migrating `DatabaseManager(readOnlyPath:)` as `preview`, for the entire
  dry-run branch. Preview does not construct STT/LLM services or migrate
  legacy retention preferences. With no cuts, it returns the inspected whole
  range for initial UI setup; creation still requires at least one cut.
  The default idempotency key is a SHA-256 digest of a
  sorted-key `{sourceId, cuts, titles}` JSON payload, stable across independent
  processes rather than just within one process. An
  exact source UUID is accepted directly by `create` and `status --source`
  without requiring `findMeeting`'s name/prefix lookup (which requires the
  row to still exist) to succeed — the mechanism a committed-retry or
  discovery-after-deletion depends on. Phase progress is written to stderr
  only; stdout carries only the JSON/plain-text result. A completed operation
  with any child `outcome == .failed` still prints the full operation, then
  exits non-zero (`ExitCode.failure`) so an automated caller cannot mistake a
  partial failure for total success without inspecting every child.
  `create`/`resume` redirect process-wide stdout to stderr for the duration of
  their own `createAndProcess`/`resumeProcessing` call (mirroring
  `retranscribe`), so a native model runtime writing diagnostics directly to
  stdout can never corrupt the CLI's own JSON/plain-text payload; the final
  `printJSON`/envelope call itself always runs after that redirect is
  restored. Ctrl-C (SIGINT) during `create`/`resume` cooperatively cancels
  the in-flight `Task` instead of terminating the process outright: it waits
  for the split's own cancellation handling to settle (leaving completed
  stages intact and the in-flight child `.cancelled`) before exiting `130`,
  the same interrupted-by-SIGINT exit code documented for the rest of the
  CLI.
  A `create` retry of an already-`.discarded` idempotency key, and a
  `resume` of an operation that is `.discarded` or still `.preparing` (never
  finished creating), all surface a specific actionable message instead of a
  generic status string: a discarded key/operation is a permanent tombstone
  requiring a fresh `--key`; a still-`.preparing` operation should be retried
  with `create` (using the original arguments) rather than `resume`. None of
  this changes the underlying repository's terminal/idempotency semantics.
- **Saved settings.** CLI processing reads the app's shared defaults, uses
  Final Transcription selection and saved model variants, meeting speaker
  detection, and enabled formatting/title/completion settings. Canonical-only
  audio uses the meeting speaker preference, not the file preference.
  Per-invocation engine/model overrides are not part of the split interface.
  The meeting-recordings root used to create/resume/discard splits is
  resolved from that same shared defaults domain (`AppPaths.appDefaults()`),
  honoring a non-default `meetingArtifactsFolder` preference and any DEBUG
  state-dir override exactly like `AppPaths.meetingRecordingsDir` — never
  `.standard`, which would be the wrong domain for a standalone CLI process.
- **Preview capability flags describe actual export capability, not just
  file presence.** `hasRawMicrophone`/`hasRawSystem`/`hasCleanedMicrophone`
  are `true` only when both the source file exists *and* the source's own
  recording metadata carries a usable alignment for that track — exactly the
  same gate `createAndProcess`'s export step itself applies. Missing or
  corrupt metadata never blocks splitting; it only narrows these flags (and
  therefore the actual exported tracks) to canonical-only, since every part
  always gets full canonical playback audio regardless.

### Native task and recovery boundary

The native sheet uses manual time fields and standard playback controls, with
two parts initially and additional cuts on demand. Incomplete time input stays
editable and disables creation. Published children are visible while processing
continues, with direct Open actions. Closing the sheet does not stop processing.
Stop preserves saved audio and completed work; Continue processing uses the
same operation, never another split. Interrupted preparation offers Continue
creation or an explicitly confirmed discard of only that unfinished split.
Deleted children are not resumable work and do not trap the source in an old
progress screen. Explicit history still opens their receipt. When a published
operation is idle and not externally owned, "Start a new split" preserves its
receipt and recordings while opening a fresh source preview and creation key.
If the original is unavailable, that new preview fails without removing the
old receipt; its surviving parts remain independently accessible.
Adding/removing a cut preserves custom titles and existing boundaries; untouched
default "Part N" titles are renumbered to match their new positions. Failures
before any parts are published remain visible in the editor for a safe retry.

Child recordings expose "View split progress…" to their provenance operation.
Their separate "Split and Transcribe…" action starts a new split of that child.
Neither action requires reopening or modifying the original recording.

`MeetingSplitViewModel` owns one app-wide task, independent of sheet lifetime.
Each draft gets a stable creation key; an intentionally new split gets a new
key. Restart recovery uses the saved receipt, including cancelled operations,
and does not require the original's audio to preview already-published parts.
Interrupted preparation retries the frozen creation request; published parts
resume processing only. A second source cannot replace a running task.

`MeetingSplitProcessingProgress` includes both `operationId` and `childId`,
plus child index/count and the actual persisted stage. Consumers must never
use a child ID as an operation ID. Stale callbacks cannot replace completed
or newer presentation state. Editable time text stays separate from validated
millisecond boundaries, so incomplete input disables creation without being
silently reformatted or discarded.

At app startup, split children use their operation lease, held across the
atomic interruption-status update, rather than the capture-only recording
lock. Deletion and clear callers use the combined file/database mutation
operation. These are native integration components, not evidence that the
rendered split UI or a stable release has passed acceptance.

## When this changes

Update this contract, the [plan](../../docs/plans/2026-09-11-issue-895-meeting-split-plan.md)
and focused tests together. Persistence changes update the data-model and
artifact/recovery contracts; public CLI changes update integration docs,
JSON contracts and help/spec discovery. Record actual runtime evidence and
limitations in the implementation PR.
