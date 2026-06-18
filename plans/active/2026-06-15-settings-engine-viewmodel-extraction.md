# Plan: Extract EngineSettingsViewModel from SettingsViewModel (extract-and-delegate)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 16e3f865f..HEAD -- Sources/MacParakeetViewModels/SettingsViewModel.swift Sources/MacParakeet/Views/Settings/SettingsView.swift`
> If either changed materially since this plan was written, re-read the engine
> members before proceeding; on a mismatch with the "Current state" inventory,
> treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/active/2026-06-15-settings-engine-characterization-tests.md` (HARD — do not start until those tests exist and pass)
- **Category**: tech-debt
- **Planned at**: commit `16e3f865f`, 2026-06-15

## Why this matters

`SettingsViewModel` is 2,568 lines and growing (it was 1,265 when its split was
first planned). Its own intended decomposition is documented but stalled:
`Sources/MacParakeetViewModels/SettingsRootViewModel.swift:24-28` says "Sub-VMs
(`Capture`, `Engine`, `AI`, `System`) will be wired in subsequent commits" — they
never were, and `SettingsView.swift:455` carries the same unfulfilled "Sub-VM
split (`EngineSettingsViewModel`) lands in a later commit." This plan executes the
**Engine slice** — the first and best-bounded one (engine selection, model
variants, model status, downloads, switch-confirmation). It uses an
**extract-and-delegate** strategy: move the engine state/logic into a new
`EngineSettingsViewModel`, and have `SettingsViewModel` hold it and forward the
same public properties, so existing views and tests keep compiling unchanged.
Re-pointing views directly at the sub-VM is an explicit follow-up. This realizes
the `EngineSettingsViewModel` row in `plans/active/2026-04-settings-ia-overhaul.md`
§3 (~250 lines) and supersedes that plan's open "god-file decomposition" remainder
for the Engine portion.

## Current state

`Sources/MacParakeetViewModels/SettingsViewModel.swift` — `@MainActor @Observable`,
constructed with closure injection (see the characterization-test plan for the
full init). The **engine/model slice** to move (verified at commit `16e3f865f`):

Stored properties (public, several with persistence `didSet`):
`speechEnginePreference` (:353), `parakeetModelVariant` (:362),
`nemotronModelVariant` (:371), `whisperDefaultLanguage` (:377),
`speechEngineSwitching` (:383), `speechEngineSwitchTarget` (:384),
`speechEngineSwitchDetail` (:385), `pendingSpeechEngineSwitchConfirmation` (:386),
`isParakeetVariantSwitch` (:391), `isNemotronVariantSwitch` (:394),
`speechEngineSwitchAvailability` (:395), `speechEngineError` (:396),
`whisperModelStatus` (:397), `whisperModelStatusDetail` (:398),
`whisperDownloading` (:399), `nemotronModelStatus` (:400),
`nemotronModelStatusDetail` (:401), `nemotronDownloading` (:402),
`parakeetStatus` (:563), `parakeetStatusDetail` (:564), `parakeetRepairing` (:565),
`downloadedParakeetVariants` (:569), `downloadedNemotronVariants` (:573).

Computed: `isNemotronModelAvailable` (:403), `isWhisperModelDownloaded` (:406),
`whisperHasBeenOptimized` (:414), `speechEngineSwitchUnavailableMessage` (:1260),
`whisperVariantFriendlyName` (:1471).

Private collaborators/state (move with the slice):
`speechEngineSwitcher` (:593), `speechEngineSwitchAvailabilityProvider` (:594),
`parakeetModelVariantCached` (:600), `nemotronModelVariantCached` (:601),
`deleteParakeetModelOnDisk` (:602), `deleteNemotronModelOnDisk` (:603),
`deleteWhisperModelOnDisk` (:604), `isApplyingSpeechEngineState` (:609),
`isApplyingParakeetVariantState` (:610), `isApplyingNemotronVariantState` (:611),
`modelStatusRefreshGeneration` (:612).

Functions (move): `refreshSpeechEngineSwitchAvailability` (:1243),
`refreshSpeechEngineSwitchAvailabilityNow` (:1250),
`speechEngineSwitchUnavailableMessage(…)` static (:1264),
`requestSpeechEngineSwitchConfirmation` (:1281),
`cancelPendingSpeechEngineSwitchConfirmation` (:1289),
`confirmPendingSpeechEngineSwitch` (:1293), `refreshModelStatus` (:1315),
`refreshWhisperModelStatus` (:1426), `refreshNemotronModelStatus` (:1432),
`applyNemotronDownloadedStatus` (:1442), `applyWhisperDownloadedStatus` (:1453),
`downloadNemotronModel` (:1477), `downloadWhisperModel` (:1576),
`applySpeechEngineChange` (:1680) — plus any Parakeet variant-apply / download /
repair functions in the same cluster (search for `parakeet`/`variant` near these).

**These names are used by views.** `SettingsView.swift` (and possibly
`Settings/Components/`) bind to `vm.speechEnginePreference`, `vm.parakeetModelVariant`,
`vm.refreshModelStatus()`, etc. The extract-and-delegate approach keeps every one
of those call sites valid by forwarding.

Conventions to honor (from `plans/active/2026-04-settings-ia-overhaul.md` §3 and
`CLAUDE.md`): `@MainActor @Observable` on the new VM; it lives in
`Sources/MacParakeetViewModels/` and imports **only** `MacParakeetCore` (no
SwiftUI/AppKit beyond what `SettingsViewModel` already imports); no fire-and-forget
`Task { }` without an awaitable caller — preserve the existing async patterns
exactly as they are when moving them. The existing `LLMSettingsViewModel` +
`LLMSettingsDraft` (`Sources/MacParakeetViewModels/`) are the in-repo exemplar of a
focused, tested sub-VM — model the new VM's shape and its test on them.

## Commands you will need

| Purpose                | Command                                                              | Expected   |
|------------------------|---------------------------------------------------------------------|------------|
| Engine char. tests     | `swift test --filter SettingsEngineCharacterizationTests`           | all pass   |
| Existing settings test | `swift test --filter SettingsViewModelTests`                        | all pass   |
| New VM test            | `swift test --filter EngineSettingsViewModelTests`                  | all pass   |
| Build                  | `swift build`                                                       | exit 0     |
| Full tests             | `swift test`                                                        | all pass   |
| Find view call sites   | `grep -rn "speechEnginePreference\|parakeetModelVariant\|nemotronModelVariant\|refreshModelStatus\|downloadNemotronModel\|downloadWhisperModel" Sources/MacParakeet/Views` | the call sites that must keep compiling |

## Scope

**In scope** (modify/create):
- `Sources/MacParakeetViewModels/EngineSettingsViewModel.swift` (create)
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` (remove the engine slice; add forwarding)
- `Tests/MacParakeetTests/ViewModels/EngineSettingsViewModelTests.swift` (create)
- `plans/README.md` (status row); update the status note in
  `plans/active/2026-04-settings-ia-overhaul.md` (mark the Engine sub-VM row done)
