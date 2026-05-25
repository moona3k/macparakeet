# Onboarding "Learn the Hotkey" — interactive live preview

> Status: **ACTIVE** — 2026-05-22

## Problem

The onboarding "Learn the Hotkey" step (step 6 of 8) shows two animated cards
("Tap fn+Space" / "Hold fn") that *imply* interactivity, but pressing the key
does nothing. Confirmed in code: for a new user the global dictation CGEvent tap
fails to arm at boot (Accessibility not yet granted) and is only re-armed at
onboarding *completion* (`OnboardingCoordinator` → `onRefreshHotkeys`). Granting
Accessibility at step 3 does not re-arm it. So the step is a dead "try me"
affordance — a trust ding at the most fragile moment.

## Goal

Turn the step into a real first-success rehearsal: pressing the user's configured
dictation trigger raises the **real dictation overlay** with a **live mic-driven
waveform** — but with **no STT, no paste, no model** (the speech model is the
*next* step). Press hold-fn → overlay while held → release dismisses; tap
fn+Space → overlay → tap again dismisses. Mirrors both modes the cards teach.

## Why feasible (existing seams)

- Overlay + waveform are pure visual: `DictationOverlayController.show()` is
  self-contained (positions bottom-center floating panel), `DictationOverlayViewModel`
  exposes `state` + `audioLevel`, `WaveformView` consumes `audioLevel: Float`.
  Zero STT dependency.
- Live mic level: `SharedMicrophoneStream.subscribe(wantsVPIO:handler:)` +
  `AVAudioPCMBuffer.rmsLevel` (public). Mic permission already granted (step 2).
- Detection: reuse `HotkeyManager` with the user's configured triggers via
  `AppHotkeyCoordinator.dictationHotkeyPlan(handsFree:pushToTalk:)`.

## Design

New `OnboardingHotkeyPreviewController` (`Sources/MacParakeet/Onboarding/`),
`@MainActor`:

- `arm()` (hotkey step appears): `suspend()` production hotkeys, build step-scoped
  `HotkeyManager`s from the dictation plan, wire press→`beginPreview(mode:)`,
  release/cancel→end.
- `disarm()` (step disappears / window closes): end preview, stop managers,
  `resume()` production hotkeys. Idempotent (guards `isArmed`).
- `beginPreview(mode:)`: build a fresh `DictationOverlayViewModel` (`.recording`,
  `recordingMode = mode`, start timer), show via injected overlay factory, start
  a gentle fallback shimmer, subscribe to mic and feed `rmsLevel` → `audioLevel`
  (first real level cancels the shimmer).
- `endPreview()`: stop mic, stop shimmer, hide overlay, reset gesture state.
- Mic abstracted behind a `MicLeveling` protocol (concrete `SharedMicLeveling`
  wraps `SharedMicrophoneStream`) so the controller is testable without audio.

**Gate the real flow during onboarding** (correctness + latent-bug fix): add
`isOnboardingVisible` to `AppEnvironmentConfigurer.Callbacks`; `onStartDictation`
no-ops while onboarding is visible. Prevents a returning user (model present,
taps armed) from starting a real dictation mid-onboarding and double-stacking
with the preview.

**Graceful degradation**: mic skipped/denied → overlay shows with the breathing
shimmer; never blocks Continue. Nudge copy ("Try it now…") only shown when
Accessibility is granted (otherwise the preview taps can't arm).

## Files

- NEW `Sources/MacParakeet/Onboarding/OnboardingHotkeyPreviewController.swift`
- `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift` — arm/disarm
  closures (default `{}`), call in `hotkeyStep` onAppear/onDisappear; "try it" nudge.
- `Sources/MacParakeet/Onboarding/OnboardingWindowController.swift` — thread
  closures into `show`/`OnboardingFlowView`; defensive disarm in `windowWillClose`.
- `Sources/MacParakeet/App/OnboardingCoordinator.swift` — thread closures.
- `Sources/MacParakeet/App/AppEnvironmentConfigurer.swift` — `isOnboardingVisible`
  gate on `onStartDictation`.
- `Sources/MacParakeet/AppDelegate.swift` — create controller, wire arm/disarm +
  `isOnboardingVisible` callback.
- NEW `Tests/MacParakeetTests/Onboarding/OnboardingHotkeyPreviewControllerTests.swift`

## Tests

Fakes for overlay (records show/hide), mic leveling (emits levels), suspend/resume
counters; empty plan provider so no real CGEvent taps are created.

1. arm→suspend once; disarm→resume once; double arm/disarm idempotent + balanced.
2. beginPreview shows overlay + starts mic; endPreview hides overlay + stops mic.
3. mic level → `audioLevel` updates.
4. disarm while previewing hides overlay + resumes (no leak).
5. beginPreview without arm is a no-op.

## Out of scope / invariants

- No STT, paste, history, or DB writes from the preview, ever.
- Don't change production dictation behavior outside the onboarding-visible gate.
- Don't block onboarding progression on mic/accessibility state.
