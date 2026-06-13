# Dictation-first onboarding

> Status: **ACTIVE** (plan) · Created 2026-05-28 · Rewritten 2026-05-29 · ADR-005 amendment

## Problem

First-run onboarding is one linear path of 8 steps for everyone:
`Welcome → Microphone → Accessibility → Meeting Recording → Calendar → Hotkey →
Speech Model → Ready` (`OnboardingViewModel.Step`, `OnboardingViewModel.swift:22`).

Two of those steps — **Meeting Recording** and **Calendar** — are shown to *every*
new user. They are skippable cards, not forced OS prompts: the system permission
dialog only fires if the user clicks "Enable…", and the default action is
"Skip — I'll set this up later", which advances without prompting anything
(`OnboardingFlowView.swift:461,473,545`). So the cost is mild — but it is still
real: every new user has to read and dismiss setup for two features they may
never touch, at the exact moment they are forming a mental model of what the app
*is*.

MacParakeet's North Star is a fast, local-first **voice** app. Dictation is the
headline, built-in mode; meeting recording and calendar are optional. Onboarding
should reflect that: set up dictation, and let meeting recording + calendar be
opt-in features the user discovers when they actually want them.

## Goal

Two independent improvements to first-run, shippable separately:

**Part A — dictation-first subtraction.** Remove Meeting Recording and Calendar
from the flow; they become opt-in features that set themselves up on first use.
Add one quiet line on the Ready screen so meeting recording stays discoverable.

New flow (everyone): `Welcome → Microphone → Accessibility → Hotkey →
Speech Model → Ready` — **8 steps → 6**.

**Part B — model-download head-start.** Kick off the ~465 MB Parakeet
speech-model warm-up when onboarding *opens*, not when the user reaches the
(second-to-last) Speech Model step. By the time they finish the interactive
steps the download is partly or fully done, so the Speech Model step is short or
instant instead of a dead wait. This changes download **timing**, not download
**contents** (see Non-goals).

Part A is low-risk and stands alone. Part B is separable and carries the
warm-up-machinery risk detailed in §5 — **ship A first** if you want to de-risk.

## Why not a use-case picker?

We considered a use-case selection step (Dictation / Meetings / Everything radio
choice that prunes the flow per intent) and **rejected it**:

- Its value concentrated on a minority — meetings-primary users — while taxing
  the dictation-majority with a decision step they don't need.
- "Not onboarding meetings at all" is the truest expression of *"meetings is
  optional"*: a picker forces every user to *confront* a meetings decision;
  simply omitting it lets meetings be ignorable until wanted.
- Simplicity is the product. This removes steps instead of adding a fork.

Do not re-propose the picker without new evidence (e.g. telemetry showing a large
meetings-primary cohort that is failing to discover the feature).

## Design

### 1. Drop `meetingRecording` + `calendar` from the onboarding flow

- Remove the two steps onboarding shows. Recommended (delete, don't leave
  dormant — CLAUDE.md "delete old code entirely"):
  - `Step.meetingRecording` / `Step.calendar` enum cases.
  - The step views `meetingRecordingStep` / `calendarStep`
    (`OnboardingFlowView.swift:429,502`).
  - Onboarding-only skip plumbing: `skipMeetingRecordingStep` /
    `skipCalendarStep` and the persisted skip booleans
    (`OnboardingViewModel.swift:107`).
- **KEEP** the shared permission plumbing — `requestScreenRecordingAccess` /
  `screenRecordingGranted` / `requestCalendarAccess` /
  `calendarPermissionGranted` are consumed by Settings and the first-use
  self-prompt paths. **Verify call sites before deleting anything.**
- `visibleSteps` can revert to a simple static list (it no longer needs to gate
  meeting/calendar on `AppFeatures`, because those steps are gone). The
  `AppFeatures.meetingRecordingEnabled` / `calendarEnabled` flags still gate the
  *features* (Transcribe tile, menu bar, Settings subsection) — they simply no
  longer have an onboarding surface to hide. Update the flag doc-comments in
  `AppFeatures.swift` accordingly (they currently claim to hide an onboarding
  step).
