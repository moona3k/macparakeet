# Persist speaker-detection outcomes without changing attribution

**Status: design reviewed; implementation pending.** Updated 2026-10-02.
This is the next metadata/UI slice from the independent app audit. A smaller
cancellation-boundary repair is being delivered first. It adds no outcome
schema and does not close the durable-report gap described here.

The design was checked against audit base `f43f4bed2` and fix head `5e4c96ac4`.
Verify the merged base and open-PR state before allocating a migration or CLI
version. This record is an implementation plan, not evidence that these fields
or notices already exist.

## Outcome and scope

Ship one complete vertical slice: a completed file, URL, or meeting transcript
records whether optional speaker detection ran, what happened, which backend
actually supplied the result, and whether detected speakers reached timed
words. Expose that same receipt in local JSON and a nonblocking result-view
notice. Successful ASR remains a successful transcription when optional
detection fails. Cancellation remains cancellation.

Do not change model selection, model settings, clustering, source reconciliation,
word overlap assignment, smoothing, timing offsets, speaker identities, count
semantics, or correction history. Do not implement the planned audio speaker
timeline in this change. In particular, keep the current file-path prerequisite
for word timings; report the skipped analysis truthfully. The meeting path
already analyzes the system track independently of word availability and must
keep doing so.

This closes audit findings DIAR-02 and the local provenance portion of DIAR-03.
It does not establish corpus accuracy, fix smoothing, or qualify telemetry
ingestion. The measured audit fixtures remain regression evidence; VoxConverse
overlaps Nemotron training and cannot support held-out quality claims.

## Existing behavior that determines the design

| Evidence in current checkout | Consequence |
| --- | --- |
| `Services/TranscriptionService.swift:1923-1925,1972-2012` combines the preference, presence of a service, and word availability; errors are logged and ASR completes. | Derive request and eligibility separately. A nil result must no longer mean disabled, skipped, empty, and failed simultaneously. |
| `Services/TranscriptionService.swift:1436-1439,1733-1826` restricts archived-source meeting detection to the system track; the helper returns nil for several different states. | Replace only this private optional return with a small stage result containing the existing optional `SystemDiarization` and the outcome receipt. |
| `Services/Diarization/DiarizationService.swift:118-134` selects Community-1 for explicit bounds or enabled voice profiles, otherwise Nemotron. | Provenance must come from the service selected for this run, not from a global default or UI preference. |
| `Services/Diarization/NemotronDiarizationService.swift:99-128` can return Community-1 output after Nemotron violates an advisory meeting bound, or retain Nemotron after fallback failure. | Record primary and selected backends and whether fallback was used or failed. A retained native result is degraded success, not total detection failure. |
| `Services/Diarization/DiarizationService.swift:257-260` turns the SDK no-speech exception into an empty successful result. Nemotron also returns successful empty activity. | Keep explicit empty acoustic success distinct from ASR returning no words. Prefer the public term `noSpeakerActivity`; it is not proof that the recording contains no speech. |
| `Services/MeetingRecording/MeetingTranscriptFinalizer.swift:57-86,129-151` can produce source-only `Me`/`Others`, or a mixture of source buckets and detected identities. | Neither a nonzero `speakerCount` nor any nonnil word speaker ID proves acoustic word attribution. Evaluate attribution against this run's actual detected ID roster. |
| `Services/Diarization/SpeakerAttributionReadService.swift:34-60` copies the automatic record and changes its effective words/roster. | The outcome remains evidence about automatic processing; corrections must preserve it and must not rewrite its provenance. |

Paths in that table are relative to `Sources/MacParakeetCore/`.

## Recommended domain model

Add `Sources/MacParakeetCore/Models/DiarizationOutcome.swift` containing small
Codable, Equatable, Sendable types. Give the public JSON explicit stable keys
and string values; do not expose Swift associated-enum synthesized encoding.

The report should have these concepts, without a generalized job/attempt
framework:

