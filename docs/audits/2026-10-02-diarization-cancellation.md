# Cancellation during speaker detection and finalization

Status: merged in [PR #1206](https://github.com/moona3k/macparakeet/pull/1206)
at `f3a8758ae7be4c0b3fdd65aa37a5a5cfea3072bd`. All 155 focused tests passed;
independent review and final-head hosted CI passed before merge. This is a bounded
follow-through from the [app audit](2026-10-02-app-audit/README.md), separate
from the planned [durable outcome receipt](../../plans/active/2026-10-02-diarization-outcomes.md).

## Failure and repair boundary

Optional speaker detection is allowed to fail while useful speech recognition
still completes. Cancellation is a different intent: a backend returning late
success, a no-speech response, or an ordinary SDK error must not convert a
cancelled operation into a successful saved transcript.

The review identified three boundaries:

- Community-1 awaits its manager and currently converts its no-speech error
  into empty success without checking whether the parent task was cancelled.
- Nemotron checks cancellation after successful native inference, but ordinary
  native errors bypass that check; a successful advisory fallback also returns
  without checking cancellation again.
- File and meeting orchestration can treat a late generic error as harmless
  optional failure. Completion then awaits text processing, formatting and
  meeting-title generation before replacing saved text. Cancellation during
  those later stages also needs a check before publication and persistence.

The repair checks cooperative task cancellation after awaited work, before
interpreting optional outcomes, and before the final mutation boundary. It
continues to await active native work and holds its inference permit until
that work actually returns. It does not claim to interrupt a running CoreML
kernel immediately. Cancellation observed at or before the final pre-mutation check preserves
the previous retranscription row and search index. Once that check is passed,
a later cancellation may arrive during synchronous publication and does not
roll back saved work.

No model, clustering, smoothing, source separation, speaker-count semantics,
telemetry schema or database schema changes belong in this repair. A genuine
optional backend failure on an uncancelled request still preserves usable ASR.

## Verification design

Deterministic test gates first signal that the backend or formatter has entered,
then cancel its owning task, then release an intentionally cancellation-ignoring
response. No sleep chooses which operation wins. Tests cover late success,
no-speech and generic errors, file/meeting paths, replacement preservation and
uncancelled controls. Adapter tests verify that error identity is retained for
uncancelled callers. Existing inference-serialization tests remain in the
focused selection.

Executed before the fix: 50 adapter tests had five failed cases/assertions;
12 orchestration regression/control tests had ten failed cases and 90 failed
assertions. All uncancelled controls passed. After the fix, the complete
`DiarizationServiceTests`, `NemotronDiarizationServiceTests` and
`TranscriptionServiceTests` selection passed all 155 cases (4.782 seconds test
time). The fresh worktree build completed in 141.96 seconds. Final changed-line
formatting was rebuilt and the same 155 cases passed again (4.740 seconds).
Independent adapter and orchestration reviews found no blockers; no formatting
diagnostics intersect changed lines.

The [validation receipt](2026-10-02-diarization-cancellation-validation.json)
records retained log hashes and tested source hashes. These are injected
concurrency and real SQLite persistence tests; no acoustic quality or native
physical-audio claim follows from them. No second full local suite was run
within the parent audit task. Final-head [CI run 37061023797](https://github.com/moona3k/macparakeet/actions/runs/37061023797)
passed 7,929 xUnit cases and 30 Swift Testing cases, plus Swift 6 and release/
bundle checks. The xUnit summary does not report skipped-case counts; the
telemetry allowlist comparison was explicitly skipped. See the
[delivery receipt](2026-10-02-app-audit/evidence/pr1206-final-ci.json).

