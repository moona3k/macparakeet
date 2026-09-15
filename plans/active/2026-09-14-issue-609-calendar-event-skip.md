# Per-event calendar skip (#609)

> Status: **PROPOSED** (design accepted 2026-09-14; not implemented)
> Issue: [#609](https://github.com/moona3k/macparakeet/issues/609)
> Governs: [ADR-017](../../spec/adr/017-calendar-meeting-auto-start.md) amendment 2026-09-14, [F48](../../spec/02-features.md)
> Priority: P2

## Original ask

Auto-start is useful, but some calendar entries should not be recorded —
especially meetings where the user is only an optional invitee. The reporter
asked for a way to **disable auto-recording for specific events**, or an
option to **exclude individual calendar entries**.

That is the whole feature. Optional invite is the motivation, not an automatic
filter. Overlapping-meeting pickers, notification Record/Skip actions, and
menu-bar next-event (#875) are later adapters of the same policy; they are
**out of this plan**.

## Why current code is incomplete

Calendar automation already has coarse filters (mode, trigger, per-calendar
include, RSVP). The per-meeting veto almost exists and then evaporates:

- `MeetingMonitor.evaluate` drops `dismissedEventIds` keyed on
  `CalendarEvent.dedupeKey` (`id` + start time).
- Auto-start toast ✕ writes that set in `MeetingAutoStartCoordinator` memory
  only. App restart forgets it. Notify mode has no toast, so no mute at all.
- Upcoming rows are display-only. Settings can ignore a whole calendar, not
  one meeting.
- Optional attendee **role** is not ingested. Tentative **RSVP** still
  auto-starts, by test. Those are different EventKit fields.

## Product rules

1. **Skip is a user decision about one meeting**, not a heuristic over
   optional invites.
2. **Skip sticks** across launches. Toast ✕ and Upcoming "Don't auto-record"
   write the same store.
3. **Skip blocks automation only** — reminders and auto-start. Manual Record,
   hotkey, and menu bar still work. A skipped event may still receive a
   `probable` snapshot if the user starts manually while it overlaps now.
4. **Skipped meetings stay visible** on Upcoming so undo is obvious.
5. **Default skip is this occurrence.** Series skip is the extra control, and
   only when `externalId` is present.
6. **Do not auto-exclude optional invites.** Do not treat optional role and
   tentative RSVP as the same switch. Do not add a Settings list of events.

Copy: **Don't auto-record this meeting** / **Don't auto-record this repeating
meeting** / **Auto-record again**. Internal name: skip. Do not say Exclude
(that already means calendars).

## Architecture

One question: **which meetings should MacParakeet automate right now?**

Skip is another eligibility input, same as declined or an excluded calendar.
Policy stays in `MeetingMonitor`. The coordinator only performs effects.

```
EventKit  →  CalendarService  →  [CalendarEvent]
                                      │
                                      ▼
                         MeetingMonitor.candidates
                         (filter + skip annotation)
                                      │
                    ┌─────────────────┴─────────────────┐
                    ▼                                   ▼
            Upcoming / CLI                         evaluate
            (show skipped, quieter)          (no remind / auto-start)
                    │                                   │
                    ▼                                   ▼
            skip / unskip store              coordinator effects
            SettingsViewModel                notification / toast / start
```

Do not add an `ExclusionService`, a skipped-meetings Settings page, or a
parallel filter in the coordinator, workspace VM, or CLI. Those three call
sites already drift; this plan collapses them onto `candidates`.

### Identity

Reuse `CalendarEvent` keys. Do not key on title.

| Scope | Key | When |
| --- | --- | --- |
| This occurrence | `dedupeKey` (`id\|startSeconds`) | Default. Reschedule is a new key, so it can fire again — same rule countdown suppression already uses. |
| This series | `externalId` (`EKEvent.calendarItemExternalIdentifier`) | Recurring optional standup. Hidden in UI when `externalId` is nil. |

`id` alone is the wrong series key: detached recurrences can change
`eventIdentifier`. ADR-017 already documents that.

### Preference store (not an event cache)

ADR-017 §6 still holds: no SQLite EventKit repository. Skips are UserDefaults
sets beside excluded calendars.

```
CalendarAutoStart.skippedOccurrences   // [dedupeKey]
CalendarAutoStart.skippedSeries        // [externalId]
```

Empty by default. Opt out, not in. Posted through the existing
`.macParakeetCalendarSettingsDidChange` so the coordinator re-evaluates
immediately.

**Janitor:** series skips live until the user unskips. Occurrence skips older
than 14 days may be pruned (they can never re-fire). Do not intersect skips
against the 7-day fetch the way in-memory `dismissedEventIds` are pruned —
a series skip must survive weeks without that event in the look-ahead window.

Telemetry may send counts and scope (`occurrence` / `series`), never titles,
attendees, or URLs.

### Policy types (`MacParakeetCore`)

Keep `MeetingMonitor` as the deep module. Grow `Config` (or a nested
`CalendarAutomationPolicy` owned by `Config`) so every caller passes the same
object:

```swift
struct CalendarAutomationPolicy: Codable, Sendable, Equatable {
    var mode: CalendarAutoStartMode
    var reminderMinutes: Int
    var triggerFilter: MeetingTriggerFilter
    var excludedCalendarIds: Set<String>
    var skippedOccurrences: Set<String>
    var skippedSeries: Set<String>
}

struct CalendarCandidate: Equatable, Sendable {
    var event: CalendarEvent
    var isSkipped: Bool
    var skipScope: CalendarSkipScope?   // .occurrence / .series
}

enum CalendarSkipScope: String, Sendable {
    case occurrence
    case series
}

enum MeetingMonitor {
    static func candidates(
        events: [CalendarEvent],
        policy: CalendarAutomationPolicy
    ) -> [CalendarCandidate]

    static func evaluate(
        candidates: [CalendarCandidate],
        now: Date,
        policy: CalendarAutomationPolicy,
        activeRecording: Bool,
        remindedEventIds: Set<String>,
        countdownShownEventIds: Set<String>
    ) -> [MonitorEvent]
}
```

`candidates` applies: not all-day, not declined, calendar not excluded,
passes trigger filter. It **includes skipped events** and annotates them.

`evaluate` ignores skipped candidates. It does not need a separate
session-dismissed set for user cancel: toast ✕ is an occurrence skip.

`countdownShownEventIds` / `remindedEventIds` stay session-only so a delivered
reminder or shown toast does not repeat every poll tick.

Helper for UI and persistence:

```swift
enum CalendarSkip {
    case occurrence(dedupeKey: String)
    case series(externalId: String)

    static func matches(_ event: CalendarEvent, occurrences: Set<String>, series: Set<String>) -> CalendarSkipScope?
}
```

Series match wins over occurrence when both are set (row copy: repeating).

### Coordinator (app layer)

Thin effects:

- Build `CalendarAutomationPolicy` from `SettingsViewModel`.
- `candidates` → `evaluate` → existing reminder / auto-start paths.
- Toast `.userDismissed` → `settingsViewModel.skip(occurrence: event.dedupeKey)`.
- Stop treating user cancel as in-memory `dismissedEventIds`.
- `.programmaticClose` still does not skip.

`probableSnapshotForManualStart` continues to consider overlapping events
that pass candidate rules **including skipped ones** if the user is starting
manually. Skip is "don't automate," not "this is not a meeting."

### SettingsViewModel

Mirror `calendarExcludedIdentifiers`:

- `calendarSkippedOccurrences: Set<String>`
- `calendarSkippedSeries: Set<String>`
- `skipOccurrence(_:)`, `skipSeries(_:)`, `unskip(_:)`
- Persist + post `.macParakeetCalendarSettingsDidChange` +
  `.settingChanged` telemetry

No new Settings card. No list of skipped meetings in this plan (a later
disclosure is allowed if undo from Upcoming proves insufficient).

### CLI

`macparakeet-cli calendar upcoming` must call `MeetingMonitor.candidates`,
not a private filter copy. Additive JSON fields (MINOR, when implemented):

- `skipped: Bool`
- `skipScope: "occurrence" | "series" | null`

Human output marks skipped rows. Update
[`spec/contracts/cli-json-v1.md`](../../spec/contracts/cli-json-v1.md) in the
same change.

## UI

The control lives on the meeting, not in Settings.

### Upcoming row (Meetings workspace)

Keep the current title + time + calendar + people line. Do not add a
persistent Skip button on every row.

- Context menu (right-click / menu-indicator on hover):
  - **Don't auto-record this meeting**
  - **Don't auto-record this repeating meeting** — only if `externalId != nil`
- Skipped row: reduced opacity, secondary caption
  **Won't auto-record** (or **Won't auto-record this series**), context menu
  **Auto-record again**.
- Recurring preview still collapses to the soonest occurrence (`collapseRecurringOccurrences`). Series skip applies to that row and future occurrences sharing `externalId`.
- Upcoming continues to list skipped events that still pass the coarse
  filters, so the mute is visible and reversible. Cap still applies after
  collapse.

Accessibility: menu items named as above; skipped rows include "won't
auto-record" in the accessibility label.

### Auto-start toast

No second button. ✕ / Escape = skip this occurrence, then close. Return still
starts now. Copy and layout stay the current countdown halo.

If the user skips and later unskips while still inside the auto-start window,
evaluate may emit `.autoStartDue` again because `countdownShownEventIds`
should drop when the skip is written (the toast already finished). Unskip
during the window is rare; re-firing once is correct.

### Notify-only mode

There is no toast, so Upcoming is the mute. Skip also suppresses the reminder
for that occurrence/series — otherwise notify-mode skip is a no-op.

### Settings

Unchanged: mode, reminder lead, trigger filter, per-calendar include. Do not
add optional-invitee auto-exclude in this plan.

## Explicitly out of scope

| Item | Why |
| --- | --- |
| Auto-exclude optional `participantRole` | Noisy; mute is the feature. Ingesting role later is fine; default-on filter is not. |
| Tentative RSVP change | Current policy (remind + auto-start) stays. Different field from optional role. |
| Concurrent-event picker | chrisdail comment; needs `chooseStart`, not skip. Later. |
| Notification actions Record / Skip | Later adapter. Identifier should move to `dedupeKey` when that ships. |
| #875 menu bar next event | Another adapter of `candidates`. |
| Dual recording | Already rejected (back-to-back plan). |
| Settings skipped-event manager | Upcoming undo is enough. |
| SQLite event cache | Conflicts with ADR-017 §6. |
| Late-join UI | ADR-017 Phase 3. |

## Landing slices

1. **Extract `candidates()`** — Upcoming, CLI, and coordinator share it.
   Behavior-neutral besides deleting the lockstep copy in
   `MeetingsWorkspaceViewModel.shouldShowCalendarEvent`. Tests first on the
   existing filter matrix.
2. **Persist skip sets** — policy fields, SettingsViewModel, toast ✕ writes
   occurrence skip, Upcoming context menu, skipped row restore. Ingest is not
   required for slice 2.
3. **CLI JSON + docs** — additive skipped fields, ADR/spec checkboxes marked
   implemented.

No new `AppFeatures` flag. Calendar is already opt-in per user (`mode == .off`
by default). Skip is inert until someone mutes a meeting.

## Tests

Primary surface: `MeetingMonitorTests`.

- Skipped occurrence: no reminder, no auto-start; still in `candidates` with
  `isSkipped == true`.
- Skipped series: all occurrences sharing `externalId` skipped; a different
  series is not.
- Reschedule: new `dedupeKey` is not skipped; series skip still applies.
- Declined vs skipped: both absent from evaluate; declined still absent from
  candidates, skipped present.
- Trigger/calendar filters still apply before skip annotation.
- Unskip restores evaluate.

Coordinator tests:

- Toast `.userDismissed` persists occurrence skip and posts settings change.
- `.programmaticClose` does not skip.
- Notify mode does not reminder-fire a skipped event.

Workspace/UI tests:

- Context menu actions call skip/unskip.
- Skipped row remains in the upcoming list (within cap).
- Series action hidden when `externalId` is nil.

Do not send event titles in telemetry assertions.

Verification command (after implementation):

```sh
swift test --filter MeetingMonitorTests
swift test --filter MeetingAutoStartCoordinatorTests
swift test --filter MeetingsWorkspaceViewModelTests
```

Full `swift test` once at the end of the task, not per slice, unless the
user scopes verification differently.

## Files (expected)

Core:

- `Sources/MacParakeetCore/Calendar/MeetingMonitor.swift`
- `Sources/MacParakeetCore/Calendar/CalendarEvent.swift` (keys only; no new
  persistence)
- `Sources/MacParakeetCore/AppPreferences.swift` (`CalendarAutoStartPreferences`)
- `Sources/MacParakeetCore/Calendar/README.md`

View models / app:

- `Sources/MacParakeetViewModels/SettingsViewModel.swift`
- `Sources/MacParakeetViewModels/MeetingsWorkspaceViewModel.swift`
- `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift`
- `Sources/MacParakeet/Views/Meetings/MeetingsView.swift` (`CalendarEventRow`)
- `Sources/CLI/Commands/CalendarCommand.swift`

Tests and contracts as named above.

## Invariants

- Core audio/transcripts stay on-device. Skip keys are local identifiers.
- Deletion of recordings is unrelated; skip never discards audio.
- Manual start remains independent (ADR-017 §10).
- `MeetingMonitor` stays pure: no EventKit, no UserDefaults, no UI.
- Public CLI JSON changes stay additive and documented.