| Field | Contract |
| --- | --- |
| `schemaVersion` | Integer 1. |
| `source` | `fileAudio`, `isolatedSystemAudio`, or `canonicalMeetingAudio`. A media URL uses `fileAudio`; a canonical-only meeting uses its existing single-file path. |
| `status` | `disabled`, `notApplicable`, `skipped`, `completed`, `noSpeakerActivity`, or `failed`. `completed` describes acoustic execution, not accuracy or complete word coverage. |
| `reason` | Optional bounded code: `noSystemTrack`, `missingWordTimestamps`, `noRecognizedWords`, `serviceUnavailable`, `inputUnavailable`, or `detectionFailed`. No localized error strings, file paths, transcript fragments, or arbitrary error descriptions. |
| `wordAttribution` | `notAttempted`, `applied`, `missingWordTimestamps`, `noRecognizedWords`, `noSpeakerActivity`, or `noAlignedWords`. `applied` means at least one timed word carries an ID from the acoustic result; it does not assert all words are attributed or attribution is correct. |
| `provenance` | Optional receipt: primary backend descriptor; fallback backend descriptor when attempted; selected result backend descriptor when one exists; `fallback` = `notAttempted`, `used`, or `failedRetainedPrimary`. Only this current two-backend route is modeled. |
| `constraint` | Optional explicit JSON snapshot of the effective bound: origin `explicit` or `meetingPrior`, kind `exact` or `range`, and applicable count/min/max. Do not serialize calendar names, attendee lists, or voice profiles. |
| `constraintSatisfied` | Optional Boolean based on the selected acoustic result and effective constraint. Nil if no bound or no acoustic result. Configuration being passed to a backend is not proof the bound was satisfied. |

A backend descriptor needs `backend` (`nemotron` / `community1`), the model
revision actually configured for that service, and an app pipeline revision
that includes the relevant preset/configuration identity. Nemotron's preset is
material and must be represented. Do not claim model-file hash verification
from a configured revision. Do not reuse the ASR `engine`/`engineVariant` or
invent a Community-1 revision for Nemotron.

Use the pinned Nemotron store revision at
`NemotronDiarizationModelStore.swift:8` and its actual instance preset. For
Community-1 use the SDK diarizer repository revision plus the app configuration
revision; `DiarizationService.swift:492-520` already contains relevant model and
pipeline identity but its embedding identity alone is not the whole diarization
pipeline. If PR #1201 lands first, the dithered preprocessing must be represented
in the pipeline revision. Leave identity embeddings and profile matching alone.

In-memory invariants should be enforced through named factories or one local
validation function. Avoid permitting a report with `failed` plus an apparent
successful selected backend, or `used` fallback whose selected backend is
still Nemotron. `failedRetainedPrimary` is paired with successful native output.
No new per-record analysis UUID, timing samples, confidence score, generic event
history, or copies of acoustic turns are needed for this milestone.

### State decisions

| Actual condition | Stored interpretation |
| --- | --- |
| Legacy row, imported legacy JSON, queued/unprocessed split child | Outcome absent: unknown/not recorded. Never infer disabled, success, or failure from nil or historical speaker fields. |
| Preference off, no explicit per-run override | `disabled`, attribution `notAttempted`, no backend execution. |
| Requested archived-source meeting has no system track | `notApplicable`, reason `noSystemTrack`; microphone/source labels may still exist. |
| Requested file/canonical path has nonempty ASR text but no words | `skipped`, reason and attribution `missingWordTimestamps`; do not start a new acoustic run in this PR. |
| Requested file/canonical path has empty ASR text and no words | `skipped`, reason and attribution `noRecognizedWords`; do not call this no-speech detection. |
| Requested and eligible, but no service | `failed`, `serviceUnavailable`; absence of a dependency is not an off preference. Tests that intentionally omit a diarizer should explicitly disable it when that is their intent. |
| System track is present but its required converted input is unexpectedly unavailable | `failed`, `inputUnavailable`; do not present this as an inapplicable microphone-only meeting. Existing whole-operation conversion failures still follow their current failure path. |
| Backend returns valid empty activity / its documented no-speech result | `noSpeakerActivity`, with actual successful backend receipt. |
| Backend returns nonempty activity and words gain detected IDs | `completed` / `applied`. |
| Backend returns nonempty activity but no timed words align to its roster | `completed` / `noAlignedWords`; existing source labels are not evidence of success. |
| Meeting acoustic analysis succeeds while system ASR has no words | `completed` or `noSpeakerActivity` for acoustics; separately `missingWordTimestamps` if system text is nonempty, otherwise `noRecognizedWords`. Microphone word availability cannot stand in for system words. |
| Primary throws, ASR usable | `failed`, `detectionFailed`, known attempted descriptor if available, no selected successful result. |
| Advisory fallback succeeds | Preserve the returned fallback result exactly, even if empty; record Nemotron primary, Community-1 selected, fallback `used`. Do not silently substitute the earlier native result. |
| Advisory fallback fails and current code retains native result | Native `completed`/`noSpeakerActivity`, Nemotron selected, fallback `failedRetainedPrimary`, constraint satisfaction computed honestly. |
| Cancellation, including a generic backend error after task cancellation | Propagate cancellation. Do not persist a degraded completed transcript or overwrite an old outcome. |

