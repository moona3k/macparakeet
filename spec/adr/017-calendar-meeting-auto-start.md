# ADR-017: Calendar-Driven Meeting Auto-Start

> Status: **IMPLEMENTED (amended)** — Phase 1 (notify-only) and Phase 2 (auto-start + countdown) are implemented and enabled (`AppFeatures.calendarEnabled = true` as of the post-#318 reliability hardening: mid-flight teardown, RSVP/zero-duration guards, reschedule re-fire). Auto-start defaults to mode `.off`, so users opt in via onboarding or Settings — nothing changes for existing users until they do. Phase 3 (late-join, retro-link, generic URL extraction) remains **PROPOSED** (see Phased Rollout below).
> Date: 2026-04-19
> **Amendment (2026-05-22): calendar-driven auto-stop removed.** §5 (auto-stop at event end) is withdrawn — see the amendment note in §5. Scheduled end times are too unreliable to drive a stop; the calendar coordinator never stops a recording. The replacement is ADR-023 (Activity-Based Meeting Auto-Stop, 2026-06-14), implemented behind a default-off flag using activity signals plus a veto countdown.
> Related: ADR-002 (local-first), ADR-005 (onboarding), ADR-009 (custom hotkeys), ADR-014 (meeting recording), ADR-015 (concurrent dictation/meeting)

## Context

ADR-014 shipped meeting recording as a manual, hotkey-or-click flow. The user opens the meeting panel (or hits the meeting hotkey) when a call starts. This is simple and predictable, but it misses the most common failure mode: *the user forgets to start recording*. By the time they remember, the first 5–10 minutes of context is already gone.

Oatmeal (sibling repo, same owner, GPL-3.0) solves this with calendar integration: EventKit access → upcoming events → reminder notifications → optional auto-start when a meeting begins. Oatmeal's code is already partitioned cleanly — a pure `MeetingMonitor` state machine plus a thin `CalendarService` wrapper plus a coordinator — and MacParakeet can port ~80% of it verbatim (license is GPL-3.0 → GPL-3.0, no conflict).

This ADR defines MacParakeet's scope for that feature. It is deliberately narrower than Oatmeal's: no cloud sync, no AI-generated meeting titles, no attendee enrichment, no cross-meeting threading. Just **"remind me, and if I want, start recording for me."**

## Decision

### 1. EventKit only — no cloud calendar APIs

Calendar access goes through Apple's EventKit framework (`EKEventStore`), which reads whatever calendars the user has already configured in the macOS Calendar app (iCloud, Google via macOS Internet Accounts, Exchange, CalDAV). MacParakeet does not run its own OAuth flows and does not ship Google/Microsoft SDKs.

**Why:** ADR-002 (local-first). Events stay on-device; we don't add a new cloud surface. It also keeps onboarding simple — "grant Calendar access" is one click and delegates the messy auth to macOS.

### 2. Three behavior modes (off / notify / notify + auto-start)

A single enum governs the whole feature:

```swift
public enum CalendarAutoStartMode: String, Codable, Sendable {
    case off         // No calendar integration at all. Default for upgraders.
    case notify      // Show a macOS notification N minutes before a matching event.
    case autoStart   // Show the reminder AND start recording automatically at T-0.
}
```

Default on a fresh install after user grants Calendar permission: `.notify`. Users who want hands-off flow opt up to `.autoStart`. Users who feel the notifications are noisy opt down to `.off`.

This is simpler than Oatmeal's split (`meetingAutoStartEnabled` + `meetingReminderMinutes` + `meetingCountdownSeconds` as three independent booleans). One mode, three values, obvious to reason about.

### 3. Trigger filter defaults to "has video conference link"

Not every calendar event is a meeting we want to record. The filter determines which events count:

```swift
public enum MeetingTriggerFilter: String, Codable, Sendable {
    case withLink        // Default. Event has a Zoom/Meet/Teams/Webex URL.
    case withParticipants // 2+ attendees (including "me").
    case allEvents       // Every non-all-day event.
}
```

`.withLink` is the default because it has the highest signal-to-noise. A 1-on-1 "coffee block" on your calendar shouldn't trigger a recording; a Zoom standup should. Zoom/Meet/Teams/Webex/Around URLs are extracted from the event's `location`, `notes`, and `url` fields by `MeetingLinkParser` (ported from Oatmeal).

### 4. Countdown toast before auto-start

When `.autoStart` fires, the app shows a 5-second cancellable countdown toast (a small floating panel) before `MeetingRecordingService.startRecording()` is called. This is the safety valve for the case where a calendar event fires but the user doesn't actually want to record (declined at the last minute, fake calendar block, test meeting).

Countdown is fixed at 5 seconds; not exposing it as a setting. Longer defeats the point of auto-start; shorter is too jumpy to cancel.

### 5. Auto-stop at event end — ~~opt-in, default on~~ **WITHDRAWN (2026-05-22)**

> **Amendment (2026-05-22):** Calendar-driven auto-stop is removed. The original design (below, struck through in intent) showed a 30s "meeting ending — stop recording?" countdown at `E.endTime - 30s`.
>
> **Why it was withdrawn:** Scheduled end times lie. Meetings overrun constantly, so a clock-driven stop risks **truncating the recording mid-meeting** — and losing the end of a meeting is far worse than over-recording. The 30s "Keep Recording" rescue was self-defeating: it demanded exactly the attention auto-start exists to remove (miss the window → premature stop). Start and stop are not symmetric — starting early is cheap and trimmable; stopping early destroys data — so it is fine for auto-*start* to trust the calendar clock, but auto-*stop* must not.
>
> **What replaces it:** Nothing, for now. The coordinator never stops a recording; the user stops manually (one click on the recording pill). The trade-off — trailing dead air if the user walks away — is recoverable (trim) and the clear lesser evil vs. truncation.
>
> **Replacement implemented in ADR-023:** the right stop signal is the meeting *actually ending*, detected from the audio MacParakeet already captures (sustained `systemLevel` silence, optionally plus a Zoom-app-quit fast path) — engine-agnostic across the Zoom app, a browser Meet/Teams tab, and in-person recordings. ADR-023 implements that replacement behind a default-off flag with a veto countdown and the normal finalize/transcribe path.
>
> **Removed surfaces:** the `.autoStop` countdown toast, the `MeetingMonitor.autoStopDue` event + auto-stop config, the coordinator's auto-start→recording ownership binding (`onAutoStartFailed` / `stopFromCalendar`), the "Stop recording at meeting end" Settings toggle (`calendarAutoStopEnabled`), and the `calendar_auto_stop_shown` / `calendar_auto_stop_cancelled` telemetry. Auto-*start* is unchanged.

### 6. No calendar cache in SQLite — in-memory only

Oatmeal persists events to GRDB for its RAG/entity-extraction features. MacParakeet doesn't need that. The coordinator fetches upcoming events on each poll tick, filters, and discards. No migration, no repository, no new table.

**Why:** Simpler, less to maintain, less data footprint, less surface to reason about for privacy. Recomputing on a 60-second poll is cheap (EventKit reads are near-instant).

### 7. Polling cadence: 60s baseline, 5s near events

A single `Timer` in the coordinator fires every 60 seconds during idle periods. When the next matching event is within 2 minutes, the timer reschedules itself at 5-second intervals so countdown accuracy doesn't drift. After the event passes, it falls back to 60s.

Also: subscribe to `.EKEventStoreChanged` so a calendar edit (e.g., meeting moved earlier) triggers an immediate re-evaluation without waiting for the next tick.

### 8. Settings surface — folded into Meeting Recording card

The implemented Settings surface is folded into the Meeting Recording card rather than a standalone Settings card. When `AppFeatures.calendarEnabled` is `true`, the Meeting Recording card includes:

- Mode picker (`Off` / `Notify` / `Auto-start`)
- Reminder lead time (`Off` / `1 min` / `5 min` / `10 min`)
- Trigger filter picker (`With video link` / `With participants` / `All events`)
- Per-calendar include list (checkboxes over the user's visible calendars)
- A "Grant Calendar access" button if permission is `.notDetermined` or `.denied`

This subsection appears once Calendar access is granted (`AppFeatures.calendarEnabled = true`).

### 9. Onboarding: optional, skippable, post-permissions

When `AppFeatures.calendarEnabled` is `true`, a new onboarding step slots in **after** the existing mic/accessibility/screen-recording permission block and **before** the model download. It explains the feature in one sentence, asks for Calendar permission, and has a clear "Skip" button. It is not blocking -- users who decline never see a regression in the rest of onboarding. The calendar flag is now `true`, so this step is live.

Skipping sets `calendarAutoStartMode = .off` explicitly so re-enabling later goes through the Settings surface, not onboarding.

### 10. Hotkey / manual start still works independently

Nothing about this ADR removes the manual flow. The meeting hotkey, the menu bar "Start Recording" item, and the Meetings panel's record button all continue to work even with auto-start fully on. If a user starts a recording manually and a calendar event's auto-start fires mid-call, the coordinator observes that a recording is already active and **no-ops** (does not restart, does not double-notify).

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                     MacParakeetCore (new)                       │
│                                                                 │
│  CalendarService      (EventKit wrapper, permission, fetch)     │
│  MeetingLinkParser    (Zoom/Meet/Teams/Webex URL extraction)    │
│  MeetingMonitor       (pure state machine; no side effects)     │
│     ├── evaluate(events, now, config, activeRecording,          │
│     │            dismissedIds, remindedIds, countdownShownIds)  │
│     │          -> [MonitorEvent]                                │
│     ├── MonitorEvent: .reminderDue / .autoStartDue /            │
│     │                 .lateJoinAvailable                        │
│     └── TriggerFilter: .withLink / .withParticipants / .all     │
└────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│                   MacParakeet (app layer)                       │
│                                                                 │
│  MeetingAutoStartCoordinator  (@MainActor)                      │
│    ├── polls CalendarService every 60s (or 5s near events)     │
│    ├── feeds events → MeetingMonitor.evaluate()                │
│    ├── fires notifications via UNUserNotificationCenter        │
│    ├── shows countdown toast (MeetingCountdownToastController) │
│    └── calls MeetingRecordingFlowCoordinator.startRecording    │
│            for auto-start                                      │
└────────────────────────────────────────────────────────────────┘
```

**Ownership:** The coordinator is owned by `AppDelegate`, wired in `AppEnvironmentConfigurer` the same way `MeetingRecordingFlowCoordinator` is. It observes settings changes via the existing `AppSettingsObserverCoordinator` pattern.

## Rationale

### Why not use `ScheduledRecording` / custom scheduling UI instead of calendar?

Users already have a calendar with their meetings in it. A second UI for "tell MacParakeet about your meetings" is duplication. The calendar is the source of truth.

### Why not port Oatmeal's full feature set?

Oatmeal uses its calendar data for AI meeting notes, cross-meeting RAG, and entity extraction. MacParakeet doesn't have those features and isn't getting them. Porting the GRDB cache, event repository, and related infrastructure would be 300+ lines we'd never use. Strip to the coordination layer only.

### Why not also port pre-meeting "late join" detection?

Oatmeal has a `.lateJoinAvailable` event for meetings that started up to 2 minutes ago without a recording. That's a nice polish, and the event type is already defined in the ported `MeetingMonitor` enum — but wiring the UI (a floating "join the Zoom that's already in progress?" toast) is more surface area than v1 warrants. Leaving the enum case unused is cheap; we can wire it in a follow-up without schema changes.

### Why in-memory events instead of SQLite cache?

No query patterns justify it. We don't list events, we don't filter them by date in UI, we don't join them against transcriptions. We just check "is there a matching event near now?" every 60 seconds. A cache adds invalidation logic for zero gain.

### Why a countdown toast and not just a notification?

Notifications are dismissed silently by macOS when the user isn't at their machine. A 5-second floating toast is a visible, cancellable last chance that can't be missed. It's the UX pattern Oatmeal uses and the one that tested well there.

## Consequences

### Positive

- The top user-visible failure mode of meeting recording ("I forgot to start it") is solved
- Calendar integration is local-only — preserves ADR-002
- Settings surface is small (one section, five controls)
- Ported code is already production-hardened in Oatmeal
- Manual flow is unchanged; no regressions for users who don't want calendar integration
- Enum-based `CalendarAutoStartMode` makes per-user preferences one-line to reason about

### Negative

- **New permission (Calendar)**: a sixth prompt on top of mic, accessibility, notifications, screen recording, and contacts (if ever). Mitigated by making the onboarding step skippable and by offering meaningful behavior (`.notify`) without auto-start.
- **Polling**: 60-second timer when no events are near is cheap but non-zero. Acceptable for an app that's already idle-friendly post-PR #111.
- **Video-link detection is heuristic**: meetings without URLs but with participants won't match the default filter. Users who rely on phone calls or non-standard conferencing tools need to change the filter to `.withParticipants` or `.allEvents`.
- **Countdown toast is new UI surface area**: another floating panel controller to maintain alongside pill / panel / dictation overlay.
- **Ported code can drift** from Oatmeal. Low impact — we don't import Oatmeal as a dependency, so drift is local.

## Implementation Direction

### Core types (MacParakeetCore)

- `CalendarService` — EventKit wrapper; public surface: `permissionStatus`, `requestPermission() async -> Bool`, `fetchUpcomingEvents(withinDays:) async throws -> [CalendarEvent]`, `availableCalendars() -> [CalendarInfo]`
- `MeetingLinkParser` — static `extractConferenceURL(from: CalendarEvent) -> URL?`
- `MeetingMonitor` — static `evaluate(...) -> [MonitorEvent]`; no stored state, stateless pure function
- `CalendarEvent` / `CalendarInfo` / `EventParticipant` — plain `Sendable` structs, no GRDB

### Settings (MacParakeetViewModels)

- Extend `SettingsViewModel` with `calendarAutoStartMode`, `calendarReminderMinutes`, `meetingTriggerFilter`, `calendarIncludedIdentifiers: Set<String>`
- Persist via `UserDefaults` (keys namespaced `CalendarAutoStart.*`)
- Post a new `AppNotification.macParakeetCalendarSettingsDidChange` on any change

### App layer (MacParakeet)

- `MeetingAutoStartCoordinator` — owns the poll timer, EventKit change observer, notification scheduler, countdown toast controller; wires to `MeetingRecordingFlowCoordinator`
- New `MeetingCountdownToastController` — a small, non-activating floating panel (reuse `KeylessPanel`) with a 5-second bar and a Cancel button
- Settings UI: `CalendarSettingsView` folded into the Meeting Recording settings card and rendered only when `AppFeatures.calendarEnabled` is `true`
- Onboarding UI: `OnboardingCalendarView` slotted in after the permissions step only when both `AppFeatures.meetingRecordingEnabled` and `AppFeatures.calendarEnabled` are `true`

### Telemetry (new cases, must mirror to website allowlist)

- `.calendarReminderShown(mode:leadMinutes:hasMeetUrl:)` — fired after a reminder notification is delivered
- `.calendarAutoStartTriggered(leadSeconds:hasMeetUrl:)` — fired when the auto-start countdown is shown
- `.calendarAutoStartCancelled(reason:)` — user cancels countdown
- `.calendarAutoStartFailed(reason:)` — auto-start countdown completed but recording could not start
- `.permissionGranted(permission: .calendar)` / `.permissionDenied(permission: .calendar)`
- `.settingChanged(setting: .calendarAutoStartMode)` etc.

Per the telemetry allowlist rule, each new `TelemetryEventName` case must also be added to `ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts`.

## Files to Port from Oatmeal (reference)

Repo: `https://github.com/moona3k/oatmeal` (same owner, GPL-3.0).

| Oatmeal path | MacParakeet path | Adaptation |
|--------------|------------------|------------|
| `Sources/OatmealCore/Services/CalendarService.swift` | `Sources/MacParakeetCore/Calendar/CalendarService.swift` | Strip telemetry hooks that reference Oatmeal categories; keep API surface |
| `Sources/OatmealCore/Services/MeetingLinkParser.swift` | `Sources/MacParakeetCore/Calendar/MeetingLinkParser.swift` | Verbatim |
| `Sources/OatmealCore/Services/MeetingMonitor.swift` | `Sources/MacParakeetCore/Calendar/MeetingMonitor.swift` | Verbatim |
| `Sources/OatmealCore/Models/CalendarEvent.swift` | `Sources/MacParakeetCore/Calendar/CalendarEvent.swift` | Drop GRDB conformances; keep `Sendable` + `Codable` |
| `Sources/Oatmeal/App/MeetingAutoStartCoordinator.swift` | `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift` | Rewrite to call `MeetingRecordingFlowCoordinator`, remove `LicenseManager`, swap notification body copy |

## Phased Rollout

1. **Phase 1 — Notify only ✅ IMPLEMENTED (2026-04-25):** Ported `CalendarService`, `MeetingLinkParser`, `MeetingMonitor`, `CalendarEvent` from Oatmeal. Built `MeetingAutoStartCoordinator` (`@MainActor`, adaptive 60s/15s/5s polling, `.EKEventStoreChanged` observer, daily stale-id cleanup). Settings subsection + onboarding step + per-calendar include list are implemented and enabled (`AppFeatures.calendarEnabled = true`). CLI surface (`macparakeet-cli calendar upcoming` + `health` extension) ships alongside for headless verification. Mode defaults to `.off` -- opt-in via onboarding (auto-`.notify` on permission grant, but only when notifications are also authorized) or Settings. Phase 1 amendment: **per-calendar include list landed in Phase 1**, not Phase 3 -- it was only ~30 lines and made onboarding feel finished.
2. **Phase 2 — Auto-start with countdown ✅ IMPLEMENTED (2026-04-25):** Built `MeetingCountdownToastController` for the pre-meeting auto-start countdown. **Superseded by the 2026-05-22 amendment:** the original end-of-meeting auto-stop countdown was removed, and the auto-start toast was redesigned as a minimal top-right "countdown halo" (sacred-geometry rosette inside a coral ring, ✕ to cancel / ↵ to start now). Current coordinator behavior handles `.autoStartDue` -> toast -> `MeetingRecordingFlowCoordinator.startFromCalendar()` and never stops recordings from calendar end times. Settings exposes all three modes but no auto-stop toggle. Current telemetry events are `calendar_reminder_shown`, `calendar_auto_start_triggered`, `calendar_auto_start_cancelled`, and `calendar_auto_start_failed`; removed auto-stop events are historical only. `meeting_recording_started` gained an optional `trigger` prop. `CalendarServicing` protocol + `MockCalendarService` extracted for `MeetingAutoStartCoordinatorTests`.
   - **Post-#318 reliability hardening (2026-05-21) — flag enabled:** countdowns are closed/ignored when calendar settings or permissions disable the action mid-flight; auto-start is gated on RSVP (declined/pending excluded) and zero-duration/inverted events are dropped; rescheduled occurrences re-fire via `CalendarEvent.dedupeKey`; `pollAsync` is reentrancy-guarded with coalescing; and onboarding only auto-enables `.notify` when notification authorization is also granted.
3. **Phase 3 — Refinements (PROPOSED):** Better URL extraction (Phone/FaceTime/generic URLs), `.lateJoinAvailable` UI (separate `lateJoinShownEventIds` set in `MeetingMonitor.evaluate(...)` so dismissed countdowns don't suppress late-join), optional retro-link (match a manually-started recording back to a calendar event).

## Open Questions

- **Naming in copy**: "Auto-start" vs "Auto-record" vs "Start automatically" — pick one and use it everywhere.
- **Countdown with LLM features**: should insights (ADR-018) begin warming up during the countdown so the first live insight lands sooner? Or wait until recording actually starts? Lean towards wait — zero-second "ghost warm-up" is complexity we don't need until measurements justify it.
- **Onboarding ordering**: before or after the STT model download? Leaning *before* so the user isn't asked to click through after a 60-second wait.
