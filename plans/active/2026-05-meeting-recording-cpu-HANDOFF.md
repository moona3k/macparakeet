# Handoff — Meeting-recording CPU regression (v0.6.14)

> Status: **ACTIVE** — handoff written 2026-05-29 by the prior agent.
> Branch: `fix/meeting-recording-cpu-swiftui-render` · PR: **#396** (open).
> Companion docs: `2026-05-meeting-recording-cpu-debug.md` (full investigation +
> measurements + the richness-restoration plan). This file is the orientation
> layer; the debug doc is the detail.

## TL;DR

v0.6.14 shipped a meeting-recording CPU regression (released ~38–60%, dev
~40–70% while recording, laggy hover). It was **pulled from the appcast**;
public is back on 0.6.13. Do **not** re-release until a **release-build**
re-measurement passes.

**Two root causes were found and fixed (verified on-device, debug build):**

1. **Continuous SwiftUI animation in always-resident windows.** `repeatForever` /
   `TimelineView(.animation)` hosted in a resident window does per-frame work on
   the main thread via `NSHostingView` (re-eval `body` → `DisplayList` → CA
   commit, every display refresh). Fixed by moving these to Core Animation
   (`CALayer` + `CABasicAnimation`), which interpolates on the render server at
   ~0 app CPU.
2. **`MeetingsView` re-laying out the whole list every elapsed-second tick** —
   `body` read `meetingPillViewModel.formattedElapsed`, so each 1 s tick
   re-evaluated the entire body incl. the meetings `ForEach` (a `sizeThatFits`
   storm). **This was the actual reported "laggy Meetings workspace while
   recording."** Fixed by isolating the elapsed read into a leaf view.

