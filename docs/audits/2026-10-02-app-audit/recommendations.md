# Recommended follow-through

Based on audited app `f43f4bed2`, current receiver main `6a9f8ffd`, current
hosted CI and the dated evidence in this directory. Estimates are coarse
engineering effort, not promised delivery dates. Fix/PR status is in README.

## 1. Make speaker attribution measurable and explainable

**Priority:** first product-quality investment after the small fixes.
**Effort:** multi-day. **Risk:** medium/high if output/projection rules change.

Current Auto uses Nemotron fast128; explicit constraints use Community-1, and
calendar fallback can change the actual backend. A fresh two-recording offline
regression slice favors Nemotron but still over-splits `ouvtt` (three versus two
reference speakers). These recordings overlap disclosed model training data.
`SpeakerMerger` can erase a genuine single-word speaker turn or fill a long
unknown run. Raw-model DER cannot qualify the final visible transcript.
The real fixed-ASR crop lost one correct attribution after smoothing
(487 → 486 of 491 eligible word midpoints). Its meeting roster also counted
one unknown source bucket as an additional entry. Both are narrow diagnostics;
neither justifies guessing the identity of uncertain speech.

Scope:

- Preserve raw audio, word timing, source separation, explicit constraints and
  user correction overlays. No persistent cross-recording identity inference.
- Introduce a small typed per-run outcome/provenance value in the diarization
  service boundary and propagate it through saved result, CLI and UI. Actual
  backend/model/fallback cause must not be guessed from the requested option.
- Preserve useful text on failure but show a nonblocking speaker-detection
  warning and an explicit retry path. Cancellation remains cancellation.
- Establish a licensed/consented held-out test set across clean calls, overlap,
  one-word interruptions, far microphones, music/silence, channel bleed,
  >8 speakers, CJK and late track starts. Public training-exposed cases remain
  regression fixtures, not the held-out quality set.
- Score raw intervals, word labels and final displayed/exported segments.
  Report DER components, exact-count accuracy, time-constrained speaker-aware
  word error, false named attribution, retained-turn recall, runtime and RSS.
  Freeze scorer/collar/overlap/UEM/alignment policy and hashes.

Start with `Services/Diarization`, `SpeakerMerger`, `MeetingTranscriptFinalizer`,
`SpeakerAttributionReadService`, `TranscriptionService` and
`benchmarks/diarization`. Update ADR-010 and matching CLI/telemetry/data contracts
with any persisted/public boundary change. Current #1201 already addresses
Community-1 zero-silence splitting; evaluate it rather than duplicate it.

Done criteria: a failed optional diarizer is distinguishable from disabled/no
speech in GUI and CLI; backend/fallback provenance round-trips; genuine short
turns survive the accepted projection policy; corrected identities survive
retranscription rules; frozen per-recording metrics accompany every model or
heuristic change. **Stop** a proposed default switch if it improves a mean while
materially regressing a supported cohort or making attribution less trustworthy.

## 2. Qualify the first successful real user journey

**Priority:** release confidence and activation. **Effort:** several days of
setup and repeated native runs. **Risk:** low to product if isolated correctly.

Current code has native qualification infrastructure and many layout/ViewModel
tests; this audit rendered actual onboarding views in synthetic states. That
is not the same as first launch with TCC, focus, hotkeys, downloads, clipboard
insertion or relaunch. A dedicated console account is needed because AppPaths
overrides do not isolate UserDefaults/Keychain/TCC.

Create the documented disposable `macparakeet-e2e` account/host through an
explicit owner setup step. Use intended signed candidate and preprovisioned
model hashes. Execute and retain evidence for:

1. Clean launch → permissions granted → download → practice → one actual
   insertion in an owned TextEdit document → matching saved History.
2. Denied permission and offline/partial-model failure → clear recovery →
   successful retry. Repeat CJK/Whisper and default Parakeet paths.
3. Skip/close while model work is running → correct lifetime behavior and
   honest completion copy; no forgotten task or unsupported “ready” claim.
4. Library notes → durable save → quit/relaunch → export, using the existing
   native runner, including selected item/focus and keyboard accessibility.
5. Meeting start/stop → source audio → recovered artifacts; cancel/restart
   and an actual Bluetooth route transition.

