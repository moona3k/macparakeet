# ADR 005: First-Run Onboarding Window

> Status: **Accepted (amended)**
>
> Current decision: first-run onboarding is the four-step flow defined by the
> 2026-09-23 amendment: Welcome, Permissions, Try It (key rehearsal plus a real
> first dictation in the window), and All Set. Meeting Recording and Calendar
> setup stay out of onboarding and request permission in context from their
> feature surfaces.

Date: 2026-02-10
> Historical note: the Qwen LLM warm-up step was removed 2026-02-23. Meeting Recording and Calendar steps added in April were later removed by the 2026-06-13 dictation-first amendment below.

## Context

MacParakeet is a menu bar app with a configurable global hotkey (default: Fn) and paste automation. To deliver a premium first-run experience, we need to:

- Explain the core interaction model (hotkey, stop/paste, cancel).
- Acquire the core Microphone and Accessibility permissions. Optional Meeting Recording and Calendar permissions are requested later, in context.
- Prepare the local speech stack so dictation and default-on file-transcription features are ready on first use.

Without onboarding, users encounter failures out of context (missing permissions, slow first warm-up) and the product feels brittle.

## Decision

Implement a dedicated first-run onboarding window that appears automatically when the app starts and onboarding has not been completed.

The current onboarding flow is linear and step-based (2026-09-23 amendment):

1. Welcome
2. Permissions: microphone (skippable) and Accessibility (required) on one page
3. Try It: light the real dictation key in the card, then dictate into a box in the window. The speech stack (Parakeet or locale-selected Whisper, plus required speaker-detection assets, retry available) downloads behind steps 1 to 3 and opens the box when ready.
4. All Set

The onboarding can also be launched manually from Settings.

If onboarding is closed before completion, the app shows an explicit confirmation dialog. If the user exits setup anyway, onboarding is shown again on the next app activation until completion.
Before the speech-stack download starts, onboarding runs lightweight preflight checks (disk space + network readiness).
While onboarding is visible, permission state is polled so changes made in System Settings are reflected automatically.

## Consequences

- Users get a guided, premium setup that reduces first-run friction.
- Hotkey manager is restarted after onboarding to reliably start listening once Accessibility is granted.
- The Parakeet STT model is downloaded/warmed during onboarding, and the first dictation happens inside onboarding once it is ready.
- Speaker detection defaults on where supported (ADR-010 amendment 2026-07-03), so its diarization assets are prepared before onboarding reports file transcription ready when a diarization service is available.
- Meeting Recording and Calendar are deliberately outside first-run onboarding. Their feature surfaces request the relevant permission on first use or from Settings.
- Preflight checks fail fast with actionable guidance, reducing avoidable warm-up failures.
- Onboarding completion is stored in `UserDefaults` as an ISO8601 timestamp.
- Incomplete setup is never silently dismissed; users either continue setup or explicitly defer it.

## Alternatives Considered

- Inline onboarding inside the main window: rejected because the app is menu-bar-first and may never open the main window on first launch.
- No onboarding: rejected due to permission and warm-up failures appearing as unexplained errors.

## Amendment — 2026-06-13: Dictation-First Onboarding (Part A)

**Decision:** Remove Meeting Recording and Calendar from the first-run onboarding flow. Onboarding is now 6 steps:
1. Welcome
2. Microphone permission
3. Accessibility permission
4. Hotkey instructions
5. Speech stack setup
6. Ready

**Rationale:** ~90% of users skipped the optional Screen & System Audio Recording permission at that step, and the step was the single largest onboarding drop-off (~24% of users who reached it did not continue to the core dictation setup). Meeting recording and calendar are optional features; their onboarding steps added friction to the dictation-primary flow without improving activation.

**Self-prompt contract:** Each removed feature sets itself up on first use:
- Meeting recording: the Transcribe tab "Record Meeting" tile triggers the Screen & System Audio Recording permission prompt on first use (`MeetingRecordingFlowCoordinator`).
- Calendar: the Settings calendar subsection requests EventKit access on first use (`CalendarSettingsView`).

Accessibility is still granted during onboarding for all users, which also covers the meeting recording global hotkey's `CGEvent` session tap.

## Amendment — 2026-06-14: Model-download head-start (Part B)

**Decision:** Start the speech-model warm-up when onboarding *opens* rather than when the user reaches the Speech Model step, so the ~465 MB download overlaps the Microphone / Accessibility / Hotkey steps. This changes download **timing**, not contents — on a fast connection the Speech Model step is already `.ready` and the user does not wait.