- `Sources/MacParakeetViewModels/SettingsRootViewModel.swift` — only if you choose
  to expose the new VM there (optional; see Step 5)

**Out of scope** (do NOT touch in this plan):
- The other slices (Capture/Dictation/Transcription/Meeting/System) — Engine only.
- Re-pointing `SettingsView.swift` bindings from `vm.<engine member>` to a sub-VM —
  deferred follow-up; forwarding keeps them working.
- Any non-engine member of `SettingsViewModel`.
- Notification names / persistence keys — unchanged.

## Git workflow

- Branch: `advisor/settings-engine-viewmodel-extraction` off `origin/main`.
- Per the IA plan's note, avoid landing other PRs touching `Views/Settings/` or
  `SettingsViewModel.swift` concurrently to minimize rebase tax.
- Commit style: rich message (`docs/commit-guidelines.md`) — this is a significant
  change. Example subject: `Refactor: extract EngineSettingsViewModel (extract-and-delegate)`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 0: Confirm the safety net is green

**Verify**:
- `swift test --filter SettingsEngineCharacterizationTests` → all pass.
- `swift test --filter SettingsViewModelTests` → all pass.

If the characterization tests do not exist yet, **STOP** — the dependency plan
must land first.

### Step 1: Create EngineSettingsViewModel owning the engine state

