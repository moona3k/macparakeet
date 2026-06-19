# Dictation-first onboarding

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. **Part A and Part B are separate commits/PRs — land Part A first.**
> If any "STOP conditions" entry occurs, stop and report — do not improvise.
> When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 237bb8ae1..HEAD -- Sources/MacParakeetViewModels/OnboardingViewModel.swift Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift Sources/MacParakeetCore/AppFeatures.swift`
> If any of those changed since `237bb8ae1`, compare the "Current state" line
> anchors below against the live code before editing; on a mismatch, re-locate
> the symbol by name (the anchors are line *hints*, not contracts) and, if the
> structure changed materially, treat it as a STOP condition.

## Status

- **Priority**: **P1** — highest-leverage activation lever in the backlog
- **Effort**: Part A = **S–M** (subtraction + switch fixes + tests) · Part B = **M** (warm-up state machine)
- **Risk**: Part A = **LOW** (pure removal, no new control flow) · Part B = **MED** (perturbs the warm-up machinery)
- **Depends on**: Part A — none. Part B — *soft*: land `plans/active/2026-06-onboarding-stall-watchdog-test.md` first so the warm-up path Part B perturbs has test coverage under it.
- **Category**: direction / activation
- **Planned at**: commit `237bb8ae1`, 2026-06-13 (refreshed to executor-grade from the 2026-05-29 design)
- **ADR**: amends ADR-005 (onboarding first-run)

## Why this matters

MacParakeet's North Star is a fast, local-first **voice** app: dictation is the
headline; meeting recording + calendar are optional. But first-run onboarding
puts **Meeting Recording** and **Calendar** setup *in the critical path before*
the user reaches the hotkey + speech-model steps that actually make dictation
work (`OnboardingViewModel.Step`, order: welcome → microphone → accessibility →
**meetingRecording → calendar** → hotkey → engine → done).

The original design called this cost "mild" because the two steps are skippable.
**The funnel data disagrees.** The recorded new-user funnel shows a **≈−21-point
completion cliff at the Meeting-Recording / screen-recording step** — the single
largest drop in onboarding — before users reach core dictation setup (activation
is otherwise strong: ~74% dictate within 1h). With the product hitting new
all-time highs, every recovered completion point compounds. Removing these two
optional steps from the path is the cheapest, highest-leverage activation change
available, and it is already designed (below). **Ship Part A, then confirm the
lift via the existing funnel telemetry** (see "Verifying the lift").

## Problem

First-run onboarding is one linear path of 8 steps for everyone:
`Welcome → Microphone → Accessibility → Meeting Recording → Calendar → Hotkey →
Speech Model → Ready` (`OnboardingViewModel.Step`, `OnboardingViewModel.swift:22`).

Meeting Recording and Calendar are shown to *every* new user. They are skippable
cards, not forced OS prompts — the system permission dialog only fires if the
user clicks "Enable…", and the default action advances without prompting
(`OnboardingFlowView.swift:429,502`). The cost looked mild on that basis; the
−21pt funnel cliff (above) shows the perceived friction is real: every new user
reads and dismisses setup for two features they may never touch, at the exact
moment they are forming a mental model of what the app *is*.

## Goal

Two independent improvements to first-run, shippable separately:

**Part A — dictation-first subtraction.** Remove Meeting Recording and Calendar
from the flow; they become opt-in features that set themselves up on first use.
Add one quiet line on the Ready screen so meeting recording stays discoverable.
New flow (everyone): `Welcome → Microphone → Accessibility → Hotkey →
Speech Model → Ready` — **8 steps → 6**.

**Part B — model-download head-start.** Kick off the ~465 MB Parakeet
speech-model warm-up when onboarding *opens*, not when the user reaches the
(second-to-last) Speech Model step, so the download overlaps the interactive
steps. Changes download **timing**, not **contents**.

Part A is low-risk and stands alone. Part B is separable and carries the
warm-up-machinery risk detailed in Design §5 — **ship A first** to de-risk.

## Why not a use-case picker?

We considered a use-case selection step (Dictation / Meetings / Everything radio
that prunes the flow per intent) and **rejected it**:

- Its value concentrated on a minority — meetings-primary users — while taxing
  the dictation-majority with a decision step they don't need.
- "Not onboarding meetings at all" is the truest expression of *"meetings is
  optional"*: a picker forces every user to *confront* a meetings decision;
  omitting it lets meetings be ignorable until wanted.
- Simplicity is the product. This removes steps instead of adding a fork.

Do not re-propose the picker without new evidence (e.g. telemetry showing a large
meetings-primary cohort failing to discover the feature).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Compile | `swift build` | exit 0, no errors |
| Focused VM tests | `swift test --filter OnboardingViewModelTests` | all pass (incl. new tests) |
| Full suite | `swift test` | exit 0, all pass |
| Manual smoke (build + launch dev app) | `scripts/dev/run_app.sh` | app launches; onboarding shows **6** steps, no Meeting Recording / Calendar |

The full suite usually runs ~1–2 min. `DictationFlowCoordinatorLoadCaptionTests`
is known-flaky on CI — re-run a failed job, don't "fix" it.

## Current state (line anchors at `237bb8ae1` — verify before editing)

- `Sources/MacParakeetViewModels/OnboardingViewModel.swift`
  - `enum Step` with the 8 cases: line **22**.
  - `meetingRecordingSkipped` / `calendarSkipped` stored props: **63 / 65**;
    their `UserDefaults` keys + reset: **108–109, 146–147, 168–173**.
  - `whisperRecommendation`: **68** · shared `isBusy`: **70**.
  - static `visibleSteps`: **212** · `canContinueFromCurrentStep()`: **256**.
  - `skipMeetingRecordingStep()`: **324** · `skipCalendarStep()`: **362**.
  - `onboarding_step` telemetry emitted on advance: **233**
    (`Telemetry.send(.onboardingStep(step: next.title.lowercased()))`).
  - `startEngineWarmUp()`: **396**; sets `isBusy` (**416**); generation/observation-token
    guards that make it idempotent: **411–423**; stall watchdog `.failed` path: **419**;
    download-duration anchor `warmUpStartedAt → .ready`: **~479–484**.
- `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift`
  - `visibleSteps`/`totalSteps`/progress index: **55–58** (read from the VM static).
  - `stepBody(_:)` switch: **325** · `meetingRecordingStep`: **429** ·
    `calendarStep`: **502** · `doneStep`: **877**.
  - engine-step `.onAppear { viewModel.startEngineWarmUp() }`: **373–376**.
  - exhaustive `Step` switches to fix: `stepIcon` (~**197**), `titleForStep`
    (~**1059**), `subtitleForStep`/`continueHint` (~**1078/1232**),
    `primaryButtonTitle` (~**1096**).
- `Sources/MacParakeetCore/AppFeatures.swift` — `meetingRecordingEnabled` (**12**),
  `calendarEnabled` (**24**); doc-comments currently claim to hide an onboarding step.
- `Sources/MacParakeet/Hotkey/GlobalShortcutManager.swift:49` —
  `CGEvent.tapCreate` session tap (needs Accessibility; see Design §3).
- Tests: `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift` (770 lines) — extend this.

Convention to match: `@MainActor @Observable` ViewModels; telemetry via
`Telemetry.send(.<case>)`; tests are XCTest, in-memory, deterministic.

## Scope

**In scope (Part A):**
- `Sources/MacParakeetViewModels/OnboardingViewModel.swift`
- `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift`
- `Sources/MacParakeetCore/AppFeatures.swift` (doc-comments only)
- `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift`
- Docs on completion: `spec/adr/005-onboarding-first-run.md`,
  `spec/02-features.md`, and `spec/README.md`. Old `REQ-*` references are
  historical only; do not update the retired requirements index.

**In scope (Part B, separate commit):** the four bounded warm-up guards in Design §5,
in the same two source files + the test file.

**Out of scope (do NOT touch):**
- The **shared** permission plumbing (`requestScreenRecordingAccess`,
  `screenRecordingGranted`, `requestCalendarAccess`, `calendarPermissionGranted`)
  — Settings + first-use self-prompts consume it. Remove only the *onboarding-only*
  skip methods + skip booleans. **Verify call sites first.**
- The STT runtime/scheduler. Part B's `isBusy` decoupling is a ViewModel-flag change
  only; if it appears to need runtime changes, that's a STOP condition.
- *What* gets downloaded (Part B is timing only).
- Any website / `telemetry.ts` change — there is none (see Design §4).
- Unrelated in-flight trees: the dictation-stall plan, `meeting-vad-sim` / VAD replay
  tooling, the silent-buffer plan.

## Design

### 1. Drop `meetingRecording` + `calendar` from the onboarding flow

- Delete (don't leave dormant — CLAUDE.md "delete old code entirely"):
  - `Step.meetingRecording` / `Step.calendar` enum cases.
  - The step views `meetingRecordingStep` / `calendarStep`
    (`OnboardingFlowView.swift:429,502`).
  - Onboarding-only skip plumbing: `skipMeetingRecordingStep` /
    `skipCalendarStep` and the persisted skip booleans + their keys
    (`OnboardingViewModel.swift:63,65,108–109,146–147,168–173,324,362`).
- **KEEP** the shared permission plumbing — consumed by Settings and the
  first-use self-prompt paths. **Verify call sites before deleting anything.**
- `visibleSteps` (`OnboardingViewModel.swift:212`) reverts to a simple static list;
  it no longer needs to gate meeting/calendar on `AppFeatures`. The
  `AppFeatures.meetingRecordingEnabled` / `calendarEnabled` flags still gate the
  *features* (Transcribe tile, menu bar, Settings subsection) — they simply no
  longer have an onboarding surface to hide. Update their doc-comments.
- Fix every exhaustive switch that referenced the removed cases: `Step.title`,
  `canContinueFromCurrentStep()` (VM); `stepBody` / `stepIcon` / `titleForStep` /
  `subtitleForStep` / `primaryButtonTitle` / `continueHint` (view).

### 2. Ready-screen discoverability line

- Add **one quiet line** to `doneStep` (`OnboardingFlowView.swift:877`) — not a
  card, not a CTA — so the dictation win stays primary:

  > Recording a meeting? Click **Record Meeting** in the Transcribe tab.

- Gate it on `AppFeatures.meetingRecordingEnabled` so it disappears if the
  feature is ever flagged off.

### 3. The self-prompt safety contract (verify, don't build)

Removing the steps is only safe because each feature sets itself up on first use.
Confirm each path before considering this done:

- **Meeting recording later:** the Transcribe "Record Meeting" tile triggers the
  Screen & System Audio prompt on first use.
- **Calendar later:** the Settings calendar subsection requests access
  (REQ-CAL-002); auto-start stays default `.off` (opt-in).
- **Accessibility:** still onboarded for **everyone** (dictation paste needs it),
  so it is *not* affected — and that is load-bearing: the meeting global hotkey
  uses a `CGEvent` session tap that *also* requires Accessibility
  (`GlobalShortcutManager.swift:49`). Because the dictation-first flow grants AX
  to every user, the meeting hotkey keeps working. (A concrete reason the *picker*
  was the wrong design: a branched flow risked withholding AX from meetings-only
  users and silently breaking their meeting hotkey.)

If any path does not self-prompt, closing that gap is in scope — but first see STOP conditions.

### 4. Telemetry — no change

No new event. The per-step `onboarding_step` telemetry for the two removed steps
simply stops firing; `onboarding_completed` is unchanged. Both events are already
on the website `ALLOWED_EVENTS`, so we deliberately avoid the two-repo allowlist
footgun — **there is nothing to add to the website Worker.**

### 5. Model-download head-start (Part B — separable, test carefully)

Today `startEngineWarmUp()` fires on `.onAppear` of the Speech Model step
(`OnboardingFlowView.swift:373–376`). Move the *trigger* earlier — call it once
when onboarding opens (top-level `.task`/`.onAppear` of `OnboardingFlowView`) — so
the download overlaps the interactive steps. Leave the engine step's existing
`.onAppear` call in place as an **idempotent fallback**.

**Why this is safe at the core.** The v0.4.22 race — a stale fire-and-forget
progress `Task` overwriting terminal `.ready` with `.working`, causing 100%
onboarding failure — was fixed with an `AsyncStream` observer loop fenced by a
generation + observation-token guard (`OnboardingViewModel.swift:411–423`). Those
guards make `startEngineWarmUp()` idempotent: the early call starts it; the engine
step's `.onAppear` call then no-ops via `if case .ready { return }` or
`if warmUpObserverTask != nil { return }`. Two call sites is exactly what those
guards were built to tolerate.

**Four bounded guards that ARE in scope for Part B** (do guard 1 first — it is the
only one that can deadlock the user):

1. **Decouple warm-up from the permission steps' `isBusy`.** `startEngineWarmUp`
   sets the shared `isBusy = true` (`OnboardingViewModel.swift:416`); the
   Microphone / Accessibility grant buttons disable on that same flag. If the
   download starts at Welcome, the user lands on Microphone with a greyed-out grant
   button held by the *model download* — a deadlock. Give warm-up its own
   `engineBusy` (it already has `engineState`); stop it touching the permission
   `isBusy`.
2. **Resolve the Whisper recommendation before kickoff.** `startEngineWarmUp`
   forks to `startRecommendedWhisperSetup` when `whisperRecommendation` is set
   (CJK Macs). The early trigger must run *after* that recommendation resolves, or a
   CJK user downloads Parakeet then has to switch. Resolve-then-prefetch.
3. **Don't surface the stall watchdog before the engine step is shown.**
   `resetWarmUpStallWatchdog` flips to `.failed` on a progress timeout
   (`OnboardingViewModel.swift:419`). Keep that failure invisible (or don't arm the
   watchdog) until the engine step is actually presented, so a dead-network user
   doesn't hit a pre-failed engine step.
4. **Re-anchor or document the download-duration telemetry.**
   `modelDownloadCompleted` measures `warmUpStartedAt → .ready`
   (`OnboardingViewModel.swift:~479–484`). Starting earlier folds the user's
   think-time into that number. Re-anchor to first-byte, or document the shift.

## Steps

### Part A — dictation-first subtraction (one commit/PR)

**Step 1 — Remove the two steps + onboarding-only skip plumbing.**
Delete `Step.meetingRecording` / `Step.calendar`, their step views, the skip
methods, and the persisted skip booleans + keys (Design §1). Keep the shared
permission plumbing — grep its call sites first.
**Verify**: `grep -nE "case meetingRecording|case calendar" Sources/MacParakeetViewModels/OnboardingViewModel.swift` → **no matches in the `Step` enum**; `grep -rn "skipMeetingRecordingStep\|skipCalendarStep\|meetingRecordingSkipped\|calendarSkipped" Sources/` → **no matches**.

**Step 2 — Simplify `visibleSteps` + fix exhaustive switches.**
Make `visibleSteps` the static 6-step list `[.welcome,.microphone,.accessibility,.hotkey,.engine,.done]`. Fix every `Step` switch in the VM and view so the project compiles. Update `AppFeatures` doc-comments.
**Verify**: `swift build` → exit 0, no errors (a missed exhaustive switch fails the build — this is your safety net).

**Step 3 — Ready-screen meetings line.**
Add the one quiet line to `doneStep`, gated on `AppFeatures.meetingRecordingEnabled` (Design §2).
**Verify**: `swift build` → exit 0; `grep -n "Record Meeting" Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift` → one match inside `doneStep`.

**Step 4 — Tests.**
Extend `OnboardingViewModelTests.swift` (see Test plan).
**Verify**: `swift test --filter OnboardingViewModelTests` → all pass, including the new `visibleSteps == 6-step list` and `goNext/goBack` walk tests.

**Step 5 — Verify the self-prompt safety contract (Design §3).**
Confirm first "Record Meeting" → screen prompt; Settings → calendar request; Accessibility still onboarded for all. If a path does **not** self-prompt, see STOP conditions.
**Verify**: `swift test` → exit 0; manual `scripts/dev/run_app.sh` → onboarding shows 6 steps, Ready shows the meetings line.

### Part B — model-download head-start (separate commit; after Part A + the watchdog test)

**Step 6 — Decouple warm-up from permission `isBusy`** (Design §5.1). Add `engineBusy`; stop warm-up touching `isBusy`.
**Verify**: new test asserting permission `isBusy` is false while a warm-up is in flight → passes.

**Step 7 — Early one-shot `startEngineWarmUp()`** at onboarding open, *after* the Whisper recommendation resolves; keep the engine-step `.onAppear` call as idempotent fallback (Design §5.1–5.2).
**Verify**: `swift test --filter OnboardingViewModelTests` → idempotency test (early call + engine-step call ⇒ no second download, no `engineGeneration` bump) passes.

**Step 8 — Suppress the stall watchdog's failure** until the engine step is presented (Design §5.3).
**Verify**: test — a warm-up failure before the engine step does not surface a terminal `.failed` to earlier steps → passes.

**Step 9 — Re-anchor or document the download-duration telemetry** (Design §5.4).
**Verify**: `swift test` → exit 0; the duration metric's anchor is either first-byte or documented in a code comment.

## Test plan

Extend `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift` (model
new tests after the existing cases there — XCTest, in-memory `UserDefaults`):

**Part A:**
- `visibleSteps == [.welcome,.microphone,.accessibility,.hotkey,.engine,.done]` regardless of `AppFeatures` flag values.
- `goNext` / `goBack` walk the 6-step list with no no-ops or skips.
- `canContinueFromCurrentStep()` correct for each remaining step.
- Speech-model / diarization warm-up still prepared (regression guard — downloads unchanged).
- Existing users (`completedAtISO` present) do not re-onboard.

**Part B:**
- Idempotency: early `startEngineWarmUp()` + engine-step call ⇒ no second download / no `engineGeneration` bump.
- Permission requests not blocked by an in-flight warm-up (assert via the decoupled `engineBusy`).
- A CJK `whisperRecommendation` makes the early kickoff take the Whisper path, not Parakeet.
- A warm-up failure before the engine step is not surfaced as terminal `.failed` to earlier steps.

**Verify**: `swift test --filter OnboardingViewModelTests` → all pass; then `swift test` → exit 0.

## Done criteria

Part A is done when ALL hold:

- [ ] `swift build` exits 0.
- [ ] `grep -nE "case meetingRecording|case calendar" Sources/MacParakeetViewModels/OnboardingViewModel.swift` → no matches in the `Step` enum.
- [ ] `grep -rn "skipMeetingRecordingStep\|skipCalendarStep\|meetingRecordingSkipped\|calendarSkipped" Sources/` → no matches.
- [ ] `swift test` exits 0; new `OnboardingViewModelTests` for the 6-step flow exist and pass.
- [ ] Manual: `scripts/dev/run_app.sh` → onboarding is 6 steps, no Meeting Recording / Calendar; Ready screen shows the meetings discoverability line.
- [ ] `git -C ../macparakeet-website status` clean (no telemetry.ts change) **and** no `Sources/.../telemetry` change — this plan adds no event.
- [ ] Only in-scope files modified (`git status`).
- [ ] Docs updated: ADR-005 amendment, `spec/02-features.md` + `spec/README.md` progress, optional `REQ-ONB-001`.
- [ ] `plans/README.md` status row updated.

Part B adds: idempotency + decoupling + watchdog-suppression + telemetry-anchor tests pass; manual fast-connection check shows the engine step is instant with no second download.

## STOP conditions

Stop and report (do not improvise) if:

- A shared permission method (`requestScreenRecordingAccess` / `screenRecordingGranted` / `requestCalendarAccess` / `calendarPermissionGranted`) has **no** non-onboarding caller — the plan assumes Settings/first-use consume it; deleting it would break those paths. Report rather than delete.
- The "Record Meeting" tile or the Settings calendar subsection does **not** self-prompt for permission on first use — the safety contract (Design §3) is violated; closing the gap may change effort/scope. Report.
- Part B's `isBusy` decoupling appears to require changes to the STT runtime/scheduler (not just the ViewModel flag) — out of scope. Report.
- A step's verification fails twice after a reasonable fix attempt.
- The drift check shows the onboarding step machine was materially restructured since `237bb8ae1`.

## Verifying the lift (post-ship analysis — not new code)

The funnel is **already instrumented**; no telemetry change ships with this plan:
- `onboarding_step` (property `step`) fires on every advance; `onboarding_completed` marks completion. Both are already on the website allowlist.

After a build carrying Part A ships and propagates (allow ~1–2 weeks for Sparkle
uptake), confirm the lift by **app version**:
- The `onboarding_step` distribution for the new version should no longer contain
  `meeting recording` / `calendar` rows.
- Step-to-step retention from `accessibility` onward should no longer show the
  ~21pt drop, and `onboarding_completed` rate (vs the `welcome`/`microphone`
  floor) should rise.
- Query via the telemetry D1 (`docs/telemetry.md`; `--remote`): group
  `onboarding_step` by `step` × app version and compute retention.

Caveats (house rules): stratify by app version; **exclude the OSS/dev cohort
(`0.0.0`/dev) and the owner fingerprint**; treat `onboarding_completed` as the
firm new-user floor (sessions ≠ users; multi-release days inflate launches).

## Non-goals (avoid scope creep)

- **No use-case picker** (considered and rejected — see above).
- **No change to what gets downloaded** (Part B changes *when*, not *what*).
  Parakeet (~465 MB) / Whisper (CJK, ~632 MB) and diarization speaker models
  (~130 MB) still download on the same critical path. Diarization also powers
  file-transcription speaker labels, so a dictation user benefits; lazy
  diarization is a separate, STT-runtime-risky idea — out of scope.
- **No live "try it" dictation step** — dictation pastes into whatever app you're
  in, so the "it works!" moment happens for free ~5s after onboarding in the
  user's real app. An in-onboarding practice field adds a step + the most build
  complexity and duplicates that aha. Declined.
- **No new "voice notes" / no-paste capture mode.**
- **No VAD onboarding work.** The former onboarding VAD prep
  (`OnboardingViewModel.prepareMeetingVADModelIfNeeded`) was removed in favor of
  universal launch-time prep. If Part B touches the warm-up sequence, coordinate
  so the two changes don't collide.
- **No persisted mid-flow resume** (onboarding still restarts at Welcome if quit
  before completion).
- **Existing users are untouched** — the coordinator only shows onboarding when
  `onboarding.completedAtISO` is absent (`OnboardingCoordinator.swift:41`).

## Invariants

- Existing users never re-onboard.
- Speech-model download stays mandatory on every path (engine step never gated).
- No feature is hard-locked; meeting recording & calendar stay enableable later
  and self-prompt on first use.
- Accessibility stays onboarded for everyone (keeps dictation paste **and** the
  meeting hotkey working).
- Local-first / no-content-telemetry unchanged; no new telemetry event.
- (Part B) Warm-up never blocks permission grants, and the engine step never
  triggers a second download — `startEngineWarmUp()` stays idempotent across its
  early and engine-step call sites.

## Maintenance notes

- A reviewer should scrutinize: that no shared permission code was deleted (only
  onboarding-only skip plumbing), that every `Step` switch is exhaustive without
  the removed cases, and that the Ready-screen line is gated on the feature flag.
- If a future change re-adds an onboarding surface for meetings/calendar, revisit
  the `AppFeatures` doc-comments updated here.
- Part B interacts with the warm-up state machine covered by
  `2026-06-onboarding-stall-watchdog-test.md` — run/extend those tests if you
  touch the watchdog arming.
- On completion: ADR-005 amendment and spec progress, then archive this plan to
  `plans/completed/`.
