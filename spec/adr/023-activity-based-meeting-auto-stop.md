# ADR-023: Activity-Based Meeting Auto-Stop

> Status: **IMPLEMENTED (Phases A+B, default-off)** — App-quit fast path, sustained dual-channel silence, veto countdown, settings plumbing, telemetry, and normal finalize/transcribe stop path are implemented behind `AppFeatures.meetingAutoStopEnabled = false`. Phase C remains deferred until ADR-024's attribution layer exists.
> Date: 2026-06-14
> Related: ADR-014 (meeting recording), ADR-015 (concurrent dictation/meeting), ADR-016 (centralized STT scheduler), ADR-017 (calendar auto-start — its §5 amendment withdrew calendar-driven auto-stop and deferred the replacement to "its own ADR"; this is that ADR), ADR-024 (activity-based meeting detection — shares the activity-signal layer)
> Requirement: REQ-MEET-015 (v0.7, implemented behind default-off flag)

## Context

ADR-017 shipped calendar-driven auto-*start*, but its **2026-05-22 amendment withdrew calendar-driven auto-*stop***. Scheduled end times are unreliable — meetings overrun constantly — so a clock-driven stop risks **truncating a recording mid-meeting**, and losing the end of a meeting is far worse than over-recording. That amendment named the correct replacement explicitly:

> "the right stop signal is the meeting *actually ending*, detected from the audio MacParakeet already captures (sustained `systemLevel` silence, optionally plus a Zoom-app-quit fast path) — engine-agnostic across the Zoom app, a browser Meet/Teams tab, and in-person recordings. To be specced as its own ADR; deliberately not pre-built here."

**This is that ADR.** Today recordings stop only manually (one click on the pill). The failure mode it leaves open: a user finishes a call, closes the meeting window, walks away — and the recording keeps running, producing trailing dead air, wasted battery, and a transcript that needs trimming. Auto-start removed "I forgot to start it"; this removes "I forgot to stop it."

**Asymmetry principle (carried from ADR-017 §5):** starting early is cheap and trimmable; stopping early destroys data. Auto-stop must therefore be conservative and must **never silently truncate a live meeting**.

## Decision

### 1. Activity-based, never time-based

Auto-stop is driven only by signals that the meeting is *actually over*. No calendar end time participates in the decision.

### 2. Two signals — sustained silence (primary, engine-agnostic) + recognized-app-quit (fast path)