- Update every exhaustive switch that referenced the removed cases: `Step.title`,
  `canContinueFromCurrentStep()` (`OnboardingViewModel.swift`), and the view's
  `stepBody` / `stepIcon` / `stepIsCompleted` / `titleForStep` /
  `subtitleForStep` / `primaryButtonTitle` / `continueHint`
  (`OnboardingFlowView.swift`).

### 2. Ready-screen discoverability line

- Add **one quiet line** to `doneStep` (`OnboardingFlowView.swift:877`) — not a
  card, not a CTA, so the dictation win the user just completed stays primary.
  Copy (audience-friendly, concise):

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
  so it is *not* affected by this change — and that is load-bearing: the meeting
  global hotkey uses a `CGEvent` session tap that *also* requires Accessibility
  (`GlobalShortcutManager.swift:47`). Because the dictation-first flow grants AX
  to every user, the meeting hotkey keeps working. (This is a concrete reason the
  *picker* was the wrong design: a branched flow risked withholding AX from
  meetings-only users and silently breaking their meeting hotkey.)

If any path does not self-prompt, closing that gap is in scope.

### 4. Telemetry

No new event. The per-step `onboarding_step` telemetry for the two removed steps
simply stops firing; `onboarding_completed` is unchanged. We deliberately avoid
the two-repo `ALLOWED_EVENTS` allowlist footgun — there is nothing to add to the
website Worker.

### 5. Model-download head-start (Part B — separable, test carefully)

Today `startEngineWarmUp()` fires on `.onAppear` of the Speech Model step
(`OnboardingFlowView.swift:376`), the second-to-last step. Move the *trigger*
earlier — call it once when onboarding opens (top-level `.task`/`.onAppear` of
`OnboardingFlowView`, or the coordinator) — so the download overlaps the
interactive steps. Leave the engine step's existing `.onAppear` call in place as
an idempotent fallback.

**Why this is safe at the core (the scary race is already neutralized).** The
v0.4.22 race — a stale fire-and-forget progress `Task` overwriting terminal
`.ready` with `.working`, causing 100% onboarding failure — was fixed with an
`AsyncStream` observer loop fenced by a generation + observation-token guard
(`OnboardingViewModel.swift:413-418`, `:440`, `:455`, `:468`…). Those same guards
make `startEngineWarmUp()` **idempotent**: the early call starts it; the engine
step's `.onAppear` call then no-ops via `if case .ready { return }` (download
finished → step is instant) or `if warmUpObserverTask != nil { return }`
(still running → existing observation continues). Calling it from two sites is
exactly what those guards were built to tolerate.

**Four bounded guards that ARE in scope for Part B:**

1. **Decouple warm-up from the permission steps' `isBusy`.** `startEngineWarmUp`
   sets the shared `isBusy = true` (`OnboardingViewModel.swift:416`), and the
   Microphone / Accessibility grant buttons are disabled on that same flag
   (`OnboardingFlowView.swift:338`, `:358`). If the download starts at Welcome,
   the user lands on Microphone with a greyed-out, "Requesting…" grant button held
   by the *model download* — a deadlock. Warm-up already has its own `engineState`;
   stop it from touching the permission `isBusy` (or split into a separate
   `engineBusy`). **This is the one with user-visible failure potential — handle
   first.**
2. **Resolve the Whisper recommendation before kickoff.** `startEngineWarmUp`
   forks to `startRecommendedWhisperSetup` when `whisperRecommendation` is set
   (CJK Macs, `OnboardingViewModel.swift:408`). The early trigger must run *after*
   that recommendation is resolved, or a CJK user starts downloading Parakeet and
   then has to switch engines. Resolve-then-prefetch.
3. **Don't surface the stall watchdog before the engine step is shown.**
   `resetWarmUpStallWatchdog` flips to `.failed` on a progress timeout
   (`OnboardingViewModel.swift:419`). If warm-up starts at Welcome on a dead
   network, the flow could enter `.failed` on a step the user can't see yet, so
   they hit a pre-failed engine step. Keep the failure invisible (or don't arm the
   watchdog) until the engine step is actually presented.
