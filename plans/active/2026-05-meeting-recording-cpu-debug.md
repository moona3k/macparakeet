# Meeting Recording CPU Debug Notes

Date: 2026-05-29

> **Owner correction (2026-05-29):** this is **not a v0.6.14 regression.** The
> meeting-recording animations (and their CPU cost) have existed since the
> feature shipped — the cost was *surfaced/noticed* around the v0.6.14 Meetings
> work, not introduced by it. Treat everything below as "a long-standing CPU
> cost we investigated and fixed," not "a regression we caught in one release."
> The engineering findings stand regardless of which release first exposed them.

## Problem

While a meeting recording was active, the Meetings workspace and hover states
felt laggy. (Noticed around the v0.6.14 Meetings update; the underlying
animation cost predates it — see correction above.)

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
| `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPillController.swift` | **Restored Reduce Motion** on the AppKit pill (the CA migration had dropped it — the old SwiftUI pill gated on `!reduceMotion`). Reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, observes `accessibilityDisplayOptionsDidChangeNotification`. **Compacted the black capsule** from 54×106 → 54×86 (it had ~20pt of dead space above/below the flower); centered on the panel midY so the icon position is unchanged. **Restored the hover-time badge** (red dot / amber when paused + live `formattedElapsed`, in a dark capsule above the pill) — the CA migration had dropped the prior SwiftUI pill's hover affordance. CALayer-based (`timeBadgeLayer`/`timeDotLayer`/`timeTextLayer`), fades in on hover, refreshes each second. |
| `Sources/MacParakeet/Views/Transcription/MeetingRecordingTile.swift` | **Removed dead animation machinery** from `SacredFlowerTile` (both call sites already passed `isAnimating: false`, so the `rotation`/`sway` `@State`, `startActive`/`stopActive`, and `onChange`/`onAppear` never ran). Now a clean static rosette; the audio-reactive glow (quantized to ~1 Hz upstream) is the only live element. Dropped the unused `reduceMotion` env var. |
| `Sources/MacParakeet/Views/Meetings/MeetingsView.swift` | **Isolated the live status chip** (`MeetingsLiveStatusChip`). `MeetingsView.body` read `meetingPillViewModel.formattedElapsed` (via `headerStatusTitle`), so every 1 s elapsed tick re-evaluated the *entire* body — including the meetings-list `ForEach` — forcing a full-tree `sizeThatFits`/layout pass while recording. **This was the actual "laggy Meetings workspace while recording" symptom from the original report** (see on-device session below). Moving the `formattedElapsed` read into its own leaf view scopes the per-second invalidation to the chip. |

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

### Pill capsule compaction + hover-time badge (before / after)

The floating capsule was 54×106 with ~20pt of dead space above and below the
flower. Compacted to 54×86, centered on the panel midY so the rosette/stem and
pause-bars don't move — only the black surface tightens. The hover-revealed
elapsed-time badge (red dot / amber + timer) was also restored — it existed on
the prior SwiftUI pill and was dropped in the CALayer migration. Tuned with an
offscreen render harness that compiles the real `MerkabaPillIconView`.

![Pill: before, compacted, compacted+hover-time, paused+hover-time](assets/2026-05-pill-compaction.png)

