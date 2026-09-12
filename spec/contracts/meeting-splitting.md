# Split and transcribe

> Status: APPROVED DESIGN — implementation and boundary tests are pending.

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
- Retry must not unnecessarily repeat completed automation. Do not promise
  exactly-once external side effects where the existing provider/hook cannot
  establish it. Surface uncertain delivery rather than silently duplicating it.

## Retention, privacy and presentation

The initial recording-date/retention anchor remains the original's date;
split-created time and ordinal are separate. Recheck current age-based expiry
before audio publication and honor normal retention during later processing.
Splitting grants no hidden grace period. The existing delete-immediately
preference remains a new-capture policy, not retroactive historical deletion.

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

No CLI flags, persisted fields, schema migrations or public DTO names are
frozen by this design-only change. Implementation must document actual names
and additive compatibility in the relevant contracts. Older binaries cannot
be assumed to honor newly introduced mutation ownership.

Required tests cover audio ranges, source hashes, independent deletion,
all-or-none publication, interruption/retry, concurrent cleanup, sequential
first transcription, enabled/disabled automation, canonical-only audio,
partial processing success and read-only preview. These tests do not yet
exist as a completed feature suite.

Three existing Core regression tests were run on implementation worktree
commit `57c3de5731656378c65108b2b46984fd9c302d99` during pipeline inspection:
`testRetranscribeDeletedDuringSTTDoesNotReturnOrRecreateRecording`,
`testRetranscribeExistingFileFailureLeavesOriginalRowIntact`, and
`testRetranscribePreservesMetadataEditedWhileSTTIsSuspended` in
`TranscriptionServiceTests`. All three passed. They establish useful existing
saved-audio behavior, not split, automation or real-model acceptance.

## When this changes

Update this contract, the [plan](../../docs/plans/2026-09-11-issue-895-meeting-split-plan.md)
and focused tests together. Persistence changes update the data-model and
artifact/recovery contracts; public CLI changes update integration docs,
JSON contracts and help/spec discovery. Record actual runtime evidence and
limitations in the implementation PR.
