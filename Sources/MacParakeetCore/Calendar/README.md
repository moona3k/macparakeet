# Calendar

> Local EventKit integration for meeting reminders and auto-start (ADR-017).
> No cloud calendar APIs. No SQLite event cache.

## Entry point

`CalendarServicing` is the EventKit seam (`CalendarService` actor in
production, `MockCalendarService` in tests). `MeetingMonitor` is the pure
policy module: given events + policy + clock, it decides what MacParakeet
should automate.

The app-layer coordinator (`MeetingAutoStartCoordinator`) polls, shows
notifications/toasts, and starts recordings. It must not decide which events
count.

## What is here

- `CalendarService.swift` / `CalendarServicing.swift` — permission, fetch,
  calendar list.
- `CalendarEvent.swift` — EventKit snapshot. Occurrence identity is
  `dedupeKey` (`id` + start time); series identity is `externalId`. Do not
  key suppression on title or on `id` alone.
- `MeetingMonitor.swift` — candidate filter + remind / auto-start /
  late-join windows. RSVP: declined is dropped; pending reminds but does not
  auto-start; tentative auto-starts.
- `MeetingTriggerFilter.swift` / `CalendarAutoStartMode.swift` —
  Settings-facing enums.
- `MeetingLinkParser.swift` — Zoom / Meet / Teams / Webex / Around URLs.
- `CalendarNotificationAuthorization.swift` — separate TCC from Calendar.

Preferences live in `CalendarAutoStartPreferences` (`AppPreferences.swift`):
mode, reminder lead, trigger filter, excluded calendar IDs.

## Accepted, not implemented — per-event skip (#609)

Users can mute one occurrence or a repeating series. Skip is a UserDefaults
set of IDs, not an event repository. Upcoming / CLI / coordinator must share
`MeetingMonitor.candidates`. Toast ✕ and Upcoming "Don't auto-record" write
the same store. Skip blocks reminders and auto-start only; manual Record
still works. Do not auto-exclude optional attendee role.

Governing docs:

- [ADR-017 §11](../../../../spec/adr/017-calendar-meeting-auto-start.md)
- [plan](../../../../plans/active/2026-09-14-issue-609-calendar-event-skip.md)

Until that lands, toast dismiss is session-only (`dismissedEventIds` in the
coordinator) and Upcoming rows have no mute.

## What to know before editing

**Do not persist a queryable calendar cache.** One `calendarEventSnapshot` on
a recording at start is allowed (ADR-017 §6 amendment). Attendee names/emails
never go to telemetry.

**Candidate filters must not fork.** If Upcoming, CLI `calendar upcoming`, and
the coordinator disagree, Upcoming is lying. Add the rule to `MeetingMonitor`
once.

**Fail open on missing calendar identifiers** when applying the per-calendar
exclude list (better to over-notify than silently miss).

## How to verify a change

```sh
swift test --filter MeetingMonitorTests
swift test --filter MeetingAutoStartCoordinatorTests
swift test --filter MeetingsWorkspaceViewModelTests
swift run macparakeet-cli calendar upcoming --help
```
