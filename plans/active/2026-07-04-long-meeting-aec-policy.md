# Plan: Long-meeting AEC + diarization policy (guard, benchmark, enrichment)

## Status

- **Priority**: P1 (post-#688, the full AEC + dual-STT + diarization load is
  the DEFAULT path for dual-track meetings; 2h+ meetings deterministically
  waste a 10-minute render today)
- **Effort**: Phase 1 = S-M (dispatchable now); Phase 2 = M-L (gated on
  Phase 1b data); Phase 3 = L (PROPOSED)
- **Risk**: Phase 1 LOW (policy predicate + env-gated benchmark, no audio-path
  change); Phase 2 MEDIUM (queueing + persistence + provenance); Phase 3 HIGH
  (audio pipeline rework)
- **Category**: fix / meeting pipeline policy / performance
- **Planned at**: 2026-07-04, branch `docs/long-meeting-aec-policy`
- **Progress**: Phase 1a implemented as PR #695, Phase 1b as PR #696 (both
  2026-07-04, fresh-eye reviewed). The Phase 1 sections below are updated to
  match the final implemented shape. Phase 1b's first real run then exposed
  a harness validity bug (fixed, #703) and a production render-throughput
  bug in the adaptive delay estimator (fixed, #704, ~0.5x -> 11.7x). The
  decision gate is CLOSED — measured results and decisions in
  `docs/audits/2026-07-04-long-meeting-full-pipeline-findings.md`.
- **Baseline**: `origin/main` at `cfbcccb30e23` (post PR #688
  diarization-default-on)
- **Relates**: issue #605; PRs #671, #676, #688; ADR-010, ADR-026, ADR-027;
  `docs/audits/2026-07-04-long-meeting-aec-diarization-queue-followup.md`
  (the governing brief — read it first);
  `docs/audits/2026-07-04-localvqe-aec-runtime-findings.md` (measured data);
  `plans/active/2026-06-28-meeting-aec-full-close.md` (parent feature);
  `plans/active/2026-06-27-meeting-aec-measurement-harness.md` (synthetic
  quality harness — deliberately NOT reused here; this plan measures runtime
  cost on real artifacts, not cancellation quality)

## Why this matters

Measured on real retained meetings, LocalVQE AEC renders at ~11.7-12.6x
realtime with peak RSS growing ~230 KB per second of meeting (full-track
decode). The cleaned-mic readiness wait is capped at 600 s, and on timeout the
render task is cancelled and its outputs discarded
(`MeetingCleanedMicrophoneReadiness.swift:145-153`). Consequence: any meeting
longer than ~2 hours spends up to 10 minutes of AEC compute, keeps nothing,
and transcribes raw mic anyway — deterministically, predictable from duration
before the render starts. PR #688 made diarization default-on for dual-track
meetings, so the worst-case post-stop load (AEC render + mic STT + system STT
+ diarization) is now the default, and we have zero measurements of that
combined path beyond 43 minutes.

Industry norm for long recordings is fast-transcript-first with background
enhancement (progressive enrichment with provenance). This plan gets there in
gated steps: first stop the provable waste, then measure, then build the
enrichment lane the measurements justify.

## Invariants (must not change)

- Dictation stays on the `interactive` STT slot; no meeting or file work ever
  routes to it (`Sources/MacParakeetCore/STT/STTScheduler.swift:843`).
- `MeetingTranscriptionQueue` stays single-active for finalization.
- Raw mic/system artifacts remain the source of truth; cleaned mic remains a
  derivative artifact and is never a replacement for raw.
- The renderer's per-frame guarantee (every output frame is echo-cancelled or
  raw-fallback, never worse than raw) is untouched.
- Diarization remains an offline, non-fatal enrichment path (ADR-010); this
  plan must not revert the #688 default (ADR-027 decision).
- No user data deletion outside existing retention flows.
- Expensive benchmark runs stay env-gated so `swift test` (the no-mistakes
  baseline gate) stays fast.

## Phase 1a — Upfront duration guard (dispatch now)

**One concern**: never start a cleaned-mic render that provably cannot finish
inside the readiness cap.

### Design (settled — do not re-litigate)

- Add to `MeetingCleanedMicrophoneReadinessPolicy`
  (`Sources/MacParakeetCore/Services/MeetingRecording/MeetingCleanedMicrophoneReadiness.swift:13-46`):
  - a constant `bestMeasuredRealtimeFactor: Double = 12.59` with a comment
    citing `docs/audits/2026-07-04-localvqe-aec-runtime-findings.md` (measured
    11.67-12.59x on M4 Pro; the FASTEST audited measurement is the bound so
    the guard only skips renders that would time out even at the best
    measured rate — it must never deny a render that could plausibly
    succeed).
  - `func shouldAttemptRender(for recordingDuration: TimeInterval) -> Bool`
    returning `recordingDuration / bestMeasuredRealtimeFactor
    <= timeoutSeconds(for: recordingDuration)`. With today's constants this
    gates meetings longer than ~7,554 s (~2.1 h). Do NOT hardcode the
    threshold; derive it so future cap/multiplier changes flow through.
- New routing reason case (e.g. `.predictedRenderTimeout`) on
  `MeetingCleanedMicrophoneRoutingReason`, surfaced exactly like existing
  fallback reasons in the `meeting_cleaned_mic` diagnostics/log line
  (outcome=skipped). Log-only: no new `TelemetryEventName` (avoids the
  two-repo allowlist change).
- Apply the guard at both render scheduling sites:
  - `MeetingRecordingService.scheduleCleanedMicrophoneRender`
    (`MeetingRecordingService.swift:659`, `:1281`) — when the guard fires,
    do not start the render task; return a readiness prewired with the
    not-scheduled reason (the existing `notScheduledReason` path at
    `MeetingCleanedMicrophoneReadiness.swift:122` already models this).
  - the equivalent path in `MeetingRecordingRecoveryService`.
- Recording duration source: CAPTURED MEDIA duration (what the render
  actually processes), never wall-clock meeting duration — a paused/idle
  meeting can have hours of wall-clock over minutes of audio, and wall-clock
  would wrongly skip viable renders. Both stop and recovery paths compute the
  media duration before scheduling the render. If the duration is unknown at
  schedule time, attempt the render (guard only fires on a known-long
  duration; unknown must not regress current behavior).

### Acceptance criteria

- Policy unit tests: boundary at the derived threshold (just under attempts,
  just over skips), floor/cap interplay, unknown/zero duration attempts.
- Service-level test: a stop with duration above threshold produces raw-mic
  finalization with the new routing reason and never constructs a render task
  (assert via the existing test seams for readiness/renderer injection —
  `MeetingRecordingServiceTests` already covers cleaned-mic scheduling).
- Recovery-path test mirroring the same.
- No change to behavior for durations under threshold (existing cleaned-mic
  tests stay green untouched).
- Focused test run only (`swift test --filter MeetingRecording`); full suite
  is the final no-mistakes gate, not per-iteration.

## Phase 1b — Full-pipeline long-meeting benchmark (dispatch now, runs need Daniel)

**One concern**: measure the real post-stop cost of the DEFAULT dual-track
path (AEC render + mic STT + system STT + diarization + merge) on a >=60-minute
real meeting, per stage.

### Design (settled)

- Follow the methodology of
  `docs/audits/2026-07-04-localvqe-aec-runtime-findings.md` (real retained
  artifacts, wall-clock + peak RSS per stage), not the synthetic quality
  harness.
- Deliverable: an env-gated entry point (env-gated XCTest in the pattern of
  existing `MACPARAKEET_*`-gated simulation tests, or a `scripts/dev/` runner —
  executor's choice, but it must NOT run in a default `swift test`) that takes
  a meeting session folder and emits a per-stage markdown table row: decode,
  AEC render, mic STT, system STT, diarization, finalizer merge — each with
  elapsed seconds, realtime factor, and peak RSS delta.
- Stages must run in the same order and through the same code paths as real
  finalization — `transcribeMeetingSources`, `diarizeMeetingSystemIfNeeded`,
  `MeetingTranscriptFinalizer.finalize` — not reimplementations. Those
  helpers are private to `TranscriptionService`, so the implemented mechanism
  is a package-internal benchmark observer seam
  (`MeetingFinalizationBenchmarkObserver`) attached via an internal
  initializer overload; the observer is nil in production and the hooks are
  wrap-only.
- Output lands as an addendum table in a new
  `docs/audits/2026-07-XX-long-meeting-full-pipeline-findings.md`.
- Runs on real 60-120 min retained meetings are executed by Daniel on the M4
  Pro (and ideally one older/16 GB machine); the dispatched work delivers the
  runnable harness + instructions. No retained-meeting fixture ships in-repo:
  the smoke run proves plumbing on an OPERATOR-SUPPLIED retained session
  (env var pointing at a local session folder); on a machine with none, a
  short synthesized dual-track fixture is acceptable for plumbing proof.

### Acceptance criteria

- Harness runs end-to-end on an existing retained short meeting and prints the
  per-stage table.
- Absent the env gate, `swift test` neither runs nor loads it.
- README-level usage note in the audit doc or script header (exact command,
  env vars, where output goes).

### Decision gate after 1b — CLOSED 2026-07-04

Measured on merged main (`2d6ed0246`), production configuration (adaptive
delay ON, diarization default-on), two real meetings — full tables in
`docs/audits/2026-07-04-long-meeting-full-pipeline-findings.md`. Decisions:

- **Guard unchanged**: factor stays 12.59 (optimistic-with-headroom;
  production measures 11.70-11.77x on M4 Pro — the asymmetry rationale is
  in the policy's code comment). Derived threshold ~2.1 h of captured
  media. No raw-first tier below 2.1 h: a 90-minute meeting fully enriches
  ~8 minutes after stop.
- **No free-memory secondary guard**: RSS tracked the ~230 KB/s model
  within +/-16%; no cliff observed. Revisit only with Phase 3.
- **Phase 2: GO in principle, P2 priority.** It is the only route to
  cleaned/diarized artifacts for >2.1 h meetings, but urgency depends on
  real-world frequency — watch the `predictedRenderTimeout` diagnostics
  line (#695) for the signal before scheduling implementation.
- Post-stop cost is AEC-render-dominated (STT + diarization run at
  195-240x realtime, ~13% of the render's cost) — Phase 2's design can
  treat enrichment as effectively AEC-only re-work.

## Phase 2 — Background enrichment lane (GO in principle, P2; not yet scheduled)

Shape (design intent, to be detailed after the gate):

- Separate serial, cancellable enrichment queue, distinct from
  `MeetingTranscriptionQueue`. Never more than one heavy enrichment at a time;
  enrichment yields to live meeting capture and dictation.
- Long meetings finalize raw-first within the existing bounded wait; AEC
  render and/or diarization re-run later as enrichment.
- Meeting record updates on enrichment completion with provenance (raw first,
  cleaned later, diarized later) building on the #676 provenance fields.
- Minimal user-facing status: "transcript ready, audio cleanup still
  enriching" — required before broad shipping, not before prototyping.
- Open design decisions to settle at the gate: does enrichment re-run mic STT
  on the cleaned track (transcript churn vs quality), retry policy, whether
  enrichment survives app relaunch (persistence), and interaction with
  retention/delete flows.

## Phase 3 — Chunked/streaming AEC render (PROPOSED, not committed)

The real RAM fix: decode/render in bounded chunks so peak RSS scales with
chunk size, not meeting duration; enables checkpointing partial renders
instead of discarding on cancel. Requires care at chunk boundaries (suppressor
state continuity — the streaming suppressor already models frame carry).
Revisit after Phase 2 or if 1b shows RAM is the binding constraint sooner.

## Dispatch briefs (codex exec, per fable-week pipeline)

Both Phase 1 items are independent; dispatch as two separate `codex exec`
runs on separate branches off `origin/main`.

### Brief 1a (implementation)

> Task: implement the upfront cleaned-mic render duration guard exactly as
> specified in `plans/active/2026-07-04-long-meeting-aec-policy.md` Phase 1a.
> Read `docs/audits/2026-07-04-long-meeting-aec-diarization-queue-followup.md`
> for context. Settled decisions: guard lives on
> `MeetingCleanedMicrophoneReadinessPolicy`; fastest-measured factor 12.59 derived-not-
> hardcoded threshold; new routing reason, log-only telemetry; guard applied in
> `MeetingRecordingService.scheduleCleanedMicrophoneRender` AND the recovery
> service; unknown duration attempts render. Fences: do not touch the
> renderer, suppressor, STT scheduler, or diarization default; no new
> TelemetryEventName. Done = acceptance criteria in the plan, focused
> `swift test --filter MeetingRecording` green. Report: files changed with
> line refs, test names added, the derived threshold value, any deviation
> from the plan. Cite `commit-messages` and `pr-descriptions` skills for
> artifacts. Open a PR early; author gate per repo workflow.

### Brief 1b (benchmark harness)

> Task: build the env-gated full-pipeline long-meeting benchmark specified in
> `plans/active/2026-07-04-long-meeting-aec-policy.md` Phase 1b. Follow the
> methodology of `docs/audits/2026-07-04-localvqe-aec-runtime-findings.md`.
> Fences: must go through the real finalization code paths; must not run in
> default `swift test`; no production code changes beyond minimal test seams
> if strictly required (call them out). Done = smoke run on an existing short
> retained meeting prints the per-stage table; usage instructions written.
> Report: how to run it, smoke-run output table, any seams added.

## Rollout / verification

- Phase 1a ships in 0.6.x behind no flag (it only skips provably-doomed work;
  behavior for <2 h meetings is unchanged).
- Watch `meeting_cleaned_mic` log lines for `predictedRenderTimeout`
  occurrences in diagnostics to learn how often real users hit 2 h+ meetings.
- Phase 2 gets its own plan revision + ADR touch (ADR-026 provenance section)
  when green-lit.
