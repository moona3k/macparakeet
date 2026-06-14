# Activity-Based Meeting Detection

**Status:** PROPOSED — not started. Implementation plan for a future coding
agent. Nothing here ships until a tagged release flips
`AppFeatures.meetingActivityDetectionEnabled` (default off until then).
**Date:** 2026-06-14
**ADRs:** ADR-024 (activity-based meeting detection — the decision this plan
implements). Related: ADR-002 (local-first), ADR-014 (meeting recording),
ADR-015 (concurrent dictation/meeting), ADR-017 (calendar auto-start — the
coordinator/pure-evaluator pattern to mirror), ADR-023 (activity-based
auto-stop — consumes the same signal layer this plan builds).
**Requirement:** REQ-MEET-016 (v0.7, proposed).

## What this plan closes out

ADR-017 lets MacParakeet notice **scheduled** meetings from the calendar and
offer to record. But many real meetings never hit the calendar — ad-hoc calls,
someone else's invite, a quick huddle. For those, the user is back to the
original ADR-014 failure mode: the first minutes are gone before anyone presses
record.

ADR-024 adds an **activity-signal detection layer** that recognizes a live
meeting from on-device, metadata-only signals (who holds the mic, is the camera
on, which app is frontmost) and offers to record it. As a byproduct it produces
the shared `ActivitySignalSnapshot` that ADR-023 auto-stop consumes to answer
"is a meeting still happening?".

This is the file-by-file breakdown. It is sequenced into independently shippable
slices; nothing is big-bang. Each phase keeps the feature flag **off** until
Phase C/D land and a false-positive + idle-CPU pass clears.

## Scope boundaries

### In scope
- Per-process audio attribution via public CoreAudio
  (`kAudioHardwarePropertyProcessObjectList` + `IsRunningInput/Output` / `PID` /
  `BundleID`), event-driven via property listeners. Self-PID excluded at source.
- Camera activity via CoreMediaIO (`kCMIODevicePropertyDeviceIsRunningSomewhere`),
  event-driven.
- Recognized conferencing-app registry (bundle-ID allowlist + trust tiers) +
  browser-with-recognized-URL via the existing `MeetingLinkParser`.
- Pure `MeetingActivityDetector` state machine: fusion rule, graduated trust
  tiers, self-exclusion, candidate dwell, per-identity decline suppression +
  cooldown, debounced refresh.
- `@MainActor MeetingActivityDetectionCoordinator` mirroring
  `MeetingAutoStartCoordinator`.
- "Record this meeting?" prompt (+ reused countdown toast for `.autoStart`).
- Settings control (`MeetingActivityDetectionMode`) + onboarding-free Settings
  surface, mirroring the ADR-017 settings/notification/telemetry pattern.
- New `AppFeatures.meetingActivityDetectionEnabled` flag for staged rollout.
- Telemetry cases + website allowlist mirror.
- Expose `ActivitySignalSnapshot` for the ADR-023 auto-stop consumer.

### Out of scope
- Screen capture / OCR / window-content reading (metadata-only is the brand line).
- Private OS log-stream parsing for per-app camera attribution (fragile across
  macOS releases — CoreMediaIO "running somewhere" + audio-process attribution
  is enough for v1).
- Always-on heavy polling (collectors/listeners tear down at rest).
- Any network / cloud path (fully on-device).
- Auto-stop itself (ADR-023 owns it; this plan only *feeds* it the snapshot).
- The deeper `.autoStart` auto-record path is Phase D, not Phase A–C.

### Invariants
- **Local-first (ADR-002):** metadata only (PIDs, bundle IDs, boolean device
  states). No audio, no screen content, nothing leaves the device.
- **Manual + calendar flows unchanged:** ADR-014 manual start and ADR-017
  calendar start/reminder behave identically; detection is additive and no-ops
  when a recording is already active (manual/calendar start wins by arriving
  first — ADR-017 §10 symmetry).
- **Idle-CPU hygiene:** event-driven collectors; listeners/timers torn down when
  the feature is off, a recording is active, or no mic is in use; debounced
  refresh. Measured idle delta ~0% app-frontmost (PR #467 lesson — occluded
  reads 0% and lies).