4. **Re-anchor or document the download-duration telemetry.**
   `modelDownloadCompleted` measures from `warmUpStartedAt` to `.ready`
   (`OnboardingViewModel.swift:479-484`). Starting earlier folds the user's
   think-time on the interactive steps into that number, inflating "download
   duration." Either re-anchor the metric to first-byte, or document the shift so
   we don't misread the trend.

## Non-goals (explicitly, to avoid scope creep)

- **No use-case picker** (considered and rejected — see above).
- **No change to what gets downloaded** (Part B changes *when*, not *what*).
  Parakeet (~465 MB per selected build) / Whisper (CJK, ~632 MB) and the
  diarization speaker models (~130 MB) still download on the same critical path
  for everyone, exactly as today.
  Diarization also powers file-transcription speaker labels, so a dictation user
  benefits from it. Lazy diarization is a separate, STT-runtime-risky idea (real
  regression surface) — out of scope here, may ship later or never.
- **No live "try it" dictation step.** Tempting (tier-1 voice apps do it), but
  redundant *here*: dictation pastes into whatever app you're in, so the "it
  works!" moment happens for free ~5 s after onboarding in the user's real app.
  An in-onboarding practice field adds a step, adds the most build complexity
  (live overlay + paste target inside the onboarding window), and duplicates that
  aha. Deliberately declined.
- **No new "voice notes" / no-paste capture mode.**
- **No VAD onboarding work.** The opposite, in fact: the former onboarding VAD
  prep (`OnboardingViewModel.prepareMeetingVADModelIfNeeded`) has been removed
  and replaced by universal launch-time prep — see
  `2026-05-meeting-vad-guided-live-chunking.md` §6 / Phase 4.5. If Part B touches
  the warm-up sequence here, coordinate so the two changes don't collide (the VAD
  prep deletion lands with that plan, not this one).
- **No persisted mid-flow resume** (onboarding still restarts at Welcome if quit
  before completion — current behavior).
- **Existing users are untouched** — the coordinator only shows onboarding when
  `onboarding.completedAtISO` is absent (`OnboardingCoordinator.swift:41`).

## Files touched

| File | Change |
|---|---|
| `Sources/MacParakeetViewModels/OnboardingViewModel.swift` | **[A]** Remove `.meetingRecording` / `.calendar` `Step` cases, skip methods + skip booleans; simplify `visibleSteps` to a static list; update exhaustive switches. Keep shared permission plumbing. **[B]** Decouple warm-up from permission `isBusy` (own `engineBusy`); resolve Whisper recommendation before early kickoff; gate stall-watchdog surfacing on engine-step visibility; re-anchor download-duration telemetry. |
| `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift` | **[A]** Remove `meetingRecordingStep` / `calendarStep`; add the Ready-screen meetings line; update step switches. **[B]** Add the early one-shot `startEngineWarmUp()` trigger (top-level `.task`/`.onAppear`); keep the engine-step `.onAppear` call as idempotent fallback. |
| `Sources/MacParakeetCore/AppFeatures.swift` | Update `meetingRecordingEnabled` / `calendarEnabled` doc-comments (they no longer hide an onboarding step). |
| `spec/adr/005-onboarding-first-run.md` | Amendment: 6-step dictation-first flow; meeting recording + calendar are opt-in post-onboarding. |
| `spec/02-features.md`, `spec/README.md` | Onboarding progress note. |
| `spec/kernel/requirements.yaml` | New `REQ-ONB-001` (optional): dictation-first onboarding; meeting recording & calendar are opt-in and self-prompt on first use. |

No website / `telemetry.ts` change. No new telemetry event.

## Testing (ViewModel/logic only — no SwiftUI view tests)

Extend `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift`:

**Part A:**
- `visibleSteps` == `[welcome, microphone, accessibility, hotkey, engine, done]`
  (no `meetingRecording` / `calendar`) regardless of `AppFeatures` flag values.
- `goNext` / `goBack` walk the 6-step list with no no-ops or skips.
- `canContinueFromCurrentStep()` is correct for each remaining step.
- Speech-model / diarization warm-up is still prepared (regression guard —
  downloads are unchanged by this plan).
- Existing users (`completedAtISO` present) do not re-onboard.

