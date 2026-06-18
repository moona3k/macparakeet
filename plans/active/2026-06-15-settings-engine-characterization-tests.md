# Plan: Characterization tests for the Settings engine/model surface (decomposition safety net)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 16e3f865f..HEAD -- Sources/MacParakeetViewModels/SettingsViewModel.swift Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `16e3f865f`, 2026-06-15

## Why this matters

`SettingsViewModel` is a 2,568-line god object and the single biggest
maintainability target in the repo. The team already designed its split (see
`plans/active/2026-04-settings-ia-overhaul.md` §3) but deferred it as "high-risk
with no test net." The engine/model surface (~40 members: engine selection,
Parakeet/Nemotron/Whisper variants, model status, downloads, switch-confirmation
state machine) is the first slice to extract — but only safely if its current
behavior is pinned first. This plan writes those characterization tests. It is a
**pure test addition** (LOW risk) and the **prerequisite** for the extraction
plan `2026-06-15-settings-engine-viewmodel-extraction.md`. After this lands, the
extraction can be verified to preserve behavior bit-for-bit.

This is NOT about coverage percentage — it is about locking the *observable
behavior* of exactly the members that will move, so the refactor can't silently
change them.

## Current state

`Sources/MacParakeetViewModels/SettingsViewModel.swift` — `@MainActor @Observable`.
Constructed with closure injection (defaults shown):

```swift
public init(
    defaults: UserDefaults = .standard,
    youtubeDownloadsDirPath: @escaping @Sendable () -> String = …,
    meetingRecordingsDirPath: @escaping @Sendable () -> String = …,
    parakeetModelVariantCached: @escaping @Sendable (ParakeetModelVariant) -> Bool = …,
    nemotronModelVariantCached: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = …,
    deleteParakeetModelOnDisk: @escaping @Sendable (ParakeetModelVariant) -> Bool = …,
    deleteNemotronModelOnDisk: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = …,
    deleteWhisperModelOnDisk: @escaping @Sendable (String) -> Bool = …,
    inputDevicesProvider: …, defaultInputDeviceUIDProvider: …, permissionPollingInterval: …
)
```

The engine/model members to characterize (declared in `SettingsViewModel.swift`):

- **Selection (settable, persist via `didSet`)**: `speechEnginePreference` (:353),
  `parakeetModelVariant` (:362), `nemotronModelVariant` (:371),
  `whisperDefaultLanguage` (:377). At init these are read from
  `SpeechEnginePreference.current(defaults:)` / `.parakeetModelVariant(defaults:)` /
  `.nemotronModelVariant(defaults:)` / `.whisperDefaultLanguage(defaults:)` (:724–727).
- **Switch-confirmation state machine**: `pendingSpeechEngineSwitchConfirmation`
  (:386), `requestSpeechEngineSwitchConfirmation(to:)` (:1281),
  `cancelPendingSpeechEngineSwitchConfirmation()` (:1289),
  `confirmPendingSpeechEngineSwitch()` (:1293). Also `speechEngineSwitching`,
  `speechEngineSwitchTarget`, `speechEngineError`.
- **Static pure helper**: `speechEngineSwitchUnavailableMessage(…)` (:1264) and
  the instance computed `speechEngineSwitchUnavailableMessage` (:1260).
- **Downloaded-variant detection (via injected `*Cached` closures)**:
  `downloadedParakeetVariants` (:569), `downloadedNemotronVariants` (:573),
  `isNemotronModelAvailable` (:403), `isWhisperModelDownloaded` (:406),
  `refreshModelStatus()` (:1315).

Existing test file (use as the construction + assertion pattern):
`Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`. Its `setUp()`:

```swift
testDefaultsSuiteName = "com.macparakeet.tests.\(UUID().uuidString)"
testDefaults = UserDefaults(suiteName: testDefaultsSuiteName)!
viewModel = SettingsViewModel(
    defaults: testDefaults,
    youtubeDownloadsDirPath: { … },
    meetingRecordingsDirPath: { … }
)
```

