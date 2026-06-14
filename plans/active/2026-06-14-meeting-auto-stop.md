# Activity-Based Meeting Auto-Stop

**Status:** Implemented for Phases A+B on 2026-06-14; default off / opt-in behind `AppFeatures.meetingAutoStopEnabled = false`. Phase C remains active/deferred until ADR-024 per-process attribution exists.
**Date:** 2026-06-14
**ADRs:** ADR-023 (activity-based meeting auto-stop), ADR-017 (calendar auto-start — §5 deferred this), ADR-014/015/016 (meeting recording, concurrency, scheduler)
**Requirement:** REQ-MEET-015 (v0.7, implemented behind default-off flag)
**Related:** ADR-024 (activity-based meeting detection — shares the activity-signal layer; Phase C consumes it)

## What this plan closes out

Calendar auto-start (ADR-017) removed "I forgot to *start* recording." It deliberately left "I forgot to *stop*" open — calendar end times are too unreliable to drive a stop without risking mid-meeting truncation (ADR-017 §5 amendment). This plan implements the replacement ADR-017 §5 named: stop when the meeting *actually ends*, detected from on-device activity, never the clock.

Signal priority (per ADR-023 §2), settled:
- **Primary: sustained dual-channel silence** — engine-agnostic (Zoom app, browser tab, in-person). Reuses the meeting VAD / `systemLevel`/`micLevel` signal already computed for live chunking.
- **Fast path: recognized meeting-app termination** — high-confidence, responsive, native-app-only.

Both feed a **veto-able pre-stop countdown** (reusing `MeetingCountdownToastController`), and the stop runs the *identical* finalize path as a manual stop — never a special discard, never lost data.

## Scope boundaries

### In scope
- Pure `MeetingAutoStopPolicy` in `MacParakeetCore` (mirror of `MeetingMonitor.evaluate`).
- `@MainActor MeetingAutoStopCoordinator` in the app layer (mirror of `MeetingAutoStartCoordinator`), active only while recording.
- Recognized-app-termination signal via `NSWorkspace.didTerminateApplicationNotification` + a recognized-conferencing-app bundle-ID registry.
- Sustained dual-channel silence signal via the existing meeting VAD / level signal.
- Veto countdown reusing `MeetingCountdownToastController`; stop via `MeetingRecordingFlowCoordinator` with the `.autoStop` operation trigger.
- Settings toggle (`meetingAutoStopEnabled`, default off) + `AppFeatures` flag + telemetry + website allowlist mirror.

### Out of scope
- Calendar-end-time-driven stop (permanently withdrawn — ADR-017 §5).
- Per-process audio attribution (ADR-024) — Phase C consumes it once it exists; this plan does not build it.
- Camera-based detection (ADR-024).
- Auto-stop for the "app stays open but the call ended" case beyond what silence catches (deferred to ADR-024 attribution).
- Any change to how a recording is finalized/transcribed (auto-stop is just another trigger of the existing stop).

### Invariants
- **Never lose user data** — auto-stop runs the normal stop/finalize/transcribe path; the original audio + transcript are preserved exactly.
- **Never silently truncate** — a stop is always preceded by a veto countdown the user can cancel.
- **Confirmed-during-recording** — only signals observed *while recording* can stop it; app-quit counts only for apps running at/after start.
- **Pause / manual win** — never auto-stop a paused recording; a manual stop/discard mid-countdown cancels cleanly (no double-stop; guard on flow state).
- **Idle teardown** — observers/timers exist only while a recording is active and the toggle is on (idle-CPU hygiene).
- Dictation + concurrent meeting recording (ADR-015) and the STT scheduler (ADR-016) are untouched.

## The pure policy (Core)

`Sources/MacParakeetCore/Services/MeetingRecording/MeetingAutoStopPolicy.swift`

```swift
public enum MeetingAutoStopPolicy {
    public struct MeetingContext: Sendable, Equatable {
        public var observedMeetingAppBundleIDs: Set<String>  // recognized apps running at/after start
        public var startedAt: Date
    }
    public struct Observation: Sendable, Equatable {
        public var now: Date
        public var isRecording: Bool
        public var isPaused: Bool
        public var runningMeetingAppBundleIDs: Set<String>
        public var continuousSilenceSeconds: TimeInterval   // both channels below threshold
    }
    public struct Config: Sendable, Equatable {
        public var appQuitEnabled: Bool
        public var silenceEnabled: Bool
        public var appQuitGraceSeconds: TimeInterval    // ~15–20
        public var silenceGraceSeconds: TimeInterval    // ~180–300
    }
    public enum StopReason: Sendable, Equatable {
        case meetingAppClosed(bundleID: String)
        case prolongedSilence
    }
    public enum Decision: Sendable, Equatable { case keepRecording; case proposeStop(reason: StopReason) }

    public static func evaluate(context: MeetingContext, observation: Observation, config: Config) -> Decision
}
```

