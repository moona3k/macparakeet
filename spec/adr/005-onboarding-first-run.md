# ADR 005: First-Run Onboarding Window

Date: 2026-02-10
> Note: Qwen LLM warm-up step referenced below was removed 2026-02-23. As of 2026-04-06, onboarding prepares the local speech stack: Parakeet STT plus any required default-on speaker-detection assets. Addendum 2026-04-10: onboarding includes an optional Screen & System Audio Recording step for meeting capture. Addendum 2026-04-25 / 2026-05-21: onboarding also includes a skippable Calendar step when `AppFeatures.calendarEnabled` is true; Calendar auto-start defaults to `.off` and is strictly opt-in.

## Context

MacParakeet is a menu bar app with a configurable global hotkey (default: Fn) and paste automation. To deliver a premium first-run experience, we need to:

- Explain the core interaction model (hotkey, stop/paste, cancel).
- Acquire permissions (Microphone, Accessibility, plus optional Screen Recording for meeting capture and optional Calendar access for reminders/auto-start).
- Prepare the local speech stack so dictation and default-on file-transcription features are ready on first use.

Without onboarding, users encounter failures out of context (missing permissions, slow first warm-up) and the product feels brittle.

## Decision

Implement a dedicated first-run onboarding window that appears automatically when the app starts and onboarding has not been completed.

The onboarding flow is linear and step-based:

1. Welcome
2. Microphone permission
3. Accessibility permission
4. Meeting recording permission (optional Screen & System Audio Recording)
5. Calendar meetings (optional EventKit access, gated by `AppFeatures.calendarEnabled`)
6. Hotkey instructions
7. Speech stack setup (Parakeet + required speaker-detection assets, retry available)
8. Ready

The onboarding can also be launched manually from Settings.

If onboarding is closed before completion, the app shows an explicit confirmation dialog. If the user exits setup anyway, onboarding is shown again on the next app activation until completion.
During speech-stack setup, onboarding runs lightweight preflight checks (disk space + network readiness) before downloading required assets.
While onboarding is visible, permission state is polled so changes made in System Settings are reflected automatically.

## Consequences

- Users get a guided, premium setup that reduces first-run friction.
- Hotkey manager is restarted after onboarding to reliably start listening once Accessibility is granted.
- The Parakeet STT model is downloaded/warmed during onboarding to reduce first-use latency for dictation.
- Speaker detection defaults on where supported (ADR-010 amendment 2026-07-03), so its diarization assets are prepared before onboarding reports file transcription ready when a diarization service is available.
- Meeting Recording and Calendar steps are explicitly skippable. If skipped, the feature surfaces can still request the relevant permission later from first use or Settings.
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
- A warm-up failure that occurs before the user reaches the Speech Model step is suppressed (state resets to `.idle`); the terminal `.failed` only surfaces once that step is shown, so an early/transient failure never flashes a failed card on an earlier step.
- `modelDownloadStarted` now fires at onboarding open; the start→ready duration still measures real download time (the background download is independent of the user's step).
