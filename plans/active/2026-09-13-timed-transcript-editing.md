# Timed Transcript Text Editing and Line Merge

> Status: **IMPLEMENTED ON FEATURE BRANCH**
> Date: 2026-09-13
> Issue: [#893](https://github.com/moona3k/macparakeet/issues/893)
> Governing decision: [ADR-030](../../spec/adr/030-timed-transcript-corrections.md)

## Goal

Make a completed timed transcription behave as one editable transcript. A user
can correct a displayed line or merge adjacent same-speaker lines, and the Text
view, Timed view, playback, retrieval, AI, sharing, exports, artifacts, and CLI
all observe the same effective result without rewriting automatic words or
inventing word timing.

## Settled scope

- Extend the shipped speaker-correction journal and shared Undo/Redo cursor.
- Keep automatic text, words, timings, durable anchors, and diarization intact.
- Edit one whole displayed line at a time; replacement text must be non-empty.
- Merge only adjacent current lines with one effective speaker assignment.
- Preserve the first start and last end time for a merged line.
- Treat corrected words as segment-timed, never word-timed.
- Derive Text view text from the corrected timed segments.
- Keep legacy whole-transcript edits untimed and do not auto-align them.
- Fingerprint retranscription separately so old corrections never replay.

Out of scope: word-level realignment, arbitrary substring cue operations,
multi-track timeline editing, bulk find/replace, and a wholesale rename of the
existing speaker-correction subsystem.

## Implementation slices

### 1. Correction model and replay

- Derive automatic, segment-timed, and untimed alignment states from the
  legacy whole-text flag and effective per-segment correction markers.
- Add `editText` and `mergeSegments` journal commands and migrate the operation
  constraint without rewriting or discarding existing history.
- Resolve boundary suppression and text overrides in replay order.
- Materialize stable effective segments with their complete automatic anchors.
- Reject unsafe split, merge, blank, stale, and legacy-untimed operations.

Verification: model round trips, migration preservation, pure replay cases,
transaction rollback, Undo/Redo/branch/reset, and retranscription tests.

### 2. One consumer projection

- Make `effectiveTranscription` publish corrected plain text, effective timed
  segments, and segment alignment while preserving automatic word evidence.
- Derive search rows from effective segments and invalidate knowledge cards in
  the correction transaction.
- Teach TXT/Markdown/PDF/DOCX, SRT/VTT/DAPT, AI context, shares, meeting
  artifacts, and CLI JSON to distinguish segment timing from untimed text.
- Bump the deterministic retrieval segmenter version.

Verification: one unique corrected phrase appears across every projection and
the replaced automatic phrase remains only in original evidence.

### 3. Timed editor UX

- Replace the Timed toolbar's speaker-only mode with `Edit transcript`.
- Add a per-line text editor with Save/Cancel and retained draft on failure.
- Add merge-with-previous/next actions only when adjacency and speaker rules
  pass; retain the existing speaker assignment and split actions.
- Label the shared actions Undo, Redo, and Reset edits.
- Highlight an active effective segment only inside its start/end interval.
- Keep whole-transcript editing for untimed transcripts and legacy content.

Verification: view-model submission tests, action-availability tests, layout
smoke tests, accessibility labels, and a manual app smoke pass.

### 4. Contracts and completion

- Update the data model, features, UI patterns, ADR index, speaker plan, DAPT,
  CLI JSON, meeting artifact, share, and view-model submission contracts.
- Run focused suites during implementation and the full `swift test` suite once
  as the final code gate.
- Run independent design/code review, resolve material findings, and commit
  each complete green slice.

## Acceptance criteria

- Editing a timed line survives relaunch and can be undone/redone after relaunch.
- Timed and Text views display the same corrected words.
- Playback highlights the complete edited/merged line only within its envelope.
- A same-speaker adjacent merge keeps the first start and last end time.
- The app refuses to invent word timing, split through rewritten text, merge
  mixed speakers, or apply stale corrections.
- Search, AI, sharing, exports, meeting artifacts, and CLI use corrected text.
- Automatic raw text, word text/timing, and durable anchors remain unchanged.
- Legacy whole-text edits stay untimed and remain reversible through their
  existing path.

## Completion evidence

- Focused correction-model, migration, service, consumer, CLI, view-model, and
  presentation suites passed during implementation.
- `swift run macparakeet-cli --help` passed on the final implementation head.
- The final `swift test` gate passed 6,494 XCTest cases and 29 Swift Testing
  cases with zero failures; 24 environment-gated tests were skipped.
- Two independent architecture/code-review passes found and verified fixes for
  automatic-boundary replay and competing whole-transcript/timed-line edits.

Merge review and hands-on testing with real saved transcripts remain release
verification, not implementation blockers.