For disabled/inapplicable runs use `notAttempted` word attribution. For an
actual acoustic run with no timed system text, prioritize the timing/no-words
description in `wordAttribution`; the acoustic status already preserves whether
speaker activity was empty. These rules avoid contradictory user explanations.

## APIs and integration points

1. **Adapter receipts.** Extend `MacParakeetDiarizationResult`
   (`DiarizationService.swift:5-27`) with optional provenance, default nil for
   existing mocks/test fixtures. Production adapters always populate it,
   including successful empty results. Add a cheap protocol descriptor method
   with a default nil implementation so the caller can identify an attempted
   backend even when the call throws; fetching a descriptor must not load models.
   Both real service actors override it. Do not guess a descriptor for a mock.

2. **Fallback ownership.** `NemotronDiarizationService.diarize` attaches primary
   and selected descriptors and fallback disposition at the exact branch that
   chooses the returned result. Community-1 reports the effective explicit
   constraint rather than a discarded caller hint. Meeting policy origin is
   known at `MeetingSpeakerPolicy.resolve`; preserve explicit-over-prior
   precedence. Keep the requested constraint snapshot separate from whether
   the selected acoustic count satisfies it.

3. **Orchestration.** In `TranscriptionService.transcribeAudio`, derive the
   effective request from the per-run override or preference before checking
   dependencies and word eligibility. Build one report along the existing
   branches and assign it before `completeTranscription`. In
   `transcribeMeetingAudio`, use a private stage result from
   `diarizeMeetingSystemIfNeeded` and finish the attribution state after the
   existing finalizer. Do not add acoustic arrays to `SystemDiarization` merely
   to carry status; the private wrapper is enough. No new top-level scheduler
   operation or second persistence write.

4. **Cancellation.** Call `Task.checkCancellation()` after awaited diarization
   returns, before interpreting no-speech exceptions as successful empty
   results, and inside the generic failure catch before materializing failure.
   Keep explicit `CancellationError` propagation in the adapter and caller.
   This protects against an SDK that returns success/another error after a
   cancelled request. Check again after later awaited post-processing and
   immediately before segment invalidation/canonical completion. Once that
   commit boundary has been crossed, cancellation does not roll back saved
   text or its outcome. A deterministic gated formatter test must cover
   cancellation after successful diarization but before persistence. Do not release the inference permit before actual model
   work finishes or change scheduler cancellation ownership.

5. **New/replacement lifecycle.** `makeRetranscriptionRecord` at
   `TranscriptionService.swift:2104` resets the candidate's old report. Only a
   successful completion commits the new one, including disabled/skipped/failed
   optional detection. Failed/cancelled retranscription preserves the previous
   saved text and report. `persistResult: false` still returns the report without
   inserting a database row. `savePreservingUserMetadata` remains the single
   authoritative completion write; this computed result is not a user-owned
   metadata field to copy back from the old row. Preserve deletion refusal.

## Database, compatibility, corrections, and artifacts

Add `Transcription.diarizationOutcome` as optional with a nil default in
`Models/Transcription.swift:35-37,103-188`; update `Columns` and custom decoding
at `:419-511`. Add a nullable JSON-text column in a new migration after the
current `v0.49-ask-conversations` at `DatabaseManager.swift:2431-2448`. Use the
current JSON-column convention, no new table, no non-null default, and no
backfill. Confirm the migration ID against the landed base rather than adopting
a reserved `v0.50` blindly.

Old JSON with a missing/null field and supported read-only databases without
the column decode to nil. Summary Library SQL includes new small columns
automatically (`TranscriptionRepository.swift:958-974`); keep this report out
of the heavy timing-field omission list.