Rules: `.keepRecording` if `!isRecording || isPaused`. App-quit fires only when a bundle ID in `context.observedMeetingAppBundleIDs` is **absent** from `observation.runningMeetingAppBundleIDs` (confirmed-during-recording guard). Silence fires only when `continuousSilenceSeconds >= config.silenceGraceSeconds && config.silenceEnabled`. App-quit reason wins when both are eligible. The coordinator owns the grace clock by tracking "signal first seen at" and only acting once the grace elapses; reversal resets it.

## Phased rollout

### Phase A — app-quit fast path + veto countdown + settings (implemented 2026-06-14)
- **Core:** `MeetingAutoStopPolicy.swift` (+ recognized-app bundle-ID registry).
- **App:** `Sources/MacParakeet/App/MeetingAutoStopCoordinator.swift` — snapshot running recognized apps at start; `NSWorkspace.didTerminateApplicationNotification` observer; grace clock + reversal; veto countdown; stop via `MeetingRecordingFlowCoordinator` with the `.autoStop` operation trigger. Wire in `AppEnvironmentConfigurer.swift`.
- **Flow:** distinguish recording-start triggers from stop operation triggers so auto-stop is attributed without becoming a recording-start source.
- **Settings:** `meetingAutoStopEnabled` on `SettingsViewModel` (namespaced key) + `.macParakeetMeetingAutoStopDidChange` in `AppNotifications.swift` + toggle in the Meeting Recording settings card + `SettingsSearchIndex` entry.
- **Gate:** `AppFeatures.meetingAutoStopEnabled` (default off).
- **Telemetry:** `meeting_auto_stop_proposed/confirmed/vetoed{reason}` + `.settingChanged(setting:.meetingAutoStop)` → mirror to `macparakeet-website/functions/api/telemetry.ts` `ALLOWED_EVENTS`.

### Phase B — sustained dual-channel silence signal (implemented 2026-06-14)
- Sample mic/system silence from the existing meeting VAD/level path (`MeetingVADService` / panel `micLevel`/`systemLevel`) on a `RunLoop.common` timer; maintain `continuousSilenceSeconds`; feed the policy. Nested under the same toggle. Start with a conservative grace (~3–5 min). Prefer "no speech on either channel" (VAD) over a raw RMS threshold if reachable.

### Phase C — consume ADR-024 attribution (deferred)
- When activity detection ships, use the per-process audio-attribution "call ended" signal for the app-open-but-call-ended case; deprecate raw app-quit if attribution is strictly better.

## Recognized conferencing-app registry (Phase A)
Native apps detectable by bundle ID via `NSWorkspace.shared.runningApplications`: Zoom `us.zoom.xos`, Teams `com.microsoft.teams2`/`com.microsoft.teams`, Webex `com.cisco.webexmeetingsapp`/`Cisco-Systems.Spark`, FaceTime `com.apple.FaceTime`. **Known limitations (document in Settings help):** browser-based meetings (a Meet/Teams tab) and in-person recordings have no app to quit — they are covered by the Phase B silence signal; FaceTime can also represent personal calls, so Phase A relies on the opt-in/default-off posture plus the veto countdown until ADR-024 attribution can sharpen trust tiers.

## Tests
- **`MeetingAutoStopPolicyTests` (Core, the bulk):** observed app disappears → `.proposeStop(.meetingAppClosed)`; a *different* app quits → keep (identity scoping); app never observed during recording → keep (confirmed-during-recording); `isPaused`/`!isRecording` → keep; silence ≥ grace with `silenceEnabled` → `.proposeStop(.prolongedSilence)`, below grace → keep, `silenceEnabled == false` → keep; both eligible → app-quit wins.
- **Coordinator tests:** use a `testHook_`-style seam (mirror `MeetingAutoStartCoordinator`) injecting running-apps / silence / stop closures + force-evaluate. Assert grace reversal cancels; veto suppresses re-propose for the session; toggling off mid-countdown tears down; never stops while paused; stop goes through the flow coordinator exactly once.
- Run focused, then full `swift test` before merge.

## Open questions (for the owner)
- Default grace values settled for the validation build: 15s after app termination, 4 min continuous dual-channel quiet; confirm with field tuning before flag-on release.
- Veto countdown is required; do not switch to silent stop without a new owner decision.
- Phase A+B shipped together in this branch; Phase C waits for ADR-024 attribution.
