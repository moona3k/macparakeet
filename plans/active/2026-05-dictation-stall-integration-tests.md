# Dictation stall — integration tests against the real audio platform

> Status: **ACTIVE — Tier 1 expanded, Tier 2 deferred**
> Created: 2026-05-03
> Branch: `test/dictation-stall-integration`
> Related: `journal/2026-05-03-dictation-silent-stall.md`, ADR-015, PR #189 (shared-mic-engine), PR #210 (diagnostic package)

## Status (2026-06-12): root cause confirmed, recovery implemented

Issue #499 (field report with an opt-in diagnostic log: 87 zero-sample
captures, 380 `shared_mic_engine_configuration_changed` events across 480
starts) confirmed hypothesis 1 from the list below: **HAL configuration
change mid-session**. `AVAudioEngine` stops itself when the input chain
reconfigures and posts `AVAudioEngineConfigurationChange`; the PR #210
observer was log-only, so nothing restarted the engine and the platform's
`running` flag stayed `true` over a dead graph.

The fix (branch `fix/mic-config-change-recovery`) makes
`AVAudioEngineMicrophonePlatform` self-heal: it replays the last successful
start request when a configuration-change notification arrives for the
current engine instance and the engine has actually stopped. The
`shared_mic_engine_configuration_changed` log line now carries
`engine_is_running=` (actual `AVAudioEngine.isRunning`) alongside the
platform-flag `isRunning=`, closing the instrumentation gap called out
below. Regression tests:
`Tests/MacParakeetTests/Audio/MicrophoneEnginePlatformConfigChangeRecoveryTests.swift`.
The Tier-4 HAL-mutation test is now expected to pass *because of* recovery
on machines where the default-input mutation is observable.

## Status (2026-05-04, amended 2026-05-27)

- **Tier 1 shipped + expanded** — 9 tests in `Tests/MacParakeetTests/Audio/MicrophoneEngineRealPlatformTests.swift`. Run the normal hardware subset with `MACPARAKEET_HARDWARE_TESTS=1`.
- **Normal hardware subset** — 6 tests: cold start, post-cycle, post-VPIO, active-VPIO + late non-VPIO subscriber, deferred-VPIO promotion, and 10-cycle raw stress.
- **Additional opt-in tests**:
  - `MACPARAKEET_SLOW_HARDWARE_TESTS=1` — 3-minute idle-gap test.
  - `MACPARAKEET_STRESS_HARDWARE_TESTS=1` — 50-cycle shared-stream raw/VPIO stress.
  - `MACPARAKEET_HAL_MUTATION_TESTS=1` — default-input device switch while the shared stream is running. Skips unless at least two input devices are available and the OS reports the default-device mutation back to the test runner. This test mutates the user's selected microphone and restores the original default in cleanup.
- **Local results after the 2026-05-04 expansion**:
  - `swift test --filter MicrophoneEngineRealPlatformTests` — 9 skipped, 0 failures (hardware gate off; compile verified)
  - `MACPARAKEET_HARDWARE_TESTS=1 swift test --filter MicrophoneEngineRealPlatformTests` — 6 passed, 3 skipped, 0 failures in 7.61 s
    - `testColdStartDeliversBuffers` ✓ 0.395 s
    - `testConcurrentVPIODeliversBuffersToLateNonVPIOSubscriber` ✓ 0.779 s
    - `testDeferredVPIOPromotionDeliversBuffersAfterRawSubscriberLeaves` ✓ 1.062 s
    - `testPostCycleDeliversBuffers` ✓ 0.614 s
    - `testPostVPIODeliversBuffers` ✓ 0.972 s
    - `testStressTenCycles` ✓ 3.782 s
  - `MACPARAKEET_HARDWARE_TESTS=1 MACPARAKEET_STRESS_HARDWARE_TESTS=1 swift test --filter MicrophoneEngineRealPlatformTests` — 7 passed, 2 skipped, 0 failures in 35.21 s
    - `testStressFiftySharedStreamCycles` ✓ 27.542 s
  - `MACPARAKEET_HARDWARE_TESTS=1 MACPARAKEET_HAL_MUTATION_TESTS=1 swift test --filter MicrophoneEngineRealPlatformTests/testDefaultInputSwitchWhileSharedStreamRunningKeepsDeliveringBuffers` — skipped: default-input mutation was not observable on this machine
  - `swift test` — 2220 XCTest, 10 skipped, 0 failures in 99.57 s; 16 Swift Testing tests passed