It uses a per-test isolated `UserDefaults` suite (cleaned in `tearDown` via
`removePersistentDomain`), a `SettingsTelemetrySpy: TelemetryServiceProtocol`, and
a `waitUntil(timeout:pollInterval:_:)` async helper (already defined in the file,
lines 50–66) for any async assertion. `@MainActor`, `@testable import MacParakeetViewModels`.

The `parakeetModelVariantCached` / `nemotronModelVariantCached` closures are
**injectable** — pass a deterministic stub to test downloaded-variant detection
without touching disk or real models.

## Commands you will need

| Purpose       | Command                                                                 | Expected   |
|---------------|-------------------------------------------------------------------------|------------|
| Focused test  | `swift test --filter SettingsEngineCharacterizationTests`               | all pass   |
| Existing test | `swift test --filter SettingsViewModelTests`                            | all pass   |
| Build         | `swift build`                                                           | exit 0     |

## Scope

**In scope** (create only):
- `Tests/MacParakeetTests/ViewModels/SettingsEngineCharacterizationTests.swift` (new)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` — no production change
  in this plan; you are only pinning current behavior.
- Real model downloads / network. Do not call paths that hit the FluidAudio
  cache or the network. Only inject deterministic `*Cached` stubs.
- The async `downloadNemotronModel()` / `downloadWhisperModel()` network bodies —
  characterizing those needs real models; out of scope (see STOP conditions).

## Git workflow

- Branch: `advisor/settings-engine-characterization-tests` off `origin/main`.
- Commit style: `Tests: characterize SettingsViewModel engine/model surface`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Create the test file with the established harness

Create `Tests/MacParakeetTests/ViewModels/SettingsEngineCharacterizationTests.swift`.
Mirror `SettingsViewModelTests.swift`'s setup: `@MainActor final class … : XCTestCase`,
`@testable import MacParakeetCore` + `@testable import MacParakeetViewModels`, a
per-test isolated `UserDefaults(suiteName:)` cleaned in `tearDown`, and a helper
to build a VM with injectable engine stubs:

```swift
private func makeViewModel(
    parakeetCached: @escaping @Sendable (ParakeetModelVariant) -> Bool = { _ in false },
    nemotronCached: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = { _, _ in false }
) -> SettingsViewModel {
    SettingsViewModel(
        defaults: testDefaults,
        parakeetModelVariantCached: parakeetCached,
        nemotronModelVariantCached: nemotronCached
    )
}
```

**Verify**: `swift build` → exit 0 (file compiles with one empty test).

### Step 2: Characterize selection defaults + persistence round-trip

Write tests that pin current behavior (observe what the code does today, assert it):

- `test_speechEnginePreference_defaultsToCurrent`: a fresh VM's
  `speechEnginePreference` equals `SpeechEnginePreference.current(defaults:)` for
  the empty suite. Same for `parakeetModelVariant`, `nemotronModelVariant`,
  `whisperDefaultLanguage` (the last defaults to `"auto"` when unset).
- `test_setSpeechEnginePreference_persists`: set
  `vm.speechEnginePreference = <a non-default value>`, then construct a *second*
  VM on the same `testDefaults` and assert it reads back the value. (This proves
  the `didSet` persistence survives the move.) Repeat for `parakeetModelVariant`
  and `nemotronModelVariant`.

**Verify**: `swift test --filter SettingsEngineCharacterizationTests` → these pass.

### Step 3: Characterize the switch-confirmation state machine

- `test_requestConfirmation_setsPending`: call
  `vm.requestSpeechEngineSwitchConfirmation(to: <other engine>)` and assert
  `vm.pendingSpeechEngineSwitchConfirmation` is set to that engine.
- `test_cancelConfirmation_clearsPending`: after requesting, call
  `cancelPendingSpeechEngineSwitchConfirmation()`; assert
  `pendingSpeechEngineSwitchConfirmation == nil`.
- `test_confirmPendingSwitch_clearsPending`: after requesting, call
  `confirmPendingSpeechEngineSwitch()`; assert the pending value is cleared.
  (Observe and pin whatever else it deterministically sets, e.g.
  `speechEngineSwitchTarget`; do not assert on async download/switch side effects.)

If `confirmPendingSpeechEngineSwitch()` triggers async work that needs a real
switcher, inject a stub via the existing seam if one exists, or assert only the
synchronous state change and note the async part is out of scope.

**Verify**: `swift test --filter SettingsEngineCharacterizationTests` → these pass.

### Step 4: Characterize the static unavailable-message builder

`speechEngineSwitchUnavailableMessage(…)` (line 1264) is a pure static function.
Read its signature and branches, then write `test_switchUnavailableMessage_*`
cases pinning the message string for each availability input (e.g. available →
nil, busy/active-work → the specific copy). Pin the *exact current strings*.

**Verify**: `swift test --filter SettingsEngineCharacterizationTests` → these pass.

### Step 5: Characterize downloaded-variant detection via injected stubs

- `test_downloadedParakeetVariants_reflectsCachedStub`: build a VM with
  `parakeetCached: { _ in true }`, call `vm.refreshModelStatus()`, await via
  `waitUntil { !vm.downloadedParakeetVariants.isEmpty }`, and assert the
  downloaded set reflects the stub. Then a `{ _ in false }` variant asserting the
  set is empty.
- Analogous test for `downloadedNemotronVariants` / `isNemotronModelAvailable`
  with `nemotronCached`.

Read `refreshModelStatus()` (line 1315) first to confirm it consults the injected
closures and is drivable without real models; if it also requires `sttClient`
readiness that isn't injectable here, assert only the disk-state portion derived
from the stubs and note the rest is out of scope.

**Verify**: `swift test --filter SettingsEngineCharacterizationTests` → these pass.

### Step 6: Full suite green

**Verify**: `swift test` → all pass (existing + new).

## Test plan

This plan *is* a test plan. New file:
`Tests/MacParakeetTests/ViewModels/SettingsEngineCharacterizationTests.swift`,
modeled structurally on `SettingsViewModelTests.swift`. Cases: selection defaults
+ persistence round-trip (Step 2), switch-confirmation state machine (Step 3),
static unavailable-message strings (Step 4), downloaded-variant detection via
injected stubs (Step 5). Aim for ~10–15 focused tests. Each asserts *current*
behavior — if a test reveals surprising current behavior, pin it as-is and note
it in a code comment; do not "fix" production code here.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `Tests/MacParakeetTests/ViewModels/SettingsEngineCharacterizationTests.swift` exists.
- [ ] `swift test --filter SettingsEngineCharacterizationTests` passes with ≥ 10 tests.
- [ ] `swift test --filter SettingsViewModelTests` still passes (untouched).
- [ ] `swift test` exits 0 (full suite).
- [ ] No file under `Sources/**` is modified (`git status --porcelain Sources` is empty).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- A behavior you intend to pin requires hitting the network or the real FluidAudio
  model cache to observe (it isn't deterministically testable here) — characterize
  only the injectable portion and report the gap; do not add real-model tests.
- `refreshModelStatus()` or `confirmPendingSpeechEngineSwitch()` cannot be driven
  to a deterministic state with the available injection seams — pin only the
  synchronous, observable subset and report which behaviors remain uncharacterized.
- The current code's behavior looks like a bug — pin the *current* behavior, add a
  `// NOTE: characterizes current behavior; possible bug — see <detail>` comment,
  and report it. Do NOT change production code in this plan.

## Maintenance notes

- These tests are the safety net for `2026-06-15-settings-engine-viewmodel-extraction.md`.
  After the extraction, they should pass **unchanged** — if the extraction forces a
  test edit beyond the VM's constructor/type name, that signals a behavior change
  the reviewer must scrutinize.
- A reviewer should confirm every assertion pins *observed current* behavior, not
  aspirational behavior, and that no test depends on real models/network.
