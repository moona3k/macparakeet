# Long-Meeting Full-Pipeline Findings - 2026-07-04

> Status: measured results closing the Phase 1b benchmark gate of
> `plans/active/2026-07-04-long-meeting-aec-policy.md`. Runs executed on
> merged `main` at `2d6ed0246` (includes the #704 estimator fix and the #703
> benchmark validity gate) via the env-gated
> `LongMeetingPipelineBenchmarkTests` harness (#696), on real retained
> dual-track meetings, idle machine, sequential runs.

## Machine

MacBook Pro `Mac16,7`, Apple M4 Pro 14-core, 48 GB RAM, macOS 26.5.1
(`25F80`). Load before runs: ~83-85% idle.

## Results

25.8-minute meeting (`8FA83AD0`, 1549.5 s):

| Stage | Outcome | Elapsed (s) | RTF | Peak RSS delta (MB) |
|---|---|---:|---:|---:|
| decode+aec_render | rendered | 132.40 | 11.70x | 308.7 |
| mic_stt | - | 6.87 | 225.67x | 196.4 |
| system_stt | - | 6.75 | 229.62x | 103.4 |
| diarization | - | 7.92 | 195.69x | 404.0 |
| finalize_merge | - | 0.12 | 12880x | 0.3 |

42.7-minute meeting (`7FF9C81D`, 2563.8 s):

| Stage | Outcome | Elapsed (s) | RTF | Peak RSS delta (MB) |
|---|---|---:|---:|---:|
| decode+aec_render | rendered | 217.90 | 11.77x | 555.2 |
| mic_stt | - | 11.14 | 230.25x | 263.9 |
| system_stt | - | 10.69 | 239.74x | 160.0 |
| diarization | - | 12.14 | 211.16x | 500.9 |
| finalize_merge | - | 0.06 | 40831x | 1.0 |

Total post-stop pipeline for the 42.7-minute meeting: **251.9 s (4 m 12 s)**
from stop to fully enriched transcript (cleaned mic + dual STT + diarization
+ merge), with diarization default-on (#688).

## What The Numbers Say

1. **The post-stop cost is AEC-render-dominated.** STT and diarization run
   at 195-240x realtime; together they are ~13% of the render's cost. The
   long-meeting problem is a render-throughput problem, full stop.
2. **RSS matches the linear model.** ~230 KB/s of meeting: mid predicted
   348 MB vs 309 MB measured (-11%); long predicted 576 MB vs 555 MB (-4%).
   The duration-scaled full-track decode remains the RAM driver; a 3-hour
   meeting still projects to ~2.5 GB transient RSS (chunked rendering,
   plan Phase 3, remains the eventual fix).
3. **Production-config render speed is 11.70-11.77x** (adaptive reference
   delay ON). The earlier audit's 12.50-12.59x was measured on the
   estimator-free path and described no shipping configuration; see the
   discovery arc below.

## The Discovery Arc (what Phase 1b actually caught)

The first real run of the #696 harness exposed two compounding issues:

- **Harness validity bug (fixed in #703):** the harness discarded the
  cleaned-mic render completion, so a timed-out render silently fell back
  to raw mic while the test passed and printed a plausible-looking table.
- **Production performance bug (fixed in #704):** the adaptive
  reference-delay estimator (#605 U1/U2) ran a naive Swift cross-correlation
  (~1.39 s per call, every 0.5 s of audio) during offline rendering,
  putting the real cleaned-mic render at ~0.5x realtime — meaning shipped
  cleaned-mic AEC could never beat the readiness timeout for meetings
  longer than ~5 minutes. The prior audit missed it because its
  measurement path ran with `adaptiveReferenceDelay: false`. The #704 vDSP
  rewrite (1393.78 ms -> 4.75 ms per call, identical chosen lags) restored
  ~11.7x with adaptivity intact.

Lesson recorded: benchmark the shipping configuration end-to-end, and make
harnesses fail loudly on fallback paths. Both are now enforced by #703's
validity gate and the outcome column.

## Guard-Factor Decision

`MeetingCleanedMicrophoneReadinessPolicy.bestMeasuredRealtimeFactor` stays
at **12.59** even though production now measures 11.70-11.77x. Rationale
(recorded in the code comment): the guard's failure modes are asymmetric.
Too high a bound wastes at most one capped render (<=600 s) for meetings in
the ~8-minute duration window just past the true threshold, on the measured
machine. Too low a bound permanently denies viable cleaned-mic renders on
hardware faster than the M4 Pro baseline — a silent quality loss with no
bound on occurrences. Optimistic-with-headroom is the correct side.

Derived guard threshold under current constants: ~7,554 s (~2.1 h) of
captured media. Meetings longer than that skip the render upfront
(`predictedRenderTimeout`) and finalize on raw mic.

## Implications For The Plan

- **Threshold gate: CLOSED.** Keep the current guard (12.59 factor, ~2.1 h
  derived threshold, media-duration basis). No raw-first tier below 2.1 h
  is warranted: a 90-minute meeting renders in ~7.7 min against a 10-min
  cap with all enrichment landing ~8 min after stop.
- **Phase 2 (background enrichment lane): GO in principle, P2 in
  priority.** It is the only path to cleaned/diarized artifacts for >2.1 h
  meetings, but its urgency depends on how often real users record them.
  The `predictedRenderTimeout` diagnostics line (#695) is the frequency
  signal; revisit priority when it shows up in the field.
- **Phase 3 (chunked render): unchanged (PROPOSED).** Now motivated by RAM
  (~2.5 GB at 3 h), not speed.
- **0.6.25: the AEC hold is lifted from this work's perspective.** The
  render-speed blocker (#704) is fixed and verified on two real meetings in
  production configuration.
