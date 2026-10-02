# Independent follow-up review — October 2, 2026

The merged retranscription and cancellation fixes passed a fresh source review.
The review also reproduced one remaining P2 Library pagination race and repaired
it with two deterministic regression cases. This record extends the initial
audit; it does not replace its dated evidence.

## Remaining bulk-delete race

The Library initially displays `[A, B]` and has a pending offset-two page.
Bulk deletion removes A, then remains suspended while deleting B. If the old
page reads after A disappears, it returns `[D, E]`. It can publish before bulk
completion, clearing `isLoading`. The previous repair then skipped its
replacement query because no load remained active. After deleting both targets,
the visible list was `[D, E]`, with `hasMore == false`; surviving C was hidden.
If B failed to delete, the list was `[B, D, E]`, with the same omission. C
remained in the database in both cases.

The two gated tests enforce that exact order without timing sleeps. Both failed
before the repair, with four failed assertions. After the repair, all 82 Library
tests passed, including partial-operation summaries, failed replacement reads,
stale generation handling, audio-only deletion and existing pagination controls.

Successful asynchronous bulk mutations now force one replacement read of the
current filter and entire requested window, even when the overlapping query
has settled. The limit is at least the configured page size, including a bulk
operation invoked before the first load. Single synchronous mutations retain
their existing pending-load behavior. All-failure batches avoid the new read.
The query still runs off the main actor and uses existing generation/cancellation
guards. Failed refreshes retain optimistic rows, selection and partial-failure
summaries. The cost is one bounded read per successful bulk operation.

[Validation receipt](evidence/library-bulk-pagination-re-review.json) records
source/log hashes and local verification. Final hosted checks are recorded on
the associated fix branch PR; local evidence alone is not a hosted-CI result.
The governing [UI spec](../../../spec/04-ui-patterns.md) now describes queries
that settle while bulk work remains suspended.

## Other review results

- **CLI/GUI persistence:** Core's committed row remains authoritative; removed
  second saves cannot overwrite post-completion corrections or resurrect a
  deleted transcription. The conditional dictation save rejects deletion and
  status changes. Existing same-status dictation metadata merging remains a
  documented limitation.
- **Diarization cancellation:** no blocker found in late-success/no-speech/error
  normalization or finalization checks. Native inference stays awaited while
  holding its gate and permit. Cancellation observed at or before the final
  pre-mutation check preserves the old row and derived index; later cancellation
  can still commit. Cancellation latency depends on actual native work exiting.
- **Evidence:** the retained logs match their hashes and contain 440 distinct
  passing cases on combined source `f3a8758ae`. Both original code PRs passed
  final hosted tests, Swift 6 and release/bundle checks; their review threads are
  resolved. This source recheck did not repeat physical capture or the full
  local suite.
- **Independent review:** one reviewer traced persistence and Library behavior,
  reproduced the race and wrote the gated tests. A separate adversarial reviewer
  reviewed cancellation and the bounded Library repair with no blocker.

## Product gaps remain

The app still needs durable speaker outcomes/backend provenance, held-out
evaluation of final attributed words, Whisper setup lifetime/watchdog parity,
non-skipped receiver compatibility and staging/deployment evidence, and matched
latency/memory qualification. The new repair changes no speaker model or
clustering policy. First-run testing remains skipped at the owner's request;
Bluetooth, AEC and long-call qualification are still open.
