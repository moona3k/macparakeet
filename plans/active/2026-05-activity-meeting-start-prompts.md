# Activity-Based Meeting Start Prompts

> Status: ACTIVE PLAN
> Date: 2026-05-26
> Scope: expand meeting start beyond calendar-only signals with local activity-based prompts. No automatic activity start in v1.

## Problem

MacParakeet already has calendar-driven meeting reminders and opt-in
calendar auto-start. That covers scheduled meetings, but not the common
ad-hoc cases:

- Someone starts a Zoom call from Slack.
- A Google Meet tab opens outside the calendar event window.
- A FaceTime or Teams call starts without a useful calendar link.
- The user joins late, or the calendar event title/link is wrong.

The product gap is not "record every time a signal appears." The safer gap is
"notice that the user is probably in a meeting and ask whether to start
recording."

The first expansion should be prompt-based, conservative, local-only, and
parallel to the existing calendar coordinator.

## Decision

Build an activity-based meeting start prompt system as a new surface next to
ADR-017 calendar auto-start:

1. Keep `MeetingMonitor` and `MeetingAutoStartCoordinator` focused on EventKit.
2. Add a separate activity detector/coordinator that produces
   `MeetingStartCandidate` values from local signals.
3. Prompt the user before starting a recording.
4. Do not activity-auto-start in v1.
5. Do not activity-auto-stop in this plan.
6. Do not add a database schema migration for v1; settings and ignored bundle
   IDs can live in UserDefaults.

This preserves the existing calendar path and lets the new subsystem iterate
without turning scheduled meeting logic into a mixed calendar/activity state
machine.

## Current MacParakeet Baseline

Important facts to preserve:

- `AppFeatures.calendarEnabled = true`; calendar is implemented and enabled.
- Calendar auto-start mode defaults to `.off`, so calendar behavior is
  strictly opt-in.
- `MeetingMonitor` is a pure `MacParakeetCore` evaluator over calendar events.
- `MeetingAutoStartCoordinator` owns EventKit polling, settings observation,
  notification/reminder handling, countdown toast, and the call into
  `MeetingRecordingFlowCoordinator.startFromCalendar(title:)`.
- Calendar-driven auto-stop has been removed. Scheduled end times are not used
  to stop recordings.
- `.lateJoinAvailable` already exists in `MeetingMonitor`, but no UI is wired.
- Meeting recording start ownership currently distinguishes manual and calendar
  starts via `MeetingRecordingFlowCoordinator` trigger handling.

The activity system should reuse those lessons:

- Pure resolver/state machine in Core.
- App-layer adapters for AppKit, CoreAudio, CoreMediaIO, notifications, and
  UI.
- Explicit feature/user preference gates.
- Recording starts still flow through `MeetingRecordingFlowCoordinator`.

## Sources Reviewed

The implementation guidance below is based on direct source review of these
open-source projects and local SDK headers.

