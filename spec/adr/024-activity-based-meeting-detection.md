# ADR-024: Activity-Based Meeting Detection

> Status: **PARTIAL IMPLEMENTATION** — Phases A+B ship the default-off CoreAudio
> process attribution collector, CoreMediaIO camera activity collector, shared
> activity snapshot types, app registry, detection mode, and pure detector tests.
> Coordinator/UI wiring, prompt/auto-start telemetry, and ADR-023 auto-stop
> attribution remain proposed until later phases flip
> `AppFeatures.meetingActivityDetectionEnabled`.
> Default off / opt-in.
> Date: 2026-06-14
> Related: ADR-002 (local-first), ADR-014 (meeting recording), ADR-015
> (concurrent dictation/meeting), ADR-017 (calendar auto-start), ADR-023
> (activity-based meeting auto-stop — authored in parallel; consumes the same
> activity-signal layer this ADR builds).
> Requirement: REQ-MEET-016 (v0.7, Phases A+B foundation implemented).

## Context

ADR-017 gave MacParakeet one way to notice a meeting before the user remembers
to press record: the **calendar**. At T-5min of a calendar event with a
conferencing link, we remind; in opt-in `.autoStart` mode we surface a
countdown and start recording. That solved the most common "I forgot to hit
record" case for *scheduled* meetings.

But a large fraction of real meetings never touch the calendar:

- **Ad-hoc calls** — someone pings "got 5 minutes?" and a Zoom starts cold.
- **Someone else's invite** — the meeting lives on a colleague's calendar, not
  yours; nothing on your machine knows it exists.
- **Quick huddles** — a Slack call, a FaceTime, a Meet tab opened from a chat
  link.

For all of these, the calendar is silent and the user is back to the original
failure mode ADR-014 left open: *the first few minutes are gone before anyone
remembers to record.*

The machine already knows a meeting is happening — the mic is hot, the camera
is on, a conferencing app is frontmost. macOS exposes this as **metadata**
through public CoreAudio and CoreMediaIO APIs: *which* process holds the input
device, *whether* a camera is running, *which* app is in front. None of it is
audio or screen content. This ADR adds an **activity-signal detection layer**
that fuses these on-device signals to recognize a live meeting and offer to
record it — without the calendar, without the cloud, without ever reading
content.

The same signal layer answers a second question MacParakeet needs:
ADR-023 (activity-based auto-stop) wants to know when a meeting is *still
happening*. "Mic + camera/app went quiet for N seconds" is the stop signal;
"mic + camera/app just came up" is the start signal. Building the collectors
once and feeding both consumers is the whole reason these two ADRs are
siblings rather than duplicated work.

This is deliberately scoped narrower than "understand what the user is doing."
We detect **meeting-shaped device activity**, prompt once, and get out of the
way. Default off, opt-in, metadata-only — same privacy posture as ADR-017.

## Decision

### 1. Per-process audio attribution via public CoreAudio (the foundation)

The privacy-clean foundation is **device-attribution metadata**, not audio.
macOS publishes the list of processes currently using audio hardware through
public CoreAudio properties:

- `kAudioHardwarePropertyProcessObjectList` → the set of audio process objects.
- Per object: `kAudioProcessPropertyIsRunningInput` /
  `kAudioProcessPropertyIsRunningOutput` (is it using the mic / a speaker right
  now), plus `kAudioProcessPropertyPID` and `kAudioProcessPropertyBundleID`.

From this we learn **which app holds the microphone or an output stream** — a
PID and bundle ID, nothing more. We never read a sample, never tap a stream,
never touch buffers. This is the cleanest possible meeting signal under ADR-002:
"Zoom is using the mic" is metadata the OS already surfaces; the audio itself
stays where it belongs.

Property listeners (`AudioObjectAddPropertyListenerBlock`) make this
event-driven — we react when the process list or a running-state flag changes,
not by polling the audio subsystem on a timer.

### 2. Camera activity via CoreMediaIO property listeners

Camera-on is the strongest "this is a video meeting, not a podcast playing"
signal. CoreMediaIO exposes it without any video access:

- `kCMIODevicePropertyDeviceIsRunningSomewhere` — true when *any* process is
  driving the camera.

