# Architecture, code quality, CI and performance

Baseline `f43f4bed2`; this is a risk-weighted review, not a line-by-line proof of
all 227,336 lines of Swift. Inventory is in `evidence/source-inventory.json`.

## Architectural judgment

Keep the existing Core / ViewModels / app / CLI split. It gives useful shared
behavior, injectable boundaries and a stable automation surface. Core has no
SwiftUI imports in the audited baseline. One app-owned microphone source and
speech scheduler avoids multiple feature-specific engines. Separate CLI
processes intentionally own separate runtimes. Source-separated meeting audio,
durable settlement/recovery, GRDB transactions and correction overlays are
assets worth preserving.

The highest-value architectural change is enforcing ownership across async
boundaries. The audit's concrete regressions share one cause: an older snapshot
is allowed to publish after newer user intent. Core's transactional completion
merge was correct, but CLI retranscription wrote its stale snapshot afterward.
The Library protected rename against stale loads but did not apply the same
rule to favorite/delete/audio-detach. Fixing those call boundaries is more
valuable than a general service-layer rewrite.

### ARCH-01 — Keep one authoritative completion write

Evidence: `TranscriptionService.completeTranscription` calls
`savePreservingUserMetadata` and returns the merged row; the baseline CLI
retranscribe methods then save a reconstructed older row. See `cli-data.md`
and the executable regression evidence. The repair removes the duplicate
write. Do not spread transaction ownership back into UI or CLI wrappers.

### ARCH-02 — Centralize presentation invalidation around successful mutations

Evidence: `TranscriptionLibraryViewModel.loadPage` uses generation checks,
while baseline `toggleFavorite`, `deleteTranscription`, and `deleteMeetingAudio`
do not retire an older load. Deterministic gated tests reproduce stale rows,
favorites and audio affordances, and loss of a requested pagination window.
See `gui-onboarding.md` for the repair. The invariant is current user intent
wins; merely cancelling a Task without checking publication generation is
insufficient.

### ARCH-03 — Extract workflow ownership before splitting large files

| Hotspot | Baseline lines | Useful seam |
| --- | ---: | --- |
| TranscriptResultView | 6,814 | Saved-result editing, speaker correction actions, search/reveal and chat selection each have distinct revision/selection ownership |
| SettingsView | 4,313 | Existing feature sections can own their local UI/state; preserve shared speech/provider route semantics |
| TranscriptionViewModel | 3,290 | File queue, selected-record projection and completion publication |
| STTRuntime | 2,700 | Keep model lifecycle central; extract policy/value computations, not a second runtime |
| MeetingRecordingService | 2,560 | Capture ownership, settlement and finalization already have separate collaborators; make their contracts explicit before further movement |
| TranscriptionService | 2,437 | Typed phase/outcome/provenance and canonical completion ownership |

Large size alone is not a defect. These sizes identify review and change-risk
concentrations. Start with characterization tests for the intended seam; move
one responsibility at a time, preserve public contracts, and stop if a split
adds forwarding layers without reducing state ownership. Do not rewrite the
whole app around a new coordinator framework or generic pipeline.

### ARCH-04 — Give optional stages a typed result

Diarization failure/fallback is caught so useful text survives, but that degraded
outcome does not reach the saved result/CLI/UI. A small result value carrying
requested/applied/not-applicable/failed/cancelled, actual backend/model and a
bounded reason can make the GUI, CLI, persistence and diagnostics agree.
Keep cancellation distinct, preserve speaker correction overlays, and do not
use cloud inference for core speech. This is a deliberate cross-contract
project, not a speculative enum added everywhere.

### ARCH-05 — Distinguish inference cancellation from an enforced deadline

`STTScheduler.swift:684-716` retains a running job's slot until its actual
execution returns. Queued cancellation is prompt, but running cancellation is
cooperative. The 30-second watchdog at `:830-880` records an unhealthy runtime
and keeps waiting; it does not terminate a stuck native call. Releasing that
slot early could permit unsafe concurrent access to the same model.

On macOS 14 the ANE gate surrounds a whole diarization run. A reserved scheduler
slot for dictation therefore does not by itself guarantee low dictation latency
during long diarization. These are source-confirmed safety tradeoffs, not
measured hangs in this audit. Test the contention scenario on supported hardware
before changing scheduling. A hard execution deadline may require a recoverable
process boundary, not another detached Task or a timer that forgets ownership.

## CI: actual current evidence

