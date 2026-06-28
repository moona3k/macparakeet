# Plan: Regression tests for the June audio/STT hardening (mic self-heal + Nemotron live dictation)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update this plan's row in
> `plans/active/2026-06-12-advisor-index.md`.
>
> **Drift check (run first)**:
> `git diff --stat 3f9361005..HEAD -- Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift Tests/MacParakeetTests/Audio/MicrophoneEnginePlatformConfigChangeRecoveryTests.swift Sources/MacParakeetCore/Services/Dictation/DictationService.swift Tests/MacParakeetTests/Services/Dictation/DictationServiceTests.swift Tests/MacParakeetTests/STT/MockSTTClient.swift`
> If any of these changed since `3f9361005`, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as
> a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M (two independent test additions; pure test code)
- **Risk**: LOW (no production change — see Scope)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `3f9361005`, 2026-06-12

## Why this matters

Two large pieces of audio/STT code landed on `main` in June (shared-mic
self-heal #507, Nemotron live dictation #496) **after** the last codebase
audit, and each exists *specifically* to prevent a failure mode that its own
tests do not actually assert:

1. **Mic self-heal (#507)**: when macOS posts `AVAudioEngineConfigurationChange`
   (route change, AirPods, sample-rate change) the engine stops and must be
   restarted, *re-installing the tap*, or the user gets the silent-stall bug
   that stranded dictation before (the PR #210 incident class: engine reports
   "running" but delivers 0 buffers). The recovery tests verify the engine is
   *restarted* (fresh instance, replayed params, `isEngineRunning == true`) but
   **not that the tap handler is re-wired** — the exact thing whose absence is
   the silent stall.
2. **Nemotron live dictation (#496)**: partial transcripts stream in while the
   user speaks; the code defends against a stale partial overwriting a newer
   one and against a partial arriving after the session is superseded, via a
   `bufferingNewest(1)` stream + a session-ID guard. That defense has **no
   test** — a future refactor could drop the guard and no CI signal would fire.

Both gaps are in high-churn code with no other safety net. The fixes are
additive test code (zero production risk) that turn "the code looks correct"
into "CI proves it stays correct."

> **Note on scope (read before padding this plan):** the *echo-suppression*
> frame-carry/flush/reset logic (#480/#485) was considered for this plan and
> deliberately left out — it is **already well covered** by 6 dedicated tests
> in `MeetingEchoSuppressorTests.swift` (full-frame carry, held-tail join,
> batch-size invariance, reference delay, flush-drains-tail, reset-clears-carry).
> Do not add redundant carry tests. One genuinely-missing, low-value boundary
> test is described as **optional** in Step 3; skip it unless asked.

## Current state

### Area 1 — mic self-heal recovery (Step 1)

- `Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift`:
  - The class `AVAudioEngineMicrophonePlatform` has a test seam: an
    `EngineStarter` closure (typealias at line ~61) injected via a test-only
    init (line ~134). Its signature passes **four** arguments —
    `(audioEngine, vpioEnabled, bufferSize, tapHandler)` — see the call at
    line ~326: `try engineStarter(audioEngine, vpioEnabled, bufferSize, tapHandler)`.
  - `configureAndStart(vpioEnabled:bufferSize:tapHandler:)` (line ~179) stores
    a `StartRequest { vpioEnabled; bufferSize; tapHandler }` in
    `lastStartRequestLocked` (struct at line ~99).
  - `recoverFromConfigurationChangeLocked` (line ~598) replays that request:
    `configureAndStartLocked(vpioEnabled: request.vpioEnabled, bufferSize: request.bufferSize, tapHandler: request.tapHandler)` (line ~608) — so on recovery the **4th arg to the `EngineStarter` is the original tap handler**.
- `Tests/MacParakeetTests/Audio/MicrophoneEnginePlatformConfigChangeRecoveryTests.swift`:
  - Three tests, all using `engineStarter: { engine, vpio, bufferSize, _ in ... }`
    — **the 4th parameter (the tap handler) is discarded (`_`) in every test.**
  - `testConfigurationChangeWhileRunningRestartsEngine` (line ~30) is the
    structural exemplar: it locks-collects engines/vpio/bufferSize, calls
    `try platform.configureAndStart(vpioEnabled: true, bufferSize: 512, tapHandler: { _, _ in })`,
    posts `NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: firstEngine)`,
    `wait(for: [recoveryExpectation], timeout: 2.0)`, then asserts 2 starter
    calls, a fresh engine instance, replayed vpio/bufferSize, and
    `XCTAssertTrue(platform.isEngineRunning)`.
  - Key queue-ordering fact documented at the top of the file: the
    config-change observer posts work via `queue.async`; `isEngineRunning`
    reads via `queue.sync`, so reading `isEngineRunning` after posting is a
    reliable flush.

### Area 2 — Nemotron live partial routing (Step 2)

- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift`:
  - Live partials feed a stream created with `bufferingPolicy: .bufferingNewest(1)`
    (around line ~733) with a comment that this + a single consumer guarantees
    "a stale partial can never land after a newer one".
  - The applied partial is exposed as `service.liveTranscript` and updated
    behind a session-ID guard (around line ~815).
- `Tests/MacParakeetTests/STT/MockSTTClient.swift` (`public actor MockSTTClient`,
  line ~4) provides the live test surface:
  - `configureLive(result:)`, `configureLive(beginError:)`,
    `configureLive(appendError:)`, `configureLive(finishError:)` (around line ~75+).
  - `emitLivePartial(_ text:)` — pushes a partial onto the live stream.
  - Call-count actors: `liveBeginCallCount`, `liveAppendCallCount`,
    `liveFinishCallCount`, `liveCancelCallCount`, `transcribeCallCount`.
- `Tests/MacParakeetTests/Services/Dictation/DictationServiceTests.swift`:
  - The exemplar is `testStopRecordingUsesLiveNemotronResultWhenAvailable`
    (line ~290): constructs the service with
    `shouldAttemptLiveDictationTranscription: { true }`, `mockAudio`, `mockSTT`,
    `dictationRepo`; uses `await mockSTT.configureLive(result:)`,
    `try await service.startRecording()`, `await mockSTT.emitLivePartial(" live partial ")`,
    then a `waitForCondition { await service?.liveTranscript == "live partial" }`
    (note: the partial is trimmed — emitting `" live partial "` yields
    `"live partial"`), `await mockAudio.emitLiveSamples([...])`,
    `try await service.stopRecording()`.
  - `waitForCondition { ... }` is the polling helper used throughout (returns
    `Bool`); use it instead of fixed sleeps.
  - Fallback paths (begin/append/finish error, empty final, dropped samples)
    are already covered at lines ~327–412.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build` | exit 0 |
| Area-1 focused | `swift test --filter MicrophoneEnginePlatformConfigChangeRecoveryTests` | all pass, incl. new test |
| Area-2 focused | `swift test --filter DictationServiceTests` | all pass, incl. new test(s) |
| Full suite | `swift test` | exit 0, 0 failures |

## Suggested executor toolkit

- Read `Sources/MacParakeetCore/Audio/README.md` and
  `Sources/MacParakeetCore/STT/README.md` before editing — they capture the
  threading/generation-guard invariants these tests are meant to protect.

## Scope

**In scope** (the only files you should modify):
- `Tests/MacParakeetTests/Audio/MicrophoneEnginePlatformConfigChangeRecoveryTests.swift`
- `Tests/MacParakeetTests/Services/Dictation/DictationServiceTests.swift`
- `Tests/MacParakeetTests/STT/MockSTTClient.swift` — **only if** Step 2 proves
  the mock cannot express the stale-partial scenario without a tiny additive
  hook (see Step 2; if you touch it, it must be purely additive).

**Out of scope** (do NOT touch):
- All production code under `Sources/` — this plan adds tests only. If a test
  cannot be written without a production change, that is a STOP condition (the
  point is to characterize existing behavior, not change it).
- `MeetingEchoSuppressorTests.swift` carry/flush/reset tests — already covered
  (see the scope note above).

## Git workflow

- Branch from `main`: `test/june-churn-regression-tests`.
- Commit message: short imperative subject, e.g.
  `Cover mic self-heal tap re-install and Nemotron live partial ordering`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Assert the tap handler is re-wired on config-change recovery

In `MicrophoneEnginePlatformConfigChangeRecoveryTests.swift`, add a test
modeled on `testConfigurationChangeWhileRunningRestartsEngine`, but **capture
and exercise the 4th `engineStarter` parameter** (the tap handler) instead of
discarding it.

Target shape:
- Make the `engineStarter` closure capture each invocation's `tapHandler`
  into an `OSAllocatedUnfairLock(initialState: [tap-handler-type])` (the
  handler type is `@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void`).
- Pass a real `tapHandler` to `configureAndStart` that appends to a buffer
  collector lock (e.g. counts invocations), so you can prove delivery.
- After posting the config-change notification and waiting for the recovery
  expectation, take the **second** captured tap handler (the recovery one),
  invoke it once with a synthetic buffer + time, and assert the original
  collector observed the call.

Constructing a synthetic buffer is the only fiddly part. Minimal recipe:
```swift
let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
buffer.frameLength = 16
let when = AVAudioTime(sampleTime: 0, atRate: 16_000)
recoveryTapHandler(buffer, when)
```
Then assert the collector recorded that delivery.

The assertion that closes the gap: **the tap handler delivered after recovery
is the same one supplied to the original `configureAndStart`** — i.e. a real
restarted engine would re-tap into the live capture sink, not a dead one.

**Verify**: `swift test --filter MicrophoneEnginePlatformConfigChangeRecoveryTests`
→ all pass, including your new test (4 tests total).

### Step 2: Cover Nemotron live partial ordering / supersession

Goal: prove that a partial belonging to a finished/superseded live session
cannot overwrite the `liveTranscript` of the next state. First, **investigate
whether the mock can express this** before writing assertions:

1. Read `emitLivePartial` and the live-session lifecycle in `MockSTTClient.swift`
   and `DictationService.swift`. Determine whether a partial can be emitted
   *after* `stopRecording()`/cancel such that it would (incorrectly) reach
   `liveTranscript`.
2. If expressible with the existing surface, add
   `testLiveStalePartialDoesNotOverwriteAfterStop` (model it on
   `testStopRecordingUsesLiveNemotronResultWhenAvailable`):
   - start recording, emit `" first partial "`, `waitForCondition` until
     `service.liveTranscript == "first partial"`.
   - drive the session to completion (`emitLiveSamples` + `stopRecording`).
   - emit a *late* partial (e.g. `" stale ghost "`).
   - assert (via `waitForCondition` with a short bounded timeout, then a final
     check) that `service.liveTranscript` is **not** `"stale ghost"` — the
     stale partial was dropped by the session-ID guard.
3. Also add a cancel-mid-stream test if a cancel entry point exists
   (`grep -n "func cancel" Sources/MacParakeetCore/Services/Dictation/DictationService.swift`):
   start recording, emit a partial, cancel, assert no further partial mutates
   state and the live append/cancel counts are consistent.

If, and only if, the scenario genuinely cannot be expressed without a new mock
hook, add a **purely additive** helper to `MockSTTClient` (e.g.
`emitLivePartialForSession(_:sessionMatches:)` or a flag to emit after
finish) — keep it minimal, do not alter existing mock behavior, and note it
in the commit. If it would require changing `DictationService` production
code, that is a STOP condition.

**Verify**: `swift test --filter DictationServiceTests` → all pass, including
the new test(s).

### Step 3 (OPTIONAL — skip unless asked): simultaneous-echo threshold boundary

`MeetingTranscriptSourceReconciler` drops a mic run of ≥5 words when fuzzy-LCS ≥80%
of the simultaneous system tokens. The existing tests in
`Tests/MacParakeetTests/Services/MeetingRecording/MeetingTranscriptSourceReconcilerTests.swift`
cover the happy path and clear positives/negatives but not the exact 80%
rounding boundary. If asked to add it: a 5-word mic run matching 4/5 system
words (80.0%) should drop; matching 3/5 (60%) should be preserved. This is a
minor robustness test, not a bug guard.

### Step 4: Full suite

**Verify**: `swift test` → exit 0, 0 failures.

## Test plan

- **Area 1**: one new test in `MicrophoneEnginePlatformConfigChangeRecoveryTests.swift`
  asserting the recovery path re-supplies and exercises the original tap
  handler (the silent-stall regression guard). Pattern source:
  `testConfigurationChangeWhileRunningRestartsEngine`.
- **Area 2**: one (ideally two) new tests in `DictationServiceTests.swift`
  proving a stale/late partial cannot overwrite `liveTranscript`, and
  (if a cancel path exists) cancel-mid-stream leaves state consistent. Pattern
  source: `testStopRecordingUsesLiveNemotronResultWhenAvailable`.
- Optional Step 3 boundary test in `MeetingTranscriptSourceReconcilerTests.swift`.

## Done criteria

ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test --filter MicrophoneEnginePlatformConfigChangeRecoveryTests` passes with 4 tests (1 new), and the new test invokes a post-recovery tap handler and asserts delivery
- [ ] `swift test --filter DictationServiceTests` passes with the new stale-partial test (and cancel test if a cancel path exists)
- [ ] `swift test` exits 0, 0 failures
- [ ] `git diff --stat Sources/` is empty — no production code changed. (If Step 2 needs a mock hook, note that `MockSTTClient.swift` lives under `Tests/`, not `Sources/`, so adding to it is permitted and does not violate this.)
- [ ] `git status` shows only files from the In-scope list modified
- [ ] Status row updated in `plans/active/2026-06-12-advisor-index.md`

## STOP conditions

Stop and report (do not improvise) if:

- The `EngineStarter` seam no longer takes a 4th (tap-handler) argument, or
  `recoverFromConfigurationChangeLocked` no longer replays `request.tapHandler`
  — the Area-1 approach depends on both.
- Writing the Area-2 stale-partial test would require changing
  `DictationService` (or any `Sources/` file) — the purpose is to characterize
  existing behavior; a production change means the behavior isn't what this
  plan assumed.
- The new stale-partial test is flaky across 3 consecutive runs — report the
  observed timing rather than inflating waits. (This repo has a known-flaky
  precedent in `DictationFlowCoordinatorLoadCaptionTests`; do not add another —
  prefer `waitForCondition` over fixed sleeps.)
- The Area-2 investigation reveals there is **no** session-ID/buffering guard
  to test (the defense described in "Why this matters" doesn't exist) — report
  it as a real correctness gap rather than writing a vacuous test.

## Maintenance notes

- Area 1's test proves the *handler is re-supplied*; it cannot prove a real
  `AVAudioEngine` re-taps without hardware. If the seam is ever removed in
  favor of an integration test, keep an assertion that recovery routes buffers
  to the live sink.
- Area 2's guard is `bufferingNewest(1)` + a session-ID check. A reviewer
  touching the live partial routing should re-run `DictationServiceTests` and
  confirm the stale-partial test still fails when the session-ID guard is
  removed (a quick mutation check is worth doing once).
- The Whisper/Parakeet live paths share the scheduler but not the Nemotron
  streaming specifics; this plan does not cover them.
