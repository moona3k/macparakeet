# Issue 1079: Transcribe tile stuck on “Wrapping up…”

Date: 2026-09-17. Investigation of
[issue #1079](https://github.com/moona3k/macparakeet/issues/1079). In-app
feedback from MacParakeet 0.8.4 (`d232ab095df7`).

## Verdict

Valid user-visible hang. Not a capture or transcription stall. The Transcribe
tab tile stays on **Wrapping up…** because `.completing` can only leave via the
floating pill’s collapse-animation callback, and `advanceToSavedCheckmarkIfReady`
refuses to resolve the saved celebration unless the pill is already
`.transcribing`. If that callback never fires, the long-lived tile never returns
to idle — even after mix, queue, and finalize have succeeded.

This is a **regression of the hideable-pill work** (#723, `894c79f3`) against the
saved-completion flourish (#587, `ba98a36d`). 0.8.4 still contains the hang.

## Reporter evidence

| Field | Value |
| --- | --- |
| App | 0.8.4 (`20260917043813`), commit `d232ab095df7` |
| macOS / chip | 26.6.2, Apple M3 Pro |
| Report | “„Wrapping up“ on Transcript Page never stop.” |
| Screenshot | Transcribe tab meeting tile, spinner + “Wrapping up…” |
| Diagnostic log | `diagnostics/1789651946989-dictation-audio.log` |

The attached log is a multi-day dictation/meeting diagnostic. The incident
session is the last 0.8.4 process:

| Time (UTC) | Event |
| --- | --- |
| 11:42:13 | App start, pid `67757`, 0.8.4 / `d232ab095df7` |
| 11:42:19 | Meeting `6FDBC5DB-…` started (mic+system, Whisper large-v3 turbo) |
| 12:00:45 | Stop requested; capture stop succeeded in 27 ms |
| 12:00:56 | Mix finished in **10,271 ms**; service stop 10.4 s; row queued |
| 12:02:03 | Cleaned-mic render finished |
| 12:03:44 | `finalize_transcript` success in 168 s; `settle_artifacts` success |
| 13:32:28 | Issue filed, same process still alive (`shared_mic` config change at 13:24) |

So wrapping-up was still on screen **~90 minutes after finalize completed**.
Audio capture, mix, queue, diarization, and transcription all succeeded. The
stuck surface is UI state, not the pipeline.

Earlier 0.8.4 meetings the same day show the same stop/mix/queue shape, with mix
cost growing with duration (17 s for a 30 min meeting, 35 s for a 90 min
meeting). Long mix is expected; an hour-plus “Wrapping up…” is not.

## Root cause

The Transcribe tile binds the long-lived `MeetingRecordingPillViewModel` and
renders:

```swift
Text(viewModel.state == .completing ? "Wrapping up…" : "Transcribing…")
```

Stop emits `.showTranscribingState`, which sets `.completing` and waits for
`onCompletionAnimationFinished` before moving to `.transcribing`. That callback
is fired only by:

- `MeetingRecordingPillController.playCompletionIfNeeded` (AppKit pill)
- `FlowerCompletionView` in the unused SwiftUI `MeetingRecordingPillView`

`refreshState()` is documented as a **no-op once the pill is hidden**. Hide
nil’s `pillView`. Users who turn off **Show floating meeting controls**, or any
path that has already `orderOut`’d the pill (quit-time dismiss, visibility
refresh), never run the collapse. The tile has no equivalent callback.

After queueing, `.showSavedCompletion` calls `advanceToSavedCheckmarkIfReady()`,
which returns immediately unless:

```swift
pillViewModel.state == .transcribing && meetingDurablySaved && metatronBloomSettled
```

`metatronBloomSettled` is only set from `startMetatronMinimumDisplay()`, which
only runs from the animation callback. Result: durable save cannot unstick
`.completing`. The tile keeps the spinner and hides Start, so the user cannot
self-recover from the Transcribe page. The flow state machine is already
`.idle`, so a *new* recording from the menu bar would overwrite the pill VM —
the tile path cannot.

## Why this is a regression

| Change | What it did |
| --- | --- |
| #587 meeting-saved flourish | Gated `.completing` → `.transcribing` on the pill collapse (~1 s CA animation) so the Metatron bloom could follow. |
| #723 hideable meeting controls | Allowed the floating pill to be hidden while the Transcribe tile remains the control surface. `refreshState()` became a no-op when hidden. No alternate completing path. |
| 0.8.4 / this report | Tile-first (or pill-hidden) stop still depends on the hidden animation. |

Existing coordinator tests cover *start* with the pill hidden, not *stop*. Most
stop tests use `testHook_enterRecording()`, which skips `.showRecordingPill`
entirely, so they never assert the pill VM leaving `.completing`.

## Must not change

- Capture stop, mix, queue, and background finalize behavior.
- Back-to-back recording: the flow still returns to `.idle` as soon as the row
  is queued.
- Visible-pill flourish: collapse → Metatron hold → checkmark → self-dismiss.
- Error / cancel teardown.

## Fix

Leave `.completing` without waiting on a window that is not on screen:

1. Always enter `.completing`, then immediately finish it when the floating pill
   is hidden so a late collapse callback cannot yank a later live recording into
   `.transcribing`.
2. If the pill is visible, keep the ~1 s collapse, plus a 2 s fallback so a
   missed CA callback or quit-time window teardown cannot deadlock the tile.
3. Cancel that fallback on a new recording, error, or teardown. The finish
   path only advances from `.completing`.

## Checks

- Diagnostic log: pipeline completed; no `meeting_stop_stage outcome=failure`.
- Code: completing→transcribing is animation-gated; saved checkmark requires
  `.transcribing`.
- History: flourish predates hideable pill; hidden-stop is untested.
- Unverified in this pass: the reporter’s exact Settings value for the floating
  pill. The hang also reproduces with no pill window at all (test hook / quit
  dismiss), so the Settings value is not required to prove the defect.