Relevant entrypoints: `docs/testing/native-library-e2e.md`,
`docs/testing/model-qualification.md`, `scripts/testing/native-library-e2e.py`,
`OnboardingViewModel` and `OnboardingCoordinator`. The Whisper download's
view-model ownership and missing stall-watchdog parity need a separate bounded
fix. Prefer native Buttons for timestamp seek/chat selection over gesture-only
controls, with VoiceOver/keyboard action checks.

Done criteria: evidence names exact signed build, OS, account, model hashes,
actual devices and pass/fail per journey. Missing prerequisites are NOT passes.
**Stop** if any runner would reset personal permissions/preferences or reuse
valuable app data; use the disposable account instead.

## 3. Close the producer/receiver observability contract

**Priority:** before shipping new event/crash producer changes. **Effort:** one
or a few days; credentials/deployment ownership may be external dependencies.

Today's app CI skipped its private receiver allowlist read. Local comparison
passes, but CI cannot protect future schema drift. New crash context on app
main depends on existing website PR #101. Public stats freshness proves a read,
not ingestion. The current onboarding dashboard fix is prepared separately and
must deploy through both Pages and the snapshot-worker owner of aggregation.

- Make a nonsecret, versioned receiver schema readable in first-party CI, or
  provision its existing read-only repository secret. Fail first-party release
  validation if compatibility cannot be checked; distinguish fork unavailability.
- Validate required fields, optional values, event names and batch rejection
  behavior with real receiver handler tests. Preserve old client compatibility.
- Finish the existing receiver crash PR, and verify staging ingestion/storage/
  retry deduplication/public redaction before shipping its app producer.
- Keep finite transport/ingestion diagnostics and sampled duration denominators.
  Avoid persistent user identifiers or transmitting speech to improve metrics.
- Deploy the onboarding step-reach fix and verify new metric discriminator,
  four current steps and old-cache fallback semantics. No production deployment
  is part of this audit's fixes.

Done criteria: one exact producer+receiver revision pair with non-skipped CI,
staging accepted/inserted/retry/redaction receipts, plus a production read after
an authorized deployment. **Stop** at credential/deployment prerequisites; do
not silently bypass the contract or inject synthetic events into production.

## 4. Measure latency and memory under the actual hard workload

**Priority:** after instrumentation boundaries are clear. **Effort:** multi-day.
**Risk:** medium for scheduling/runtime changes, low for isolated measurement.

The current stop-to-posted-paste p99 is 6.6 seconds despite a 225ms median.
Mixed model warm-up and transcription-duration percentiles cannot attribute
that tail. An 8 GiB Mac running a video call is a different workload from this
48 GiB audit machine.

Build an optimized fixed-fixture matrix: warm/cold dictation, 30/60-minute
source-separated meetings, overlap/silence, concurrent video-call load,
cancel/restart, and long-transcript editing. Capture phase timings, peak RSS,
post-teardown memory, pressure/swap, scheduler queue time and actual insertion.
Compare changes on identical model/audio/build/OS/hardware. Review existing
live-result retention PR #1202 before creating overlapping code.

Done criteria: repeated measurements identify a responsible phase/allocation;
a focused fix lowers the selected p90/p99 or retained-memory measure without
hurting capture correctness, cancellation or source alignment. **Stop** tuning
if only Debug timings or unmatched user environments support the claimed win.

## 5. Reduce CI wait and maintenance cost without losing product boundaries

**Priority:** parallel engineering efficiency work. **Effort:** one or a few days
of measurement, then a narrowly scoped change. **Risk:** medium if caches/gates
are altered.

The current 35m02s baseline is dominated by the Release/Bundle lane. Compiled
caching is already implemented; this run missed SwiftPM caches and restored
Xcode. Capture hit/miss reasons, retention scope and actual avoided compilation
for a small matched series. Preserve app resources, CLI packaging, strict
first-party compile and process recovery checks. Keep expensive signal/race
coverage that catches real defects; test count alone is not the target.

For code quality, keep atomic completion ownership and generation-aware
publication. Extract one independently testable transcript workflow at a time
from the 6,814-line result view. Do not combine this with a styling rewrite,
dependency migration or all-app coordinator framework.

Done criteria: same correctness gates plus lower measured critical-path time
or lower aggregate runner cost, with cache invalidation proof and artifact
retention. For refactoring, unchanged public outputs and real behavioral tests
must survive. **Stop** when abstraction/CI complexity exceeds the measured win.