**Part B:**
- Idempotency: an early `startEngineWarmUp()` followed by the engine-step call
  does **not** bump `engineGeneration` / start a second download (it no-ops on
  `.ready` or on `warmUpObserverTask != nil`).
- Permission requests are not blocked by an in-flight warm-up — i.e. the warm-up
  busy state and the permission `isBusy` are independent (assert via the
  decoupled flag the buttons read).
- A CJK `whisperRecommendation` makes the early kickoff take the Whisper path,
  not Parakeet.
- A warm-up failure before the engine step is presented is not surfaced as a
  terminal `.failed` to earlier steps (assert the VM exposes the suppression the
  view gates on).

Run focused VM tests, then full `swift test`.

## Invariants

- Existing users never re-onboard.
- Speech-model download stays mandatory on every path (engine step never gated).
- No feature is hard-locked; meeting recording & calendar stay enableable later
  and self-prompt on first use.
- Accessibility stays onboarded for everyone (keeps dictation paste **and** the
  meeting hotkey working).
- Local-first / no-content-telemetry unchanged.
- (Part B) Warm-up never blocks permission grants, and the engine step never
  triggers a second download — `startEngineWarmUp()` stays idempotent across its
  early and engine-step call sites.

## Handoff

For the agent picking this up.

**Read first:** this plan top-to-bottom, `spec/adr/005-onboarding-first-run.md`,
and `Sources/MacParakeetCore/STT/README.md` if you touch warm-up. The Design
section has the file:line references.

**Scope:** two parts. **Part A** (steps 1–5) = remove two onboarding steps + add
one Ready-screen line; low-risk, ship-on-its-own. **Part B** (steps 6–9) = start
the model download earlier; separable and touches the warm-up state machine, so
**land Part A first, then do Part B as its own commit/PR.** Do **not** reintroduce
a use-case picker, and do **not** change *what* gets downloaded (Part B is timing
only).

### Part A — dictation-first subtraction

1. Remove `Step.meetingRecording` / `Step.calendar` and their step views, skip
   methods, and persisted skip booleans. Keep the shared screen-recording /
   calendar permission plumbing (Settings + first-use self-prompts use it —
   verify call sites first). (Design §1.)
2. Simplify `visibleSteps` to the static 6-step list; update `AppFeatures`
   doc-comments. (Design §1.)
3. Add `.useCase`-free arms: fix every exhaustive `Step` switch in the VM and the
   view so it compiles without the removed cases. (Design §1.)
4. Add the quiet Ready-screen meetings line, gated on
   `AppFeatures.meetingRecordingEnabled`. (Design §2.)
5. **Verify the self-prompt safety contract** (Design §3) — first Record Meeting
   → screen prompt; Settings → calendar; Accessibility still onboarded for all.
   If a path doesn't self-prompt, fixing it is in scope.

**No telemetry change. No website change.** (Design §4.)

### Part B — model-download head-start (separate commit; do after A)

Do these in order — guard 6 first, it's the only one that can deadlock the user.

6. **Decouple warm-up from permission `isBusy`** so a background download can't
   grey out the Microphone/Accessibility grant buttons. (Design §5.1.)
7. Add the **early one-shot `startEngineWarmUp()`** trigger at onboarding open,
   *after* the Whisper recommendation is resolved; keep the engine-step
   `.onAppear` call as the idempotent fallback. (Design §5.1–5.2.)
8. **Suppress the stall watchdog's failure** until the engine step is actually
   presented. (Design §5.3.)
9. **Re-anchor (or document) the download-duration telemetry** so the earlier
   start doesn't silently inflate it. (Design §5.4.)

Verify the idempotency by hand: reach the engine step on a fast connection — it
should already be `.ready` (instant), with no second download kicked off.

**Tests:** extend `OnboardingViewModelTests.swift` per the Testing section —
ViewModel/logic only. Run focused VM tests, then full `swift test`.

**Docs on completion:** ADR-005 amendment, `spec/02-features.md` +
`spec/README.md` progress, new `REQ-ONB-001`, traceability map, then archive this
plan to `plans/completed/`.

**Do not touch** unrelated in-flight work in the tree (dictation-stall plan,
`meeting-vad-sim` / VAD replay tooling, silent-buffer plan).