**Regression check vs PR #204 (issue #200 — tooltip wrapping past 99:59).** PR
#204 fixed the *old SwiftUI* pill's elapsed tooltip wrapping to two lines past
`99:59` (e.g. `114:44`). That pill is now dead code, so the fix had to be
re-established in the new CALayer badge. It is, and more robustly: `isWrapped =
false` plus the badge/text width are computed from the *measured* text width
(the original bug was the tooltip being constrained to the pill's narrow width).
Verified single-line at `114:44` and `999:59`:

![Hover badge at long durations: 0:17, 12:34, 114:44 (#200), 999:59](assets/2026-05-pill-hover-longtimes.png)

## Live on-device measurement session — 2026-05-29 (agent, debug build)

Driven on-device via `scripts/dev/run_app.sh` + AppleScript (menu-bar
"Capture ▸ Start Recording" / "Go ▸ Meetings"), sampled with
`top -l N -s 1 -pid` and `sample <pid>`. **Debug build, dev hardware** — see the
caveat below; the absolute % is inflated, the *deltas + profile change* are the
proof. VAD live-chunking is flag-on, so the recording floor includes VAD + STT
preview work.

| Scenario | CPU (settled) | Notes |
|---|---|---|
| Idle (menu-bar, no window) | **0.0%** | clean |
| Recording, **pill only** (no main window) | **~19–21%** | capture + VAD + animated CALayer pill — the floor |
| Recording, **Meetings workspace visible** — *before* `MeetingsView` fix | **~25–46% sustained** (never settled) | reproduces the reported lag. `sample`: per-display-cycle `NSWindow layoutIfNeeded` → recursive `NSHostingView.layout` → **`MeetingsView.body` / `MeetingRowCard.body` / `LayoutEngineBox.sizeThatFits` storm** |
| Recording, **Meetings workspace visible** — *after* `MeetingsView` fix | **~15–18%** (brief ~24% blips on transcript chunks) | back at the pill floor. `sample`: **no more `MeetingsView.body` / `MeetingRowCard.body`** — residual `sizeThatFits` is ScrollView content re-measure when the live tile ticks (legitimate live work) |

### Coverage vs the requested 4-measurement checklist

The handoff asked for four measurements. Status this session (debug build, on-device):

- ✅ **Idle after restart** — 0.0%.
- ✅ **Recording, main window visible** — ~15–18% after the `MeetingsView` fix (was ~25–46%).
- ✅ **Recording, main window closed** — the "pill only" row (~19–21%); the main window was not open.
- ⚠️ **Settled dictation (for comparison)** — *not re-measured this session, by choice.* Triggering dictation via automation pastes the transcript into whatever app has focus (a side effect I won't impose on a live session), and a meeting recording was concurrently active (ADR-015), which would both contaminate the number and risk stray text insertion. The prior agent's figure stands as the comparison: **~5–11% settled (debug)**. The owner should confirm it in the release-build pass.

**Note on the band/noise.** The pill-only (~19–21%) and window-visible-after-fix (~15–18%) figures overlap inside one **~15–21% "capture + VAD + pill" floor band** — the ±several-% spread is debug-build noise plus transcript-chunk timing (VAD live-chunking is flag-on). The result that matters is qualitative and robust: window-visible dropped *out of* the ~25–46% regression range and *into* that floor band, and the `sizeThatFits` storm is gone from the profile.

**Root cause #2 (the reported symptom).** The original complaint was "the
Meetings workspace and hover states felt laggy *while a meeting recording was
active*." That is **not** an animation — it is `MeetingsView.body` re-evaluating
on every 1 s elapsed tick. `body` read `meetingPillViewModel.formattedElapsed`
(through the inlined `headerStatusTitle` computed property), so the per-second
elapsed update invalidated the whole body and re-laid out the entire meetings
list (`ForEach` of `MeetingRowCard`s) — only while recording, because that is
when elapsed ticks. Hover felt laggy because every second the list re-layout
competed with hover feedback. Fixed by extracting `MeetingsLiveStatusChip`, a
leaf view that owns the `formattedElapsed` read so the tick re-renders only the
chip. Verified: ~46% → ~17%, and the `sizeThatFits` storm rooted in the list is
gone from the profile.

This is a third instance of the same family as Root Cause #1, but a different
mechanism: not a continuous animation, but **a frequently-mutated `@Observable`
read high in a `body` that also contains an expensive subtree.** General rule:
keep a fast-ticking observable read (elapsed timer, audio level) in the smallest
possible leaf view; never read it in a `body`/computed-property that also builds
a list or other heavy layout.

## Continued session — settled dictation (live log, 2026-05-29)

Attempted the 4th checklist item; partially completed, then aborted on owner redirect.

- **Stopped the lingering dev-app meeting.** Final meeting transcription ran as a transient (~28–42% for a few seconds), then the app settled to a **clean baseline of ~0.1–0.5%** (no meeting, no dictation) — a fresh on-device confirmation that idle is ~0%.
- **Dictation comparison: deprioritized by the owner (2026-05-29) — "no need… this doesn't need testing rn."** It was never the regression surface (this work is all meeting-recording UI), so a dictation number isn't required to validate the fix. The prior agent's **~5–11% settled** figure stands as the rough comparison. (Capturing a live dictation number needs a human anyway, since dictation pastes into the focused app.)

## Restore the pill's lost richness — IMPLEMENTED (2026-05-29)

The owner observed the AppKit/CALayer pill had dropped richness the old SwiftUI
pill (`MeetingRecordingPillView`, now dead code) had, and correctly intuited the
pill was never the main CPU hog. Both were right — so the richness was restored
**in CALayer**, where it's nearly free.

**What was lost, and is now back:**

1. **Live audio-responsive glow** — the rosette's internal light intensifies with
   mic/system level. The old pill pushed `audioLevel` through SwiftUI at the
   shipped **150 ms** poll cadence; the CPU-fix branch had slowed the pill poll to
   **1 s + quantized 0.05 steps**, so the glow barely breathed.
2. **Completion flourish** — old `.completing` used `FlowerCompletionView`
   (flower accelerates, petals collapse, leaves drift, stem retracts, glow warms
   green→gold), `.transcribing` used a merkaba spinner, `.completed` used a
   ring-draw checkmark. The CALayer pill had a generic 0.6 s callback and a static
   rosette for transcribing/completed.

**Why the old pill cost anything:** the rosette rotation was *already* CALayer
even in the old pill — cheap. The cost was the SwiftUI *wrapper* re-rendering at
audio cadence plus `.ultraThinMaterial`/shadows. **The richness was never the
cost; the SwiftUI re-render path was.** So porting the richness to CALayer keeps
it.

**What shipped (PR #396):**

- **`MerkabaPillIconView` now owns four lifecycle "faces"** in one view — rosette
  (recording/paused), collapse, merkaba spinner, checkmark — so transitions read
  as the *same mark* transforming in place. New API: `setLiveGlow(level:)`,
  `playCompletion(reduceMotion:onFinished:)`, `showSpinner(animated:)`,
  `showCheckmark(animated:)`. `update(isAnimating:audioLevel:)` is kept intact for
  the countdown-toast consumer. All four faces honor `reduceMotion` (collapse → a
  quiet fade; spinner → static Star-of-David merkaba; checkmark → drawn instantly).
- **Live glow channel:** `MeetingRecordingFlowCoordinator.startPillGlowPolling()`
  — a **separate ~30 fps loop**, distinct from the 1 s `startPillPolling`, that
  reads `meetingRecordingService.mic/systemLevel` and calls
  `pillController.updateLiveAudioLevel(_:)` → the view → `iconView.setLiveGlow`
  (EMA-smoothed, implicit-animation-disabled `glowLayer.opacity` set). It runs
  only while `.recording` and is cancelled alongside `stopPillPolling`. **It never
  writes `@Observable`**, so it can't re-trigger Root-Cause-#2. The 1 s poll no
  longer drives the pill glow at all.
- **Instant state transitions:** the coordinator pushes each pill-state change via
  `pillController.refreshState()`, so stop → collapse → spinner → checkmark fires
  immediately instead of waiting up to a 1 s poll tick (a 1 s `Task` ticker still
  drives the elapsed badge text). This was a latent responsiveness bug in the
  committed PR that a visible collapse flourish would have made obvious. (An
  earlier `withObservationTracking` attempt tripped Swift 6 `@Sendable` capture
  rules; the explicit push is cleaner and matches the coordinator's style.)
- **Stem-less states use a circular container:** the recording capsule is tall to
  host the rosette + stem; transcribing/completed shrink it to a **circle** that
  hugs the compact mark (matching the prior SwiftUI pill's separate `iconPill`).
  The circle keeps the capsule's top edge and rises from the bottom, so the stop
  reads as the stem being absorbed into the head; the path animates tall→circle in
  sync with the collapse.
- **Swift 6 language-mode clean (the CI gate):** CI runs a `-swift-version 6`
  build the default `swift build` skips. The completion callback uses a
  `@MainActor` `Task` (not `DispatchQueue.asyncAfter(execute:)`, which demands a
  `@Sendable` closure), the badge ticker is a `@MainActor` `Task` (not a `Timer`,
  so the nonisolated `deinit` can cancel a `Sendable` handle), and `onFinished` is
  a `@MainActor` closure. Verified locally with the exact CI invocation
  (`MACPARAKEET_SKIP_WHISPERKIT=1 swift build -Xswiftc -swift-version -Xswiftc 6`).

**On-device verification (debug build, this session):**

| Scenario | CPU |
|---|---|
| Idle after relaunch | ~0.0–0.3% |
| Recording (rich pill + 30 fps glow loop), main window closed | **~14–21%, avg ~16–17%** |
| After completion (checkmark dismissed) | settles back to ~0% |

That recording figure sits **in/below the prior pill baseline (~19–21%)** from
the earlier session — i.e. **restoring the richness added no measurable CPU**, as
predicted (CA interpolates on the render server; the only new app-side work is
one actor read + one opacity set per frame). The full lifecycle was eyeballed
live and captured (`plans/active/assets/2026-05-pill-richness-live.png`: recording
→ collapse→merkaba → checkmark; `…-faces.png`: all faces + glow at two audio
levels). `swift build` ✅, `swift test` ✅ (exit 0).

**The trap that was avoided:** liveness was *not* restored by speeding up the
shared `startPillPolling` loop (1 s) — that updates the `@Observable`
`pillViewModel`/`panelViewModel` the SwiftUI Meetings tile + workspace observe,
and would re-introduce the Root-Cause-#2 list re-layout. The pill got its own
CALayer-only channel instead.

## Measurement caveat: debug vs release

The numbers above are from a **debug/dev build** (`-Onone`). Debug inflates Swift
+ SwiftUI/AppKit render cost substantially, so the absolute percentages are
**not** what release users see, and they can't be compared 1:1 with the released
0.6.14 figure (38–60%). What *is* trustworthy here is the **relative delta and
the profile change** — ~46% → ~17% for the reported case, with the list-layout
storm provably gone. The **release-build re-measurement below is still the
acceptance gate** before re-release.

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
- [ ] **Pill richness (restored):** glow visibly intensifies with mic/system
      audio while recording; stopping plays the collapse → merkaba spinner →
      green checkmark sequence (instant, not delayed); Reduce Motion shows a
      quiet fade + static merkaba + instantly-drawn check.

## Recurrence guard (proposed)

This is the second time a SwiftUI continuous animation in a resident surface
caused a CPU regression (PR #107 was the first). Cheap guard worth adding:

- A grep/CI check (or a documented review rule) flagging `repeatForever` and
  `TimelineView(.animation)` introduced in always-resident window surfaces
  (meeting pill/panel/tile, main window chrome), steering them to CALayer.
- The rule is now stated at the top of `BreathingSeedOfLifeView` and
  `MerkabaPillIcon` so the next person porting a rosette sees it.

## Remaining follow-ups

- [x] **Restore the pill's lost richness** — done (PR #396); live glow + collapse
      merkaba + spinner + checkmark, all CALayer, verified ~16–17% recording.
- [ ] **Owner (optional pre-release):** run the release-build verification matrix
      above on the final (richness-included) build. The hard "regression gate"
      framing is relaxed — per the owner this was never a v0.6.14 regression, and
      the owner is "ok even with the cpu spike (until someone complains)." The
      debug delta already shows richness adds no CPU; a release pass is
      confirmation, not a blocker.
- [ ] Delete the dead `MeetingRecordingPillView` — note its helpers
      `FlowerCompletionView` + `MeetingCompletionCheckmarkView` were the reference
      for the CALayer port and are now also unreferenced once the dead pill goes.
      Left in place this PR (safe, and useful as a SwiftUI cross-check); a small
      follow-up can remove all three together.
- [ ] Consider the CI/lint recurrence guard above.
