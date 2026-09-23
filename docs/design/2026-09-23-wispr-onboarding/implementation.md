# First-run onboarding: implementation design

Date: 2026-09-23. Status: **implemented** in the branch that adds this file.
Governing decision: [ADR 005](../../../spec/adr/005-onboarding-first-run.md), amendment 2026-09-23.
Visual spec: [note.md](./note.md) and its stills.
Evidence: [onboarding activation leak](../../research/2026-09-18-onboarding-activation-leak.md).

This file records how the locked note became code, and the choices the note left open.

## The problem in one line

People finish setup without pressing the hotkey. The old flow ended with a tip list, so "You're all set" was the last thing many users saw. The fix is to make the first real dictation happen inside the onboarding window, and to use the model download time for the key rehearsal instead of a separate waiting step.

## Flow

| # | Step (`Step`) | Telemetry `step` | Continue gate |
|---|---|---|---|
| 1 | Welcome (`.welcome`) | `welcome` | none |
| 2 | Permissions (`.permissions`) | `permissions` | Accessibility granted. The microphone may be skipped. |
| 3 | Try It (`.practice`) | `practice` | Key phase: one key has lit. Box phase: a dictation delivered non-empty text into the box. **Skip** always leaves this step. |
| 4 | All Set (`.done`) | `ready` | Finish writes completion and closes the window. |

Removed: the separate Microphone, Accessibility, and Speech Model steps, the "Try it now" caption, and the off-card overlay rehearsal.

The speech model warm-up still starts when the window opens (ADR 005, 2026-06-14). Its progress is shown in two places: a small status line in the sidebar on every step, and inside the dictation box on step 3.

## Step 2: one permissions page

Two rows. Each row is titled by what the app will do, not by the macOS privilege name.

- **Hear you while you dictate** (Microphone). Detail: only while the dictation key is active. Skippable. If it is denied, the row offers Open Settings.
- **Use your dictation key and type into any app** (Accessibility). Required. Allow calls `AXIsProcessTrustedWithOptions(prompt: true)`, so the macOS prompt appears over this page. The existing 2-second poll flips the row to granted when the user returns from System Settings.

When both rows are granted, the headline becomes a privacy thank-you. When only Accessibility is granted, the primary button reads "Continue without microphone", as before.

## Step 3: the key card and the dictation box

One screen, two cards.

### Key card

The card draws the configured hands-free key and the push-to-talk key. With the default shared gesture both caps are the Fn key, captioned "Double-tap" and "Hold".

Lighting is driven by the same `HotkeyManager` gesture machine that production uses, through `OnboardingHotkeyPreviewController`:

- `onStartRecording(.holdToTalk)` lights the push-to-talk cap. Release (`onStopRecording`) returns it to rest.
- `onStartRecording(.persistent)` lights the hands-free cap. The next tap, or Escape, returns it to rest.
- AI-polish and clipboard-only extra triggers are not armed during rehearsal, so they cannot light the wrong cap.

This rehearsal never records, never touches STT, and runs while the model downloads. It proves two things: the Accessibility grant reaches the event tap, and the binding resolves the way production will resolve it. The 0.8.0 Fn-ledger bug ([first-run regression](../../research/2026-09-18-08-first-run-regression.md)) is the kind of failure this surfaces on the first screen that can see it.

Continue on this phase stays disabled until one cap has lit once (`hasLitHotkey`). Pressing Continue moves the screen to the box phase. It does not change steps.

**Edit shortcut** opens a sheet with the production `HotkeyRecorderView` rows for push-to-talk and hands-free, the same conflict validation Settings uses, and Reset to default. While a recorder is capturing, the rehearsal taps and the production taps both stand down (the same suspension Settings uses). When the sheet changes a binding, the rehearsal rebuilds its taps from the new plan and the caps redraw.

If neither dictation key is set, the card says so and points at Edit shortcut. Skip stays available.

### Dictation box

The box is a real text view in the onboarding window. It has five visible states (`PracticeBoxState`):