- **Self-exclusion:** MacParakeet's own capture is subtracted before fusion — an
  active recording can never re-trigger detection on itself.
- **Never auto-record without opt-in:** default `.off`; recording starts only on
  explicit confirmation, except the separately-opted-in `.autoStart` mode, which
  still shows a cancellable countdown.

## Phased rollout

### Phase A — Audio-process attribution collector + pure detector (foundation)

Flag stays off; no UI. Headlessly verifiable via tests. The pure detector lands
with the **app-signal path only** (camera arrives in Phase B), so the fusion
rule is partial but the structure (tiers, self-exclusion, dwell, suppression) is
in place and tested.

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/AppFeatures.swift` | Add `meetingActivityDetectionEnabled: Bool = false`. Doc-comment mirrors `calendarEnabled`'s framing (what's hidden when off; intact services). |
| `Sources/MacParakeetCore/MeetingDetection/AudioProcessActivityCollector.swift` *(new)* | Public CoreAudio wrapper. `kAudioHardwarePropertyProcessObjectList` + per-object `IsRunningInput/Output` / `PID` / `BundleID`. Installs property listeners (`AudioObjectAddPropertyListenerBlock`); emits `ProcessAudioSnapshot`. **Excludes our own PID/bundle ID at the source.** Tears down listeners on stop. |
| `Sources/MacParakeetCore/MeetingDetection/MeetingAppRegistry.swift` *(new)* | Static bundle-ID → `MeetingApp` + trust-tier map (Zoom `us.zoom.xos`; Teams `com.microsoft.teams2`/`com.microsoft.teams`; Webex `com.cisco.webexmeetingsapp`/`Cisco-Systems.Spark`; Slack `com.tinyspeck.slackmacgap`; FaceTime `com.apple.FaceTime`; browser bundle IDs). |
| `Sources/MacParakeetCore/MeetingDetection/ActivitySignalSnapshot.swift` *(new)* | Plain `Sendable` struct: mic-holders, output-holders, camera state (field present, set in Phase B), frontmost bundle ID, recognized meeting URL. The shared contract ADR-023 also consumes. |
| `Sources/MacParakeetCore/MeetingDetection/MeetingActivityDetector.swift` *(new)* | Pure `enum`, `static evaluate(signal:now:config:activeRecording:candidateSince:suppressedIdentities:) -> [DetectionEvent]`. `DetectionEvent`: `.promptToRecord` / `.autoStartDue` / `.signalCleared`. App-signal fusion + tiers + self-exclusion + dwell + suppression. No stored state. Mirrors `MeetingMonitor`. |
| `Sources/MacParakeetCore/MeetingDetection/MeetingActivityDetectionMode.swift` *(new)* | `.off` / `.prompt` / `.autoStart`, `Codable`/`Sendable`. |
| `Tests/MacParakeetTests/MeetingDetection/MeetingActivityDetectorTests.swift` *(new)* | Table tests mirroring `MeetingMonitorTests`: mic-alone does not trigger; mic + dedicated-app triggers; chat-app without full-duplex does not; self-PID excluded; dwell gate (candidate must persist); declined identity suppressed for cooldown; `.signalCleared` when signal drops. |

**Ship criteria:** `swift test` green. Detector returns correct events for
fabricated snapshots. Collector compiles and excludes self. No user-visible
change (flag off, no coordinator).

### Phase B — Camera collector + full fusion rule + self-exclusion across signals

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/MeetingDetection/CameraActivityCollector.swift` *(new)* | CoreMediaIO wrapper. `kCMIODevicePropertyDeviceIsRunningSomewhere` property listener; emits `cameraRunning: Bool` on transitions. Tears down on stop. Treats unavailability as "no camera signal" (fail closed). |
| `Sources/MacParakeetCore/MeetingDetection/ActivitySignalSnapshot.swift` | Camera state now populated. |
| `Sources/MacParakeetCore/MeetingDetection/MeetingActivityDetector.swift` | Complete the fusion rule: **mic active AND (camera active OR recognized app/URL)**; camera-alone never triggers. Graduated tiers finalized — dedicated apps (running + mic), chat apps (full-duplex audio), browsers (frontmost or recognized URL). Self-exclusion applied across both signal types. |
| `Sources/MacParakeetCore/MeetingDetection/MeetingLinkParser` *(reused — no new file)* | Used by the coordinator/snapshot builder to recognize a browser meeting URL. No change to the parser. |
| `Tests/MacParakeetTests/MeetingDetection/MeetingActivityDetectorTests.swift` | Extend: camera-alone (Photo Booth / scanner) does NOT trigger; mic + camera triggers; mic + camera but self-only is excluded; browser frontmost-with-URL triggers, browser-background does not; chat full-duplex triggers, half-duplex does not. |