We register a property listener and react to on→off / off→on transitions. No
polling at rest. CoreMediaIO tells us *that* a camera is running, not *which*
app is driving it (see §"Out of Scope") — and that is enough for v1.

### 3. Recognized conferencing-app registry

A static **bundle-ID allowlist** of known meeting apps, plus browser bundle IDs
whose active tab carries a recognized meeting URL. This is the same idea as
ADR-017's `MeetingTriggerFilter.withLink`, reused for live processes instead of
calendar events.

```swift
public enum MeetingApp: String, Sendable, CaseIterable {
    case zoom        // "us.zoom.xos"
    case teams       // "com.microsoft.teams2", "com.microsoft.teams"
    case webex       // "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"
    case slack       // "com.tinyspeck.slackmacgap"
    case facetime    // "com.apple.FaceTime"
    case browser     // Safari/Chrome/etc. — only counts WITH a recognized URL
}
```

Browsers are recognized by bundle ID **and** require that a recognized meeting
URL is present (reuse `MeetingLinkParser` from ADR-017) — a browser with the
mic open but no meeting URL (a voice-note web app, a language site) must not
count.

### 4. Signal-fusion rule (false-positive avoidance is the whole game)

A recording prompt that fires on a YouTube video, a Photo Booth selfie, or a
document scan is worse than no feature — users disable it and never come back.
The fusion rule is conservative by construction:

> **Trigger only when: mic is active AND (camera is active OR a recognized
> meeting app/URL holds audio).**

Camera-alone never triggers (Photo Booth, a scanner app, a webcam test).
Audio-output-alone never triggers (a video plays through the speakers). The
intersection of "I am speaking into the mic" with "this is a video call or a
known meeting app" is what a meeting looks like.

**Graduated app-trust tiers** sharpen this further:

| Tier | Apps | Requirement to count |
|------|------|----------------------|
| Strong (dedicated) | Zoom, Teams, Webex, FaceTime | App running **and** holding the mic is enough |
| Background-capable chat | Slack | Requires **full-duplex** audio (input *and* output) — idle messaging holds neither, an active call holds both |
| Browser | Safari, Chrome, … | Requires **frontmost or the same browser bundle ID to have a recognized meeting URL** — never counts in the background |

The tiers encode the real failure modes: a dedicated meeting app is rarely open
without a call; a chat app is open all day, so we demand the audio shape of an
actual call; a browser is a grab-bag, so it counts only when it's the focused
window or carries a meeting link.

### 5. Self-attribution exclusion

MacParakeet itself uses the mic (dictation, meeting recording). Its own audio
process must be **subtracted from every signal** before fusion, or an active
recording would re-trigger detection on itself in a loop. Filter the process
list by our own PID/bundle ID first; everything downstream sees the world
minus us.

### 6. Detection → prompt state machine (pure, mirrors `MeetingMonitor`)

All policy lives in a pure, `static`, `Sendable` evaluator that mirrors
`MeetingMonitor.evaluate(...)` — caller passes the current signal snapshot and
suppression state in, gets monitor events out, no side effects:

```swift
MeetingActivityDetector.evaluate(
    signal: ActivitySignalSnapshot,   // mic/camera/app facts at `now`
    now: Date,
    config: Config,                   // dwell, cooldown, mode
    activeRecording: Bool,
    candidate: Candidate?,            // current identity plus first-seen timestamp
    suppressedIdentities: [MeetingIdentity: Date]  // declined-until timestamps
) -> [DetectionEvent]                 // .promptToRecord / .autoStartDue / .signalCleared
```

Behavior the state machine encodes:

- **Candidate stabilization dwell (~3s).** A meeting signal must hold steady for
  a short dwell before we surface anything. Filters the mic-blip when an app
  grabs the device for a half-second, and the camera flash of a permissions
  prompt.
- **Per-meeting-identity suppression with cooldown.** A `MeetingIdentity`
  (derived from the recognized app + coarse session boundary, *not* content)
  remembers a decline. If the user says "no" to recording this call, we do not
  re-nag the same live call — `suppressedIdentities` holds a declined-until
  timestamp, and the same identity is suppressed for a cooldown window.
