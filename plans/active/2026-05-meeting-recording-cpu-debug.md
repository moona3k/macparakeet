# Meeting Recording CPU Debug Notes

Date: 2026-05-29

## Problem

After the v0.6.14 Meetings update, the Meetings workspace and hover states felt
laggy while a meeting recording was active.

## Release Safety Action

- Pulled the 0.6.14 Sparkle update from the public appcast.
- Hid the GitHub `v0.6.14` release as a draft.
- Current public appcast was verified back on `0.6.13`.

## Measurements

All CPU numbers below are from debug/dev builds unless noted.

- Released app while recording and visible: roughly 38-60% CPU.
- Current dev app, recording active, original animated pill/tile: roughly
  40-70% CPU, with spikes higher.
- Idle dev app after restart: roughly 0-1% CPU.
- Recording active with the floating pill suppressed: roughly 13-14% CPU.
- After removing the Transcribe tile's idle SwiftUI `repeatForever`, idle on
  the Transcribe page stayed at roughly 0% CPU.
- After making the active recording pill AppKit/Core Animation backed and
  removing repeat-forever/numeric animations from the retained main-window
  meeting tile:
  - Meeting recording with main window visible: roughly 25-28% CPU in the best
    repeatable run.
  - Meeting recording with main window closed and its hosting view released:
    roughly 11-18% CPU.
  - Dictation startup/warm-up: roughly 30-31% CPU for the first few seconds.
  - Dictation after settling: roughly 5-11% CPU.
- Memory stayed low throughout, roughly 0.3-0.6%; this is a CPU/rendering
  issue, not a RAM issue.

## Samples

Repeated `sample <pid> 5` captures showed the hot path was mostly main-thread
SwiftUI/AppKit display/layout work:

- `NSHostingView.layout`
- `ViewGraphRootValueUpdater.render`
- `DisplayList.ViewUpdater...`
- `NSWindow layoutIfNeeded`
- `CA::Transaction::commit`

The hot samples did not point at VAD, STT, or the audio capture service as the
primary CPU consumer.

## Experiments

1. Quantized audio-level display updates and changed pill polling from 150 ms to
   1 second.
   - Result: reduced observable churn but did not solve the high CPU.

2. Froze the Meetings page flower animation while keeping the floating pill.
   - Result: CPU stayed high during real recording.
   - Interpretation: the large Meetings page tile is not the main culprit.

3. Froze both the Meetings page flower and floating pill flower animation.
   - Result: CPU still stayed high during real recording.
   - Interpretation: the whole floating pill SwiftUI/window render surface, not
     only the explicit flower rotation, is involved.

4. Suppressed the floating pill window entirely while recording.
   - Result: CPU dropped to roughly 13-14%.
   - Interpretation: baseline recording capture is nontrivial but acceptable;
     the floating pill window/render path adds most of the regression.

5. Shrunk the floating pill panel from 240x150 to 118x150.
   - Result: CPU stayed high.
   - Interpretation: transparent panel area alone is not enough to explain the
     overhead.

6. Replaced the flower glyph with a Core Animation-backed `NSViewRepresentable`.
   - Result: CPU stayed high with the pill visible.
   - Sample still showed `NSHostingView.layout` and
     `DisplayList.ViewUpdater...` as the hot path.
   - Interpretation: the explicit flower animation is not sufficient as the
     root cause. The active floating pill being hosted/rendered through SwiftUI
     is the expensive surface.

7. Removed idle breathing from `SacredFlowerTile`.
   - Result: idle CPU on the Transcribe page dropped from roughly 55% to 0%.
   - Interpretation: an always-on SwiftUI `repeatForever` in a retained main
     window can make the whole app feel hot even when no recording is active.

8. Removed the Transcribe tile recording dot pulse, elapsed numeric transition,
   paused opacity animation, and audio-level glow animation.
   - Result: recording with the main window visible improved into roughly the
     30% range, but not all the way to the no-pill baseline.
   - Interpretation: these were contributing, but another SwiftUI live panel
     animation was still active.