- **Earlier idle result retained**: `MACPARAKEET_HARDWARE_TESTS=1 MACPARAKEET_SLOW_HARDWARE_TESTS=1 swift test --filter testIdleGapDeliversBuffers` passed in 180.75 s before this expansion.
- **2026-05-04 review finding addressed**: the plan listed `testConcurrentVPIODeliversBuffers`, but the test file did not cover the real `SharedMicrophoneStream` concurrent path. The suite now adds:
  - `testConcurrentVPIODeliversBuffersToLateNonVPIOSubscriber`
  - `testDeferredVPIOPromotionDeliversBuffersAfterRawSubscriberLeaves`
- **What this narrows the hypothesis to**: the bug is not triggered by any same-process scenario we can reach from a test — neither engine recreate, nor VPIO transition, nor 3-min idle. The remaining suspects are external triggers we haven't yet exercised:
  1. **HAL configuration change mid-session** (default-input device switch, sample-rate change, virtual-audio routing toggle). The user's reported-stall log shows 9+ `engine_configuration_changed` events, including one with `ch=9` (multichannel virtual-audio). The idle-gap test sits idle without inducing a config change, so it can't catch this.
  2. **Cross-process VPAU residue** (Tier 3 below).
  3. **System-level events** — sleep/wake, exclusive-access takeover by another process.
- **Tier 2 deferred** — needs a test seam that doesn't exist today.
- **Tier 3 not started** — feasible follow-up.
- **Tier 4 scaffolded**: `testDefaultInputSwitchWhileSharedStreamRunningKeepsDeliveringBuffers` programmatically toggles the default input device via `AudioObjectSetPropertyData(kAudioHardwarePropertyDefaultInputDevice)` mid-session and asserts the shared stream continues delivering buffers. It is gated by `MACPARAKEET_HAL_MUTATION_TESTS=1` because it mutates system audio state.
- **Instrumentation gap closed in this branch**: `AVAudioEngineMicrophonePlatform` now installs a log-only Core Audio listener for `kAudioHardwarePropertyDefaultInputDevice` while the shared mic engine is running and emits `audio_default_input_changed ...` to `dictation-audio.log`. This completes the decision rule that separates HAL route churn from a fresh-engine attach failure on the next field stall.
- **Tier 1 earns its keep** as permanent regression coverage for the healthy paths even though it didn't reproduce the bug. Any future change that breaks the contract on these paths fails immediately.

### 2026-05-27 release-audit note: VPIO tests are not the shipped-path gate

`MACPARAKEET_HARDWARE_TESTS=1 swift test --filter MicrophoneEngineRealPlatformTests`
failed on macOS 26.5 with CoreAudio `-10868` in the VPIO teardown path,
especially `testPostVPIODeliversBuffers` (start VPIO -> stop -> start raw).
Raw cold start and the active-VPIO + late non-VPIO subscriber path still passed.

Treat this as a retained/experimental VPIO-path signal, **not** as a release
blocker for the default shipped meeting-recording path. The app-level meeting
mic default was changed to `.raw` in `AppEnvironment` after the Zoom live-mic
degradation report; VPIO remains in the codebase only as explicit plumbing for
future experiments and regression forensics. A failed VPIO hardware test is
therefore a false positive for raw meeting/dictation release readiness unless a
release deliberately re-enables VPIO.