Create `Sources/MacParakeetViewModels/EngineSettingsViewModel.swift`:
`@MainActor @Observable public final class EngineSettingsViewModel`. Its `init`
takes exactly the injected dependencies the moved logic needs:
`defaults: UserDefaults`, `parakeetModelVariantCached`, `nemotronModelVariantCached`,
`deleteParakeetModelOnDisk`, `deleteNemotronModelOnDisk`, `deleteWhisperModelOnDisk`,
plus the `speechEngineSwitcher` / `speechEngineSwitchAvailabilityProvider` seams.
Move the stored properties, computed properties, private state, and functions
listed in "Current state" **verbatim** (including their `didSet` bodies and the
`isApplying*` reentrancy guards — these are load-bearing; do not simplify them).

Keep the init reads from `SpeechEnginePreference.current(defaults:)` etc. that
currently run in `SettingsViewModel.init` (:724–727) — they move here.

**Verify**: `swift build` → the new file compiles in isolation (you may have
temporary duplicate-symbol or unused warnings until Step 2; it must at least parse —
if SettingsViewModel still also declares them, comment nothing out yet, just get
the new file to compile as a standalone type, then proceed to Step 2 in the same
edit pass).

### Step 2: Replace the engine slice in SettingsViewModel with a held sub-VM + forwarding

In `SettingsViewModel`:
1. Add `public let engine: EngineSettingsViewModel`, constructed in `init` with the
   same injected closures `SettingsViewModel` already receives
   (`parakeetModelVariantCached`, `nemotronModelVariantCached`, `delete*OnDisk`,
   `defaults`, and the switcher/availability seams).
2. Delete the moved stored/computed properties and functions from `SettingsViewModel`.
3. For **every** removed public member that views/tests reference, add a forwarding
   shim so the public surface is unchanged. Example:
   ```swift
   public var speechEnginePreference: SpeechEnginePreference {
       get { engine.speechEnginePreference }
       set { engine.speechEnginePreference = newValue }
   }
   public func refreshModelStatus() { engine.refreshModelStatus() }
   ```
   Forwarding computed properties on an `@Observable` type correctly participate in
   observation because they read the sub-VM's `@Observable` storage — bindings in
   views stay reactive.

Keep forwarding for the full public engine surface enumerated in "Current state".
Do not forward the `private` members (they moved entirely).

**Verify**: `swift build` → exit 0 (all view call sites still compile via the shims;
run the "Find view call sites" grep and confirm each referenced member has a shim).

### Step 3: Existing tests must pass unchanged

**Verify**:
- `swift test --filter SettingsViewModelTests` → all pass (the public surface is
  unchanged, so these must pass without edits). If a test references a now-`private`
  member or fails, **STOP** — the public surface drifted.
- `swift test --filter SettingsEngineCharacterizationTests` → all pass **without
  editing the test bodies** (only a constructor/type change is acceptable if those
  tests constructed members directly; ideally zero edits). If a characterization
  assertion fails, the extraction changed behavior — **STOP and report**.

### Step 4: Add focused tests for the new VM

Create `Tests/MacParakeetTests/ViewModels/EngineSettingsViewModelTests.swift`,
modeled on `LLMSettingsViewModelTests.swift`. Construct `EngineSettingsViewModel`
directly with injected stubs and re-assert the same behaviors the characterization
tests pin (selection persistence, switch-confirmation state machine, downloaded-
variant detection, the static message builder) — now at the sub-VM level. This is
the durable home for those tests going forward.

**Verify**: `swift test --filter EngineSettingsViewModelTests` → all pass (≥ 10).

### Step 5 (optional): expose the sub-VM on SettingsRootViewModel

