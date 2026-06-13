# Plan: Make the onboarding warm-up stall watchdog testable, and test it

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update this plan's row in
> `plans/active/2026-06-advisor-index.md`.
>
> **Drift check (run first)**:
> `git diff --stat f8e28be91..HEAD -- Sources/MacParakeetViewModels/OnboardingViewModel.swift Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift Tests/MacParakeetTests/STT/MockSTTClient.swift`
> If any of these changed since `f8e28be91`, compare the "Current state"
> excerpts below against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S–M
- **Risk**: LOW (production change is a parameterized constant; everything
  else is test code)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `f8e28be91`, 2026-06-12

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
  - Line ~99: the constant:
    ```swift
    /// ... Memory: v0.4.22 stranded ~23 users for ~24h with no escape hatch.
    public static let warmUpStallTimeout: Duration = .seconds(180)
    ```
    There are **no references to `warmUpStallTimeout` outside this file**
    (verified at `f8e28be91`), so keeping the static public while adding an
    instance copy is safe.
  - Line ~111: `public init(...)` — already takes injectable knobs ending
    with `permissionPollingInterval: Duration = .seconds(2)` and
    `relaunchHintDelay: TimeInterval = 10`. **Match this pattern.**
  - Lines ~406-412 (`startEngineWarmUp()`): bumps `engineGeneration`,
    creates an `observationToken`, sets
    `engineState = .working(...)`, and calls
    `resetWarmUpStallWatchdog(generation:observationToken:)` BEFORE the
    preflight begins.
  - Line ~465: each event from the warm-up progress stream re-arms the
    watchdog via the same call.
  - Lines ~772-800: `resetWarmUpStallWatchdog(generation:observationToken:)`
    — cancels the previous watchdog task and starts:
    ```swift
    warmUpStallWatchdogTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.warmUpStallTimeout)
        guard !Task.isCancelled, let self else { return }
        guard self.engineGeneration == generation,
              self.warmUpObservationToken == observationToken else { return }
        let stallSeconds = Int(Self.warmUpStallTimeout.components.seconds)
        ...
        self.engineState = .failed(
            message: "Setup is taking longer than expected. Check your network connection and tap Retry."
        )
        self.isBusy = false
        self.cancelWarmUpObservation()
    }
    ```
    Note the **two** uses of `Self.warmUpStallTimeout` (the sleep and
    `stallSeconds`).
  - Lines ~48-52: `public enum EngineState: Sendable, Equatable` with
    `case failed(message: String)`.

- `Tests/MacParakeetTests/STT/MockSTTClient.swift` — `public actor
  MockSTTClient: STTClientProtocol, ...`. Configuration is done through
  `configure...` methods because it is an actor (e.g.
  `configureWarmUp(error:progressPhases:)` at line ~61). Its private
  `warmUp(onProgress:)` (body around lines ~108-126) emits
  `warmUpProgressPhases`, optionally throws, then sets `ready = true`.
  `backgroundWarmUp()` (line ~128) sets the shared state to
  `.working(message: "Checking setup requirements...", progress: nil)` and
  runs `warmUp` in a task whose `catch is CancellationError` branch
  deliberately does not mutate state.