[Baseline run 37041613709](https://github.com/moona3k/macparakeet/actions/runs/37041613709)
passed at the exact audited SHA. It is newer evidence than the September
sequential-pipeline audit. The downloaded xUnit summary records 7,908 cases,
zero failures/errors; a separate Swift Testing summary records 30 cases.
The XML does not reliably identify skips, so these counts are not proof that
all opt-in hardware/model journeys executed.

| Measure | Observed |
| --- | ---: |
| Workflow creation → completion | 35m02s |
| Tests and Swift 6 job | 28m41s |
| Release and Bundle job | 34m46s |
| Approximate sum of the two macOS job elapsed times | 63m27s |
| Debug tests build, concurrency diagnostics | 9m48s |
| Swift Test execution | 9m31s |
| Swift 6 no-Whisper/no-Markdown compatibility build | 5m07s |
| SwiftPM Release build | 18m47s |
| Xcode Release Bundle Smoke | 13m09s |

These are one run's elapsed times, not billed minutes or a controlled speedup
measurement. Release compilation/packaging is the critical path. Deleting
unit tests will not remove that cost. The longest individual reported case
was a 30.59-second DSP measurement; 7,908 case durations total 1,668.81 seconds,
which overlaps under parallel execution and is not wall time.

The current workflow already caches compiled SwiftPM products and Xcode
DerivedData. Both SwiftPM restores missed on this run; Xcode restored about
1.53 GB. A read-only cache inventory found six entries totaling 11.68 GB
(10.88 GiB), with a behavior entry about 3.37 GiB. This is evidence to examine
cache retention/scope and restore utility, not proof of eviction or a
particular account quota. The repository's cache quota/billing was not read.

**CI-01: treat skipped compatibility as unavailable.** The telemetry allowlist
step returned zero after skipping. See the telemetry report. A green aggregate
currently does not guarantee every nominal subcheck actually executed.

**CI-02: optimize the measured critical path.** Compare three matched warm/cold
runs with job/step cache receipts and Xcode build-time summaries. Check whether
restored products really avoid compilation before adding more lanes. Retain
SwiftPM product, Xcode bundle/resource and first-party Swift 6 checks: each
covers a different boundary. The opt-in cache invalidation lane is useful and
should remain a separate correctness proof.

**CI-03: align lint claims with the actual gate.** `Swift Format Lint` is
informational (`continue-on-error`); concurrency warnings are diagnostic.
A successful CI run is not a clean-format or zero-warning guarantee. Enforce
changed-file formatting first if desired, with a deliberate baseline policy;
do not reformat hundreds of unrelated files during this audit.

## Tests: where confidence exists and where it does not

| Boundary | Evidence at baseline/audit | Remaining limitation |
| --- | --- | --- |
| Pure logic, repositories, cancellation/state machines | Thousands of deterministic tests; new stale-snapshot failures reproduced | Cannot establish microphone or UI focus behavior |
| CLI → real database → export | Hosted process smoke; current local CLI probes and persistence smoke | Speech/provider behavior substituted or absent |
| Writer → SIGKILL → fresh-process recovery | Dedicated hosted execution passes | Synthetic audio and stub recognition; not all OS terminations |
| Speaker acoustic model | Four current offline real-model runs, two pinned public recordings | Regression slice with training overlap; no held-out corpus claim |
| Real ASR → diarization → meeting/file → reopened DB/artifacts | One offline product E2E passed in 33.58s; 706.89 MiB peak process RSS; offset and silence reset asserted | Public 180s crop; no physical capture, GUI or packaged release |
| Actual SwiftUI onboarding rendering | Eight synthetic states rendered from production views | No full app startup, TCC, focus, hotkey or real download |
| Full native Library → notes → relaunch/export | Runner and documentation exist | Not executed in this audit's everyday account |
| Physical mic/system/Bluetooth/echo | Strong logic/source tests and explicit qualification plans | No physical route or acoustic qualification in this audit |
| Signed release / upgrade / Sparkle | Existing distribution fixtures and baseline bundle smoke | No new signed build, installed upgrade or release in this audit |

The testing spec was stale: it said SwiftUI tests were skipped and caches held
only source downloads. Both conflict with actual tests/workflow. The audit
updates that active spec and records evidence dates without rewriting history.

## Performance and latency

Local clean `swift build --build-tests --jobs 8` completed in **206.30 seconds
wall time** on a 48 GiB Apple Silicon Mac, macOS 26.7.1/Xcode 26.4.1. The Swift
build's reported build duration was 201.90s. This uses a different host and
newer compiler than hosted CI; do not divide the two to claim an optimization.

The live telemetry tail is more urgent than shaving an already-good median:
stop-to-posted-paste phase sum p50=225ms, p90=1,207ms, p99=6,645ms in 9,143
samples. Successful model warm-up p99=598.7s is highly mixed by engine/cache
state. See exact metric definitions and caveats in the telemetry report.
Neither aggregate establishes an allocation, lock, provider or main-thread
root cause.

Recommended fixed workloads:

1. Five- and thirty-second synthetic dictation, warm and cold, Raw/Clean and
   optional formatter separately; time release, final ASR, refinement and
   actual insertion acknowledgment independently.
2. A 30- and 60-minute two-source meeting, with system-only intervals, speaker
   overlap and a late source. Measure stop settlement, STT, diarization,
   merge, artifact persistence, peak RSS and memory after teardown.
3. Repeat capture/finalize/cancel under a video-call workload on an 8 GiB M1/M2
   host. Observe pressure/swap and retained tasks/models rather than assuming
   a specific backend leak from aggregate RSS.
4. A 1,000-item Library and a long transcript with search/replace, corrections
   and chat streaming. Use native layout/interaction timing, not repository
   query time alone.

Use optimized builds, fixed audio/model hashes, bounded cold/warm definitions,
at least repeated trials and hardware/OS records. Keep observed Debug
regression-run timing as diagnostic only. Preserve original user recordings
and preference/keychain state; use synthetic/public owned fixtures.

## Prioritized architectural recommendations

1. Finish the proven snapshot-ownership fixes and keep their red/green tests.
2. Add typed diarization outcome/provenance and evaluate after all word/segment
   projection heuristics, not just raw model DER.
3. Establish a dedicated native qualification account/machine and execute
   first-run, permissions, recovery, notes persistence and actual insertion.
4. Profile tail latency and long-meeting memory before changing runtimes or
   scheduling policy. Review existing #1202 for retained live-result cleanup
   instead of duplicating that work.
5. Extract the few transcript/Library workflows that share revision ownership;
   defer framework migrations, speculative package upgrades and broad rewrites.

Security-sensitive process/filesystem/CLI findings are in `cli-data.md`.
Gated Ask, Voice Control, sharing, voice profiles and MLX are source-reviewed
only to their relevant boundaries; this audit does not qualify their release.
