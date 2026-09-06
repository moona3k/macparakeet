# Speaker Attribution Editing and Speaker Management

> **Status:** IN PROGRESS — Phases 0–2 and output parity implemented; final UX
> hardening and Phase 4 remain.
> **Priority:** P1
> **Date:** 2026-09-05
> **Tracks:** [#542](https://github.com/moona3k/macparakeet/issues/542),
> [#900](https://github.com/moona3k/macparakeet/issues/900), and the
> speaker-management slice of
> [#893](https://github.com/moona3k/macparakeet/issues/893).
> **Builds on:**
> [`docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md`](../../docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md),
> [`spec/adr/010-speaker-diarization.md`](../../spec/adr/010-speaker-diarization.md),
> and the shipped per-transcript rename flow.

## Goal

Let a user repair incorrect post-transcription speaker attribution without
retranscribing audio:

- assign one or more displayed timed transcript segments to an existing speaker;
- create a speaker and assign selected segments to it;
- merge duplicate speakers;
- remove an unused speaker or remove a used speaker while explicitly
  reassigning its segments;
- split an incorrectly combined speaker by moving selected segments to a new
  or existing speaker;
- split one displayed segment at a word boundary, then attribute each resulting
  slice independently;
- undo or redo each speaker-management action;
- see the same corrected attribution in the transcript, statistics, search,
  exports, meeting artifacts, CLI, and LLM context.

The feature is a correction layer over diarization, not a new diarizer and not
cross-recording speaker recognition.

## Verified Current State

- `WordTimestamp.speakerId` is the effective attribution consumed by most
  renderers today. `SpeakerInfo` stores only an ID and display label.
- `TranscriptSegmentRecord` already provides a stable UUID and a half-open
  `wordRange` for each durable citation segment. It is the correct anchor for
  V1 corrections, but not always the displayed edit unit.
- The Timed view currently reconstructs transient `TranscriptSegment` values
  from words and identifies rows by timestamp/text/speaker. For file/URL
  transcripts these presentation rows are usually shorter than the durable
  200–500-character knowledge/citation segments. V1 must preserve the current
  visual granularity while anchoring every selected word range to the durable
  segment IDs it overlaps.
- Rename updates `speakers` and matching `transcriptSegments` labels, but does
  not change word attribution.
- `diarizationSegments` and `wordTimestamps` feed speaker statistics and export
  formats. `KnowledgeSegmenter` feeds `segments`/FTS and cards. Meeting
  artifacts and CLI JSON expose speaker-bearing data too.
- The existing rename path refreshes meeting artifacts, but a broader speaker
  mutation must also rebuild search segments and invalidate any derived card
  whose speaker-aware context changed.
- Meeting attribution contains two different facts that are currently encoded
  in one identifier: original audio source (`microphone`/`system`) and inferred
  speaker identity (`system:S1`, etc.). The correction layer must separate
  those concepts rather than erase source evidence.
- Speaker-count constraints for retranscription already exist in the
  diarization service and CLI. This plan only exposes the existing exact-count
  option in the GUI; it does not rebuild that mechanism.

## Product Scope

### V1 In Scope

- Completed meeting, file, URL, and podcast transcriptions with word timings
  and durable transcript segments.
- Whole displayed-segment selection in the Timed transcript, anchored to
  durable citation segments and exact word ranges.
- Single, range, and Command-click multi-selection.
- Assign to speaker, assign to `Unassigned`, create-and-assign, merge, remove,
  and split-selected-to-new-speaker.
- Split a displayed timed segment between two words, without changing its text
  or durable citation anchors.
- Existing inline rename, routed through the same mutation boundary.
- Transcript-scoped persistent undo/redo and a persisted, undoable
  `Reset speaker corrections` action.
- An optional `Speakers: Auto / Exact count` control in the existing
  retranscription confirmation, backed by the already-shipped diarization
  constraint.
- Keyboard and VoiceOver operation.
- Corrected projections across all user and automation surfaces.
- Explicit behavior when a retranscription replaces the transcript version.

### Out of Scope

- Editing transcript words or arbitrary text ranges.
- Splitting or merging durable citation segments.
- Splitting inside a word, inventing a timestamp, or editing text as part of a
  speaker split.
- Live diarization or editing while transcription is still running.
- Speaker voiceprints, enrollment, biometric matching, or cross-recording
  identity. Those remain in the separate speaker-profile plan.
- Automatic attendee-to-speaker matching.
- Changing the diarization model, thresholds, speaker-count inference, AEC, or
  source-capture routing.
- Automatically regenerating existing summaries after a correction.

## Product Decisions and Invariants

1. **The V1 edit atom is a displayed timed segment or a user-created slice.** A pure
   `SpeakerEditableSegment` preserves today's punctuation/gap/40-word visual
   boundaries and carries its exact `wordRange`, the durable segment IDs that
   overlap it, and the transcript-version fingerprint. Timestamp/text tuples
   alone are not stable enough. A manual split partitions that range only at a
   boundary between two timed words; arbitrary character selections remain out
   of scope.
2. **Automatic evidence remains immutable.** Persisted word-level model/source
   attribution and `diarizationSegments` remain the automatic baseline.
   Corrections are stored separately and resolved into an effective view.
3. **Source provenance survives every edit.** A user may correct the displayed
   speaker even across mic/system attribution, but that never rewrites which
   audio source produced the words. Protected source speakers such as `Me`
   cannot be deleted as provenance.
4. **No silent deletion of speech.** Removing a speaker that owns effective
   segments requires a destination or an explicit `Unassigned` choice.
5. **Merge means identity merge.** Every effective segment attributed to the
   source speaker moves to the target; the source disappears from the effective
   roster. Merely giving two speakers the same label still does not merge them.
6. **Names are not IDs.** User-created speakers receive stable
   `user:<UUID>` IDs. Duplicate display names are allowed with a non-blocking
   warning.
7. **Text/timing validity is unchanged.** Speaker correction must not set
   `isTranscriptEdited`; SRT/VTT/DAPT and timed playback remain valid.
8. **Durable segment IDs remain stable.** Attribution edits never merge, split,
   or remint durable citation segments. A manual presentation split creates two
   stable child edit identities from the original range and split word index.
   Adjacent slices assigned to the same speaker may render as one visual turn
   while retaining their edit identities and citation anchors.
9. **The database is canonical.** Artifact refresh failure cannot roll back a
   committed correction. It is reported separately with Retry.
10. **One user action is one transaction.** Add-and-assign, merge, and
    remove-and-reassign never expose partial state.
11. **Derived state follows canonical state.** The same successful transaction
    updates the correction record, `segments`/FTS, and card invalidation.
    Artifacts refresh only after commit.
12. **No content telemetry.** Metrics may record action kind, bounded counts,
    success/failure class, and latency, never names, transcript text, audio,
    segment IDs, or source paths.

## Target Data Model

Add a table-backed correction log rather than mutating the diarizer output or
growing `SpeakerInfo` into an identity model.

```text
speaker_corrections
  id                    UUID primary key
  transcriptionId       UUID foreign key -> transcriptions(id) ON DELETE CASCADE
  parentId               previous correction on this branch, nullable
  sequence               monotonically increasing within transcription
  transcriptFingerprint  hash of durable segment IDs/ranges/text/timing
  operation              rename | add | assign | split | unsplit | merge | remove | reset
  payload                 versioned JSON with targets and before/after state
  branchState             current | redo | abandoned
  createdAt               timestamp

speaker_correction_states
  transcriptionId       UUID primary key, foreign key -> transcriptions(id) ON DELETE CASCADE
  transcriptFingerprint current automatic transcript-version hash
  headId                 current correction cursor, nullable
  revision               optimistic-concurrency revision, not null default 0
  updatedAt              timestamp
```

The cursor lives in a separate one-row-per-transcription table rather than in
`transcriptions`. Existing transcription and retranscription paths save whole
`Transcription` value snapshots; keeping correction state separate prevents an
older snapshot from silently overwriting the persisted Undo/Redo head.

The versioned payload supports these domain values:

```text
SpeakerCorrectionTarget
  anchorTranscriptSegmentIds
  expectedWordRange

ManualSpeaker
  id = user:<UUID>
  label

Assignment
  target
  effectiveSpeakerId?    nil means Unassigned

PresentationSplit
  target
  splitWordIndex         startIndex < splitWordIndex < endIndexExclusive
```

Rules:

- target ranges must be in bounds and non-overlapping within one command;
- a split index must be strictly inside its current editable range and both
  child ranges must contain at least one timed word;
- anchor UUIDs, expected range, and transcript fingerprint must all match;
- Undo moves the persisted head to the parent operation; Redo advances to the
  retained child. A new action after Undo marks the old redo branch abandoned;
  corrections are not deleted from history;
- existing speaker-bearing fields on `transcriptions` remain the automatic
  baseline (including any labels saved before this feature); the correction
  log is authoritative for new manual attribution and label changes;
- a new database migration is registered in `DatabaseManager`; shipped
  migrations are never edited;
- schema documentation in `spec/01-data-model.md` changes in the same PR.

Before implementation, confirm whether the existing world-class architecture's
broader `speaker_corrections` table will land first. If so, extend that table;
do not create a competing store.

For transcripts predating this feature, existing renamed labels are already
part of the baseline and their original automatic labels cannot be recovered.
`Reset speaker corrections` therefore means “remove corrections recorded by
this feature.” For newly finalized transcripts, that is exactly the automatic
baseline. The UI must not promise “Restore original names” for legacy rows.

## Core Architecture

### `SpeakerAttributionResolver`

Add one pure, Sendable resolver in the diarization/speaker domain. Input:

- the automatic `Transcription` speaker data;
- durable transcript segments and baseline presentation ranges;
- ordered corrections for that transcript version.

Output is one `EffectiveSpeakerAttribution` containing:

- effective roster, including manual speakers and excluding merged/removed
  speakers;
- effective durable segments with unchanged IDs/ranges/text/timing;
- effective editable/presentation segments with stable range identities;
- effective word speaker IDs for word-based exporters;
- effective speaker turns and statistics;
- original source provenance for each range;
- unresolved/stale corrections requiring review.

Roll it out first with `corrections = []` and prove exact parity with current
rendering. No surface should implement its own correction replay.

When a manual split or subrange assignment creates multiple effective speakers
inside one durable citation segment, `KnowledgeSegmenter` must emit separate
derived retrieval rows at those effective word boundaries. Durable
`TranscriptSegmentRecord` IDs remain unchanged, while rebuildable `segments`
sequence values may change; dependent cards are invalidated in the same
transaction. Bump `KnowledgeSegmenter.currentVersion` once when this derivation
rule ships.

### `SpeakerCorrectionService`

Add one async service boundary with commands:

```text
renameSpeaker
addSpeaker
assignSegments
splitSegment
removeManualSplit
mergeSpeakers
removeSpeaker
undo
redo
resetCorrections
```

The service validates a command against the current persisted transcript,
serializes mutations per transcription, appends the correction, refreshes
derived search segments, and invalidates the derived card in one GRDB
transaction. It returns the freshly resolved state.

Do not add this orchestration to `TranscriptionService`; speaker correction is
post-finalization domain work. Do not broaden `updateSpeakers` into several
partially atomic writes.

Despite its name, the existing `SpeakerMerger` is not reusable for this
operation: it aligns automatic diarization time ranges to ASR words. Identity
merge belongs in `SpeakerCorrectionService.mergeSpeakers`.

### Concurrency and Failure Rules

- Every command carries the transcript fingerprint and expected correction
  sequence. A stale command fails with `conflict`, reloads the transcript, and
  keeps the selection so the user can retry.
- Undo/Redo is transcript-scoped and survives page closure/app relaunch until a
  new transcript version is created. A new action after Undo invalidates Redo.
- The ViewModel may update optimistically, but must retain the previous
  effective snapshot until commit. A DB failure restores the whole snapshot.
- Rapid commands for one transcript are ordered. Different transcripts may
  mutate independently.
- Artifact materialization is queued after commit and coalesced by correction
  sequence, following the existing rename refresh pattern.
- A failed artifact refresh shows `Saved locally, but meeting files could not
  be refreshed` and a Retry action. It does not move the correction head.

## UX Design

### Entry Point

In a completed Timed transcript, add `Edit speakers` beside the existing text
editing action. Text editing and speaker editing are distinct modes.

Speaker edit mode:

- shows a selection control on every displayed timed segment;
- supports click, Command-click, and Shift-click;
- pauses auto-scroll while selecting but keeps playback/seek available;
- presents a fixed action bar: `Assign to...`, `New speaker...`,
  `Unassigned`, and `Done`;
- shows a visible `...` button on segment hover or keyboard focus with
  `Assign to...`, `New speaker...`, `Split...`, and `Unassigned`;
- also exposes the same operations from the native context menu.

The menu on a turn header includes `Assign this turn to...` as a shortcut for
selecting all displayed segments in that visual turn.

### Add and Assign

`New speaker...` opens a small popover with a default `Speaker N` label. From a
selection it creates the speaker and assigns the selection atomically. The
Speaker overview also has `+ Add speaker`; an unassigned speaker can be removed
with Undo.

Keep the existing inline rename and pencil affordance on every turn label. Add
an always-visible `Rename...` action to each speaker's overview menu so rename
is discoverable without knowing that the label itself is clickable.

Success feedback:

> 12 segments assigned to Alice — Undo

### Merge

Speaker overview `...` -> `Merge into...` -> target speaker. Confirmation names
the effect without exposing technical IDs:

> Merge “Speaker 3” into “Alice”? 18 segments (6m 42s) will be reassigned.

The operation reassigns all effective segments, hides the source from the
effective roster, preserves raw attribution, and supports Undo.

### Remove

- Unused manual speaker: remove immediately with Undo.
- Used speaker: require `Reassign to...` or explicit `Leave unassigned`.
- Protected source speaker: keep the provenance entry; offer reassignment of
  its effective segments but no destructive removal.

`Me`/microphone and other protected source entries can never be the source of a
merge and can never be removed. They may be the target of an explicit merge or
segment reassignment; original system/microphone provenance remains unchanged.

### Split a Segment

Segment `...` -> `Split...` turns the row into a word-boundary picker. Hovering
or moving with the arrow keys places a visible divider between two words; the
UI shows the resulting left/right timestamps and confirms with click or Return.
The first and last boundaries are unavailable, and a one-word segment cannot be
split.

The split creates two independently selectable `SpeakerEditableSegment`
slices. It does not edit text, invent timing, or change the durable citation
segment. The left slice ends at the preceding word's `endMs`; the right slice
starts at the following word's `startMs`, so an existing silence gap remains a
gap. The user can immediately assign the right or left slice to another
speaker. `Remove split` removes only a user-created boundary when doing so does
not discard attribution; otherwise it first asks which attribution the joined
range should keep. Split and remove-split both support Undo/Redo.

### Split a Speaker

The shortcut `Split selected into new speaker...` creates a speaker and moves
exactly the selected displayed segments or slices. V1 does not infer which
speaker occurrences belong together and does not accept arbitrary character
selection.

### Empty and Error States

- No timings: editing unavailable; explain that structured attribution needs a
  timestamp-capable retranscription and offer the existing rerun action when
  retained audio exists.
- Timings but no speakers: show all segments as `Unassigned`, plus `Add speaker`.
- Processing transcript: disable `Edit speakers` with `Available after
  transcription finishes`.
- No selection: disable assignment actions.
- Persistence error: keep selection and show `Couldn't save speaker changes.
  Nothing was changed.` with Retry.
- Duplicate names: allow, but warn that they remain distinct speakers.
- A manual `Unassigned` is an explicit effective state, not a nil value that
  inherits the previous speaker during turn grouping. Render it visibly as
  `Unassigned` until reset or reassigned.

### Accessibility

- Extend `SpeakerRenameAccessibility` into speaker-management presentation
  helpers and stable identifiers.
- VoiceOver announces selection state, current speaker, target speaker, number
  of selected segments, split-boundary position/timestamps, merge/remove
  consequences, and Undo availability.
- Support Return/Space for selection, Command-Z for undo, Shift-Command-Z for
  redo, Escape to exit/cancel, and full keyboard traversal.
- All buttons keep `.parakeetAction(...)`; color is never the only carrier of
  speaker identity or selection.
- Derive palette slots deterministically from stable speaker IDs so adding or
  hiding another speaker does not recolor every remaining speaker.

## Consumer Migration

Every consumer must read the shared effective projection:

1. Timed SwiftUI transcript and Speaker overview.
2. Speaker statistics and color/turn grouping.
3. Plain speaker-aware copy and TXT/Markdown/PDF/DOCX exports.
4. SRT, VTT, and DAPT cue/character attribution.
5. `MeetingMarkdownRenderer`, `meeting.md`, and `transcript.json`.
6. CLI meeting/transcription JSON and human-readable output.
7. `TranscriptAIContextFormatter` and new LLM runs.
8. `KnowledgeSegmenter`, `segments`/FTS speaker filters, and card provenance.

Contract decisions:

- user-facing output fields keep their existing names and form one coherent
  effective set after correction: `speakerCount`, `speakers`, word speaker IDs,
  computed diarization ranges, and `transcriptSegments` all agree;
- `speakerCount` means the effective roster count, excluding hidden/removed
  speakers and excluding `Unassigned`;
- additive JSON fields expose `speakerCorrectionsApplied`, correction revision,
  and an `automaticAttribution` object when corrections exist. That object
  carries the original roster, compact word-speaker runs, raw
  `diarizationSegments`, and source provenance, so raw IDs never dangle against
  an effective-only roster;
- current summaries/prompt results are not rewritten. New runs consume the
  corrected context. The UI may mark older results `Generated before speaker
  corrections` when their snapshot predates the correction revision;
- update `spec/contracts/cli-json-v1.md`,
  `spec/contracts/meeting-artifacts-v1.md`, and `Sources/CLI/CHANGELOG.md` with
  the exact additive shape before shipping.

If `isTranscriptEdited` is already true, speaker editing remains available only
in the Timed view over the original aligned words. The correction does not make
the edited plain text aligned again: timed/speaker-aware exports that are
currently disabled remain disabled, and plain-text/LLM surfaces keep the
existing edited-text fallback. Output parity means every surface that can
safely expose timed attribution agrees; it does not override alignment guards.

## Retranscription Semantics

Retranscription mints a new transcript version and may change segment IDs,
boundaries, and anonymous speaker IDs. It must never silently apply stale
corrections.

For file/URL retranscription, the confirmation exposes `Speakers: Auto` or
`Exact: N`. For a mic+system meeting, it says `Other speakers: Auto` or
`Exact: N`, because `Me` comes from the microphone and only the system track is
diarized. Hide the control when the meeting has no retained system track. The
value is positive and bounded, applies only to that run unless the existing
preference contract says otherwise, and does not promise that every requested
speaker will receive speech.

This GUI is not only presentation work: the implementation must provide a
per-operation diarization service/factory so the selected constraint reaches
the retranscription run instead of being trapped in the currently injected
service instance.

V1 uses the safe, deterministic rule: if active corrections exist,
retranscription requires confirmation that the new transcript version will
reset them. The old log remains stored under its previous fingerprint but is
inactive; failed retranscription leaves the old transcript, head, and
corrections untouched. No timing/text heuristic replay ships in V1.

Correction replay is a separate follow-up. Before it can ship, extend the model
with durable replay outcome (`applied`, `needsReview`, `obsolete`) and
`replayedFromCorrectionId`, then apply only unambiguous range/source matches.
Never use speaker-name guessing to force a replay.

## Implementation Sequence

Implementation checkpoint (2026-09-05): the correction payload/fingerprint,
resolver, v0.32 persistence, transactional commands, search derivation,
interactive Timed-view editing, persistent Undo/Redo, and per-run Auto/Exact
retranscription controls are implemented. App display/export/LLM context,
knowledge-card generation/recheck, meeting artifact refresh, CLI commands,
bulk export, and public artifact JSON contracts use the effective projection.
Remaining before the plan can be completed: explicit artifact
Retry/stale-result presentation, a dedicated remove-split UI beyond Undo, and
the Phase 4 hardening/replay work below.

### Phase 0 — Contract and Parity Foundation

- Amend ADR-010 or add a focused ADR for automatic versus effective speaker
  attribution, source provenance, correction operations, and retranscription.
- Define the correction payload version and transcript fingerprint.
- Introduce `SpeakerAttributionResolver` with no corrections.
- Add parity tests across meetings, file/URL transcripts, their different
  presentation/citation granularities, nil speakers, unassigned words,
  duplicate names, and long transcripts.
- Route no UI to mutable corrections yet.

**Gate:** every current speaker-aware output is byte-for-byte or
semantically identical with an empty correction log.

### Phase 1 — Persistence and Atomic Domain Operations

- Add migration, `SpeakerCorrection` model, and one repository for the new
  table.
- Add `SpeakerCorrectionService` and pure command validation.
- Implement add, rename, assign, merge, remove, reset, head-based undo, and
  branch-invalidating redo, plus split/remove-split at validated word
  boundaries.
- Update the correction log, search segments, and card invalidation in one
  transaction.
- Make `KnowledgeSegmenter`, `SegmentRepository.rebuildAll`, and
  `rebuildOutdated` consume the effective projection in this phase; no reindex
  may restore automatic labels after the first correction is writable.
- Implement the confirmed V1 reset-on-success behavior during retranscription;
  failed reruns preserve the previous correction head.

**Gate:** all operations round-trip through an in-memory GRDB database; forced
failure leaves transcription, corrections, search segments, and cards in the
previous state.

### Phase 2 — Timed Transcript Editing UX

- Change the Timed view/cache to use effective `SpeakerEditableSegment` values
  that preserve current display granularity and durable citation anchors.
- Add speaker edit mode, selection, action bar, context menus, add-and-assign,
  word-boundary split picker, and persisted Undo/Redo.
- Thread the Auto/exact speaker count through a per-run diarization service or
  factory in retranscription.
- Add overview merge/remove actions and split-selected shortcut.
- Preserve playback, find navigation, scroll targets, long-turn chunking, and
  stable SwiftUI identity.
- Add error, empty, processing, and accessibility states.

**Gate:** a user can repair a two-person transcript that was split into three
speakers without retranscribing and can undo the full repair.

### Phase 3 — Output and Automation Parity

- Route statistics, export/copy, DAPT, artifacts, CLI, and LLM context through
  the resolver. Knowledge/search already moved in Phase 1.
- Add correction revision/provenance to public additive JSON contracts.
- Coalesce artifact refresh and expose retry.
- Add stale-result presentation for summaries/cards generated before the
  correction.

**Gate:** one corrected fixture produces the same effective speaker turns and
labels in every supported output.

### Phase 4 — Retranscription Replay and Hardening

- Specify and implement the optional replay-result schema before adding
  deterministic replay plus `Needs review` handling.
- Add concurrent app/CLI conflict tests and large-transcript performance tests.
- Add bounded, content-free telemetry only if the cross-repo allowlist is
  updated in the same change.
- Complete manual keyboard, VoiceOver, playback, artifact, and real-meeting QA.

**Gate:** replay never silently loses or misapplies a correction; until this
phase ships, the V1 confirmation-and-reset rule remains authoritative.

## Test Plan

### Pure and Model Tests

- resolver parity with no corrections;
- single/multi/range assignment and `Unassigned`;
- add, duplicate labels, rename, merge, remove, split-selected, reset;
- segment split at every valid word boundary, nested sequential splits,
  remove-split, one-word rejection, and boundary timestamp derivation;
- effective roster ordering and ID-deterministic stable colors;
- source provenance unchanged after cross-source display correction;
- invalid UUID/range/fingerprint, overlapping targets, missing speaker, and
  stale correction revision;
- statistics computed from effective assignments;
- correction head traversal, redo invalidation after a branched action, and
  legacy-baseline reset semantics.

### Database and Service Tests

- empty and previous-schema migration;
- foreign-key cascade on transcription deletion;
- atomic update of corrections/read models/segments/card invalidation;
- rollback on failures injected at every write stage;
- separate transcripts mutate concurrently; one transcript remains ordered;
- retranscription confirmed reset, cancellation, and failure rollback; replay
  outcomes are Phase 4 tests only.

### View and ViewModel Tests

- editable segment identity and durable anchors with duplicate
  timestamp/text rows;
- Shift/Command selection and selection persistence after recoverable error;
- create-and-assign, turn assignment, merge confirmation, remove destination,
  segment boundary picker, split-speaker shortcut, remove-split, undo, redo,
  and reset;
- no timing, no speaker, processing, edited-text, and retained-audio states;
- Auto/exact speaker-count validation and propagation through retranscription;
- existing rename accessibility tests remain valid and new controls have
  identifiers, labels, hints, and keyboard behavior;
- playback seeking, find navigation, auto-scroll pause/resume, and 2-hour
  transcript opening remain responsive.

### Output Contract Tests

- TXT/Markdown/SRT/VTT/PDF/DOCX/DAPT use effective attribution;
- meeting `meeting.md` and `transcript.json` match the database projection;
- CLI human and JSON output match GUI attribution and preserve clean stdout;
- effective JSON fields remain referentially coherent and
  `automaticAttribution` preserves the raw baseline when corrections exist;
- FTS speaker filter and snippets reflect corrections immediately;
- an effective speaker split inside one durable citation segment produces
  deterministic speaker-specific retrieval rows without reminting that durable
  segment ID;
- existing card is invalidated; new card/context uses corrected speakers;
- artifact refresh failure preserves the committed DB state and can retry.

### Execution Gates

- Iterate only on focused suites for changed areas.
- Run format/lint and contract checks.
- Run `scripts/dev/check.sh <FocusedFilter>` for the relevant slices.
- Run the full `swift test` suite at most once, as the final local gate.
- For substantial implementation, follow `docs/pr-review-workflow.md`, use
  `no-mistakes` when available, and complete independent review before merge.

## Acceptance Criteria

- A completed timed transcript exposes a discoverable `Edit speakers` mode.
- Every displayed timed segment exposes a visible-on-hover/focus `...` action;
  one or many selected segments can be atomically assigned to an existing,
  new, or explicitly `Unassigned` speaker.
- Rename remains available through a visible-on-hover/focus pencil on turn
  labels and an always-visible `Rename...` overview menu action.
- A duplicate speaker can be merged into another and disappears as a distinct
  effective identity.
- A used speaker cannot be removed without explicit reassignment or
  unassignment; protected source provenance cannot be deleted.
- Selected segments can be split into a new speaker without changing text,
  timing, durable segment IDs, or word ranges.
- A multi-word displayed segment can be split only between timed words; both
  child slices keep exact disjoint ranges, can receive different speakers, and
  can be rejoined or undone without changing transcript text or durable
  citation IDs.
- Rename, add, assign, merge, remove, split, reset, undo, and redo persist and
  roll back completely on failure.
- `isTranscriptEdited` remains unchanged by speaker-only corrections.
- An already text-edited transcript keeps its existing alignment/export guards;
  speaker correction does not falsely revalidate edited text.
- UI, statistics, all exports, artifacts, CLI, LLM context, search, and cards
  agree on effective attribution.
- Original automatic/source attribution remains recoverable internally and in
  the additive artifact/CLI diagnostic projection when corrections exist.
- A correction conflict is rejected and recoverable; no last-writer-wins loss.
- V1 retranscription explicitly resets active corrections only after
  confirmation; future replay requires its own durable review-state schema.
- File/URL retranscription can use `Speakers: Auto/Exact N`; a meeting with a
  system track uses `Other speakers: Auto/Exact N` through a per-run constraint.
- The feature works without timestamps only by explaining the limitation and,
  when possible, offering a timestamp-capable retranscription.
- No new cloud, audio upload, voiceprint, or content telemetry behavior is
  introduced.

## Approval Decisions Before Implementation

Recommended defaults are in bold:

1. **Ship whole displayed timed segments plus explicit between-word splits in
   V1, anchored to durable citation segments and exact word ranges**; defer
   arbitrary character-level editing and durable citation split/merge.
2. **Allow explicit cross-source display corrections while preserving and
   protecting original mic/system provenance**; alternatively forbid them.
3. **Keep duplicate display names with a warning**; do not auto-merge by name.
4. **Ship GUI mutation first but design the service/contract for CLI parity in
   the same plan**; expose mutating CLI commands only after the GUI contract is
   stable.
5. **V1 requires explicit reset confirmation on retranscription**; design
   replay and `Needs review` as a separate follow-up rather than delaying basic
   post-transcription repair.
