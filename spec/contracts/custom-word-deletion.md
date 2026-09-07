# Custom word deletion

> Status: ACTIVE — the shared selected-word deletion boundary.

## Purpose

Users can remove selected vocabulary rules, including a whole imported list,
without deleting the database or changing other local data. Issue #882's
start-muted meeting request is separate.

## Producers and consumers

- `CustomWordRepository.delete(ids:)` implements the asynchronous database operation.
- `CustomWordsViewModel` snapshots the confirmation and owns pending, success,
  and failure state for `CustomWordsView`.
- `CustomWordRepositoryTests` and `CustomWordsViewModelTests` enforce this contract.

## Semantics

- Input is a set of explicit UUIDs. An empty set deletes nothing. The operation
  never interprets an empty selection as “all.”
- Only matching `custom_words` rows are removed. Disabled rules are eligible
  when selected. Missing IDs are harmless; the returned integer counts actual
  deleted rows, not requested IDs.
- All selected rows are deleted in one GRDB transaction. Bounded SQL chunks
  share that transaction; a failure in any chunk rolls back every deletion.
- Database work runs asynchronously on GRDB's writer queue. The UI prevents
  another deletion or other word mutation while the operation is pending.
- Confirmation captures the exact words and UUIDs shown to the user. Clearing
  the alert binding before its asynchronous action runs does not discard the
  confirmed request. Later imports or selections cannot expand that request.
- The UI does not remove words optimistically. After success it removes the
  confirmed IDs from its loaded list, exits selection mode, and clears selection.
  A later read is not required to establish deletion success.
- On failure, the loaded words and selection remain available, an error is
  visible beside the list, and the user can retry. Cancelling confirmation
  does not mutate the database or clear the selection.
- Search changes clear selection and unconfirmed requests. Select all captures
  the currently matching rules; clearing the search permits selecting the
  entire loaded vocabulary. Reloading prunes selected IDs that no longer exist.
- Selection does not alter rule enabled states, stored transcripts, recordings,
  snippets, or preferences. There is no schema migration or new network call.

## Compatibility and non-stable details

Existing single-ID and whole-table repository deletion operations remain
available. The public CLI's existing `vocab words list` and
`vocab words delete <id>` commands and their JSON outputs are unchanged; agents
can continue to enumerate and delete explicit rules with those commands.

SQL chunk size and transient view-model presentation types are implementation
details. The [UI specification](../04-ui-patterns.md#custom-words-management)
defines the selection interaction. The [approved HTML study](../../docs/plans/2026-09-07-issue-882-bulk-delete.md)
records the visual direction, not release verification.

Changes to these guarantees require updated repository/view-model regression
tests and the governing UI specification in the same PR. Changes to the public
CLI would additionally require its JSON contract and changelog; none are made here.