9. Changed the main window close path to release the `NSHostingView` and clear
   `mainWindow`.
   - Result: recording with the main MacParakeet window closed dropped to
     roughly 11-18% CPU.
   - Interpretation: before this, a closed main window was still retaining and
     rendering SwiftUI content. Closing the window must actually tear down the
     retained hosting tree.

10. Sampled the remaining high visible-window recording case.
    - Result: samples pointed at `BreathingSeedOfLifeView` in
      `MeetingRecordingPanelView.swift` through `TimelineView(.animation)`,
      `NSHostingView.layout`, and `DisplayList`.
    - Interpretation: the live meeting panel/main window still has a SwiftUI
      timeline animation path when visible. That is separate from the system
      audio/screen capture baseline.

11. Compared meeting recording to dictation.
    - Meeting recording closed-window baseline: roughly 11-18% CPU.
    - Dictation after startup settles: roughly 5-11% CPU.
    - Interpretation: system audio/screen capture does carry a real extra CPU
      cost compared with microphone dictation, but the original 50-70% behavior
      was not inherent to capture. It was capture plus SwiftUI render churn.

## Current Hypothesis

There are two distinct costs:

1. Baseline meeting capture cost: system audio/screen capture while recording
   appears to cost roughly low-teens CPU in this debug build when the main
   SwiftUI window is closed and released. This is higher than settled dictation
   because dictation is microphone-only.

2. SwiftUI live-surface cost: visible or retained SwiftUI meeting surfaces
   (`SacredFlowerTile`, `BreathingSeedOfLifeView`, numeric/opacity transitions)
   can drive `NSHostingView.layout` and `DisplayList` work repeatedly. This was
   the source of the original 50-70% CPU behavior and hover lag.

The current preferred fix is:

- Keep the floating recording pill animated, but keep its animation in AppKit /
  Core Animation rather than SwiftUI.
- Keep the main window's meeting flower static during active recording.
- Ensure closing the main window releases its SwiftUI hosting tree.
- Audit visible meeting panel animations, especially `BreathingSeedOfLifeView`,
  before re-release.

## Constraints

- The floating recording pill should continue to animate.
- The Meetings page flower can remain static if needed.
- Do not proceed with a release until this CPU issue is fixed and re-QA'd.

---

# Root Cause (confirmed) — 2026-05-29

The investigation above localized the cost empirically; here is the mechanism it
points at, stated precisely.

**Any continuously-animating SwiftUI view does per-frame work _in the app
process_.** A `repeatForever` animation or a `TimelineView(.animation)` asks
SwiftUI to produce a new frame on every display refresh. Each frame, SwiftUI
re-evaluates `body`, diffs the view tree, rebuilds the `DisplayList`, and commits
a Core Animation transaction through the bridging `NSHostingView`. That is
exactly the hot path the samples show:

```
NSHostingView.layout
ViewGraphRootValueUpdater.render
DisplayList.ViewUpdater...
CA::Transaction::commit
```

This cost is paid by the **main thread**, for as long as the animation is on
screen. Three things made it severe here:

1. **Residency.** The floating pill, the retained main-window meeting tile, and
   the live meeting panel watermark are each on screen for the *entire* duration
   of a recording — minutes, not a transient spinner.
2. **Multiplicity + refresh rate.** Several such surfaces were co-resident, and
   on a 120 Hz ProMotion display each one re-renders up to 120×/second. They
   add up to the observed 50–70%.
3. **Per-frame offscreen passes.** The breathing glow animated a SwiftUI
   `.shadow()` (re-blurred every frame), the tile glow recomputed a
   `RadialGradient`, and `rotationEffect` re-composited the rotated subtree each
   frame.

**Core Animation is categorically different.** A `CABasicAnimation` on a
`CALayer` is declared once and then **interpolated by the render server**
(WindowServer), not by the app. The app process does ~0 per-frame work; the
animation keeps running even if the main thread is busy. This is why migrating
the pill to `MerkabaPillIconView` (CALayer) worked, and it is the same fix for
the remaining surface.