Key reframe (the owner intuited this and it's correct): **the floating pill was
never the main hog.** The dominant cost was #2 (the workspace). The pill is
~19–21% (mostly capture + VAD). The rosette rotation was *already* CALayer even
in the old pill. It was **CPU/rendering, never memory** (RAM stayed ~0.5%).

## What changed (all committed + pushed on the branch)

| File | Change |
|---|---|
| `Views/MeetingRecording/MeetingRecordingPanelView.swift` | `BreathingSeedOfLifeView` → `NSViewRepresentable` + CALayer (`BreathingSeedOfLifeNSView`). CA pause for `freeze`; honors Reduce Motion. Fixes all 3 consumers (transcript + live-notes watermark, summary skeleton). |
| `Views/MeetingRecording/MeetingRecordingPillController.swift` | (prior WIP: AppKit/CALayer pill) + **restored Reduce Motion**, **compacted capsule 54×106→54×86**, **restored hover-time badge** (red/amber dot + live timer, CALayer). |
| `Views/MeetingRecording/MerkabaPillIcon.swift` | (prior WIP) CALayer rosette icon used by the pill. |
| `Views/Transcription/MeetingRecordingTile.swift` | `SacredFlowerTile` dead rotation/sway machinery removed → static rosette. |
| `Views/Meetings/MeetingsView.swift` | **Root cause #2 fix** — `MeetingsLiveStatusChip` leaf view owns the `formattedElapsed` read. |
| `App/AppWindowCoordinator.swift` | (prior WIP) main-window close releases the SwiftUI hosting tree. |
| `App/MeetingRecordingFlowCoordinator.swift` | (prior WIP) pill poll 1 s + change-gated + quantized (`displayLevel`). |
| `plans/active/2026-05-meeting-recording-cpu-debug.md` | full log + measurements + richness plan. |

Commits on the branch (newest first): `05c25683` (dictation outcome + richness
plan), `0bf8f17d` (measurement coverage), `788a19ad` (#204 regression note),
`c2ce04b9` (MeetingsView fix + hover-time), `57698106` (animation→CA + pill +
window).

## Verified on-device (debug build — numbers are inflated vs release)

| Scenario | CPU |
|---|---|
| Idle (no window) | ~0.0–0.5% |
| Recording, pill only | ~19–21% |
| Recording, Meetings workspace visible — **before** #2 fix | ~25–46% sustained (the bug) |
| Recording, Meetings workspace visible — **after** #2 fix | ~15–18% (storm gone from `sample` profile) |
| Settled dictation | not re-measured; prior ~5–11% stands |

`swift build` ✅, `swift test` ✅ (exit 0). PR #204 (issue #200, tooltip wrap
past 99:59) **not regressed** — the new CALayer badge stays single-line at
`114:44`/`999:59` (`isWrapped=false` + width from measured text).

## What's NOT done — next steps (priority order)

1. **[GATE] Release-build CPU re-measurement on-device.** Debug numbers are
   inflated; the acceptance gate is a Release build. Use the verification matrix
   in the debug doc. Key case: recording + main window visible + Transcript tab
   should be near the closed-window floor.
2. **Restore the pill's lost richness** (owner explicitly wants this). Full
   analysis + concrete implementation sketch is in the debug doc under
   "Follow-up: restore the pill's lost richness." Summary: live audio-responsive
   glow via a **pill-local ~20–30 fps audio channel → CALayer only** (do NOT
   speed the shared `startPillPolling` loop — that re-triggers root cause #2),
   plus port the completion merkaba flourish + checkmark to CA one-shots. Measure
   after; keep in the ~19–21% band; honor `reduceMotion`. ~80–150 LOC across
   `MeetingRecordingFlowCoordinator` / `MeetingRecordingPillController` /
   `MeetingRecordingAppKitPillView`.
3. **Settled-dictation comparison** — needs a human (dictation pastes into the
   focused app; must run without a concurrent meeting).
4. **Delete dead `MeetingRecordingPillView`** (`MeetingRecordingPillView.swift`)
   — superseded by the AppKit pill. Audit co-located helpers first
   (`FlowerCompletionView`, `MeetingCompletionCheckmarkView` — useful as
   reference for #2 above before deleting).
5. **CI/lint recurrence guard** — flag `repeatForever` /
   `TimelineView(.animation)` introduced in always-resident window surfaces. This
   is the 2nd occurrence of this class (PR #107 was the 1st).

## Operational notes for the next agent

- **Driving the dev app for measurement** (Accessibility is granted, AppleScript
  works): `scripts/dev/run_app.sh` builds + relaunches (kills old instance,
  non-blocking). Trigger meeting:
  `osascript -e 'tell application "System Events" to tell process "MacParakeet" to click menu item "Start Recording" of menu 1 of menu bar item "Capture" of menu bar 1'`
  (toggles to "Stop Recording"). Open workspace: same pattern with
  `"Meetings"` of `"Go"`. "Start Dictation" is also under "Capture".
- **Measure CPU:** `top -l N -s 1 -pid <pid> -stats pid,cpu,command | grep "^<pid>"`
  (skip the 1st sample). `-stats cpu` alone parses unreliably — use the multi-col
  form. `sample <pid> 3 -file /tmp/x.txt` for hot paths.
- **Pill render harness** (preview pill states without launching the app, faithful
  because it compiles the real `MerkabaPillIconView`):
  `plans/active/assets/pill_preview_harness.swift`. Run:
  `swiftc -o /tmp/pillrender plans/active/assets/pill_preview_harness.swift Sources/MacParakeet/Views/MeetingRecording/MerkabaPillIcon.swift && /tmp/pillrender`
  → writes a PNG. Edit the `panels` array to render variants (hover, paused,
  long timestamps). Used to tune the 54×86 compaction + verify the hover badge.
- **⚠️ A meeting recording may still be live on the dev app** (the owner started
  one to test hover). It captures audio — stop via the pill's right-click. Also
  **~2 short test meetings** (~20–30 s) were created during measurement — delete
  from Library → Meetings if unwanted. (Did not auto-delete: never remove meeting
  data without confirmation.)

## Key learnings (worth a memory entry)

- **Never drive a *continuous* animation with SwiftUI (`repeatForever` /
  `TimelineView(.animation)`) in an always-resident window.** It does per-frame
  main-thread work through `NSHostingView`. Use `CALayer` + `CABasicAnimation`
  (render-server interpolation, ~0 app CPU). Transient indicators in SwiftUI are
  fine; resident ones are not.
- **Don't read a fast-ticking `@Observable` value (elapsed timer, audio level)
  high in a `body` that also builds an expensive subtree** (a list). The whole
  subtree re-lays out every tick. Push the read into the smallest leaf view.
- **CALayer makes *rich* animation cheap**, not just static — live glows /
  waveforms via direct layer-property updates cost ~nothing. The old SwiftUI
  pill's cost was the re-render path, not the richness.
- The CALayer pill migration silently dropped two things that were re-added:
  **Reduce Motion** and the **hover-time badge**. When porting SwiftUI→AppKit,
  audit for dropped affordances.

## Unrelated (do not conflate)

`plans/active/2026-05-silent-buffer-fallback.md` is a **separate** workstream
(silent-mic device fallback), intentionally left untracked / out of PR #396.