- **Debounced refresh.** The collectors are event-driven, but transitions can
  arrive in bursts (an app grabbing mic + camera + going frontmost within
  100ms). Coalesce them and re-evaluate at most every ~500ms so we don't thrash
  the state machine or burn idle CPU. **This repo is idle-CPU sensitive**
  (PR #467 — a continuous SwiftUI rotation cost ~17% main-thread CPU; idle work
  is measured app-frontmost, not occluded). Detection must add ~0% at rest:
  no timers when no audio process is using the mic, listeners torn down when the
  feature is off or a recording is already active.

The default output is a **non-nagging "Record this meeting?" prompt** — a small,
dismissible surface the user can ignore. Auto-start *without* a prompt is a
separate, deeper opt-in (§7) gated behind its own setting.

### 7. Default off, opt-in, no content captured

A new settings control governs the feature, mirroring the ADR-017
`calendarAutoStartMode` pattern exactly (same `UserDefaults` namespace shape,
same `.macParakeet…DidChange` notification, same `Telemetry.send(.settingChanged(...))`
on mutation):

```swift
public enum MeetingActivityDetectionMode: String, Codable, Sendable {
    case off            // No collectors, no listeners, no detection. Default.
    case prompt         // Detect → "Record this meeting?" prompt (no auto-record).
    case autoStart      // Detect → countdown → start recording (deeper opt-in).
}
```

Default `.off` for everyone, including upgraders. `.prompt` is the recommended
on-state. `.autoStart` is the hands-off mode and reuses the ADR-017 countdown
toast surface so a detection can be cancelled before recording begins.

A new compile-time flag, `AppFeatures.meetingActivityDetectionEnabled`, gates
the whole feature for staged rollout — identical in spirit to
`AppFeatures.calendarEnabled`. When `false`, no collectors are constructed, the
settings control is hidden, and the coordinator never starts.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          MacParakeetCore (new)                         │
│                                                                        │
│  AudioProcessActivityCollector   (public CoreAudio property listeners) │
│     └── emits ProcessAudioSnapshot: [{pid, bundleID, input, output}]   │
│  CameraActivityCollector         (CoreMediaIO IsRunningSomewhere)      │
│     └── emits cameraRunning: Bool                                      │
│  MeetingAppRegistry              (bundle-ID allowlist + tier)          │
│  MeetingLinkParser  (reused from ADR-017 — browser-URL recognition)    │
│                                                                        │
│  MeetingActivityDetector  (pure state machine; no side effects)        │
│     ├── evaluate(signal, now, config, activeRecording,                 │
│     │            candidate, suppressedIdentities)                      │
│     │          -> [DetectionEvent]                                     │
│     ├── DetectionEvent: .promptToRecord / .autoStartDue /             │
│     │                   .signalCleared                                 │
│     └── fusion rule + graduated app-trust tiers + self-exclusion       │
└──────────────────────────────────────────────────────────────────────┘
                 │                                          │
                 │  ActivitySignalSnapshot (shared layer)   │
                 ▼                                          ▼