> **The rule:** never drive a *continuous* animation with SwiftUI
> (`repeatForever` / `TimelineView(.animation)`) inside an **always-resident**
> window. Use `CALayer` + `CABasicAnimation` so interpolation happens off the
> app's main thread. Transient indicators (a few-second spinner) are fine in
> SwiftUI; resident ones are not.

This is the **second** occurrence of this exact class of bug. PR #107 ("idle
CPU/GPU fix") was the first — four `repeatForever` animations in an idle
surface. See "Recurrence guard" below.

## Resolution — 2026-05-29

Completes the prior agent's in-flight work (AppKit pill, window-release on close,
tile de-animation, polling quantization) and fixes the one remaining live
culprit from Experiment #10.

| File | Change |
|---|---|
| `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPanelView.swift` | **`BreathingSeedOfLifeView` migrated from SwiftUI `TimelineView(.animation)` to an `NSViewRepresentable` + CALayer (`BreathingSeedOfLifeNSView`).** Rotation/breathing now run as `CABasicAnimation`s on the render server. `freeze` uses the canonical CA pause (`layer.speed = 0` + `timeOffset`) — the clean external pause the old `TimelineView(paused:)` comment was reaching for. `reduceMotion` renders a still rosette. Public API (`BreathingSeedOfLifeView(freeze:)`) unchanged, so all three call sites (transcript watermark, live-notes watermark, summary skeleton) are fixed with no call-site edits. |
| `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPillController.swift` | **Restored Reduce Motion** on the AppKit pill (the CA migration had dropped it — the old SwiftUI pill gated on `!reduceMotion`). Reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, observes `accessibilityDisplayOptionsDidChangeNotification`. **Compacted the black capsule** from 54×106 → 54×86 (it had ~20pt of dead space above/below the flower); centered on the panel midY so the icon position is unchanged. |
| `Sources/MacParakeet/Views/Transcription/MeetingRecordingTile.swift` | **Removed dead animation machinery** from `SacredFlowerTile` (both call sites already passed `isAnimating: false`, so the `rotation`/`sway` `@State`, `startActive`/`stopActive`, and `onChange`/`onAppear` never ran). Now a clean static rosette; the audio-reactive glow (quantized to ~1 Hz upstream) is the only live element. Dropped the unused `reduceMotion` env var. |

These build on the already-applied WIP:

- `AppWindowCoordinator.windowWillClose` clears `contentView` and `mainWindow`
  so closing the main window tears down the retained SwiftUI hosting tree
  (Experiment #9).
- `MeetingRecordingFlowCoordinator` pill poll slowed 150 ms → 1 s and now writes
  view-model fields only on change, with audio levels quantized to 0.05 steps
  (`displayLevel`). This removes per-tick view-model churn that re-rendered the
  observing SwiftUI surfaces.

## Additional findings during the fix

1. **`BreathingSeedOfLifeView` had two meeting consumers, not one.** Experiment
   #10 named only `MeetingRecordingPanelView`. It is also the watermark in
   `LiveNotesPaneView` (and the `SummarySkeletonView` loading state). A
   per-call-site "freeze during recording" patch would have missed the notes
   pane; the shared CA migration fixes all three at once.
2. **The Reduce Motion regression.** Migrating the pill to CALayer silently
   dropped the `!reduceMotion` gate the SwiftUI pill had. Every other animated
   surface in the app honors Reduce Motion; the pill now does again.
3. **Dead code from the iteration.** `SacredFlowerTile`'s animation path was
   dead. Also: the old SwiftUI pill **`MeetingRecordingPillView`** (in
   `MeetingRecordingPillView.swift`) is now unreferenced — superseded by
   `MeetingRecordingPillController`/`MeetingRecordingAppKitPillView`. It is left
   in place for now (the file also houses `MeetingCompletionCheckmarkView` and
   other helpers that need an audit before deletion). **Follow-up:** confirm and
   delete the dead pieces. See CLAUDE.md "delete old code entirely."
4. **The capture baseline is genuinely near-minimal.** Hypothesis #1 (system
   audio/screen-capture costs low-teens CPU) is not bloated by stray video
   frames: `SystemAudioStream.swift` already configures ScreenCaptureKit at
   `width = 2, height = 2, minimumFrameInterval = 1s` (the standard audio-only
   trick). The low-teens floor is inherent to the SCStream + mixing pipeline; no
   easy win there. Documented so nobody re-investigates it.

