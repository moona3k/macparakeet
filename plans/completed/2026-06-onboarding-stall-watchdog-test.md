# Plan: Make the onboarding warm-up stall watchdog testable, and test it

> **Archive status (2026-07-16): SHIPPED in PR #518 (`89298746d`).** The
> injectable timeout and stall/healthy-path tests are present on `main`.

> **Recovery note (2026-06-12)**: this plan was originally authored on a branch
> (`chore/improve-audit-fixes`/`feat/487-stop-meeting-transcription`) at commit
> `f8e28be91`, which never merged to `main`. It has been re-validated against
> `main` HEAD `3f9361005` — the design and structure all still hold; only line
> numbers drifted (refreshed below). The watchdog still has zero test coverage
> on `main` (`grep -rn warmUpStall Tests/` → no matches, confirmed 2026-06-12).
>
> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update this plan's row in
> `plans/active/2026-06-12-advisor-index.md`.
>
> **Drift check (run first)**:
> `git diff --stat 3f9361005..HEAD -- Sources/MacParakeetViewModels/OnboardingViewModel.swift Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift Tests/MacParakeetTests/STT/MockSTTClient.swift`
> If any of these changed since `3f9361005`, compare the "Current state"
> excerpts below against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S–M
- **Risk**: LOW (production change is a parameterized constant; everything
  else is test code)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `3f9361005`, 2026-06-12 (re-validated; originally `f8e28be91`)

## Why this matters

The 180-second warm-up stall watchdog in `OnboardingViewModel` is the
**only** escape hatch for a user whose first-run model download silently
stalls. The last time this path regressed (v0.4.22), a background download
broke the Continue button and stranded ~23 brand-new users for ~24 hours —
the code even carries that memory in a comment. Today the watchdog has
**zero test coverage**: `grep -rn warmUpStall Tests/` returns nothing. A
regression in its generation guard, its state transition, or its observation
cleanup would ship silently and hit users at the most trust-sensitive moment
of the product. The blocker is that the timeout is a non-injectable
`public static let`, so a test would take 180 real seconds. This plan makes
the timeout injectable (following the exact precedent of the existing
`permissionPollingInterval` init parameter) and adds the missing test.

## Current state

- `Sources/MacParakeetViewModels/OnboardingViewModel.swift` — `@MainActor`
  `@Observable` ViewModel for first-run onboarding.
  - Line 99: the constant:
    ```swift
    public static let warmUpStallTimeout: Duration = .seconds(180)
    ```
    There are **no references to `warmUpStallTimeout` outside this file**
    (verified at `3f9361005` — only lines 99, 463, 780, 784, 785, all in this
    file), so keeping the static public while adding an instance copy is safe.
  - Line 111: `public init(...)` — already takes injectable knobs; the last
    two are `permissionPollingInterval: Duration = .seconds(2)` (line 125) and
    `relaunchHintDelay: TimeInterval = 10` (line 126), stored at lines 144–145.
    **Match this pattern.**
  - Line 396 (`startEngineWarmUp()`): bumps `engineGeneration` (line 406),
    captures `let generation` (407), sets a `warmUpObservationToken` (411),
    and calls `resetWarmUpStallWatchdog(generation:observationToken:)` (412)
    before the preflight begins.
  - Line 465: each event from the warm-up progress stream re-arms the watchdog
    via the same `resetWarmUpStallWatchdog(...)` call.
  - `resetWarmUpStallWatchdog(generation:observationToken:)` contains the
    watchdog task. The timeout is referenced **twice**:
    - Line 780: `try? await Task.sleep(for: Self.warmUpStallTimeout)`
    - Line 785: `let stallSeconds = Int(Self.warmUpStallTimeout.components.seconds)`
    The task body (a `Task { @MainActor [weak self] in ... }`) guards
    `!Task.isCancelled`, `engineGeneration == generation`, and
    `warmUpObservationToken == observationToken`, then sets
    `engineState = .failed(message: "Setup is taking longer than expected. Check your network connection and tap Retry.")`,
    `isBusy = false`, and clears the observation.
  - Lines 48–52: `public enum EngineState: Sendable, Equatable` with
    `case failed(message: String)` (line 52).

- `Tests/MacParakeetTests/STT/MockSTTClient.swift` — `public actor MockSTTClient`
  (line 4). Configuration goes through `configure...` methods because it is an
  actor (e.g. `configureWarmUp(error:progressPhases:)` at line 75;
  `warmUpProgressPhases` property at line 17). Its `public func
  warmUp(onProgress:)` (line 212) increments `warmUpCalled`/`warmUpCallCount`
  (213–214), emits `warmUpProgressPhases` (216–220), optionally throws, then
  sets `ready = true` (231). `backgroundWarmUp()` (line 234) sets
  `.working(message: "Checking setup requirements...", progress: nil)` and runs
  `warmUp` in a task whose `catch is CancellationError` branch (line 256)
  **deliberately does not mutate state** — exactly the property the stall test
  relies on.

