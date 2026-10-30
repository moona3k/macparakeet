# Preserve recordings and edits; keep imports responsive

Status: implementation and verification in progress.

GPT-6-Astra reviewed the proposed scope against `763fb5d50` on 2026-09-26
and supplied an approved revised specification before implementation. The four
changes share no new framework or database migration.

## Scope and acceptance

1. Stop preserves the complete recording folder and recovery marker when any
   non-pending source cannot be inspected or writer evidence contradicts an
   empty source. An uncertain source cannot be silently omitted beside a valid
   sibling. Stop releases its live session and engine lease on inspection
   failure so the next recording can start. Proven-empty recordings still
   clean up; valid silence and pending-writer ownership remain protected.
2. Whole-text edit and revert capture the draft's immutable source snapshot.
   A repository transaction requires an existing, unchanged, non-processing
   source and applicable correction state, rechecks timed-edit eligibility,
   preserves current unrelated metadata, and updates derived search/card state
   atomically. Deletion/conflict leaves the draft visible with an actionable
   error. No upsert, automatic retry, or updatedAt conflict token.
3. AI formatting checks the complete rendered request against the existing
   provider budget before invoking the model. Oversized input, a truncated
   detailed result, or a length/max_tokens finish falls back to complete
   deterministic text with failed-attempt metadata. No chunking or partial
   replacement, no change to opt-in or cancellation boundaries.
4. File/folder discovery runs outside MainActor, has visible cancellable state,
   and owns a request identity. Admission precedes return; unsupported results
   are asynchronous. All competing transcription entrypoints respect admission.
   Cancel retires identity and signals the worker; stale success/error cannot
   start work or overwrite replacement state. Format filtering, deduplication,
   package/hidden exclusions, ordering and 200-file cap stay intact. Cancellation
   is cooperative between filesystem calls, not an OS-call interruption promise.

## Verification

Use injected storage failures, real in-memory GRDB interleavings and rollback,
real formatter service with fake provider, and suspended discovery barriers.
Run focused tests locally; hosted CI supplies the final full-suite and packaging
checks. Native GUI, real-model and physical microphone qualification remain
separate and are not implied by these tests.

No release, deployment, personal data mutation, broad refactor, or changes to
unrelated primary-checkout work are included.