### Pill capsule compaction (before / after)

The floating capsule was 54×106 with ~20pt of dead space above and below the
flower. Compacted to 54×86, centered on the panel midY so the rosette/stem and
pause-bars don't move — only the black surface tightens. Tuned with an offscreen
render harness that compiles the real `MerkabaPillIconView`.

![Pill capsule before/after and paused state](assets/2026-05-pill-compaction.png)

## Measurement caveat: debug vs release

**Every CPU number in the "Measurements" section above is from a debug/dev
build** (`-Onone`, no optimization). Debug builds inflate Swift + SwiftUI/AppKit
render cost substantially, so the absolute percentages are **not** the numbers
real users see, and the debug experiment results cannot be compared 1:1 with the
released-build figure (38–60%). The relative deltas between experiments are
still informative (they isolate which surface mattered), but the **acceptance
gate must be a release-build measurement**, not a debug one.

This environment (headless agent) cannot reproduce the GUI render path — the
cost only appears with windows actually compositing during a real recording,
which needs a logged-in display session plus Mic + Screen Recording TCC grants.
The CLI meeting path is headless and does not exercise SwiftUI/AppKit at all, so
it cannot validate the fix. The numbers below must therefore be captured
manually on-device.

## Verification matrix (owner — required before re-release)

Build a **Release** configuration (`swift build -c release` / a signed dev
bundle), start a real meeting, and capture CPU from Activity Monitor (note the
display refresh rate — ProMotion 120 Hz vs 60 Hz materially changes the number).

| Scenario | Expectation |
|---|---|
| Idle after launch (Transcribe tab visible) | ~0–1% |
| Recording, main window **closed** | low-teens (capture floor) |
| Recording, main window **visible**, live panel on **Transcript** tab | should now be close to the closed-window floor — **this is the case Experiment #10 regressed and the BreathingSeedOfLifeView migration targets** |
| Recording, live panel on **Notes** tab | same — `LiveNotesPaneView` watermark is now CA too |
| Recording, **paused** | rosette frozen (pill + panel), CPU drops further |
| Reduce Motion ON, recording | pill + panel rosettes static; no spinning |
| Dictation after settle (comparison) | ~5–11% |

Visual QA (the fix changes how animations are produced, so confirm they still
look right):

- [ ] Floating pill rosette still rotates smoothly; pause freezes it cleanly and
      resume continues from the same frame (no snap-forward).
- [ ] Compacted capsule (54×86) looks balanced — see PR screenshots.
- [ ] Live panel / notes watermark rosette breathes + rotates as before; fades to
      a faint watermark when transcript/notes text appears.
- [ ] Summary skeleton (`SummarySkeletonView`) still animates.
- [ ] Reduce Motion: all rosettes render as a calm still flower.

## Recurrence guard (proposed)

This is the second time a SwiftUI continuous animation in a resident surface
caused a CPU regression (PR #107 was the first). Cheap guard worth adding:

- A grep/CI check (or a documented review rule) flagging `repeatForever` and
  `TimelineView(.animation)` introduced in always-resident window surfaces
  (meeting pill/panel/tile, main window chrome), steering them to CALayer.
- The rule is now stated at the top of `BreathingSeedOfLifeView` and
  `MerkabaPillIcon` so the next person porting a rosette sees it.

## Remaining follow-ups

- [ ] **Owner:** run the release-build verification matrix above; only re-release
      if the visible-window recording case is at/near the closed-window floor.
- [ ] **Owner:** check telemetry for how many users already auto-updated to
      0.6.14 before it was pulled (blast radius for the regression).
- [ ] Delete the dead `MeetingRecordingPillView` (after auditing co-located
      helpers in that file).
- [ ] Consider the CI/lint recurrence guard above.