The initial follow-up proposal was to split VPIO teardown/promotion tests behind
a stricter opt-in. The teardown-order result below fixed their shared lifecycle
failure instead, so they remain useful in the normal hardware subset.

### 2026-07-22 teardown-order result

A Bluetooth/input-readiness audit reproduced the same VPIO → stop → raw
`-10868` failure on both the working branch and its prior committed revision.
The platform teardown was disabling VPIO before stopping the engine, although
Core Audio only permits `setVoiceProcessingEnabled` while stopped. Reordering
teardown to remove the tap → stop → disable VPIO → replace the engine fixed the
immediate transition without a delay: the focused hardware case passed five
consecutive runs, followed by the complete normal hardware subset (10 passed,
3 opt-in tests skipped). Keep the VPIO tests in the normal hardware subset as
lifecycle regression coverage; VPIO remains outside the shipped raw meeting
path.

## Context

The dictation silent stall (May 3, 2026) is a regression: dictation
worked before some recent change, doesn't always work now. PR #210
shipped passive instrumentation — watchdog, heartbeat,
configuration-change observer, HAL listener. That's "wait-and-watch."
We need an **active reproducer** so we can:

1. Trigger the bug deterministically (or at least, frequently)
2. Verify any candidate fix actually closes the gap
3. Catch future regressions before they reach users

The existing `MockMicrophonePlatform`-based unit tests (~150 of them
in `SharedMicrophoneStreamTests.swift`) cover orchestration. They
**mock away the bug** — `MockMicrophonePlatform.configureAndStart`
immediately marks the engine running and stores the tap handler.
The bug lives one layer below: in the real
`AVAudioEngineMicrophonePlatform`'s interaction with macOS HAL.

## The contract being tested

`SharedMicrophoneStream` invariant per ADR-015 and PR #189:

> **Subscribe → buffers arrive within deadline, regardless of prior
> state.**

Operationally:

- Regardless of: cold/warm process start, prior subscribe history,
  VPIO state of co-subscribers, idle duration since the last subscribe,
  prior process audio activity.
- "Within deadline" = first buffer within ~1 second on a healthy
  system. Real-world successful captures show 100–200 ms first-buffer
  latency; 1 s gives a 5× safety margin.

## Test design

### Tier 1 — invariant under varied state (real platform, real mic)

New file: `Tests/MacParakeetTests/Audio/MicrophoneEngineRealPlatformTests.swift`

Each test method:

1. Constructs a real `AVAudioEngineMicrophonePlatform` (no mocks).
2. Drives a specific scenario sequence.
3. Asserts a tap callback fires within 1 second of `configureAndStart`.

| Test method | Scenario | Gate |
|-------------|----------|------|
| `testColdStartDeliversBuffers` | Fresh process, single platform start | `MACPARAKEET_HARDWARE_TESTS=1` |
| `testPostCycleDeliversBuffers` | Platform start → stop → start immediately | `MACPARAKEET_HARDWARE_TESTS=1` |
| `testPostVPIODeliversBuffers` | Platform VPIO start → stop → raw start | `MACPARAKEET_HARDWARE_TESTS=1` |
| `testConcurrentVPIODeliversBuffersToLateNonVPIOSubscriber` | Shared stream: VPIO subscriber active, then non-VPIO subscriber joins | `MACPARAKEET_HARDWARE_TESTS=1` |
| `testDeferredVPIOPromotionDeliversBuffersAfterRawSubscriberLeaves` | Shared stream: raw subscriber blocks VPIO, then leaves and VPIO promotes | `MACPARAKEET_HARDWARE_TESTS=1` |
| `testStressTenCycles` | 10 back-to-back raw platform start/stop cycles | `MACPARAKEET_HARDWARE_TESTS=1` |
| `testIdleGapDeliversBuffers` | Platform start → stop → wait 3 min → start | `MACPARAKEET_HARDWARE_TESTS=1 MACPARAKEET_SLOW_HARDWARE_TESTS=1` |
| `testStressFiftySharedStreamCycles` | 50 shared-stream cycles alternating raw and VPIO | `MACPARAKEET_HARDWARE_TESTS=1 MACPARAKEET_STRESS_HARDWARE_TESTS=1` |
| `testDefaultInputSwitchWhileSharedStreamRunningKeepsDeliveringBuffers` | Shared stream stays alive across default-input switch away/back | `MACPARAKEET_HARDWARE_TESTS=1 MACPARAKEET_HAL_MUTATION_TESTS=1` |