Preserve unsupported optional report data on unrelated writes. Do not just
`try?` decode an unknown version to nil and then allow a favorite/note/title
update to overwrite the stored receipt: repository mutation methods currently
decode and update whole rows (`TranscriptionRepository.swift:729-905`). Keep
the optional storage envelope capable of retaining its opaque payload while
exposing typed v1 content only when understood. Unknown versions/statuses render
as unavailable, never success/failure; a malformed report must not make ordinary
transcript text disappear. Limit this codec to the new field rather than
refactoring every existing JSON report. Verify unknown-version preservation
before settling the model implementation. Preserve additive unknown fields,
including nested fields, even in an otherwise understood v1 payload; unrelated
metadata writes must re-emit the original payload rather than reconstructing
only known fields. A new processing run may replace it. This is a data-integrity requirement,
not a reason for a library-wide abstraction.

The report is automatic processing metadata. Leave
`SpeakerAttributionResolver.fingerprint(for:)` and the correction journal
unchanged. Effective projections, edits, rename/assign/merge, undo/redo, and
reset retain it; they do not upgrade `noAlignedWords` to an acoustic success
because a user added labels. This report describes the automatic run, not the
current corrected roster. Existing retranscription confirmation continues to
govern replacing text/corrections.

Split children are currently constructed fresh at
`Database/MeetingSplitRepository.swift:423`; they begin with nil and receive
their own result from child processing. Do not copy the parent's report or
backend/count conclusions. Audio retention deletes audio only and preserves
the report as historical metadata, while removing the retry affordance.

`MeetingArtifactStore` uses explicit DTOs, so updating `Transcription` alone
is incomplete. Add the same optional report to:

- `MeetingArtifactSnapshot` properties/CodingKeys/decoder/initializer at
  `Services/MeetingRecording/MeetingArtifactStore.swift:131-261`, and its
  construction at `:415-437`.
- The manifest meeting payload at `:575-615`.
- `MeetingArtifactTranscript` at `:650-729`.

Artifact refresh projects the saved report, not reconstructed current speaker
fields. This remains an additive v1 artifact field. Do not put it into shared
public transcript bundles or prompts/AI context as part of this change; those
remain governed by their existing allowlists. No transcript/embedding/profile
data belongs in the report itself.

## CLI and GUI behavior

Automatic JSON coverage comes from `Transcription` encoding for `transcribe`,
history transcription results, `retranscribe`'s `record`, and standard JSON
export (`ExportService.exportJSON`). Explicit DTOs still require changes in
`Sources/CLI/Commands/MeetingsCommand.swift`:

- `MeetingRecord` at `:1311-1408` (`meetings show`).
- `MeetingTranscriptRecord` at `:1410-1440` (`meetings transcript` and meeting
  JSON export).
- Leave `MeetingListItem` at `:1258-1309` unchanged. The detail, transcript and
  export surfaces provide the receipt; list expansion needs a demonstrated
  consumer and separate additive contract.

The indexed `transcript` slice command has a separate segment DTO
(`TranscriptCommand.swift:78`) and is not a processing receipt. It need not
gain this field. Keep segment/search/citation formats untouched.

For human CLI execution, print a concise warning to stderr when ASR completed
but speaker detection failed, and a distinct notice for an unmet advisory
bound whose native labels were retained. Also explain skipped missing timings
when detection was requested. Do not insert notices into transcript stdout,
SRT/VTT/DAPT, exported text, or a JSON envelope's data shape. Keep success exit
status when ASR succeeded. Provide JSON consumers the same typed receipt;
they need no new command or flag.

Warning emission must cover all existing branches: single-file/stdout,
podcast-to-output-directory, and each batch result. `emitStdout` alone misses
file-only outputs (`TranscribeCommand.swift:679-710,790-804`). Use one bounded
report-to-notice helper called exactly once per result after processing, with
stderr as its output. Keep native stdout suppression/teardown order intact.
`RetranscribeCommand.printResult` at `:760` similarly handles human output;
dictation payloads have no diarization outcome and remain unaffected. A no-save
run must not say “saved”; use “Transcription completed, but speaker detection
was unavailable.” in CLI copy.

