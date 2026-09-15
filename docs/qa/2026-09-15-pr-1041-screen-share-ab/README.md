# PR #1041 review and real Zoom screen-share A/B

**PASS.** Disabling live meeting transcription removed Parakeet inference
bursts and reduced MacParakeet CPU use while preserving healthy microphone and
system-audio capture, final transcription, and the shared workload's frame
pacing. No actionable defect or merge blocker was found.

This report preserves the evidence collected for
[PR #1041](https://github.com/moona3k/macparakeet/pull/1041). The runtime test
used source head `8e6ebb957dd920bf32f40a72793f96bdb10b25e2`. The report commit changes
documentation and QA evidence only.

GitHub later merged the reviewed source to `main` as `58a7c42f` in PR #1041.

The detailed result was also published in the
[PR screen-share comment](https://github.com/moona3k/macparakeet/pull/1041#issuecomment-5677142731).

## Code and review gates

The source review traced preference persistence, immutable per-recording
speech plans, engine leases, live chunk submission, warm-up gating, final
transcription, artifact provenance, panel state, settings search, telemetry,
and the governing specifications.

| Gate | Observed result |
| --- | --- |
| Focused exact-head tests | 636 XCTest cases passed with zero failures. |
| Full exact-head suite | 6,626 XCTest cases and 29 Swift Testing tests passed. |
| Latest-main integration | 694 focused tests passed on a temporary merge of source head `8e6ebb95` with main `e9a02922`; the merge was then aborted. |
| Hosted CI | [Run 34934659543](https://github.com/moona3k/macparakeet/actions/runs/34934659543) passed Release build, CLI smoke, packaged-app smoke, concurrency checks, Swift 6 compilation, and all 6,655 tests. |
| Independent correctness review | No findings. |
| CodeRabbit | No actionable findings; final status succeeded. |
| Claude Fable 5.1 | Medium-effort final source review returned LGTM with no actionable findings. |

The hosted run tested GitHub merge `32ceacf9`, combining source head
`8e6ebb95` with then-main `8cc3c209`. The later integration run covered the
calendar and shared Settings changes that landed on main while hosted CI ran.

## A/B setup

- Release build from exact source head `8e6ebb95`, launched with isolated app
  state and model caches.
- MacBook Pro `Mac16,7`, M4 Pro with 14 cores, 48 GB RAM.
- macOS 26.6.2 (25G83), on battery power.
- Private two-participant Zoom 7.1.5 meeting.
- Native Zoom sender sharing the full 1728x1118 desktop.
- Same-machine Zoom web receiver with microphone and camera disabled.
- Animated 16x9 canvas with continuously moving tiles, gradient, and marker at
  the display's 120 Hz refresh rate.
- Repeatable 119-second synthetic speech fixture; no user audio. Recordings
  lasted 81.3 to 98.3 seconds and captured a leading portion of the fixture,
  so final-transcript validation applies only to the captured portion.
- Run order: live on, live off, live off, live on.
- Forty process samples per arm. Canvas traces covered 68.5 to 82.8 seconds
  because process enumeration extended the nominal sample interval.

Each arm started a fresh meeting recording. Measurement began after a
consistent seven-second capture warm-up. Final transcription completed before
the next arm began.

## Results

| Metric | Live on | Live off | Interpretation |
| --- | ---: | ---: | --- |
| MacParakeet CPU, median | 8.50% | 7.25% | 1.25 percentage points of median headroom when off |
| MacParakeet CPU, mean | 12.26% | 7.38% | 4.88 points of mean headroom when off |
| MacParakeet CPU, p95 | 43.2% | 9.0% | Live Parakeet inference produced the expected bursts |
| Canvas render FPS, run range | 119.65 to 119.73 | 119.56 to 119.74 | No meaningful difference |
| Canvas p95 frame time, run range | 9.2 to 9.9 ms | 9.8 ms | No live-preview penalty |
| Frames over 25 ms, two runs total | 2 | 2 | No increase |
| Zoom aggregate CPU, pooled median | 77.6% | 78.1% | No condition-correlated increase; load rose with run order |
| WindowServer CPU, pooled median | 85.65% | 87.3% | No condition-correlated increase |

Zoom's native sender statistics supplied an active-share transport check:
1728x1118, 5 FPS, 24 to 26 ms latency, 2 to 6 ms jitter, and 0.0% packet loss.
Opening Zoom's statistics window replaces the high-motion foreground content,
so these readings are a transport check rather than an A/B metric.

## Recording validation

- Both live-on artifacts recorded `previewSpeechEngine: parakeet`; both
  live-off artifacts omitted `previewSpeechEngine`.
- Each live-on arm submitted eight system-audio chunks to live STT. Live-off
  arms submitted zero live chunks.
- Every arm reported healthy capture, complete microphone and system sources,
  1.0 coverage for both sources, and zero transcription failures.
- Every arm completed its post-stop transcript using Parakeet Unified.
- macOS reported no thermal or performance warnings before or after the run.

The aggregate table and recording checks were derived from forty process
samples per arm, browser frame traces, app logs, artifact manifests, and
app-produced recording metadata. Those inputs were audited against this report
before being left out of Git.

## Temporary-file audit

The task-owned temporary files were reviewed before this report was committed.
The durable report includes the method, aggregate measurements, native Zoom
statistics, final review results, test/CI receipts, source provenance, and
limits needed to interpret the result.

The following data did not add durable review value and remains outside Git:

- the 7.1 GB Swift/Xcode build tree and exact-head worktree;
- 603 MB of copied STT and diarization model caches;
- the 123 MB Chrome profile and browser automation state;
- synthetic source and meeting audio, generated summaries, and the isolated
  SQLite database;
- raw process samples, frame traces, recording metadata, app logs, artifact
  manifests, Zoom statistics screenshots, and the separate Fable transcript;
- duplicate, blank, setup, and picker screenshots, including captures that
  contained the tester's face or desktop content;
- stale review snapshots, CI polling output, full hosted logs already retained
  by GitHub, formatter baseline warnings, empty logs, PID files, and lock files;
- the failed unauthenticated Greptile attempt.

The source diff, PR body, commit message, hosted checks, and published benchmark
comment already have canonical Git/GitHub copies. Reproduction scripts were
excluded because they contain one-run process IDs and temporary paths; the
protocol above captures the reusable method.

## Limits

- This is directional evidence from one high-end M4 Pro Mac, one Zoom version,
  one private session, and synthetic speech.
- The receiver ran on the sender Mac through Zoom's cloud path, increasing
  absolute load relative to a separate-device receiver.
- Standard desktop sharing reported 5 FPS. Optimized video sharing,
  camera-heavy calls, Teams, Meet, and larger meetings were not exercised.
- Two measured arms per condition reveal the repeatable inference burst and
  rule out a large local rendering regression. They are not a broad performance
  characterization.
- Older or lower-core Apple Silicon is the best follow-up target for testing
  whether the added CPU headroom cures user-visible choppiness.

## Assessment

At the final reviewed source revision, PR #1041 was merge-ready. The setting
provides measurable CPU headroom, especially at the tail, while preserving
capture and final transcript behavior. Live preview did not measurably degrade
local frame pacing on this machine, and the toggle did not change Zoom's
standard sender frame-rate policy.