┌──────────────────────────────────┐      ┌─────────────────────────────────┐
│  MacParakeet (app layer, new)    │      │  ADR-023 auto-stop consumer       │
│                                  │      │  "is a meeting still happening?"  │
│  MeetingActivityDetectionCoord-  │      │  (sustained signal-cleared →      │
│  inator  (@MainActor)            │      │   stop prompt)                    │
│   ├── owns the collectors        │      └─────────────────────────────────┘
│   ├── debounced refresh →        │
│   │     MeetingActivityDetector  │
│   │       .evaluate()            │
│   ├── shows "Record this meeting?"│
│   │     prompt (or countdown toast│
│   │     in .autoStart mode)       │
│   └── routes confirm →            │
│        MeetingRecordingFlow-      │
│        Coordinator.startRecording │
│          (trigger: .activity…)    │
└──────────────────────────────────┘
```

**Ownership:** `MeetingActivityDetectionCoordinator` is a `@MainActor` class
owned by `AppDelegate`, wired in `AppEnvironmentConfigurer` exactly the way
`MeetingAutoStartCoordinator` is — same `NSWorkspace.shared.notificationCenter`
observer style, same settings observer via `.macParakeet…DidChange`, same
`RunLoop.common` debounce timer, same reentrancy/coalescing guard, same
`testHook_` test seam. The collectors live in `MacParakeetCore` so they (and the
pure detector) are testable without the app target.

**Shared signal layer:** `ActivitySignalSnapshot` is the contract. This ADR
produces it and consumes it for the *start* prompt; ADR-023 consumes the same
snapshot for the *stop* prompt. Neither owns the collectors — the coordinator
fans the snapshot out to both.

## Rationale

### Why metadata-only and not "richer" context?

Device-attribution metadata (who holds the mic, is the camera on, who's
frontmost) is everything we need to recognize a meeting and nothing we'd be
uncomfortable explaining. It keeps the local-first / no-content brand intact
(ADR-002): MacParakeet's promise is that your audio and screen never leave the
device, and this feature never even *reads* them. Anything richer (screen OCR,
log-stream scraping) trades that clarity for marginal precision.

### Why the conservative fusion rule instead of "any meeting app open"?

"Zoom is running" is a weak signal — Zoom can sit idle in the background for
hours. "Zoom is running AND holding the mic AND (camera on OR it's a dedicated
meeting app)" is a meeting. We bias hard toward precision because a false prompt
costs trust permanently while a missed meeting just falls back to manual
recording, which already works.

### Why graduated app-trust tiers?

A flat rule can't express that a dedicated meeting app and an always-on chat app
deserve different scrutiny. Slack is open all day; demanding full-duplex audio
(both input and output streams) distinguishes "in a Slack huddle" from "Slack is
just running." Browsers are the wildest card, so they earn the strictest gate
(frontmost or a recognized URL). The tiers are the minimum structure that keeps
false positives near zero across very different apps.

### Why a pure detector mirroring `MeetingMonitor`?

ADR-017 proved the pattern: a `static` `Sendable` `evaluate(...)` with all state
passed in is trivially unit-testable (table tests over fabricated snapshots,
mirroring `MeetingMonitorTests`) and trivially safe to call from any actor. The
coordinator stays a thin I/O shell; every interesting decision is a pure
function with no EventKit, no CoreAudio, no UI in the way.

### Why reuse the ADR-017 countdown toast for `.autoStart`?

`.autoStart` mode needs exactly what calendar auto-start needs: a brief,
cancellable "we're about to record" surface. Reusing
`MeetingCountdownToastController` means one floating-panel controller to
maintain, consistent UX, and visual continuity (the repo's lesson —
`feedback_visual_continuity_over_invention`).

## Consequences

### Positive

- Closes the gap ADR-017 left open: **unscheduled** meetings (ad-hoc calls,
  someone else's invite, quick huddles) get the same "don't forget to record"
  safety net.
- Fully local — metadata-only, nothing leaves the device; preserves ADR-002 and
  the no-content brand.
- The shared signal layer is a two-for-one: ADR-023 auto-stop consumes it
  directly instead of building parallel collectors.
- Pure detector → cheap, deterministic table tests; the coordinator pattern is
  already proven by ADR-017.
- Default off / opt-in / staged behind a flag — zero behavior change for
  existing users until they choose it.

### Negative

- **New macOS frameworks (CoreMediaIO; deeper CoreAudio).** More surface to
  maintain across OS releases. Mitigated by leaning only on *public, stable*
  properties and treating any unavailability as "no signal" (fail closed — no
  prompt — never crash).
- **Bundle-ID allowlist drifts.** New meeting apps (and bundle-ID renames like
  the Teams `teams2` migration) need allowlist updates. Low impact: an
  unrecognized app simply doesn't trigger, which is the safe direction.
- **Another floating surface.** The "Record this meeting?" prompt is new UI to
  maintain alongside the pill, panel, dictation overlay, and countdown toast.
  Mitigated by reusing the countdown toast for the `.autoStart` path.
- **Idle-CPU risk if collectors are sloppy.** A polling collector or a
  never-torn-down listener would regress idle CPU. Mitigated by the
  event-driven design and strict teardown invariants (and a focused idle-CPU
  check before flag-on, per PR #467's lesson).

## Implementation Direction

### Core types (MacParakeetCore)

- `AudioProcessActivityCollector` — wraps `kAudioHardwarePropertyProcessObjectList`
  + per-process `IsRunningInput/Output` / `PID` / `BundleID`; installs property
  listeners; emits `ProcessAudioSnapshot`. **Self-PID excluded at the source.**
- `CameraActivityCollector` — wraps `kCMIODevicePropertyDeviceIsRunningSomewhere`;
  installs a property listener; emits `cameraRunning: Bool`.
- `MeetingAppRegistry` — static bundle-ID → `MeetingApp` + trust-tier map.
- `ActivitySignalSnapshot` — plain `Sendable` struct: mic-holders, output-holders,
  camera state, frontmost bundle ID, and browser bundle IDs with recognized
  meeting URLs (via `MeetingLinkParser`).
- `MeetingActivityDetector` — `static evaluate(...) -> [DetectionEvent]`;
  fusion rule + tiers + self-exclusion + dwell + suppression. No stored state.
- `MeetingActivityDetectionMode` / `MeetingActivityDetector.Config` — `Codable`,
  `Sendable`.

### Settings (MacParakeetViewModels)

- Extend `SettingsViewModel` with `meetingActivityDetectionMode` (and any
  cooldown/dwell tunables we expose — likely none in v1). Persist under a
  `MeetingActivityDetection.*` `UserDefaults` namespace.
- `didSet` posts a new `AppNotification.macParakeetMeetingActivitySettingsDidChange`
  and fires `Telemetry.send(.settingChanged(setting: .meetingActivityDetectionMode))`.

### App layer (MacParakeet)

- `MeetingActivityDetectionCoordinator` — `@MainActor`; owns the collectors,
  debounced refresh, settings + workspace observers, prompt/countdown surface;
  routes confirm → `MeetingRecordingFlowCoordinator.startRecording(trigger: .activityDetection)`.
  No-ops when `activeRecording` is already true (manual/calendar start wins by
  arriving first — symmetric with ADR-017 §10).
- New `MeetingActivityPromptController` (or reuse the countdown toast for
  `.autoStart`) — small non-activating floating panel (`KeylessPanel`) with
  "Record" / "Not now". "Not now" suppresses this `MeetingIdentity` for the
  cooldown window.
- Settings UI: a control in the Meeting Recording settings card, rendered only
  when `AppFeatures.meetingActivityDetectionEnabled` is `true`.
- `MeetingRecordingFlowCoordinator` — add `.activityDetection` (and, for §7
  auto-start, `.activityAutoStart`) cases to `TelemetryMeetingRecordingTrigger`,
  threaded through `startRecording` the same way `.calendarAutoStart` is.

### Wiring (AppEnvironmentConfigurer)

- Construct + `.start()` the coordinator behind
  `AppFeatures.meetingActivityDetectionEnabled` (only when
  `meetingRecordingEnabled` is also true — detection only makes sense when the
  user can record), exactly where `MeetingAutoStartCoordinator` is wired.

## Telemetry (new cases — must mirror to website allowlist)

Privacy-safe, coarse, no raw app names beyond the allowlist enum:

- `.meetingActivityDetectionShown(signalSource: SignalSource, appCategory: MeetingAppCategory)`
  — a prompt/countdown was surfaced. `signalSource` ∈ {`micCamera`, `micApp`,
  `micCameraApp`}; `appCategory` ∈ {`dedicated`, `chat`, `browser`, `unknown`}
  — **the allowlist enum only, never a free-form bundle ID or app name.**
- `.meetingActivityDetectionAccepted(signalSource:appCategory:)` — user chose
  Record.
- `.meetingActivityDetectionDeclined(signalSource:appCategory:)` — user chose
  Not now (identity suppressed for the cooldown).
- `.settingChanged(setting: .meetingActivityDetectionMode)`.

> **Two-repo change.** Each new `TelemetryEventName` case here must *also* be
> added to `ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts`.
> The Worker rejects the **entire batch** if any event name is unknown — silently
> dropping co-batched valid events. Deploy the website allowlist change *before*
> shipping a build that emits these.

## Out of Scope (explicitly not building)

- **Screen capture / OCR-based context.** No reading windows, no scraping UI
  text. Metadata only — this is the brand line.
- **Per-app camera attribution via private OS log streams.** Tempting (it would
  tell us *which* app drives the camera), but it parses private/undocumented log
  formats that break across macOS releases. CoreMediaIO's "a camera is running
  *somewhere*" — combined with the audio-process attribution we already
  have — is enough for v1. Camera answers "is this video?", the audio process
  answers "who".
- **Always-on heavy polling.** No timer loops at rest. Collectors and listeners
  tear down when the feature is off, when a recording is already active, and
  when no audio process is using the mic. Idle cost must measure ~0%.
- **Network calls / cloud anything.** Detection is fully on-device.

## Invariants

- **Local-first (ADR-002):** metadata only — process IDs, bundle IDs, boolean
  device states. No audio, no screen content, nothing leaves the device.
- **Manual + calendar flows unchanged:** ADR-014 manual start and ADR-017
  calendar start/reminder behave identically; detection is additive and no-ops
  when a recording is already active.
- **Idle-CPU hygiene:** event-driven collectors; listeners and timers torn down
  when not needed; debounced refresh; measured idle delta ~0% (PR #467 lesson).
- **Never auto-record without opt-in:** `.off` is the default; recording only
  ever starts on explicit user confirmation, except in the separately-opted-in
  `.autoStart` mode, which still shows a cancellable countdown.
- **Self-exclusion:** MacParakeet's own capture is subtracted from all signals
  before fusion — an active recording can never re-trigger detection on itself.

## Phased Rollout

1. **Phase A — Audio-process attribution + pure detector (foundation).**
   `AudioProcessActivityCollector` (with self-exclusion), `MeetingAppRegistry`,
   the `MeetingActivityDetector` skeleton (app-signal path only, no camera yet),
   and table tests. Flag stays off; no UI. Verifiable headlessly.
2. **Phase B — Camera collector + full fusion rule.** `CameraActivityCollector`,
   wire camera into `ActivitySignalSnapshot`, the full fusion rule + graduated
   trust tiers + self-exclusion across both signal types. More table tests.
3. **Phase C — Prompt + settings + coordinator wiring.** The
   `MeetingActivityDetectionCoordinator`, the "Record this meeting?" prompt,
   the `.prompt` settings mode, dwell + suppression + debounce, telemetry +
   website allowlist mirror. First user-visible (flag-on) slice.
4. **Phase D — `.autoStart` mode + ADR-023 auto-stop feed.** Opt-in
   auto-record-on-detect via the reused countdown toast, and expose
   `ActivitySignalSnapshot` to ADR-023's auto-stop consumer (the "meeting still
   happening?" signal).

Flag-on (any tagged release) is a separate decision after Phase C/D land and a
focused false-positive + idle-CPU pass clears.

## Open Questions

- **Identity granularity for suppression.** What defines one "meeting" for the
  decline-cooldown? Recognized-app + a coarse session boundary (mic-active span)
  is the metadata-only candidate — is that stable enough that "Not now" reliably
  suppresses the *same* call without bleeding into the next one an hour later?
- **Cooldown length.** How long after a decline before we'd re-offer the same
  identity? Short enough to catch a genuinely new call on the same app; long
  enough never to feel like nagging. Needs a default to pick.
- **`.prompt` vs `.autoStart` as the recommended on-state.** Is the gentle
  prompt enough value to be the headline, with `.autoStart` as power-user depth,
  or does the prompt's interruption undercut the "I forgot" win? Lean prompt
  for v1; revisit from telemetry.
- **Relationship to calendar auto-start when both fire.** If a calendar event
  *and* an activity signal both point at the same live meeting, which surface
  wins, and how do we de-dupe so the user sees one prompt, not two? (First-to-
  arrive wins + a short cross-suppression window is the leaning answer.)
- **Browser meeting-URL detection without screen access.** Recognizing a Meet/
  Teams tab needs the active tab URL. Is there a metadata-only path (e.g. the
  frontmost window's accessibility-exposed URL) that stays within the no-content
  invariant, or do browsers stay limited to "frontmost + mic" until one exists?