- `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift` — XCTest
  file. Private helper `makeViewModel(...)` at line 88 forwards all init knobs
  with test-friendly defaults; it already forwards
  `permissionPollingInterval` (declared at line 102, passed at line 119). The
  structural exemplar for the new test is `testEngineWarmUpTransitionsToReady()`
  at line 340:
  ```swift
  let perms = MockPermissionService()
  let stt = MockSTTClient()
  let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
  ...
  let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
  vm.jump(to: .engine)
  vm.startEngineWarmUp()
  try await Task.sleep(for: .milliseconds(120))
  XCTAssertEqual(vm.engineState, .ready)
  ```

Important flow facts for getting the test right:

- `startEngineWarmUp()` short-circuits into a *Whisper* setup path when
  `whisperRecommendation != nil`. The helper's default
  `preferredLanguages: { ["en-US"] }` keeps the recommendation nil, so the
  default path is the Parakeet warm-up this plan targets. Don't override
  `preferredLanguages`.
- The ViewModel subscribes via `sttClient.observeWarmUpProgress()`; the mock's
  stream yields the current state once at subscription time, which re-arms the
  watchdog once. After that, a hung mock emits nothing — which is precisely the
  stall scenario.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build` | exit 0 |
| Focused tests | `swift test --filter OnboardingViewModelTests` | all pass, incl. the new test(s) |
| Full suite | `swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `Sources/MacParakeetViewModels/OnboardingViewModel.swift`
- `Tests/MacParakeetTests/STT/MockSTTClient.swift`
- `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- `STTRuntime`/`STTClient` production warm-up code — the watchdog is purely
  ViewModel-side.
- The Whisper download stall handling (`startRecommendedWhisperSetup`) — a
  different path with its own progress plumbing; testing it is a separate
  effort.
- Onboarding views in `Sources/MacParakeet/Views/Onboarding/` — no UI change.
- Changing the 180s production value or the failure message copy.

## Git workflow

- Branch from `main`: `test/onboarding-stall-watchdog`.
- Commit message style: short imperative subject, e.g.
  `Cover the onboarding warm-up stall watchdog with a test`. (Repo has a rich
  commit format in docs/commit-guidelines.md for significant changes; optional
  at this size.)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make the timeout injectable

In `OnboardingViewModel.swift`:

1. Add an init parameter, placed next to `permissionPollingInterval` (match
   its style):
   ```swift
   warmUpStallTimeout: Duration = OnboardingViewModel.warmUpStallTimeout,
   ```
2. Store it: add `private let warmUpStallTimeout: Duration` near the other
   stored lets (~lines 84–85), and `self.warmUpStallTimeout = warmUpStallTimeout`
   in the init body (~lines 144–145). (Swift allows an instance property and a
   static property with the same name; the existing `public static let` stays
   as the default value and public constant.)
3. In `resetWarmUpStallWatchdog`, change **both** `Self.warmUpStallTimeout`
   references (lines 780 and 785) to the instance value. Because they live
   inside a `Task { @MainActor [weak self] in ... }`, the simplest correct
   change is to **capture the duration into a local `let` before creating the
   Task** and use that local in both places (avoids touching the `guard let
   self` ordering):
   ```swift
   let stallTimeout = warmUpStallTimeout
   warmUpStallWatchdogTask = Task { @MainActor [weak self] in
       try? await Task.sleep(for: stallTimeout)
       ...
       let stallSeconds = Int(stallTimeout.components.seconds)
       ...
   }
   ```

**Verify**: `swift build` → exit 0, and
`grep -n "Self.warmUpStallTimeout" Sources/MacParakeetViewModels/OnboardingViewModel.swift`
→ at most the init default (`OnboardingViewModel.warmUpStallTimeout`) and the
static declaration remain; no `Self.warmUpStallTimeout` uses left inside
`resetWarmUpStallWatchdog`.

### Step 2: Add a hang mode to MockSTTClient

In `Tests/MacParakeetTests/STT/MockSTTClient.swift`:

1. Add a property `public var warmUpHangIndefinitely = false` next to the
   other warm-up config vars (near line 17), and an actor-friendly setter
   following the existing pattern:
   ```swift
   public func configureWarmUpHangIndefinitely() {
       warmUpHangIndefinitely = true
   }
   ```
2. In `public func warmUp(onProgress:)` (line 212), insert immediately before
   the `if let phases = warmUpProgressPhases` block (line 216) — i.e. after the
   `warmUpCalled`/`warmUpCallCount` increments so the call is still recorded:
   ```swift
   if warmUpHangIndefinitely {
       try await Task.sleep(for: .seconds(3600))
   }
   ```
   Cancellation makes the sleep throw `CancellationError`, which
   `backgroundWarmUp()`'s existing `catch is CancellationError` branch (line
   256) already handles without mutating state — do not add handling.

**Verify**: `swift build` → exit 0.

### Step 3: Write the stall test

In `OnboardingViewModelTests.swift`:

1. Extend the private `makeViewModel` helper (line 88) with a pass-through
   parameter `warmUpStallTimeout: Duration = OnboardingViewModel.warmUpStallTimeout`,
   forwarded to the init (mirror how `permissionPollingInterval` is forwarded
   at lines 102 and 119).
2. Add, modeled structurally on `testEngineWarmUpTransitionsToReady` (line 340):
   ```swift
   func testEngineWarmUpStallTimeoutTransitionsToFailed() async throws {
       let perms = MockPermissionService()
       let stt = MockSTTClient()
       await stt.configureWarmUpHangIndefinitely()
       let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

       let vm = makeViewModel(
           permissionService: perms,
           sttClient: stt,
           defaults: defaults,
           warmUpStallTimeout: .milliseconds(200)
       )
       vm.jump(to: .engine)
       vm.startEngineWarmUp()

       // Generous margin over the 200ms watchdog to keep CI deterministic.
       try await Task.sleep(for: .seconds(2))

       guard case .failed(let message) = vm.engineState else {
           return XCTFail("expected .failed after stall, got \(vm.engineState)")
       }
       XCTAssertTrue(message.contains("longer than expected"))
       XCTAssertFalse(vm.isBusy)
   }
   ```
3. Add a companion negative test proving the watchdog does NOT fire on a
   healthy warm-up even with a short timeout window being continually re-armed
   — simplest honest version: copy `testEngineWarmUpTransitionsToReady`'s body,
   pass `warmUpStallTimeout: .milliseconds(500)`, and keep its existing
   `.ready` assertion (the mock completes in well under 500ms).

**Verify**: `swift test --filter OnboardingViewModelTests` → all pass,
including 2 new tests.

### Step 4: Prove the test actually guards the watchdog

Temporarily break the watchdog (e.g. comment out the
`self.engineState = .failed(...)` line in `resetWarmUpStallWatchdog`), run the
focused test, and confirm `testEngineWarmUpStallTimeoutTransitionsToFailed`
**fails**. Revert the breakage.

**Verify**: focused test fails while broken, passes after revert;
`git diff Sources/` afterwards shows only the Step-1 changes.

### Step 5: Full suite

**Verify**: `swift test` → exit 0, 0 failures.

## Test plan

Covered by Steps 3–4: one stall-fires test (the regression this plan exists
for), one healthy-path-doesn't-fire test, plus a mutation check that the new
test fails against a broken watchdog. Pattern source:
`testEngineWarmUpTransitionsToReady` (`OnboardingViewModelTests.swift:340`).

## Done criteria

- [ ] `swift test --filter OnboardingViewModelTests` exits 0 with 2 new tests
- [ ] `grep -rn "warmUpStall" Tests/` now returns matches (the gap is closed)
- [ ] `swift test` exits 0
- [ ] Production diff is limited to the init parameter + stored property + the
      two reference changes in `resetWarmUpStallWatchdog` (no behavior change
      at default value)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] Status row updated in `plans/active/2026-06-12-advisor-index.md`

## STOP conditions

- `resetWarmUpStallWatchdog` or `startEngineWarmUp` no longer match the
  excerpts (e.g. the watchdog was refactored into a service) — report instead
  of adapting the design.
- The stall test is flaky across 3 consecutive runs at the 200ms/2s margins —
  report the observed timing rather than inflating sleeps past 2s. (This repo
  has a known-flaky precedent in `DictationFlowCoordinatorLoadCaptionTests`; do
  not add another.)
- Step 4's mutation check passes while the watchdog is broken — the test is not
  actually exercising the watchdog; report.

## Maintenance notes

- Anyone changing the warm-up observation loop must keep the "every stream
  event re-arms the watchdog" property (line 465); the new negative test only
  partially guards it.
- The Whisper-recommendation download path (`startRecommendedWhisperSetup`)
  still has no stall test — deliberately deferred; it uses a different progress
  mechanism.
- If onboarding ever moves to Swift Testing (`@Test`), keep the mutation-check
  habit from Step 4.