In the app, add a small `DiarizationOutcomePresentation` in ViewModels and a
small banner view in the transcription views directory. Mount it immediately
above the transcript at `TranscriptResultView.swift:2087-2113`, using
`activeTranscription` so the report survives correction projections. Suggested
failure copy: “Speaker detection was unavailable. Your transcript was saved.”
Missing timings should explain why speaker labels are unavailable without
claiming failed speech recognition. Avoid duplicating the existing meeting
no-word-timestamps banner (`:4659-4705`); choose one presentation for that state.
Successful detection with `noAlignedWords` warrants a distinct informational
notice that detected speakers could not be matched to the transcript; do not
describe the acoustic run as failed or imply the existing source buckets are
identified people.

For retained native labels after fallback failure, explain that the count hint
could not be applied and automatic labels were kept; do not present total
failure. Disabled, inapplicable, unknown legacy, and successful empty activity
do not get an alarming failure banner. Backend identifiers belong in optional
diagnostic details/JSON, not the primary warning copy.

Use the existing “Retranscribe…” action and confirmation, including the
correction-reset warning (`TranscriptResultView.swift:1236-1265,1300-1345`).
Do not add an action labeled “Retry speaker detection” that actually reruns
ASR. Gate the action on retained compatible audio and existing status checks;
when audio is gone, the notice remains informational. A disclosure/details
button is optional; a new retry-only pipeline is out of scope.

## Required focused verification

1. **Domain/codec/migration:** one new `DiarizationOutcomeTests` table covers
   allowed states, explicit stable JSON shape, nil legacy semantics, and
   opaque unknown-version and additive unknown-v1-field preservation.
   `TranscriptionModelTests` and
   `TranscriptionRepositoryTests` cover DB round trip/reopen, migration from
   the previous schema, missing/null field, summary loading, and unrelated
   favorite/note/title update retaining the receipt. Completion still refuses
   deleted rows and preserves concurrent user metadata.
2. **Adapters:** extend `DiarizationServiceTests` and
   `NemotronDiarizationServiceTests` with injected runners/managers. Assert
   backend/model/preset receipts for native success, explicit Community-1,
   empty/no-speech, advisory fallback success, fallback empty, fallback error
   retaining primary, explicit-over-prior precedence, and cancellation during
   primary/fallback. No live model/network dependency is needed for this gate.
3. **Orchestration:** extend `TranscriptionServiceTests` for the state table,
   both file and isolated-source meeting paths. Include a meeting whose mic
   has words but system has only untimed text; a successful nonempty diarizer
   with zero matching word spans; nil dependency with preference on; ASR usable
   plus optional failure; disabled overriding stale prior report; no-save;
   cancellation after a backend returns; and cancelled/failed replacement
   retaining the original report, including cancellation during a later
   formatter/title await after diarization has succeeded. Assert existing words/offsets/rosters are
   unchanged for every non-failure case.
4. **Corrections and persistence parity:** extend
   `SpeakerAttributionReadServiceTests` / resolver tests for report and
   fingerprint preservation across corrections and Undo/Redo. Extend
   `MeetingArtifactStoreTests` and `MeetingSplitServiceTests` or repository
   tests for saved artifact equality, nil/new child receipt, parent retention,
   and audio-removal behavior. Do not duplicate the full correction suite.
5. **CLI:** `TranscribeCommandTests`, `RetranscribeCommandTests` /
   `RetranscribePersistenceTests`, `MeetingsCommandTests`, and
   `ExportCommandTests`: canonical JSON parity across named surfaces; absent
   legacy report; stderr-only notice exactly once for single/batch/file-output;
   parseable JSON and unchanged exit semantics; no transcript-text pollution;
   dictation unchanged.
6. **UI:** pure presentation tests cover all status/attribution combinations,
   audio availability, source-only labels, legacy nil, fallback retention,
   and deduplication with the timing banner. Add an isolated native/offscreen
   result fixture to inspect copy, wrapping, keyboard/VoiceOver labeling, and
   routing into the existing destructive retranscription confirmation. A pure
   presenter test does not prove native action wiring.
7. **Qualification:** after focused tests and review, run the full suite once
   through the coordinated root workflow. Re-run the isolated, network-denied
   real-model E2E with the already-owned public fixture/model clones to verify
   actual Nemotron receipts survive ASR, database reopen, artifacts and JSON.
   Injected C1/fallback tests establish branch behavior; do not claim a
   real-model fallback run unless executed. Acoustic outputs should be
   unchanged. No corpus-wide accuracy/performance benchmark is required for a
   metadata-only change.