**Implementation guards** (`OnboardingViewModel` / `OnboardingFlowView`):
- The warm-up tracks its own `engineBusy` flag, separate from the permission `isBusy`, so the head-start download never disables the Microphone/Accessibility grant buttons.
- `startEngineWarmUp()` is idempotent (generation + observation-token guards): the early trigger starts it; the Speech Model step's `.onAppear` call is a no-op fallback. No second download.
- The Parakeet-vs-Whisper fork is preserved for CJK locales — `whisperRecommendation` resolves synchronously in `init`, before any trigger.
- A warm-up failure that occurs before the user reaches the Speech Model step is preserved as `.failed`, but only the Speech Model step renders failure UI. Earlier steps continue to show their permission/hotkey surfaces, and the user sees the existing error + Retry affordance immediately on reaching Speech Model.
- `modelDownloadStarted` now fires at onboarding open; the start→ready duration still measures real download time (the background download is independent of the user's step).

## Amendment — 2026-09-16: Microphone may be skipped (issue #879)

The Microphone step stays in onboarding, but Continue is no longer gated on grant. Dictation and mic-backed meetings request access on first use; persistent dictation prompts before capture so the same press can continue. Hold-to-talk cannot survive the system permission sheet, so a grant returns to idle and the next hold starts capture. Settings offers Grant or Open Microphone Settings when the mic is missing. Idle launch prewarm is skipped when the mic is not granted. Accessibility remains required.

## Amendment — 2026-09-23: First dictation inside onboarding

**Decision:** Onboarding is four steps. The separate Microphone, Accessibility, Hotkey, and Speech Model steps are replaced.

1. **Welcome.** Keeps the private-by-default line. The speech-model warm-up still starts when the window opens (2026-06-14 amendment).
2. **Permissions.** One page with two rows written as what the app will do: hear you while you dictate (microphone, skippable per the 2026-09-16 amendment) and use your dictation key and type into any app (Accessibility, required). The macOS prompt opens over this page and the existing poll flips each row when granted. No meeting audio, screen recording, or calendar.
3. **Try It.** One screen with two beats.
   - The configured push-to-talk and hands-free keys are drawn in the card. `OnboardingHotkeyPreviewController` runs the production `HotkeyManager` gesture machine for those two triggers with production taps suspended. The matching cap lights while its gesture is active and returns to rest on release (hands-free: on the next tap or Escape). It never records or runs STT, so it works during the download. Continue waits until a cap has lit once. Edit shortcut opens the production recorder in a sheet, and a changed binding rebuilds the rehearsal taps.
   - The dictation box below shows model progress (or the failure with Retry) until the engine is ready, then asks for the key, then asks for a click. Once clicked, the rehearsal disarms, production hotkeys resume, and the app's onboarding dictation gate lifts. The practice dictation is a real dictation through `DictationFlowCoordinator`: capture, STT, processing, paste at the active cursor, history, and telemetry. The box is the initial target; if the user switches apps, paste follows that app's cursor and a successful delivery still counts as practice. Practice uses normal paste even when optional streaming-cursor insertion is enabled, because streaming cancellation flushes remaining text into the next focused target. If the box does not contain the delivered text after a short grace, it displays the transcript directly. A successful clipboard fallback also counts as delivery. Continue waits for a non-empty delivered result. **Skip** is always available so a failed download or unusable key cannot trap onboarding. Leaving Try It or closing the window dismisses an active practice take and its pending insertion; it does not delete a completed local history item.
4. **All Set.** Shown after a practice result or Skip. Quotes the practice words when present, says if the model is still downloading or failed, and points at the frontmost app. **Finish** writes completion and closes the window; it no longer opens the main window.

**Rationale:** About 38% of starters abandon setup, and same-session dictation among completers fell to about 33% in September 2026. The miss is mostly people who never press the hotkey after "You're all set" ([activation leak](../../docs/research/2026-09-18-onboarding-activation-leak.md)). The old hotkey step's "Try it now" raised an off-card overlay that did not change the card, and Continue did not wait for a press. The download was its own step to watch. Design note and stills: [2026-09-23 Wispr onboarding](../../docs/design/2026-09-23-wispr-onboarding/note.md); implementation choices: [implementation.md](../../docs/design/2026-09-23-wispr-onboarding/implementation.md).

**What changes from earlier amendments:**
- A ready speech model no longer gates a step. It gates the practice box, and Skip can complete onboarding without it. The download keeps running in the shared runtime after the window closes, and Settings shows its state.
- `engine_failed` / `engine_ready` step telemetry is sent on whichever step the user is on when the warm-up settles, instead of only on the Speech Model step.
- `onboarding_step` names are now `welcome`, `permissions`, `practice`, `ready`, with new actions `hotkey_confirmed`, `practice_succeeded`, and `practice_skipped`. `total_steps` is 4.

**Out of scope:** sign-in, intent or meeting surveys, calendar connect, time-saved claims, referrals, and fake third-party app chrome. The after-close tip and a job picker are possible follow-ups.
