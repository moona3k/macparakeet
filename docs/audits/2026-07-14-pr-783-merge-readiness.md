# PR #783 Merge-Readiness Review — 2026-07-14

> Status: hardening is complete locally; committed-diff and hosted checks are
> pending. Review baseline is PR head
> `6e3a9a55a95c13c56f9887dd023720fc02f636ca` against `main`. This note records
> the blocking finding, the deliberately narrow fix boundary, and the evidence
> required before the PR can be called merge-ready.

## Verdict Before Hardening

The workflow split is a meaningful improvement and its architecture is sound:
dictation and Meetings & Transcriptions carry independent route selections,
while all jobs continue through ADR-016's single process-wide scheduler and
runtime. Meeting selection is pinned at start, file/media/URL work snapshots at
job entry, and recovery preserves captured provenance.

The reviewed head is not merge-ready because one cold-start transition violates
the two-slot scheduler contract. The Settings engine tiles also retain copy from
the former single-route design and can send users to the wrong selector.

## Standards Finding

### P1 — Cold cross-engine work can be rejected as `engineBusy`

`STTRuntime` counts all active transcription work globally. Cold Whisper,
Nemotron, and Parakeet Unified construction use that total to decide whether a
new engine instance is safe to create. With the new split routes, this supported
sequence can therefore fail:

1. Engine A is active in the interactive dictation slot.
2. A background file or meeting job starts on cold engine B.
3. The background job increments the total active count to two.
4. Engine B's construction guard sees two active jobs and throws `engineBusy`,
   even though the other job uses a different engine instance.

The routed Whisper warm-up also calls the guarded transcription helper despite
the helper's existing invariant that warm-up must use actor-isolated
reuse-or-construct semantics and must not be gated by active transcription work.

### P2 — Dictation tiles still describe meeting/file routing

The Speech Recognition card now controls dictation only, but its Parakeet and
Whisper tiles still say that choosing them affects meetings, files, media, and
retranscription. Those workflows are controlled by the separate Meetings &
Transcriptions picker.

## Spec Coverage

| Workflow | Route contract |
|---|---|
| Dictation | Dictation selection, interactive slot |
| Files/media/URLs | Meetings & Transcriptions selection, snapshotted per job |
| Meeting live preview | Meeting selection pinned at start; unavailable for engines without timed words |
| Meeting finalization | Fresh full-source transcription with the same pinned meeting selection |
| Meeting recovery | Captured selection when present; current transcription route for legacy artifacts |

No third route is introduced for meeting preview versus finalization. That is a
deliberate scope boundary: the current product has two user decisions, not a
three-engine routing matrix.

## Fix Boundary

The implementation must:

- retain one shared `STTScheduler` and `STTRuntime`;
- retain the interactive/background slot policy;
- keep global idleness checks for engine switches, variant changes, shutdown,
  and destructive model lifecycle work;
- make cold construction depend on activity for the target engine rather than
  unrelated work on another engine;
- preserve the process-wide `ANEInferenceGate` behavior: serialized Core ML
  inference on macOS 14, full lane concurrency on macOS 15+;
- restore Whisper warm-up's existing ungated reuse-or-construct behavior;
- avoid a new adapter layer, scheduler, or route preference.

The agreed test seam is the runtime's engine-activity policy plus the existing
scheduler/runtime routing boundary. Required regression cases are:

- active Parakeet + first cold Whisper background acquisition is allowed;
- active Parakeet + first cold Nemotron background acquisition is allowed;
- concurrent work on the same target engine does not authorize replacement of
  an in-use instance;
- global engine/variant switching still requires a fully idle runtime;
- routed Whisper warm-up remains independent of unrelated active work.

## Verification Record

Completed locally:

- the new activity-policy test was observed failing before implementation
  because `SpeechEngineActivity` did not exist, then passed after integration;
- 465 focused runtime, scheduler, settings, meeting, recovery, persistence, and
  telemetry tests passed;
- the one final full `swift test` run passed 4,769 tests with 16 expected skips
  and zero failures;
- `git diff --check` passed;
- the preferred `no-mistakes` executable was unavailable, so the documented
  focused/full-test and committed-review fallback is being used.

Still required on the committed head:

- committed-diff review against the PR base;
- exact-head hosted CI and unresolved-thread sweep.