- **Primary — sustained dual-channel silence.** When both the mic ("You") and system ("Others") audio have been continuously below the speech threshold for a long grace window, the meeting has very likely ended. This is the *engine-agnostic* signal: it works identically for the Zoom app, a browser Meet/Teams tab, and an in-person recording. It reuses the VAD / level signal MacParakeet already computes for live chunking (`MeetingVADService`, and the panel's `systemLevel` / `micLevel`) — no new audio plumbing.
- **Fast path — recognized meeting-app termination.** If a recognized conferencing app (bundle-ID allowlist: Zoom `us.zoom.xos`, Teams `com.microsoft.teams2`/`com.microsoft.teams`, Webex `com.cisco.webexmeetingsapp`/`Cisco-Systems.Spark`, FaceTime `com.apple.FaceTime`) that was running *while we recorded* quits, that is a high-confidence "call over" signal — stop responsively, ahead of the silence grace. This covers the most common case (close the Zoom window) without waiting minutes.

> When ADR-024's per-process audio-attribution layer lands, auto-stop can consume the richer "the call's audio session ended" signal (app still open, call ended) in addition to / instead of raw app-quit.

### 3. Veto-able pre-stop, never a silent cut

When a signal fires *and persists through its grace*, show a short countdown toast — **"This meeting looks finished — stopping in 15s · Keep recording"** — and stop only if the user does not veto. This reuses the existing `MeetingCountdownToastController` from ADR-017 (the same surface auto-start uses). The countdown is what makes the silence signal's residual false-positive risk (a long genuine quiet stretch) acceptable: the user always gets the last word. A veto suppresses that reason for the rest of the session.

> Owner UX decision point (see Open Questions): the ADR settles on the **veto countdown**. A fully silent auto-stop is a one-line change (swap the countdown for a direct stop) if the owner prefers it, but it reintroduces the truncation-by-surprise risk this ADR exists to avoid.

### 4. Stop runs the identical finalize path as a manual stop

Auto-stop calls the normal stop through `MeetingRecordingFlowCoordinator` with the `.autoStop` operation trigger. The recording is finalized, transcribed, and saved *exactly* as if the user clicked stop. There is **no special discard path**. Never lose data.

### 5. Opt-in, default off, one Settings toggle

A single `meetingAutoStopEnabled` preference (default `false`), mirroring the opt-in posture of calendar auto-start. Staged behind a new `AppFeatures.meetingAutoStopEnabled` compile-time flag. The settings plumbing mirrors `calendarAutoStartMode`: persist to a namespaced key → post `.macParakeetMeetingAutoStopDidChange` → `Telemetry.send(.settingChanged(...))`. The toggle lives in the Meeting Recording settings card.

### 6. Pure policy + thin coordinator

A pure `MeetingAutoStopPolicy.evaluate(...)` in `MacParakeetCore` (mirrors `MeetingMonitor.evaluate` — all state passed in, no side effects, `Sendable`, trivially unit-testable), and a `@MainActor MeetingAutoStopCoordinator` in the app layer (mirrors `MeetingAutoStartCoordinator`) that, *only while a recording is active*, observes app termination + samples the audio signal, runs the grace clock, and drives the veto countdown.

### 7. Correctness invariants

- **Confirmed-during-recording.** Only signals *observed while recording* may stop it. The recognized-app-quit signal counts only for apps that were running at/after recording start (snapshotted into the meeting context). A stop signal that was never observed live must never trigger.
- **Identity-scoped.** Match the specific meeting context captured at start, not "any app quit" / "any silence."
- **Grace + reversal.** A transient blip (app relaunches, speaker resumes after a pause) resets the grace clock. Stop only after the signal is *continuously* present through the full grace window.
- **Pause / manual win.** Never auto-stop a `.paused` recording. A manual stop/discard mid-countdown cancels cleanly — guard on the flow state-machine state so there is no double-stop.
- **Sticky veto.** "Keep recording" suppresses that reason for the rest of the session.
- **Single-flight.** App-termination and the silence-sampling timer can fire near-simultaneously; one evaluation at a time (reuse the coordinator reentrancy/coalescing guard pattern).
- **Idle teardown.** No observers or timers alive when there is no active recording or the toggle is off (idle-CPU hygiene — the same lesson behind the rotation/render-server cleanup).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       MacParakeetCore                        │
│                                                              │
│  MeetingAutoStopPolicy   (pure, Sendable — no AppKit)        │
│    evaluate(context, observation, config) -> Decision        │
│      Decision: .keepRecording | .proposeStop(reason)         │
│      reason:   .meetingAppClosed(bundleID) | .prolongedSilence│
│    context:    observedMeetingAppBundleIDs, startedAt         │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    MacParakeet (app layer)                   │
│                                                              │
│  MeetingAutoStopCoordinator  (@MainActor)                    │
│    ├── active ONLY while a recording is in flight            │
│    ├── snapshots running recognized apps at start            │
│    ├── NSWorkspace.didTerminateApplicationNotification obs.   │
│    ├── samples mic/system silence (MeetingVADService/levels) │
│    ├── grace clock (+ reversal cancel)                       │
│    ├── MeetingCountdownToastController  (veto countdown)      │
│    └── MeetingRecordingFlowCoordinator stop(operation:.autoStop)│
└─────────────────────────────────────────────────────────────┘
```

**Ownership:** the coordinator is wired in `AppEnvironmentConfigurer` next to `MeetingAutoStartCoordinator`, observing settings via the same notification pattern. The recognized-app bundle-ID registry is shared with ADR-024 if/when that lands.

## Rationale

- **Why silence primary, app-quit fast-path:** silence is the only signal that covers *every* meeting medium (app, browser tab, in-person); app-quit is faster but native-app-only. Combining them gives responsiveness for the common case and coverage for the rest. This is exactly the direction ADR-017 §5 named.
- **Why a veto countdown, not a silent stop:** the start/stop asymmetry — over-recording is trimmable, truncation loses data. The countdown is the safety valve, and it reuses the auto-start UX the user already understands.
- **Why default off:** auto-stopping a recording is a trust-sensitive action; same posture as calendar auto-start.
- **Why reuse VAD / levels:** already computed for live chunking, so the primary signal adds no new audio capture surface.

## Consequences

### Positive
- Closes the "forgot to stop" failure mode without any truncation risk (the veto countdown guarantees the user can override).
- Reuses the existing countdown toast and the existing VAD/level signal — small new surface.
- Pure policy is trivially unit-testable (table tests, like `MeetingMonitor`).
- Engine-agnostic: works for the Zoom app, a browser Meet/Teams tab, and in-person recordings.

### Negative
- A new coordinator + observers to maintain (idle-teardown keeps CPU off when no recording).
- Browser / in-person meetings rely on the slower silence grace (no fast path until ADR-024's attribution layer).
- FaceTime is intentionally in the native allowlist, so a personal FaceTime
  call observed during a recording can still produce the veto countdown. The
  default-off flag, opt-in setting, and "Keep recording" veto are the Phase A
  guardrails; ADR-024's trust tiers can refine this once attribution exists.
- The silence threshold + grace need careful tuning; start conservative (a long continuous-silence window) to avoid stopping during a quiet stretch.

## Implementation Direction

### Core (`MacParakeetCore`)
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingAutoStopPolicy.swift` — pure `evaluate(...)`, `Decision`/`StopReason`/`MeetingContext`/`Observation`/`Config` value types.
- Recognized conferencing-app bundle-ID registry (shared with ADR-024).

### App layer (`MacParakeet`)
- `Sources/MacParakeet/App/MeetingAutoStopCoordinator.swift` — wired in `AppEnvironmentConfigurer.swift`; reuses `MeetingCountdownToastController`; calls the flow coordinator's stop with the `.autoStop` operation trigger, distinct from recording-start trigger attribution.

### Settings (`MacParakeetViewModels` + UI)
- `meetingAutoStopEnabled` on `SettingsViewModel` (namespaced UserDefaults key), posting `.macParakeetMeetingAutoStopDidChange` (add to `AppNotifications.swift`).
- Toggle in the Meeting Recording settings card; add to `SettingsSearchIndex`.
- `AppFeatures.meetingAutoStopEnabled` flag for staged rollout.

### Telemetry (new cases — must mirror to website allowlist)
- `meeting_auto_stop_proposed{reason}` · `meeting_auto_stop_confirmed{reason}` · `meeting_auto_stop_vetoed{reason}` · `.settingChanged(setting: .meetingAutoStop)`.
- Per the telemetry allowlist rule, each new `TelemetryEventName` case must also be added to `ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts` (two-repo change) before any flag-on build.

## Phased Rollout

1. **Phase A — app-quit fast path + veto countdown + settings toggle + tests — IMPLEMENTED (2026-06-14).** Pure `MeetingAutoStopPolicy`, recognized-app-termination signal, veto countdown, `meetingAutoStopEnabled` toggle. Flag-gated, default off. Ships the whole feature for native conferencing apps once the flag flips.
2. **Phase B — sustained dual-channel silence signal — IMPLEMENTED (2026-06-14).** Adds engine-agnostic coverage (browser tabs, in-person) under the same toggle, reusing the meeting level signal (`micLevel` / `systemLevel`) with a conservative four-minute continuous-silence grace.
3. **Phase C — consume ADR-024 attribution — DEFERRED.** Once activity detection lands, use the per-process audio-attribution "call ended" signal for the case where the recognized app stays open but the call ends; deprecate raw app-quit if attribution is strictly better.

## Open Questions

- **Default grace values:** implemented at 15s after recognized-app termination and 4 min continuous quiet on both channels; tune from field telemetry before any flag-on release.
- **Veto countdown vs silent stop:** resolved in favor of the veto countdown; do not silently stop without a new owner decision.
- **App-open-but-call-ended:** when a recognized app stays open after the call ends, only silence will catch it until ADR-024's attribution layer exists. Acceptable for the default-off validation build.
