# PR #783 Merge-Readiness Review — 2026-07-14

> Status: hardening is complete locally. Hosted merge readiness is evaluated
> from the live exact-head checks and review threads on PR #783 rather than
> copied into this point-in-time audit. Review baseline is PR head
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

### Hosted P1 follow-up — meeting startup can warm a different engine

The first hardened head still started meeting warm-up from the mutable
Meetings & Transcriptions preference before `MeetingRecordingService` finished
pinning the session selection. A preference change during startup could
therefore warm one engine while the recording used another; initial preview
status had the same race.

The follow-up fix starts warm-up, readiness, and preview-status handling from
the service's single pinned selection after startup succeeds. The mutable
preference is retained only as a compatibility fallback for service
implementations that expose no active selection.

### Hosted P1 follow-up — schema v1 locks can mimic captured routing

The earlier lock-file shape always encoded `speechEngine` under schema v1,
before Meetings & Transcriptions had an independent route. Treating field
presence as captured provenance would therefore reuse a stale former-shared
selection during crash recovery.

The compatibility fix makes new lock files schema v2. The decoder still reads
v1, but only a v2 `speechEngine` is treated as a captured meeting route; v1
recovery follows the current Meetings & Transcriptions selection. This is a
schema clarification, not a new migration layer or preference.

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
- the one allowed full local `swift test` run passed 4,769 tests with 16
  expected skips and zero failures on the first hardening commit;
- hosted review then exposed the meeting-startup pinning race; its regression
  test failed against the reviewed behavior, passed after the fix, and all 21
  `MeetingRecordingFlowCoordinatorTests` passed;
- hosted re-review exposed ambiguous schema v1 engine provenance; its focused
  regression test failed against the reviewed decoder and passed after the
  v2 boundary was introduced;
- `git diff --check` passed;
- the preferred `no-mistakes` executable was unavailable, so the documented
  focused/full-test and committed-review fallback is being used.
- the committed-diff invariant review passed with no findings; the local
  Greptile CLI was unavailable, so hosted Greptile, CodeRabbit, and CI remain
  the live source of truth for the final pushed exact head, including the full
  post-follow-up test gate.
