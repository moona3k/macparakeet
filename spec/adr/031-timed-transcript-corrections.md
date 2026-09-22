# ADR-031: Segment-Timed Transcript Corrections

> Status: **Accepted; implemented in development source**
> Date: 2026-09-13
> Related: [ADR-010](010-speaker-diarization.md),
> [ADR-027](027-product-north-star.md),
> [issue #893](https://github.com/moona3k/macparakeet/issues/893)

## Context

MacParakeet currently has two correction paths for completed transcriptions.
The Text view can replace the whole transcript, but that edit has no safe map
back to the recognized words. The Timed view can correct speaker attribution
and split a displayed segment at an existing word boundary, but it cannot
correct the words shown in that segment or join adjacent lines. The result can
be two visible versions of what users reasonably understand as one transcript.

Writing edited text into the automatic word array would appear to solve the
display problem, but it would invent word-level alignment. It would also erase
the recognized evidence needed for undo, retranscription diagnostics, and
future alignment improvements.

## Decision

### One effective transcript over an immutable baseline

The automatic `rawTranscript`, word text, word timing, durable segment anchors,
and diarization evidence remain immutable. User edits are append-only commands
in the existing transcript-scoped correction journal and share its persistent
Undo/Redo cursor, optimistic revision, fingerprint, and reset behavior.

The journal retains its historical `speaker_corrections` schema and Swift type
names for compatibility, but it now owns both speaker and timed-text
corrections. A second edit log or independent undo stack is not introduced.

The active correction branch resolves to one effective projection containing:

- the current speaker roster and attribution;
- the ordered displayed timed segments;
- the corrected plain transcript derived from those segments; and
- a derived text-alignment mode.

The app, search, AI context, shares, exports, meeting artifacts, and CLI must
consume that projection. No consumer may independently replay corrections or
reconstruct corrected text from the automatic word strings.

### V1 edit operations

V1 adds two commands:

- **Edit text** replaces the non-empty text of one current displayed segment.
  Its original start and end time remain the timing envelope.
- **Merge lines** joins two or more ordered, adjacent current segments that
  have the same effective speaker assignment. The result spans the first
  segment's start through the last segment's end and composes their current
  text. Reassigning a line before merging is explicit and undoable.

Existing between-word splits remain valid only where no text override crosses
the requested boundary. MacParakeet does not guess how a rewritten sentence
should be divided between words. Undo the text edit, split, and edit the
resulting lines when a different boundary is needed.

Blank replacements, non-adjacent merges, overlapping targets, stale ranges,
mixed-speaker merges, and commands against a different transcript fingerprint
are rejected without advancing the journal or changing derived state.

### Alignment modes

`Transcription.transcriptTextAlignment` derives three states without adding a
second persisted transcript-wide flag:

- `automatic`: text/timing behavior is derived from present automatic words;
- `segment`: effective text is aligned only to effective segment envelopes;
- `untimed`: the transcript has no safe timed mapping, either because automatic
  word timestamps are absent or because a legacy whole-transcript edit replaced
  the timed text.

The existing `isTranscriptEdited` value identifies `untimed` legacy edits;
absence of automatic word timestamps also derives `untimed`.
Effective segment records mark only corrected text/boundaries, which derives
`segment`; otherwise the projection is `automatic`. Correction history remains
the durable source of truth for the effective segment state.

Segment-aligned text may be highlighted, sought, shared, and exported at the
line's start/end time. It must never be emitted as if each edited word retained
the automatic word timestamps. Automatic word strings and timestamps remain
available as original evidence in JSON and meeting artifacts.

Legacy whole-text edits remain `untimed`. They are not silently aligned and do
not accept timed-text commands. Whole-text editing remains available for
transcripts without timing; completed timed transcripts edit through their
lines instead.

### Projection and identity

Each effective segment is identified by the automatic transcript fingerprint
and its half-open word range. It retains every overlapping automatic durable
segment ID as anchors. A deterministic UUID may be materialized for existing
JSON boundaries, but it represents an effective segment for the current
transcript version; it does not replace or mutate its automatic anchors.

Text replacement is emitted exactly once for its complete effective range,
including when the range overlaps more than one automatic durable segment.
Merging suppresses the internal display boundaries in replay order and
preserves child text edits. A later edit of the merged line replaces the
composed text as one indivisible segment.

### Atomic publication

Appending a command, advancing the correction cursor, replacing derived search
segments, and invalidating the current knowledge card remain one GRDB
transaction. Meeting artifact refresh occurs only after that transaction
succeeds. Text-only corrections must activate publication even when speakers,
word attribution, and diarization are unchanged.

Retranscription produces a new fingerprint. Previous history remains available
for audit but is neither replayed nor undoable on the new automatic transcript.

### Implemented surfaces

The development implementation includes correction replay and migration,
effective search/card derivation, Timed and Text views, playback highlighting,
SRT/VTT/TXT/Markdown/PDF/DOCX and DAPT exports, AI context, encrypted-share
projection, meeting artifacts, and CLI meeting JSON. Public JSON and artifact
fields are additive; automatic word evidence stays present for inspection.

Focused model, database, view-model, UI-layout, export, sharing, artifact, and
CLI tests cover the projection and compatibility rules. Stable-DMG availability
and hardware interaction remain release evidence, not consequences of this ADR.

## Consequences

Users see and export one corrected transcript without losing the recognized
evidence. Playback can honestly highlight the edited line, but the app cannot
claim which rewritten word was spoken at a particular millisecond.

The existing correction layer becomes broader than its historical name. That
small naming debt is accepted to avoid a risky table migration and duplicated
history machinery; a wholesale rename has no user value.

Every correction-aware output must honor the alignment mode. Word-based export
fallbacks are no longer safe for `segment` text, while `untimed` text must not
gain timestamps merely because the source still has an automatic word array.

## Alternatives considered

- **Rewrite `wordTimestamps`:** rejected because it fabricates alignment and
  destroys automatic evidence.
- **Store a second corrected transcript blob:** rejected because line identity,
  timing, speaker edits, and Undo/Redo would drift again.
- **Independent text-correction journal:** rejected because two cursors make a
  single visible edit history ambiguous and duplicate concurrency logic.
- **Realign edited words automatically:** deferred. It is a separate accuracy
  problem and is not required for honest segment-timed editing.
- **Arbitrary substring and drag-based cue editing:** deferred. Whole-line text
  replacement and adjacent same-speaker merge satisfy issue #893 without
  turning MacParakeet into a subtitle editor.