- `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift` —
  XCTest file. Private helper `makeViewModel(...)` at line ~88 forwards all
  init knobs with test-friendly defaults (`isRuntimeSupported: { true }`,
  `isNetworkReachable: { true }`, `preferredLanguages: { ["en-US"] }`,
  etc.). The structural exemplar for the new test is
  `testEngineWarmUpTransitionsToReady()` at line ~340:
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
- The ViewModel subscribes via `sttClient.observeWarmUpProgress()`; the
  mock's stream yields the current state once at subscription time, which
  re-arms the watchdog once. After that, a hung mock emits nothing — which
  is precisely the stall scenario.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build` | exit 0 |
| Focused tests | `swift test --filter OnboardingViewModelTests` | all pass, incl. the new test |
| Full suite | `swift test` | exit 0, 0 failures (baseline at `f8e28be91`: 3,576 tests, 0 failures) |

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
  `Cover the onboarding warm-up stall watchdog with a test`. (Repo has a
  rich commit format in docs/commit-guidelines.md for significant changes;
  optional at this size.)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make the timeout injectable

In `OnboardingViewModel.swift`:

1. Add an init parameter, placed next to `permissionPollingInterval`
   (match its style):
   ```swift
   warmUpStallTimeout: Duration = OnboardingViewModel.warmUpStallTimeout,
   ```
2. Store it: add `private let warmUpStallTimeout: Duration` near the other
   stored lets, and `self.warmUpStallTimeout = warmUpStallTimeout` in the
   init body. (Swift allows an instance property and a static property with
   the same name; the existing `public static let` stays as the default
   value and public constant.)
3. In `resetWarmUpStallWatchdog`, change **both** `Self.warmUpStallTimeout`
   references to the instance property:
   - `try? await Task.sleep(for: Self.warmUpStallTimeout)` →
     `try? await Task.sleep(for: warmUpStallTimeout)` — note this is inside
     a `Task { @MainActor [weak self] in ... }` closure, so it must read
     `self.warmUpStallTimeout` **after** the `guard let self` line, or
     capture the duration into a local `let` before creating the Task
     (capture-before-Task is simpler and avoids touching the guard order —
     prefer it).
   - `Int(Self.warmUpStallTimeout.components.seconds)` → use the same local.

**Verify**: `swift build` → exit 0, and
`grep -n "Self.warmUpStallTimeout" Sources/MacParakeetViewModels/OnboardingViewModel.swift`
→ at most the init default (`OnboardingViewModel.warmUpStallTimeout`) and
the static declaration itself remain; no uses left inside
`resetWarmUpStallWatchdog`.

### Step 2: Add a hang mode to MockSTTClient

In `Tests/MacParakeetTests/STT/MockSTTClient.swift`:

1. Add a property `public var warmUpHangIndefinitely = false` next to the
   other warm-up config vars (~line 15), and an actor-friendly setter
   following the existing pattern:
   ```swift
   public func configureWarmUpHangIndefinitely() {
       warmUpHangIndefinitely = true
   }
   ```
2. At the top of the private `warmUp(onProgress:)` body (before the
   `warmUpProgressPhases` loop), add:
   ```swift
   if warmUpHangIndefinitely {
       try await Task.sleep(for: .seconds(3600))
   }
   ```
   Cancellation makes the sleep throw `CancellationError`, which
   `backgroundWarmUp()`'s existing `catch is CancellationError` branch
   already handles without mutating state — do not add handling.

**Verify**: `swift build` → exit 0.

### Step 3: Write the stall test

In `OnboardingViewModelTests.swift`:

1. Extend the private `makeViewModel` helper with a pass-through parameter
   `warmUpStallTimeout: Duration = OnboardingViewModel.warmUpStallTimeout`,
   forwarded to the init (mirror how `permissionPollingInterval` is
   forwarded).
2. Add, modeled structurally on `testEngineWarmUpTransitionsToReady`:
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
   healthy warm-up even with a short timeout window being continually
   re-armed — simplest honest version: copy
   `testEngineWarmUpTransitionsToReady`'s body, pass
   `warmUpStallTimeout: .milliseconds(500)`, and keep its existing
   `.ready` assertion (the mock completes in well under 500ms).

**Verify**: `swift test --filter OnboardingViewModelTests` → all pass,
including 2 new tests.

### Step 4: Prove the test actually guards the watchdog

Temporarily break the watchdog (e.g. comment out the
`self.engineState = .failed(...)` line in `resetWarmUpStallWatchdog`), run
the focused test, and confirm `testEngineWarmUpStallTimeoutTransitionsToFailed`
**fails**. Revert the breakage.

**Verify**: focused test fails while broken, passes after revert;
`git diff Sources/` afterwards shows only the Step-1 changes.

### Step 5: Full suite

**Verify**: `swift test` → exit 0, 0 failures.

## Test plan

Covered by Steps 3–4: one stall-fires test (the regression this plan
exists for), one healthy-path-doesn't-fire test, plus a mutation check that
the new test fails against a broken watchdog. Pattern source:
`testEngineWarmUpTransitionsToReady` (`OnboardingViewModelTests.swift:340`).

## Done criteria

- [ ] `swift test --filter OnboardingViewModelTests` exits 0 with 2 new tests
- [ ] `grep -rn "warmUpStall" Tests/` now returns matches (the gap is closed)
- [ ] `swift test` exits 0
- [ ] Production diff is limited to the init parameter + stored property +
      two reference changes in `resetWarmUpStallWatchdog` (no behavior change
      at default value)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] Status row updated in `plans/active/2026-06-advisor-index.md`

## STOP conditions

- `resetWarmUpStallWatchdog` or `startEngineWarmUp` no longer match the
  excerpts (e.g. the watchdog was refactored into a service) — report
  instead of adapting the design.
- The stall test is flaky across 3 consecutive runs at the 200ms/2s
  margins — report the observed timing rather than inflating sleeps past
  2s. (This repo has a known-flaky precedent in
  `DictationFlowCoordinatorLoadCaptionTests`; do not add another.)
- Step 4's mutation check passes while the watchdog is broken — the test
  is not actually exercising the watchdog; report.

## Maintenance notes

- Anyone changing the warm-up observation loop must keep the
  "every stream event re-arms the watchdog" property (line ~465); the new
  negative test only partially guards it.
- The Whisper-recommendation download path
  (`startRecommendedWhisperSetup`) still has no stall test — deliberately
  deferred; it uses a different progress mechanism.
- If onboarding ever moves to Swift Testing (`@Test`), keep the mutation
  check habit from Step 4.