Per the IA design (`SettingsRootViewModel` is the composition root for sub-VMs),
you MAY store/pass the `EngineSettingsViewModel` through `SettingsRootViewModel`
so a later view-repointing follow-up can bind to it directly. Only do this if it is
additive and does not change current view wiring. If it risks the build, skip it
and leave it to the follow-up.

**Verify**: `swift build` → exit 0; `swift test` → all pass.

### Step 6: Update docs

- In `plans/active/2026-04-settings-ia-overhaul.md` §3, annotate the
  `EngineSettingsViewModel` row as shipped (with this branch name).
- Confirm `SettingsViewModel.swift` line count dropped meaningfully
  (`wc -l Sources/MacParakeetViewModels/SettingsViewModel.swift`).

## Test plan

- **Regression net (must pass unchanged):** `SettingsViewModelTests` and
  `SettingsEngineCharacterizationTests` — they pin the public surface and engine
  behavior. The extraction is correct only if both pass without behavioral edits.
- **New:** `EngineSettingsViewModelTests` — re-home the engine behavior tests at the
  sub-VM level, modeled on `LLMSettingsViewModelTests.swift`. Cover: selection
  persistence round-trip, switch-confirmation transitions, downloaded-variant
  detection via injected `*Cached` stubs, static unavailable-message strings.
- Verification: `swift test` → all pass; the three filters above each green.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `Sources/MacParakeetViewModels/EngineSettingsViewModel.swift` exists; is `@MainActor @Observable`; imports only `Foundation`/`MacParakeetCore` (no SwiftUI).
- [ ] `swift build` exits 0.
- [ ] `swift test --filter SettingsViewModelTests` passes **without edits to assertions**.
- [ ] `swift test --filter SettingsEngineCharacterizationTests` passes **without edits to assertions**.
- [ ] `swift test --filter EngineSettingsViewModelTests` passes (≥ 10 tests).
- [ ] `swift test` exits 0 (full suite).
- [ ] `wc -l Sources/MacParakeetViewModels/SettingsViewModel.swift` is at least ~300 lines smaller than the 2,568 baseline.
- [ ] `grep -n "import SwiftUI" Sources/MacParakeetViewModels/EngineSettingsViewModel.swift` → no matches.
- [ ] No `Sources/MacParakeet/Views/**` file is modified (forwarding kept them valid; `git status --porcelain Sources/MacParakeet/Views` is empty).
- [ ] `plans/README.md` and the IA plan's Engine row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- The characterization tests (`SettingsEngineCharacterizationTests`) do not exist or
  are red before you start (Step 0).
- Moving a member forces a behavior change to keep it compiling (e.g. a `didSet`
  that referenced a non-engine property of `SettingsViewModel`) — report the
  cross-coupling; do not paper over it by leaving the member in `SettingsViewModel`
  half-moved.
- `SettingsViewModelTests` or the characterization tests require **assertion** edits
  (not just a constructor/type rename) to pass — that means behavior changed.
- A view in `Sources/MacParakeet/Views` cannot be kept compiling via a forwarding
  shim (e.g. it used a `private` member through `@testable`/same-module access) —
  report it rather than widening access or editing the view.
- The engine slice turns out to be entangled with non-engine state such that a clean
  forward isn't possible — report the entanglement points; a smaller first slice may
  be needed.

## Maintenance notes

- **Deferred follow-ups** (own plans): (1) re-point `SettingsView.swift` engine
  cards to bind `engine.*` directly and drop the forwarding shims; (2) extract the
  remaining slices (Capture/Dictation/Transcription/Meeting/System) the same way;
  (3) the poster-side notification unification noted in the observer-fan-out plan.
- A reviewer should scrutinize: that the `isApplying*` reentrancy guards and `didSet`
  persistence moved intact, that observation still works through the forwarding
  computed properties (bindings update live), and that the characterization tests
  passed without behavioral edits.
- When the next slice is extracted, the forwarding-shim pattern established here is
  the template; keep `SettingsViewModel` as a thin composition+forwarding shell until
  views are re-pointed.