**Ship criteria:** `swift test` green. Full fusion matrix covered by table tests.
Still flag-off / no UI.

### Phase C — Prompt state machine + settings + coordinator wiring (first flag-on slice)

| File | Change |
|------|--------|
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | New `meetingActivityDetectionMode: MeetingActivityDetectionMode` persisted under a `MeetingActivityDetection.*` `UserDefaults` namespace. `didSet` posts the new notification + `Telemetry.send(.settingChanged(setting: .meetingActivityDetectionMode))`. Mirror the `calendarAutoStartMode` block exactly. |
| `Sources/MacParakeetCore/AppNotifications.swift` | Add `macParakeetMeetingActivitySettingsDidChange`. |
| `Sources/MacParakeet/App/MeetingActivityDetectionCoordinator.swift` *(new)* | `@MainActor`. Owns both collectors; subscribes to settings + `NSWorkspace` (frontmost-app / wake) notifications via `NSWorkspace.shared.notificationCenter`; debounced refresh on a `RunLoop.common` timer; reentrancy/coalescing guard; `testHook_` seam. Builds `ActivitySignalSnapshot`, calls `MeetingActivityDetector.evaluate(...)`, holds `candidateSince` + `suppressedIdentities`, drives the prompt. Routes confirm → `MeetingRecordingFlowCoordinator.startRecording(trigger: .activityDetection)`; no-ops when a recording is already active. Tears down collectors when mode is `.off` / a recording is active / no mic in use. |
| `Sources/MacParakeet/Views/MeetingRecording/MeetingActivityPromptController.swift` *(new)* | Non-activating `KeylessPanel` "Record this meeting?" prompt with Record / Not now. "Not now" suppresses the current `MeetingIdentity` for the cooldown. |
| `Sources/MacParakeet/App/AppEnvironmentConfigurer.swift` | Construct + `.start()` the coordinator behind `AppFeatures.meetingActivityDetectionEnabled` (only when `meetingRecordingEnabled` is also true), where `MeetingAutoStartCoordinator` is wired. Add to `Runtime`. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Add `.activityDetection` to `TelemetryMeetingRecordingTrigger`; thread through `startRecording(trigger:)` like `.calendarAutoStart`. |
| `Sources/MacParakeet/Views/Settings/` (Meeting Recording card) | Add the mode control, rendered only when `AppFeatures.meetingActivityDetectionEnabled` is `true`. |
| `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` | Add `.meetingActivityDetectionShown/Accepted/Declined(signalSource:appCategory:)` + `TelemetrySettingName.meetingActivityDetectionMode`. Coarse enums only — no bundle IDs / app names. |
| `../macparakeet-website/functions/api/telemetry.ts` | **Mirror every new `TelemetryEventName` into `ALLOWED_EVENTS`.** Deploy before shipping a flag-on build (the Worker rejects the whole batch on an unknown event). |
| `Tests/MacParakeetTests/MeetingDetection/MeetingActivityDetectionCoordinatorTests.swift` *(new)* | Mirror `MeetingAutoStartCoordinatorTests`: active recording suppresses the prompt; decline suppresses the same identity for cooldown; mode `.off` tears collectors down; debounce coalesces bursts; confirm routes to the flow coordinator with `.activityDetection`. |

