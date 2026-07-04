# LocalVQE Meeting AEC Runtime Findings - 2026-07-04

> Status: local latest-main runtime audit. This note records the findings from
> testing the current LocalVQE meeting acoustic echo cancellation path on real
> retained meeting artifacts. It is not a product-quality audio evaluation.

## Scope

- Codebase: `origin/main` at `893edadfef73` (`Skip no-echo cleaned mic renders (#676)`).
- App runtime: dev app rebuilt and restarted from a clean latest-main worktree.
- AEC assets: `localvqe-v1.4-aec-200K-f32.gguf` plus `liblocalvqe.dylib`,
  prepared by `scripts/dist/prepare_meeting_echo_assets.sh`.
- Test method: copied source artifacts into `.codex/aec-localvqe-bench/...` and
  rendered `microphone-cleaned.m4a` from the copies. Original meeting artifacts
  were not modified.
- Host observed in LocalVQE logs: CPU backend on Apple M4 Pro, 4 threads.

## Asset Size And Bundling Impact

The LocalVQE AEC bundle payload is small:

| Asset | Observed size |
|---|---:|
| `liblocalvqe.dylib` | 1.6 MB |
| `localvqe-v1.4-aec-200K-f32.gguf` | 2.8 MB |

Model SHA256:

```text
b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731
```

The app-size concern is therefore not the main risk. The meaningful runtime
question is memory while rendering long meetings, because the current renderer
decodes full mic and system tracks before running the conditioner.

## Live Ambient Audio Check

A live meeting-style recording was made while Korean ambient audio was playing
from the room/computer environment. The result was correctly skipped:

```json
{
  "probeBestCorrelation": 0,
  "reasonCode": "skippedNoEchoPath"
}
```

Interpretation:

- The mic contained the ambient Korean audio.
- The captured `system.m4a` was effectively silent for AEC purposes.
- Because there was no correlated system-reference path, the echo guard chose
  not to run LocalVQE.

This is the desired failure mode. AEC should run when the far-end audio exists
in `system.m4a` and bleeds into `microphone.m4a`; it should not try to process
unrelated room audio or a missing reference.

## Retained Meeting Artifact Inventory

The local retained recordings included many older dual-source folders, but most
of the older ones did not have `meeting-recording-metadata.json`. Current
production-style rendering depends on that metadata for source alignment, so
those older folders are not equivalent runtime fixtures.

Metadata-backed dual-source candidates found:

| Duration | Artifact ID | Tested |
|---:|---|---|
| 42.7 min | `7FF9C81D-74EF-4F73-AA91-0422397EFA75` | yes |
| 25.8 min | `8FA83AD0-DDE6-449A-8274-9BBB64B29B98` | yes |
| 20.6 min | `75D86317-DC7F-4743-B772-A564944E9984` | no |
| 4.1 min | `7B83830F-F23A-4974-AC87-586462F65854` | live no-echo skip |
| 3.1 min | `1EE7D8DA-86EA-4A2A-B9D6-F25A1FA56608` | yes |

No clean metadata-backed 60-minute meeting fixture was found. The 42.7-minute
recording is the closest retained current-format sample in the requested 30-60
minute range.

## Runtime Results

All benchmarked LocalVQE renders completed successfully with
`processingFailures=0`.

| Fixture | Duration | Elapsed render | Realtime factor | Peak RSS | Probe correlation | Output |
|---|---:|---:|---:|---:|---:|---|
| Short real meeting | 183.4 s | 14.57 s | 12.59x | 111.6 MB | 0.4564 | rendered |
| Long real meeting | 1549.5 s | 124.01 s | 12.50x | 421.6 MB | 0.6599 | rendered |
| 43-min real meeting | 2563.8 s | 219.66 s | 11.67x | 663.7 MB | 0.1443 | rendered |

Details from the longest fixture:

```text
duration_s=2563.8
elapsed_s=219.66
realtime_factor=11.67
processed_frames=160237
raw_fallback_frames=1
failures=0
rms_ratio=0.469
probe_best_corr=0.1443
mem_peak_maxrss_mb=663.7
```

The one `raw_fallback_frames` value appears to be a small boundary/final-frame
case, not a broad processing failure, because all runs reported
`processingFailures=0` and produced cleaned output files.

## Memory Interpretation

The LocalVQE model itself is not the memory problem. The measured RSS increase
around conditioner creation was about 9-10 MB:

| Fixture | Before LocalVQE load | After LocalVQE load | Increase |
|---|---:|---:|---:|
| 3.1 min | 82.0 MB | 92.0 MB | 10.0 MB |
| 25.8 min | 333.8 MB | 342.8 MB | 9.0 MB |
| 42.7 min | 557.2 MB | 566.0 MB | 8.8 MB |

The duration-scaled memory is already present before LocalVQE load, which points
to decoded full-track buffers as the dominant source. On the 42.7-minute sample,
peak process RSS was about 664 MB. That is acceptable for normal 30-45 minute
meetings on the tested Apple Silicon machine, but it is not free.

If users routinely record multi-hour meetings, the current full-decode design
could push memory into the multi-GB range. That is the main long-meeting risk,
not the small bundled model.

## Timeout Headroom

Production readiness currently uses:

- floor: 60 seconds
- duration multiplier: 0.25
- cap: 600 seconds

For the measured long fixtures:

| Fixture | Production timeout budget | Observed render |
|---|---:|---:|
| 25.8 min | about 387 s | 124 s |
| 42.7 min | 600 s cap | 220 s |

The current LocalVQE runtime has enough headroom for the measured 26-minute and
43-minute real meetings. The cap means very long meetings can still fall back to
raw if rendering exceeds 10 minutes, which is the correct bounded behavior for
final-STT readiness.

## Product Impact

- Normal dictation is not in this path. The AEC work is meeting-scoped.
- The bundled LocalVQE payload is small enough that app-size impact should be
  negligible compared with larger app assets and dependencies.
- For users who only use dictation, the main concern is not bundle size or
  dictation behavior. The main product risk is meeting-stop latency/resource use
  when a meeting recording has a valid echo path and cleaned-mic rendering runs.
- The no-echo guard is important and should stay. It prevented unnecessary
  LocalVQE work on a live recording where the system reference did not match the
  mic audio.

## Remaining Gaps

This pass answered the resource question, not the full quality question.
Remaining confidence gaps:

1. A controlled real-call smoke still matters: Zoom, Meet, or Teams with
   speakers on and no headset, where `system.m4a` contains the far-end audio and
   the mic contains speaker bleed plus near-end speech.
2. A retained 60-minute current-format fixture would be useful. The local
   retained set topped out at 42.7 minutes for metadata-backed dual-source
   recordings.
3. If multi-hour meeting quality is a product target, the renderer should move
   toward chunked or streaming decode/render so peak memory is bounded by chunk
   size instead of full recording duration.
4. Long-duration AEC should stay in release smoke coverage, with separate
   reporting for resource usage, echo-path detection, and transcript-quality
   outcomes. Runtime success alone does not prove echo removal quality.

## Bottom Line

LocalVQE AEC on current main looks resource-safe for normal 30-45 minute meeting
recordings on the tested Apple Silicon machine. The app-size increase from
bundling is negligible. The runtime concern is full-track decoded memory for
very long meetings, so a streaming renderer is the main future hardening item if
multi-hour recordings become a common expectation.