Each test uses `OSAllocatedUnfairLock` to count tap callbacks
thread-safely from the audio render thread. Assert `count > 0` after
the deadline.

### Tier 2 — watchdog unit test (mock platform, fast) — **deferred**

> Status: **DEFERRED** — needs a test seam that doesn't exist today.

Original intent: use the existing `MockMicrophonePlatform` to simulate
the bug shape ("configureAndStart succeeds but no buffers ever arrive")
and verify PR #210's diagnostic watchdog actually logs
`dictation_capture_no_buffers_within_timeout`. This catches *future
regressions in the diagnostic itself* — without it, we'd only know the
watchdog is broken when a stall happens and we get no log.

Why deferred: the watchdog has no observable signal short of writing
to the user's log file. `AudioCaptureDiagnostics.append` writes via a
private static `FileHandle` to the path computed in
`AppPaths.logsDir`; there is no injection point, and the firing-decision
state (`captureDiagnosticsTimers` in `AudioRecorder`) is private and
unreachable even via `@testable import`.

Two routes available, each requiring source changes outside the
test-only scope of this plan:

1. **Extract the firing decision to a pure function.** Pull the
   "should this timer fire?" logic out of
   `AudioRecorder.scheduleFirstBufferTimeout` into a small testable
   helper (`WatchdogTimerDecision.shouldFire(armed:firstBufferSeen:current:for:)`).
   Tiny extraction, comprehensive test coverage, no behavior change.
   **Recommended.**

2. **Inject a logger sink into `AudioCaptureDiagnostics`.** Make the
   `append` destination overridable for tests. Broader API change with
   blast radius across all callers; not justified for one watchdog.

Pick (1) when we're willing to take a small source change. Until then,
the watchdog is verified by code review and field signal only.

### Tier 3 — cross-process VPAU residue (optional, if Tier 1 misses)

If Tier 1 doesn't reproduce, the bug needs cross-process state.
A scripted sequence:

1. Process A engages VPIO via `AVAudioEngineMicrophonePlatform`,
   exits cleanly.
2. Process B, within ~200 ms, subscribes non-VPIO; assert buffers
   arrive within 1 s.

Implement as two test fixtures + a shell harness that runs them in
sequence. Slow, but the only way to falsify the cross-process
hypothesis.

### Tier 4 — HAL default-input mutation (real platform, opt-in)

> Status: **SCAFFOLDED** — gated by `MACPARAKEET_HAL_MUTATION_TESTS=1`.

`testDefaultInputSwitchWhileSharedStreamRunningKeepsDeliveringBuffers`
targets the strongest field-log signature we have: Core Audio
configuration changing around the stall window. It:

1. Requires at least two input devices and an observable default-device switch.
2. Starts the real `SharedMicrophoneStream`.
3. Verifies buffers arrive.
4. Switches the system default input device to an alternate device via
   `AudioObjectSetPropertyData(kAudioHardwarePropertyDefaultInputDevice)`.
5. Verifies buffers keep arriving.
6. Restores the original default input and verifies buffers again.

This is opt-in because it mutates the user's selected microphone. The
test restores the original default in both success and error paths, but
it should still be treated as a local forensic tool rather than a
routine developer-machine check. If Core Audio accepts the mutation call
but the test runner cannot observe the default-device change, the test
skips rather than fails; that is an environment limitation, not the
silent-stall signal.

## Gating

These tests require real microphone access. They can't run in CI
without infrastructure that grants TCC microphone access to the test
runner and provides a real or emulated input device. For now:

- Gated via `XCTSkipIf` on a `MACPARAKEET_HARDWARE_TESTS=1` environment
  variable.
- `swift test` skips them by default.
- Developers run locally:
  `MACPARAKEET_HARDWARE_TESTS=1 swift test --filter MicrophoneEngineRealPlatform`
- Slow/forensic additions are separately gated:
  `MACPARAKEET_SLOW_HARDWARE_TESTS=1`,
  `MACPARAKEET_STRESS_HARDWARE_TESTS=1`, and
  `MACPARAKEET_HAL_MUTATION_TESTS=1`.
- Document the variable in `docs/cli-testing.md` and AGENTS.md once
  the pattern is proven.

## Out of scope

- **WAV-via-virtual-loopback** (BlackHole, Loopback). Useful for
  content-correctness tests; this bug is "any buffers at all," so
  unnecessary. If we need content-deterministic tests later, that's a
  separate plan.
- **CGEvent / accessibility-based keyboard simulation.**
  `FnKeyStateMachine` is directly testable; reaching the OS event
  layer adds fragility for no diagnostic gain.
- **System-level event injection** beyond default-input switching
  (sleep/wake, exclusive-access takeover by another process). Hard to
  make reliable. Keep as manual repro.
- **Codifying the new test tier in `spec/09-testing.md`.** Premature
  until the pattern proves out. Revisit once tests land.

## Success criteria

- At least one Tier 1 test reliably reproduces the stall on a
  developer machine that has hit the bug in the wild.
  - **If yes:** we have a deterministic reproducer. Pre-write the
    candidate fix (HAL probe + retry in `startEngineLocked`),
    guard with `AppFeatures.dictationStallRecovery`, ship in
    v0.5.8, flip flag and verify test goes green.
  - **If no:** bug needs cross-process state or system-level events.
    Tier 3 + manual repro carry forward.
- All non-idle Tier 1 tests pass on a healthy system within total
  wall-clock < 60 s. The idle-gap test intentionally sleeps 3 min and
  is the only slow one.
- Watchdog unit test (Tier 2) deterministically passes / fails based
  on whether `AudioRecorder` arms the watchdog correctly.

## Estimated effort

| Step | Effort |
|------|--------|
| Tier 1 scaffolding + first scenario | 1 hour |
| All Tier 1 scenarios | 2–3 hours |
| Watchdog unit test (Tier 2) | 30 min |
| Doc updates (AGENTS.md, cli-testing.md, spec/09 if proven) | 30 min |
| Tier 3 cross-process (if needed) | 1–2 hours |

**Total: half a day to a day.**

## Open questions

- Should the idle-gap test really wait 3 minutes? Could we artificially
  trigger the engine teardown that idle would cause (force the shared
  stream to release, then resubscribe immediately)? Faster test, but
  narrower coverage — the real bug may need real wall-clock idle for
  coreaudiod to enter the failure window.
- Should we also add a HAL probe in `AVAudioEngineMicrophonePlatform`
  unconditionally — call `inputNode.outputFormat(forBus: 0)` again
  after `start()` returns, log if it changed? Defensive and low-cost.
- Where does the "Hardware integration" tier fit in
  `spec/09-testing.md` long-term? Add an entry once this pattern proves
  out across at least two investigations.

## Why this is also generally valuable

This investment isn't only for this bug. The audio capture layer is:

- **Opaque** — bugs manifest as silence, not exceptions.
- **OS-dependent** — the same code can succeed or fail based on
  HAL state we don't control.
- **Regression-prone** — every refactor that touches
  `MicrophoneEnginePlatform` or `SharedMicrophoneStream` has the
  potential to silently break the contract.

Once a real-platform integration test target exists with the gating
convention established, future audio investigations get a 30-minute
on-ramp instead of a 4-hour one. That said, the real-mic constraint
makes this a developer-machine tool, not a CI safety net — the trick
is to keep the harness thin enough that maintenance is cheap.