**Ship criteria:** End-to-end with flag on locally: starting a Zoom/Teams call
(mic + camera) surfaces a "Record this meeting?" prompt after the dwell; Record
starts a recording with `trigger=activity_detection`; Not now suppresses that
call; a plain video play / Photo Booth does NOT prompt. Idle CPU delta ~0%
measured app-frontmost.

### Phase D — Opt-in `.autoStart` + feed ADR-023 auto-stop

| File | Change |
|------|--------|
| `Sources/MacParakeet/App/MeetingActivityDetectionCoordinator.swift` | Handle `.autoStartDue` in `.autoStart` mode → reuse `MeetingCountdownToastController` (cancellable) → `startRecording(trigger: .activityAutoStart)`. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Add `.activityAutoStart` trigger case. |
| `Sources/MacParakeet/Views/Settings/` (Meeting Recording card) | Unclamp the `.autoStart` option. |
| `Sources/MacParakeetCore/MeetingDetection/` (snapshot surface) | Expose `ActivitySignalSnapshot` (via the coordinator) to the ADR-023 auto-stop consumer — the "meeting still happening?" signal. Exact handoff finalized with ADR-023. |
| `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` + website | Add any `.autoStart`-specific telemetry; mirror to allowlist. |
| `Tests/MacParakeetTests/MeetingDetection/MeetingActivityDetectionCoordinatorTests.swift` | `.autoStart`: countdown cancel does not start; completion routes `.activityAutoStart`; mode change mid-countdown closes it (ADR-017 mid-flight-teardown symmetry). |

**Ship criteria:** `.autoStart` mode records on detection after a cancellable
countdown; ADR-023 receives the shared snapshot. Flag-on decision is separate,
after a false-positive + idle-CPU pass.

## Testing matrix

- `swift test` baseline before each phase; green after.
- Pure-detector table tests are the spine (mirror `MeetingMonitorTests`):
  fusion matrix, tiers, self-exclusion, dwell, suppression/cooldown.
- Coordinator tests mirror `MeetingAutoStartCoordinatorTests` (active-recording
  suppression, decline cooldown, mode-off teardown, debounce coalescing).
- Manual smoke per phase per the ship criteria above (real Zoom/Teams/FaceTime
  call; a chat-app huddle; a browser Meet tab; plus negatives: video playback,
  Photo Booth, a background chat app).
- Idle-CPU smoke: app frontmost, no meeting active — collectors quiescent,
  delta ~0% (PR #467 lesson; occluded reads lie).

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| False-positive prompt (video playback, Photo Booth, idle chat app) | Medium | High (trust loss) | Conservative fusion (mic AND …), graduated tiers, dwell, decline-cooldown; negative-case table tests |
| Idle-CPU regression from collectors | Low | Medium | Event-driven listeners (no rest polling), strict teardown, debounce, measured idle pass before flag-on |
| Self-retrigger loop (our own capture) | Low | High | Self-PID excluded at the collector source; invariant + test |
| CoreMediaIO / CoreAudio property unavailable on some OS | Low | Low | Fail closed — treat as "no signal", never crash, fall back to manual/calendar |
| Bundle-ID allowlist drift (new app, rename like Teams `teams2`) | Medium | Low | Unrecognized app simply doesn't trigger (safe direction); allowlist is one file |
| Double prompt when calendar + activity both fire | Medium | Low | First-to-arrive wins + short cross-suppression window (open question in ADR-024) |

## Documentation hygiene (when phases land)

- Mark ADR-024 status from PROPOSAL → IMPLEMENTED as phases ship; record any
  amendments inline (ADR-017 style).
- `spec/README.md` + `spec/02-features.md`: add the activity-detection entry to
  the meeting section; update REQ-MEET-016 status when the coordinator wires.
- `CLAUDE.md` Release Channels: note the new `AppFeatures` flag in the
  `main`-vs-release delta until it ships in a tagged build.
- Archive this plan to `plans/completed/` once Phase C/D land and the flag is
  on in a release.