1. `loading(message, progress)`: the speech model is not ready. Progress is drawn where the text will appear. The box cannot be focused.
2. `failed(EngineFailure)`: the warm-up failed. The box shows the message, the recovery tips, Retry, and Open Settings. Skip stays available, so a failed download cannot trap onboarding.
3. `waitingForKey`: the model is ready, but the key phase is not done. The box says to press the key above first.
4. `clickToStart`: model ready and key confirmed. The box says "Click here". Nothing records on its own.
5. `listening`: the user clicked. The box has focus and shows the gesture for the key they just proved. The key cap inside the box lights while a real dictation is recording.

Once a dictation delivers text, the words stay in the box, Try again clears it, and Continue unlocks.

### How the text lands

The practice dictation is the production dictation flow, not a copy of it. `isPracticeListening` becomes true only in state 5. While it is true:

- `DictationFlowCoordinator.isStartSuppressed` lets starts through (it still blocks them for every other onboarding state).
- The rehearsal controller is disarmed, which resumes the production hotkey taps. The production tap and a rehearsal tap never own the same key at once.

The user's key starts the real capture, the overlay pill, STT, text processing, and paste. Paste posts Cmd+V to the key window. That window is onboarding, and the box is its first responder, so the words land in the box. This exercises the Accessibility grant for paste, which is the second thing the grant exists for.

`DictationFlowCoordinator` gains two observer hooks: `onFlowStateChanged` (drives the lit cap inside the box and the "Listening" / "Transcribing" line) and `onDictationDelivered(text)` (fires after a successful insert or copy). The view model records the transcript as the practice result. If the box still does not contain that text after a short grace period (a slow or failed paste, or a clipboard-only trigger), the view model appends it. A dictation that succeeds therefore always shows up in the box, and Continue never waits on a paste race.

The practice dictation is a real dictation. It is saved to history and emits normal dictation telemetry, with `pastedToApp` set to MacParakeet.

Once the box has started listening, the rehearsal is not re-armed while the user stays on this screen, so an in-flight hold-to-talk can never lose its release event to a suspended tap. Leaving the step (Back, Skip, Continue) does not suspend production taps either; the next step never arms rehearsal.

## Step 4: All Set

- After a practice dictation: "Your first dictation worked", with the words quoted back.
- After Skip: a plain line that dictation is ready whenever they are. If the model was not ready, the line says it is still getting ready and where to check.
- One line points at the frontmost app: close this window, click into any text field, and use the key there.
- **Finish** writes the completion timestamp and closes the window. It no longer opens the main window.

No hours-saved claim, no speed claim, no referral.

## Telemetry

No new event names. `onboarding_step` gains step names and actions:

- Steps: `welcome`, `permissions`, `practice`, `ready`. The old `microphone`, `accessibility`, `hotkey`, and `speech_model` names stop on new builds.
- New actions: `hotkey_confirmed` (Continue after a lit key), `practice_succeeded` (first delivered practice text), `practice_skipped` (Skip on step 3).
- `engine_ready` and `engine_failed` are now emitted on whichever step the user is on when the warm-up settles, with `engine_state`. Previously `engine_failed` was sent only when the failure landed on the Speech Model step, so head-start failures were undercounted.

`total_steps` drops from 6 to 4, so step-index comparisons across versions need `app_ver`. The public stats funnel still groups by legacy labels (see the leak note); mapping the new names is a website follow-up.

## Must not change

- Warm-up starts at window open, is idempotent, and does not disable permission buttons (`engineBusy` separate from `isBusy`).
- The Parakeet-vs-Whisper fork for CJK locales.
- Microphone is skippable. Accessibility is required.
- The completion key, re-run semantics (`hasCompletedCurrentRun`), and the incomplete-close confirmation.
- Escape cancels, and the undo window is unchanged. The practice dictation uses the real flow, so both behave exactly as they do in any other app.
- No meeting audio, screen recording, calendar, sign-in, survey, referral, or fake third-party app chrome.

## Deferred

- The after-close tip near the menu bar.
- A job picker after the drill.
- Mapping the new step names in the public stats funnel.
