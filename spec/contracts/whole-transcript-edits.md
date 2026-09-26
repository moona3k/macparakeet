# Whole-transcript edits

Whole-text editing applies to untimed transcripts and existing legacy whole-text
edits. Timed source text is edited through the existing line correction flow.

The editor captures an immutable source snapshot when it opens. Saving or
reverting requires the persisted row to exist and its canonical text, edit flag,
timing/segment data, processing status and correction state still to match.
Metadata-only changes (notes, favorite, title and other unrelated fields) do not
conflict and must be preserved. A deleted row must never be recreated.

The repository updates only edit intent on the current row, keeps its raw text,
and commits derived segments/FTS and card invalidation atomically. Failure rolls
back the transaction. updatedAt does not regress and is not a conflict token.
The returned persisted row is published to the UI. Conflicts retain the draft
and ask the user to reopen; edits are not silently retried over newer content.

Coverage: TranscriptEditPersistenceTests and TranscriptionViewModelTests.