## Contracts and docs in the implementation PR

- `spec/01-data-model.md`: nullable JSON column and legacy/ownership semantics.
- New concise `spec/contracts/diarization-outcome-v1.md`: exact schema/state
  matrix, surface list, cancellation/replacement lifecycle, unknown data
  preservation and privacy boundary.
- `spec/contracts/cli-json-v1.md`, `Sources/CLI/CHANGELOG.md`, and relevant
  discovery/version fixtures: additive receipt and stderr/success behavior.
  Select the actual minor version from the implementation base.
- `spec/contracts/meeting-artifacts-v1.md`: manifest/transcript/snapshot parity.
- `spec/adr/010-speaker-diarization.md`: implemented durable outcome and fallback
  provenance, with unchanged acoustic algorithms and remaining evaluation gap.
- `spec/03-architecture.md` and `spec/09-testing.md`: concise updates for
  orchestration/report ownership and meaningful verification lanes.
- `spec/contracts/audio-speaker-timeline-v1.md`: remain explicitly planned.
  Cross-reference the new outcome receipt as a landed prerequisite; do not
  claim independent acoustic timelines or wordless file analysis now exist.
- Audit follow-through: close only the delivered local outcome/provenance gap;
  leave telemetry receiver, held-out evaluation, and source-bucket counting
  work separately visible.

No new telemetry key is necessary for this PR. Local receipts do not flow
automatically into telemetry. A later bounded telemetry change can add
backend/fallback/outcome enums only with matching receiver allowlists and
contract tests; raw reports, counts derived from calendar membership, model
paths, and speaker data must not be sent wholesale.

## Open PR coordination

Fresh GitHub read on 2026-10-02:

- [#537](https://github.com/moona3k/macparakeet/pull/537) remains OPEN at
  `171466962f68a0d34a5ce65f19dfe156438bb786`, last updated September 22.
  It has broader quality controls, word assignment/evaluation, and provenance
  work. Do not copy or merge that old branch wholesale. Document that this
  follow-on extracts the durable processing-outcome requirement while leaving
  its algorithm/evaluation changes for independent qualification. Check its
  public field naming before finalizing the new contract to avoid two future
  meanings for the same name.
- [#1201](https://github.com/moona3k/macparakeet/pull/1201) remains OPEN at
  `53a644f870268aa8c285568ac4eef315539b5266`, last updated October 2.
  It changes Community-1 dithered input, not outcome persistence. Preserve
  its adapter/process wrapper edits and coordinate pipeline revision metadata
  if it lands first. This plan does not duplicate its fix or claim its corpus
  qualification.

## Separate speaker-count follow-on

Do not “fix” `speakerCount` while landing this receipt. The audit's real meeting
reported four roster entries (`Me`, source-only `Others`, and two remote
identities), while the corresponding file reported two acoustic identities.
`MeetingTranscriptFinalizer.activeSpeakers` deliberately retains the unmatched
system bucket, and correction projections also recompute roster length.
Changing this field alone can break GUI menus, speaker filters, CLI consumers,
and corrected projections without removing the source bucket itself.

First inventory every consumer and define distinct quantities: acoustic cluster
count for the analyzed source; effective transcript roster count; presence of
unattributed system words; and the explicitly modeled local microphone source.
None is a guaranteed number of physical people. Then add an honest presentation
or additive API quantity with its own contract/tests, preserving existing
`speakerCount` compatibility or deliberately versioning its replacement. The
current receipt uses its adapter result to evaluate bounds and never uses the
legacy combined roster count for that purpose.

## Delivery boundary

This is a moderate cross-layer change, not a one-file warning. Keep it as one
reviewable PR because the migration, producers, durable model, JSON, artifacts,
and UI need a single truthful contract. Parallel ownership can separate
adapter/model work, orchestration/persistence, and CLI/UI once the schema is
settled; coordinate all Swift builds. Stop when focused tests, independent
review, final full-suite gate, representative artifact/JSON parity, and the
native warning-action check pass. Land acoustic heuristics, timeline rendering,
speaker-count reinterpretation, and telemetry ingestion separately.