| Project | Reviewed commit | Relevant files |
|---|---:|---|
| Steno | `d3849f463851` | [`mic-monitor/mic_monitor.swift`](https://github.com/ruzin/stenoai/blob/d3849f463851ca1900463c62449baf12e7288b5a/mic-monitor/mic_monitor.swift), [`app/main.js`](https://github.com/ruzin/stenoai/blob/d3849f463851ca1900463c62449baf12e7288b5a/app/main.js) |
| Hyprnote / Anarlog | `58040f6df7df` | [`crates/detect`](https://github.com/fastrepl/hyprnote/tree/58040f6df7df415e20935d6062704e19856bd34a/crates/detect), [`plugins/detect`](https://github.com/fastrepl/hyprnote/tree/58040f6df7df415e20935d6062704e19856bd34a/plugins/detect) |
| Muesli | `8016b1d47199` | [`MeetingDetector.swift`](https://github.com/pHequals7/muesli/blob/8016b1d4719936566a27cfef5b4d5ca01a2f6e89/native/MuesliNative/Sources/MuesliNativeApp/MeetingDetector.swift), [`MeetingCandidateResolver.swift`](https://github.com/pHequals7/muesli/blob/8016b1d4719936566a27cfef5b4d5ca01a2f6e89/native/MuesliNative/Sources/MuesliNativeApp/MeetingCandidateResolver.swift), [`AudioProcessAttributionCollector.swift`](https://github.com/pHequals7/muesli/blob/8016b1d4719936566a27cfef5b4d5ca01a2f6e89/native/MuesliNative/Sources/MuesliNativeApp/AudioProcessAttributionCollector.swift), [`MeetingPromptStateMachine.swift`](https://github.com/pHequals7/muesli/blob/8016b1d4719936566a27cfef5b4d5ca01a2f6e89/native/MuesliNative/Sources/MuesliNativeApp/MeetingPromptStateMachine.swift), [`CameraActivityMonitor.swift`](https://github.com/pHequals7/muesli/blob/8016b1d4719936566a27cfef5b4d5ca01a2f6e89/native/MuesliNative/Sources/MuesliNativeApp/CameraActivityMonitor.swift) |
| OpenOats | `eff5a63c1fa3` | [`MeetingDetector.swift`](https://github.com/yazinsai/OpenOats/blob/eff5a63c1fa3f4f4ff6ddaf703d7298a170f3d73/OpenOats/Sources/OpenOats/Meeting/MeetingDetector.swift), [`CameraActivityMonitor.swift`](https://github.com/yazinsai/OpenOats/blob/eff5a63c1fa3f4f4ff6ddaf703d7298a170f3d73/OpenOats/Sources/OpenOats/Meeting/CameraActivityMonitor.swift), [`MeetingDetectionController.swift`](https://github.com/yazinsai/OpenOats/blob/eff5a63c1fa3f4f4ff6ddaf703d7298a170f3d73/OpenOats/Sources/OpenOats/App/MeetingDetectionController.swift), [`NotificationService.swift`](https://github.com/yazinsai/OpenOats/blob/eff5a63c1fa3f4f4ff6ddaf703d7298a170f3d73/OpenOats/Sources/OpenOats/Meeting/NotificationService.swift) |
| OpenWhispr | `19b066c8b31a` | [`resources/macos-mic-listener.swift`](https://github.com/OpenWhispr/openwhispr/blob/19b066c8b31afdd32514e3693ec18eaaa3010bb9/resources/macos-mic-listener.swift), [`src/helpers/meetingDetectionEngine.js`](https://github.com/OpenWhispr/openwhispr/blob/19b066c8b31afdd32514e3693ec18eaaa3010bb9/src/helpers/meetingDetectionEngine.js), [`src/helpers/audioActivityDetector.js`](https://github.com/OpenWhispr/openwhispr/blob/19b066c8b31afdd32514e3693ec18eaaa3010bb9/src/helpers/audioActivityDetector.js), [`src/helpers/meetingProcessDetector.js`](https://github.com/OpenWhispr/openwhispr/blob/19b066c8b31afdd32514e3693ec18eaaa3010bb9/src/helpers/meetingProcessDetector.js) |

Official Apple references checked:

- [Core Audio](https://developer.apple.com/documentation/CoreAudio) and
  [`kAudioProcessPropertyBundleID`](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertybundleid)
  confirm the public `AudioHardwareProcess` surface and its related process
  properties, including PID, bundle ID, devices, input state, and output state.
- [`AudioObjectAddPropertyListenerBlock`](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock%28_%3A_%3A_%3A_%3A%29)
  is the public property-listener mechanism for waking the adapter on hardware
  state changes.
- [`kAudioDevicePropertyDeviceIsRunningSomewhere`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertydeviceisrunningsomewhere)
  is public CoreAudio device activity state.
- [`kCMIODevicePropertyDeviceIsRunningSomewhere`](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunningsomewhere)
  is public CoreMediaIO camera activity state.
- [`NSWorkspace.runningApplications`](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications)
  and [`frontmostApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
  are public AppKit surfaces for app snapshots and frontmost-app context.
- [Declaring actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)
  and [`UNNotificationCategory.actions`](https://developer.apple.com/documentation/usernotifications/unnotificationcategory/actions)
  define the official notification action model and banner action limits.
- [Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)
  and [`EKEventStoreChangedNotification`](https://developer.apple.com/documentation/eventkit/ekeventstorechangednotification)
  confirm the existing calendar permission/refetch model this activity plan
  must not disturb.

SDK feasibility was checked against the installed macOS SDK:

- CoreAudio exposes process-level audio properties in
  `AudioHardware.h`: `kAudioHardwarePropertyProcessObjectList`,
  `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
  `kAudioProcessPropertyDevices`, and
  `kAudioProcessPropertyIsRunningInput`.
- CoreMediaIO exposes camera running state in `CMIOHardwareDevice.h`:
  `kCMIODevicePropertyDeviceIsRunningSomewhere`.

These are public SDK headers. Avoid designs that depend on private KVC keys or
parsing Control Center logs.

Grounding notes:

- The CoreAudio process properties are appropriate for attribution, but the
  default-input "running somewhere" device listener should be treated as a
  wake-up signal. The authoritative candidate evidence should come from a
  process snapshot.
- `NSWorkspace.runningApplications` can be called from any thread, but Apple
  says changes arrive when the main run loop runs in a common mode and
  recommends KVO instead of tight polling. The app adapter should observe and
  snapshot rather than spin.
- EventKit objects are stale after `EKEventStoreChangedNotification`; existing
  calendar code already refetches. Activity should consume `CalendarEvent`
  snapshots from the existing calendar service, not hold `EKEvent` objects.
- If any future release makes the app sandboxed, Apple requires the Calendar
  entitlement for reading calendar data. This plan adds no new calendar access;
  it should reuse the current calendar permission/service path.
- UserNotifications can support custom actions, but banners display only the
  first two actions. Do not rely on every prompt action being visible from a
  notification banner.

## Competitive Findings

### Steno

Steno has a small, practical design:

- A Swift helper emits JSON lines when mic use starts/stops.
- On macOS 14+, it uses CoreAudio process objects to attribute mic activity to
  a PID, bundle ID, and app name.
- It normalizes browser/helper processes to parent user-facing apps.
- It ignores its own app.
- It shows a native "Meeting detected" notification with a "Take Notes"
  action.
- It has a 60-second per-app notification debounce.
- It auto-pauses after a detected app stops using the mic.

Borrow:

- Process-attributed mic detection.
- Browser/helper normalization.
- Per-app debounce.
- Self-exclusion.

Do not borrow yet:

- Default-on detection.
- Auto-pause/auto-stop.
- Generic mic-start prompt without a stronger meeting context.

### Hyprnote / Anarlog

Hyprnote has the strongest policy layer:

- Core detector emits `MicStarted(apps)` and `MicStopped(apps)`.
- macOS implementation uses CoreAudio process attribution and an event-driven
  default-input listener.
- It seeds initial state so launching the detector while the mic is already in
  use does not create a false "started" prompt.
- It requires sustained mic activity before surfacing a prompt. The default
  threshold is 15 seconds.
- It has a 10-minute cooldown after a prompt/claim.
- Its policy filters ignored app categories and supports user ignored/included
  bundle IDs.
- It can respect Do Not Disturb.
- It has optional Zoom mute detection through Accessibility menu inspection.

Borrow:

- Sustained-activity threshold for weak candidates.
- Policy object for app filtering and user ignored bundle IDs.
- Cooldown/suppression as first-class logic, not UI glue.
- Initial-state seeding.

Do not borrow yet:

- Zoom mute watcher. It adds Accessibility complexity and is not needed for
  start prompts.
- Broad ignored category list as product copy. Use it as seed data only.

### Muesli

Muesli has the best candidate model:

- It separates raw signals from candidate resolution.
- A candidate carries an evidence set: mic, camera, browser URL, calendar
  event, foreground app, dedicated app, audio input process, and source
  identity.
- It treats Slack/WhatsApp-style apps as weak/noisy and requires more evidence.
- It distinguishes candidate identity from suppression identity.
- It uses a prompt state machine with stability delay and dismissal
  suppression.
- It suppresses activity prompts while a calendar notification/countdown is
  visible.
- It uses process-level audio input/output attribution.
- It experiments with browser URL and Control Center sensor attribution.

Borrow:

- Pure candidate resolver with an evidence set.
- Candidate ID vs suppression ID.
- Weak/noisy app handling.
- Prompt state machine with stability delay.
- Calendar UI suppression.
- Process-level audio attribution including input/output state.

Do not borrow yet:

- Control Center `log stream` parsing for sensor attribution.
- Private camera device mapping by KVC `_connectionID`.
- Browser URL extraction as a required v1 signal.

### OpenOats

OpenOats is useful for Swift shape:

- It defines protocolized audio/camera signal sources.
- Audio and camera activity are exposed as `AsyncStream<Bool>`.
- Camera monitoring uses CoreMediaIO device enumeration and listens for
  `kCMIODevicePropertyDeviceIsRunningSomewhere`.
- Its notification actions include "Start transcribing", "Not a Meeting",
  and "Ignore This App".
- It freezes the detection snapshot when posting a notification.
- It attaches current calendar context on accept when available.

Borrow:

- Protocolized signal sources for testability.
- CoreMediaIO camera monitor implementation style.
- Prompt actions: start, not a meeting, mute/ignore app.
- Frozen candidate snapshot at prompt time.

Do not borrow yet:

- Camera-only prompts.
- Silence timeout and app-exit auto-stop.

### OpenWhispr

OpenWhispr is a useful caution:

- Process detection is context, not a trigger by itself.
- Audio detection is event-driven with polling fallback and heartbeat.
- Meeting detection suppresses prompts while a calendar meeting recording is
  active.
- If an imminent calendar event exists, the prompt uses that event context.
- It queues/suppresses notifications around recording transitions.

Borrow:

- Process detection as context only.
- Calendar context attached to activity detections.
- Post-recording suppression/cooldown.
- Event-driven first, polling fallback where needed.

Do not borrow yet:

- Sustained mic-only prompts as the main signal.
- Electron helper architecture.
- Cloud Google Calendar cache model.

## Core Product Rules

These rules should be explicit in tests:

1. Camera alone never prompts.
2. Mic alone never prompts.
3. Running a known meeting app alone never prompts.
4. Calendar reminder/countdown UI wins over activity UI.
5. Active or starting MacParakeet meeting recording suppresses activity prompts.
6. MacParakeet's own bundle/processes are excluded from activity evidence.
7. Slack, Discord, WhatsApp, and similar communication apps are weak signals.
8. Browser foreground + mic is weaker than browser meeting URL + mic.
9. Dismissal suppresses a stable meeting session, not every future meeting in
   that app forever.
10. "Mute this app" is an explicit user choice and persists.

## Detection Policy

### Strong v1 candidates

These should be eligible for a prompt after a short stability delay:

1. External mic input process + dedicated meeting app:
   Zoom, Microsoft Teams, FaceTime, Webex, Around, Tuple.
2. External mic input process + active calendar event:
   use the calendar title/context, unless the existing calendar UI is already
   handling it.
3. External mic input process + camera active + dedicated meeting app.
4. External mic input process + foreground browser + known meeting URL.
   This is Phase 2/3 if browser URL extraction is not in the first slice.

### Weak candidates

These need stronger evidence or a longer sustained threshold:

1. Foreground browser + external mic, with no known meeting URL.
2. Slack/Discord/WhatsApp + external mic.
3. Any app that is known to produce routine voice notes, huddles, calls, or
   audio messages.

Weak candidates should require one of:

- Calendar event context.
- Camera active.
- Full-duplex app attribution: the same candidate has input and output
  activity, when available.
- Longer sustained activity, for example 15 seconds.

### Rejected triggers

Do not prompt from:

- Camera active with no external mic process.
- External mic with no meeting app/browser/calendar context.
- Background browser process with no foreground/browser URL evidence.
- App launch/start alone.
- Calendar event alone. Calendar already has its own coordinator.

## Proposed Types

Add pure types to `MacParakeetCore`, likely under a new folder:

```text
Sources/MacParakeetCore/MeetingActivity/
```

Core types:

```swift
public struct MeetingActivitySnapshot: Sendable, Equatable {
    public var capturedAt: Date
    public var micProcesses: [AudioProcessActivity]
    public var cameraActive: Bool
    public var runningApps: [RunningApplicationSnapshot]
    public var frontmostApp: RunningApplicationSnapshot?
    public var browserContext: BrowserMeetingContext?
    public var calendarContext: CalendarEvent?
    public var isRecordingActive: Bool
    public var isRecordingStarting: Bool
    public var isCalendarPromptVisible: Bool
}

public struct MeetingStartCandidate: Sendable, Equatable, Identifiable {
    public var id: String
    public var suppressionID: String
    public var displayName: String
    public var sourceBundleID: String?
    public var sourcePID: Int32?
    public var platform: MeetingPlatform?
    public var calendarEventID: String?
    public var calendarTitle: String?
    public var browserURL: URL?
    public var evidence: Set<MeetingStartEvidence>
    public var confidence: MeetingStartConfidence
    public var firstSeenAt: Date
    public var lastSeenAt: Date
}

public enum MeetingStartEvidence: String, Sendable, Codable {
    case calendarEvent
    case micInputProcess
    case micOutputProcess
    case cameraActive
    case dedicatedMeetingApp
    case weakCommunicationApp
    case foregroundBrowser
    case browserMeetingURL
    case runningMeetingApp
}

public enum MeetingStartConfidence: String, Sendable, Codable {
    case weak
    case likely
    case strong
}
```

Pure reducers:

- `MeetingActivityResolver`
  - Input: `MeetingActivitySnapshot`, policy/config, current session clock.
  - Output: optional `MeetingStartCandidate`.
  - No timers, no AppKit calls, no notifications.
- `MeetingActivityPromptStateMachine`
  - Input: candidate changes, user actions, recording/calendar visibility.
  - Output: show prompt, suppress, dismiss, reset.
  - Owns stability delay, cooldown, and suppression decisions as pure state.
- `MeetingActivityPolicy`
  - Known dedicated apps.
  - Weak/noisy apps.
  - Ignored app bundle IDs.
  - Browser helper normalization.
  - Self-bundle exclusion.

Keep these in Core so the hard logic can be tested without GUI or hardware.

## App-Layer Adapters

Add adapters in the app target because they depend on AppKit/CoreAudio/
CoreMediaIO lifecycle:

```text
Sources/MacParakeet/App/MeetingActivity/
```

Recommended adapters:

- `AudioProcessActivityMonitor`
  - Event-driven default input device listener.
  - On change, snapshot CoreAudio process objects.
  - Collect PID, bundle ID, app name, input/output booleans, and device IDs.
  - Exclude self.
  - Poll fallback while active if process list changes without device state
    toggling.
- `CameraActivityMonitor`
  - CoreMediaIO device enumeration.
  - Listen for `kCMIODevicePropertyDeviceIsRunningSomewhere`.
  - Use camera only as confidence evidence, not a standalone trigger.
- `RunningApplicationSnapshotProvider`
  - `NSWorkspace.runningApplications`.
  - Frontmost app.
  - Observe app-list/frontmost changes where possible; do not tight-poll.
  - Browser/helper normalization where possible.
- `BrowserMeetingContextProvider`
  - Phase 2/3 only.
  - If added, be explicit about permissions and never log raw URLs to
    telemetry.
- `MeetingActivityStartCoordinator`
  - MainActor coordinator.
  - Starts/stops adapters.
  - Builds snapshots.
  - Feeds resolver/state machine.
  - Shows prompt.
  - Calls `MeetingRecordingFlowCoordinator.startFromActivity(candidate:)`.

Do not add these adapters to `MacParakeetCore` unless wrapped as narrow,
non-UI system adapters. The preferred first cut is pure Core logic plus app
adapters.

## Settings

Add a setting separate from calendar auto-start:

```swift
public enum MeetingActivityPromptMode: String, Codable, Sendable {
    case off
    case suggest
}
```

Recommended default:

- Existing users: `.off`.
- New users: only enable `.suggest` after explicit onboarding/setup action.
- No `.autoStart` in v1.

Persist through `UserDefaults`, not SQLite:

- `MeetingActivityPrompts.mode`
- `MeetingActivityPrompts.ignoredBundleIDs`
- Optional: `MeetingActivityPrompts.respectDoNotDisturb`

This is preference state, not meeting history. No schema migration is needed
unless product later needs a durable prompt audit log.

## Prompt UX

Use a lightweight prompt, not a silent automatic start.

Recommended copy shape:

- Title: `Looks like you're in a meeting`
- Body with context:
  - Calendar: `<event title>`
  - App: `<app name>`
  - Browser URL known: `<platform name>`

Actions:

1. `Start Recording`
2. `Not a Meeting`
3. `Mute This App`
4. Dismiss/close

If this is delivered as a macOS notification, only depend on the first two
actions being visible in banner presentation. `Start Recording` and `Not a
Meeting` should be the notification actions. `Mute This App` can live in the
in-app prompt, a notification detail path, or Settings. Dismiss can be the
system dismissal affordance.

Behavior:

- Freeze the candidate snapshot when the prompt is shown.
- Accept uses the frozen candidate, not a later re-evaluated one.
- Suggested recording title:
  - Calendar title if present.
  - Platform/app name plus timestamp otherwise.
- Start path should be new and explicit:
  - `MeetingRecordingFlowCoordinator.startFromActivity(candidate:)`
  - New trigger value such as `.activityPrompt`
- The prompt should disappear if recording starts elsewhere, calendar countdown
  appears, or the candidate goes idle long enough.

## Privacy And Telemetry

Local signal collection must not capture audio/video content. It only observes
activity state and process/app metadata until the user starts recording.

Telemetry must be content-free:

- OK:
  - signal bucket names
  - confidence bucket
  - app category
  - prompt outcome
  - suppression reason
- Not OK:
  - raw meeting title
  - raw browser URL
  - participant names
  - transcript/audio/video content

Suggested events:

- `meeting_activity_candidate_detected`
- `meeting_activity_prompt_shown`
- `meeting_activity_prompt_accepted`
- `meeting_activity_prompt_dismissed`
- `meeting_activity_app_muted`
- `meeting_activity_prompt_suppressed`
- `meeting_activity_monitor_failed`

Remember the project rule: new telemetry names need the website allowlist
updated before release.

## Tests

The first implementation should be test-heavy in pure Core before any UI
polish.

Resolver tests:

- Mic alone returns no candidate.
- Camera alone returns no candidate.
- Camera + mic + no app/context returns no candidate.
- Mic + Zoom returns a likely/strong candidate.
- Mic + Teams returns a likely/strong candidate.
- Mic + FaceTime returns a likely/strong candidate.
- Calendar event + mic returns a strong candidate.
- Calendar event alone returns no activity candidate.
- Calendar countdown visible suppresses activity candidate.
- Foreground browser + mic is weak or no prompt without URL, depending on phase.
- Background browser + mic returns no candidate.
- Browser meeting URL + mic returns a strong candidate.
- Slack input-only returns no candidate or weak candidate below prompt
  threshold.
- Slack full-duplex or Slack + calendar returns a candidate.
- Self bundle is excluded.
- Browser helper bundle maps to the parent browser.
- Candidate `id` can change with richer evidence, but `suppressionID` remains
  stable across the same contiguous session.

Prompt state machine tests:

- Settings `.off` suppresses all prompts.
- Active recording suppresses prompts.
- Starting recording suppresses prompts.
- Calendar prompt visible suppresses prompts.
- Candidate must remain stable for the configured delay before prompt.
- Weak candidates require longer sustained activity.
- Dismiss suppresses the candidate session.
- `Mute This App` persists and suppresses future candidates for that bundle.
- Cooldown prevents repeated prompts after dismissal/auto-dismiss.
- Idle reset clears active candidate state.
- Initial monitor start with already-active mic does not prompt as a new start.

Adapter tests:

- Prefer protocol fakes around the app-layer monitor interfaces.
- Do not try to unit-test hardware state directly.
- Add manual smoke scripts/checklists for real devices and apps.

Manual smoke matrix:

- Zoom native app: join, leave, mute/unmute.
- Microsoft Teams native app.
- FaceTime.
- Google Meet in Chrome.
- Google Meet in Safari.
- Slack huddle.
- Browser tab playing audio but no mic.
- Camera-only app such as Photo Booth.
- MacParakeet recording already active.
- Calendar countdown active.
- AirPods/device switch while in a call.
- Wake from sleep with call already active.

## Phased Implementation

### Phase 0: Pure Model And Policy

Build:

- `MeetingActivitySnapshot`
- `AudioProcessActivity`
- `RunningApplicationSnapshot`
- `MeetingStartCandidate`
- `MeetingActivityPolicy`
- `MeetingActivityResolver`
- `MeetingActivityPromptStateMachine`

No UI. No hardware monitors. Use fakes and tests.

Exit criteria:

- Pure tests cover the false-positive rules above.
- No app behavior changes.

### Phase 1: Mic Attribution + Dedicated App Prompts

Build:

- CoreAudio process attribution adapter.
- Running app/frontmost app provider.
- Settings mode `.off` / `.suggest`.
- Ignored bundle IDs.
- Prompt UI/notification.
- Start path `startFromActivity(candidate:)`.

Trigger only on external mic input process plus dedicated meeting app or
calendar context. No camera dependency. No browser URL scraping.

Exit criteria:

- Zoom/Teams/FaceTime prompt manually verified.
- Slack/Discord/WhatsApp do not produce noisy prompts.
- Calendar countdown/reminder does not double-prompt.
- No activity auto-start.

### Phase 2: Camera As Confidence Booster

Build:

- CoreMediaIO camera activity adapter using public device enumeration.
- Resolver evidence for camera active.

Rules:

- Camera never prompts alone.
- Camera improves confidence only when paired with mic + app/browser/calendar.
- Avoid private camera device identifiers.

Exit criteria:

- Camera-only apps do not prompt.
- Camera + mic + Zoom/Meet improves confidence and prompt timing.

### Phase 3: Browser Meeting Context

Build only if the product accepts the permission/trust tradeoff:

- Browser URL detection for frontmost browser tabs.
- Platform normalization for Meet, Zoom, Teams, Webex, FaceTime links.
- Clear privacy copy.

Rules:

- Do not log raw URLs to telemetry.
- Do not persist raw URLs unless needed for the accepted meeting metadata.
- Browser URL is context/evidence; still require activity before recording.

Exit criteria:

- Google Meet in browser prompts reliably.
- Ordinary browser audio does not prompt.

### Phase 4: Revisit Automatic Behavior

Only after prompt metrics and user feedback:

- Consider activity-based auto-start as a separate ADR.
- Consider activity-based auto-stop as a separate ADR.
- Do not mix stop logic into this start-prompt plan.

## Rejected Approaches

### One Giant Calendar + Activity Monitor

Rejected. Calendar monitoring is already clean and reliable as its own
EventKit-driven path. Mixing activity into `MeetingMonitor` would make a pure
calendar reducer carry AppKit/CoreAudio concepts it should not know about.

### Mic-Only Detection

Rejected for v1. It catches more cases but creates too many false positives:
voice dictation, voice messages, audio tests, gaming/chat apps, browser
permissions, and MacParakeet itself.

### Camera-Only Detection

Rejected. Camera usage often means Photo Booth, Continuity Camera preview,
OBS/setup, or an app permission test. Camera is useful evidence, not a trigger.

### Browser URL Detection First

Deferred. It is valuable, but it creates a trust/perception problem because the
app appears to inspect browser contents. Start with app/process signals first;
add browser context only when the prompt UX and privacy copy can justify it.

### Control Center Log Parsing

Rejected for v1. Muesli's approach is clever, but parsing `log stream` output
from Control Center internals is fragile and difficult to explain.

### Zoom Mute State Detection

Deferred. Hyprnote's Accessibility menu watcher can improve live meeting state,
but start detection does not need mute state. Avoid adding another fragile
permission-sensitive path before the base detector works.

### Activity Auto-Stop

Rejected for this plan. ADR-017 already removed calendar-driven auto-stop
because stopping early is destructive. Activity-based stop may be better, but
it needs its own design and tests.

## Implementation Checklist

1. Add pure Core model/policy/resolver/state-machine types.
2. Add resolver and prompt state-machine tests.
3. Add `MeetingActivityPromptMode` preference and ignored bundle list.
4. Add app-layer monitor protocols and fake implementations.
5. Add CoreAudio process attribution adapter.
6. Add running/frontmost app snapshot provider using observer-driven snapshots.
7. Add `MeetingActivityStartCoordinator`.
8. Add prompt UI/notification actions, with notification banners limited to
   the two primary actions.
9. Add `MeetingRecordingFlowCoordinator.startFromActivity(candidate:)`.
10. Add telemetry event names and website allowlist entries.
11. Add manual smoke checklist to the plan or QA docs.
12. Re-check official Apple docs and installed SDK headers before relying on
    any new system signal.
13. Only then consider Phase 2 camera support.

## Bottom Line

The sensible first move is not "replace calendar with automatic activity
recording." It is:

```text
calendar remains the scheduled-meeting path
activity adds conservative local prompts for unscheduled meetings
recording starts only after user confirmation
```

Borrow the rigor of Muesli's resolver/state machine, the process attribution
from Steno and Hyprnote, the Swift signal-source shape from OpenOats, and the
calendar/prompt suppression lessons from OpenWhispr. Leave camera-only,
mic-only, browser scraping, mute watchers, Control Center logs, and auto-stop
out of v1.
