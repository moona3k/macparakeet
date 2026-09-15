# Per-event calendar skip (#609)

> Status: **IMPLEMENTED** (2026-09-14; review-corrected then built)
> Issue: [#609](https://github.com/moona3k/macparakeet/issues/609)
> Governs: [ADR-017](../../spec/adr/017-calendar-meeting-auto-start.md) amendment 2026-09-14, [F48](../../spec/02-features.md)
> Priority: P2
>
> Independent reviews (Fable 5.1, GPT-6 Astra via Codex) were **NOT LGTM**
> on the first two drafts. This revision settles persisted keys, recurrence
> gating, CLI membership, owning-countdown re-eval (post-#318), immediate
> skip/unskip rearm, and undo. The Swift implementation matches this
> revision. Do not implement against earlier drafts.

## Original ask

Auto-start is useful, but some calendar entries should not be recorded —
especially meetings where the user is only an optional invitee. The reporter
asked for a way to **disable auto-recording for specific events**, or an
option to **exclude individual calendar entries**.

That is the whole feature. Optional invite is the motivation, not an automatic
filter. Overlapping-meeting pickers, notification Record/Skip actions, and
menu-bar next-event (#875) are later adapters of the same policy; they are
**out of this plan**.

## Why this was incomplete (pre-implementation)

This section describes `main` before Phase 2b. The implementation replaces
session-only dismiss with persisted skip.

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
- `calendarItemExternalIdentifier` exists on one-off events. It is not a
  recurrence signal. Recurrence is not ingested today (`hasRecurrenceRules` /
  `isDetached` unread).

## Product rules

1. **Skip is a user decision about one meeting**, not a heuristic over
   optional invites.
2. **Skip sticks** across launches. Toast ✕ and Upcoming write the same store.
3. **Skip blocks automation only** — reminders and auto-start. Manual Record,
   hotkey, and menu bar still work. A skipped event may still receive a
   `probable` snapshot if the user starts manually while it overlaps now.
4. **Skipped meetings stay visible** on Upcoming so undo is obvious.
5. **Upcoming default is the whole meeting for one-off events and this
   occurrence for recurring events.** Toast ✕ is always this occurrence.
   Series skip is the extra Upcoming control, offered only when
   `event.isRecurring` is true.
6. **Do not auto-exclude optional invites.** Do not treat optional role and
   tentative RSVP as the same switch. Do not add a Settings list of events.

Copy:

- **Don't auto-record this meeting** — one-off: whole meeting; recurring: this
  occurrence. Caption in notify mode: MacParakeet won't remind you or start
  recording.
- **Don't auto-record this repeating meeting** — recurring only.
- **Auto-record again** — occurrence or one-off undo.
- **Auto-record this repeating meeting again** — series undo.

Internal name: skip. Do not say Exclude (that already means calendars).

## Architecture

One question: **which meetings should MacParakeet automate right now?**

Skip is another eligibility input, same as declined or an excluded calendar.
Policy stays in `MeetingMonitor`. The coordinator only performs effects.

```
EventKit  →  CalendarService  →  [CalendarEvent]
                 (isRecurring from hasRecurrenceRules || isDetached)
                                      │
                                      ▼
                         MeetingMonitor.candidates
                         (Upcoming + coordinator membership)
                                      │
                    ┌─────────────────┴─────────────────┐
                    ▼                                   ▼
                 Upcoming                           evaluate
            (show skipped, quieter)          (no remind / auto-start)
                    │                                   │
                    ▼                                   ▼
            skip / unskip store              coordinator effects
            SettingsViewModel                notification / toast / start
                                                      ▲
CLI `calendar upcoming` keeps today's membership      │
(--filter + not-all-day) and annotates skips ─────────┘
via CalendarSkip.matches, not candidates() membership.
```

Do not add an `ExclusionService` or a skipped-meetings Settings page.
Upcoming and the coordinator share `candidates`. The CLI stays an inspection
list for this feature; aligning its membership with `candidates` is a later
compatibility change, not #609.

### Identity

Reuse `CalendarEvent` keys. Do not key on title. Ingest
`isRecurring: Bool` (`EKEvent.hasRecurrenceRules || EKEvent.isDetached`) in
`CalendarService.convertEvent`, defaulting to `false` on `CalendarEvent.init`
so existing fixtures compile. Decode with `decodeIfPresent` defaulting to
`false` so older snapshots without the field still load. `externalId` is
**not** a recurrence flag.

| Scope | Key | When |
| --- | --- | --- |
| This occurrence | `dedupeKey` (`id\|startSeconds`) | Toast ✕ always. Upcoming default for recurring events. A rescheduled occurrence is a new key. |
| This meeting / series | `eventKey` (`externalId ?? id`) | Upcoming default for one-off events (survives reschedule). Recurring series skip. |

`id` alone is the wrong series key when `externalId` exists: detached
recurrences can change `eventIdentifier`. ADR-017 already documents that.

### Preference store (not an event cache)

ADR-017 §6 still holds: no SQLite EventKit repository. Skips are UserDefaults
sets beside excluded calendars.

```
CalendarAutoStart.skippedOccurrences   // [dedupeKey]
CalendarAutoStart.skippedEvents        // [eventKey]  // one-off meeting or recurring series
```

Empty by default. Opt out, not in. Posted through the existing
`.macParakeetCalendarSettingsDidChange` so the coordinator re-evaluates
immediately. `SettingsViewModel` re-resolves these sets on that notification
the same way it already re-resolves other calendar keys (multi-instance).

**Janitor:** event-level skips live until the user unskips. Occurrence skips
older than 14 days may be pruned (they can never re-fire). Parse `dedupeKey`
on the last `|` in a **pure Core helper**. Run once from coordinator
`start()` and on the existing 24-hour cleanup task (daily relaunch otherwise
never prunes). Do not intersect event-level skips against the 7-day fetch —
a series skip must survive weeks without that event in the look-ahead window.

Telemetry may send counts and scope (`occurrence` / `event`), never titles,
attendees, or URLs. Add a `TelemetrySettingName` case; it is a value of the
existing `setting_changed` event (no website allowlist change).

### Policy types (`MacParakeetCore`)

Keep `MeetingMonitor` as the deep module. Grow `Config` so skip sets sit
beside the fields `evaluate` already uses. Do **not** drop
`countdownSeconds` or `lateJoinGraceMinutes`.

```swift
// Nested in MeetingMonitor.
struct Config: Codable, Sendable, Equatable {
    var mode: CalendarAutoStartMode
    var reminderMinutes: Int
    var countdownSeconds: Int
    var triggerFilter: MeetingTriggerFilter
    var lateJoinGraceMinutes: Int
    var excludedCalendarIdentifiers: Set<String>
    var skippedOccurrences: Set<String>
    var skippedEvents: Set<String>
}

struct CalendarCandidate: Equatable, Sendable {
    var event: CalendarEvent
    var isSkipped: Bool { skipScope != nil }
    var skipScope: CalendarSkipScope?   // .occurrence / .event
}

enum CalendarSkipScope: String, Sendable {
    case occurrence
    case event   // one-off meeting or recurring series
}

enum MeetingMonitor {
    static func candidates(
        events: [CalendarEvent],
        config: Config
    ) -> [CalendarCandidate]

    static func evaluate(
        candidates: [CalendarCandidate],
        now: Date,
        config: Config,
        activeRecording: Bool,
        remindedEventIds: Set<String>,
        countdownShownEventIds: Set<String>
    ) -> [MonitorEvent]
}
```

`candidates` applies: not all-day, not declined, calendar not excluded
(fail open when `calendarIdentifier` is missing, same as today's
coordinator and Upcoming), passes trigger filter. It **includes skipped
events** and annotates them. It does **not** drop `.pending` RSVPs
(reminders stay lenient).

`evaluate` ignores skipped candidates. It does not need a separate
session-dismissed set for user cancel: toast ✕ is an occurrence skip.

`countdownShownEventIds` / `remindedEventIds` stay session-only so a delivered
reminder or shown toast does not repeat every poll tick. Skip/unskip of an
occurrence must reconcile that occurrence’s key in `countdownShownEventIds`
**immediately**, without requiring a successful intervening calendar fetch.
Closing a countdown because its occurrence became skipped clears that
occurrence’s countdown suppression immediately. Preserve the transition
across awaited notification handling and coalesced polls. Unrelated
occurrences retain their suppression. Undo re-evaluates current eligibility
and time windows; it does not directly start recording. Do **not** clear
`remindedEventIds` on skip/unskip — a delivered reminder must not re-fire
inside the same window. Do not require the settings notification `userInfo`
to name the key; every current poster uses `object: nil`.

Helper for UI, CLI annotation, and persistence:

```swift
enum CalendarSkip {
    static func eventKey(for event: CalendarEvent) -> String {
        event.externalId ?? event.id
    }

    static func matches(
        _ event: CalendarEvent,
        occurrences: Set<String>,
        events: Set<String>
    ) -> CalendarSkipScope?
}
```

Event-level match wins over occurrence when both are set (row copy: repeating
or whole meeting).

### Coordinator (app layer)

Thin effects, with an **effect-boundary contract**:

- Build `MeetingMonitor.Config` from `SettingsViewModel`.
- `candidates` → `evaluate` → existing reminder / auto-start paths.
- Toast `.userDismissed` → occurrence skip (`dedupeKey`).
- Stop treating user cancel as in-memory `dismissedEventIds`.
- `.programmaticClose` never writes a skip.
- Skipping never stops an existing recording.

A persisted skip prevents **effects not yet committed**. Recheck current
shared eligibility (mode, permission, trigger filter, excluded calendar,
and skip) after any awaited preparation, immediately before countdown
presentation, and immediately before notification submission or recording
confirmation. Track the occurrence that owns the visible countdown. On any
calendar settings change, re-evaluate **only that owning occurrence** under
the new policy and close it if it is no longer eligible; otherwise keep
it. This preserves the post-#318 rule that a mode, filter, or permission
change still closes the owning countdown. Countdowns for other occurrences
are never closed by a skip write. Skipping never stops an existing
recording. Today's "any calendar settings change closes the toast" is too
broad for skip writes and must not drop an in-flight auto-start for meeting
A when the user skips meeting B.

Settings-change reconciliation runs synchronously on the main queue and
reloads persisted settings before evaluating. A skip followed by undo in
the same actor turn must not disappear behind a queued observer task, and
writes from another SettingsViewModel must not depend on observer order.

`probableSnapshotForManualStart` continues to consider overlapping events
that pass candidate rules **including skipped ones** if the user is starting
manually, and it **keeps its local `.pending` exclusion** (candidates do not
drop pending). Skip is "don't automate," not "this is not a meeting."

### SettingsViewModel

Mirror `calendarExcludedIdentifiers`:

- `calendarSkippedOccurrences: Set<String>`
- `calendarSkippedEvents: Set<String>`
- `skipOccurrence(_:)`, `skipEvent(_:)`, `unskipOccurrence(_:)`,
  `unskipEvent(_:)`
- Persist + post `.macParakeetCalendarSettingsDidChange` +
  `.settingChanged` telemetry
- Re-resolve from defaults when that notification arrives (same as other
  calendar keys)

**Undo:**

- Occurrence undo removes only the selected `dedupeKey`.
- Event/series undo removes the matching `eventKey` **and** the selected
  occurrence key. Other explicit occurrence skips for that series stay.
- After series undo, the selected row is unskipped immediately.
- Series undo label: **Auto-record this repeating meeting again.**

No new Settings card. No list of skipped meetings in this plan (a later
disclosure is allowed if undo from Upcoming proves insufficient).

### CLI

For #609, preserve existing `calendar upcoming` membership, `--filter`
semantics, defaults, and the flat event-array JSON shape. Reuse the existing
local trigger predicate and `CalendarSkip.matches` for annotations only.
Read skip sets through `macParakeetAppDefaults()` (`CLIHelpers.swift`).
Do **not** encode `CalendarCandidate` (that would nest fields under `event`).
Do **not** newly drop declined or excluded-calendar events in this feature.
(Declined events are already absent from `CalendarService` fetch when
`excludeDeclined` is true; excluded-calendar preferences are not applied.)

The CLI-local flat DTO carries the pre-feature `CalendarEvent` JSON fields
plus only the two skip annotations below. `isRecurring` stays internal to
the calendar policy and UI for #609. Before this feature the command encoded
`CalendarEvent` directly; the DTO prevents the new internal recurrence field
from leaking into CLI output.
Preserve existing field names, values, date encoding, and optional-field
omission behavior. Do not nest the event under an `event` key.

Map through a **pure function** over `[CalendarEvent]` plus the skip sets
(no EventKit, no `CalendarService.shared`) so CLI tests can assert the DTO
without a live store. `run()` stays the EventKit adapter.

Implemented additive JSON fields (MINOR):

- `skipped: Bool`
- `skipScope: "occurrence" | "event" | null`

Human output marks skipped rows. The `calendar upcoming --json` entry in
[`spec/contracts/cli-json-v1.md`](../../spec/contracts/cli-json-v1.md)
and the CLI CHANGELOG document the additions; the contract lists
`CalendarUpcomingJSONTests` under "Tests that enforce this". Aligning CLI membership with
`candidates` is a separately documented compatibility change.

## UI

The control lives on the meeting, not in Settings.

### Upcoming row (Meetings workspace)

Keep the current title + time + calendar + people line. Do not add a
persistent Skip button on every row.

- Context menu (right-click / Control-click). Six cells:

  | Row | Skip state | Menu |
  | --- | --- | --- |
  | One-off | none | Don't auto-record this meeting |
  | One-off | occurrence | Auto-record again |
  | One-off | event | Auto-record again |
  | Recurring | none | Don't auto-record this meeting; Don't auto-record this repeating meeting |
  | Recurring | occurrence | Auto-record again; Don't auto-record this repeating meeting |
  | Recurring | event | Auto-record this repeating meeting again |

  Series item is hidden when `isRecurring == false`. Occurrence undo never
  offers the series undo label.
- Skipped row: reduced opacity. Caption **Won't auto-record this time** for
  an occurrence skip on a collapsed recurring row; **Won't auto-record this
  series** for a **recurring** event-level skip; **Won't auto-record** for a
  one-off (occurrence or event-level). In notify-only mode the caption
  states that MacParakeet won't remind you or start recording.
- Recurring preview still collapses to the soonest occurrence
  (`collapseRecurringOccurrences`). Event-level skip applies to that row and
  future occurrences sharing `eventKey`. Collapse plus the Upcoming cap means
  users cannot preemptively skip every fetched occurrence from this list;
  later occurrences of a series are muted only via series skip or toast ✕
  when they come due.
- Upcoming continues to list skipped events that still pass the coarse
  filters, so the mute is visible and reversible. Cap still applies after
  collapse.

Accessibility: menu items named as above; skipped rows include the caption
in the accessibility label.

### Auto-start toast

No second button. ✕ / Escape = skip this occurrence, then close. Return still
starts now. Copy and layout stay the current countdown halo. The shared
view's `.autoStop` kind is untouched. Accessibility may keep
"Cancel auto-start"; behavior is occurrence skip. Keep firing
`calendarAutoStartCancelled(reason: "user_cancel")` alongside the new
`settingChanged` so the existing dashboard series stays continuous.

If the user skips and later unskips while still inside the auto-start window,
evaluate may emit `.autoStartDue` again because skip/unskip immediately
clears that occurrence’s `countdownShownEventIds` mark. Undo does not
directly start recording.

### Notify-only mode

There is no toast, so Upcoming is the mute. Skip also suppresses the reminder
for that occurrence/event — otherwise notify-mode skip is a no-op. Menu
titles stay "Don't auto-record…"; the row caption states that reminders are
included.

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
| CLI membership alignment with `candidates` | Compatibility change; not this feature. |

## Landing slices

1. **Extract `candidates()` for Upcoming + coordinator.** Delete the lockstep
   copy in `MeetingsWorkspaceViewModel.shouldShowCalendarEvent`. CLI is
   **not** in this slice. Tests first on the existing filter matrix.
2. **Persist skip sets + recurrence flag.** `CalendarEvent.isRecurring` from
   `CalendarService.convertEvent`. Policy fields, SettingsViewModel, toast ✕
   writes occurrence skip, Upcoming context menu, undo rules, effect-boundary
   on the coordinator (don't close unrelated toasts; recheck before notify/
   start). Introduce the CLI-local flat DTO here so adding the internal
   recurrence field does not change CLI JSON.
3. **CLI annotations + docs** — additive `skipped` / `skipScope` on the
   existing flat JSON; contract **entry added**; CHANGELOG; F48 checkboxes.

No new `AppFeatures` flag. Calendar is already opt-in per user (`mode == .off`
by default). Skip is inert until someone mutes a meeting.

## Tests

Primary surface: `MeetingMonitorTests`. Call sites now use persisted skip
sets in `Config` instead of the former `dismissedEventIds:` parameter.

- Skipped occurrence: no reminder, no auto-start; still in `candidates` with
  `isSkipped == true`.
- Skipped event/series: all occurrences sharing `eventKey` skipped; a
  different series is not.
- Recurring reschedule: new `dedupeKey` is not occurrence-skipped; event-level
  skip still applies.
- One-off reschedule: `eventKey` skip still applies after start-time change.
- Declined vs skipped: both absent from evaluate; declined still absent from
  candidates, skipped present.
- Trigger/calendar filters still apply before skip annotation.
- Unskip restores evaluate. Series undo clears event key + selected
  occurrence; sibling occurrence skips remain.
- `isRecurring == false` even when `externalId` is non-nil.

Coordinator tests:

- Toast `.userDismissed` persists occurrence skip and posts settings change.
- `.programmaticClose` does not skip.
- Notify mode does not reminder-fire a skipped event.
- Skipping B while A's countdown is visible does not close or suppress A.
- Mode change to notify, trigger-filter change, and excluding the owning
  calendar while A's countdown is visible still close A.
- Hold a fetch, skip the visible countdown, undo before releasing the fetch:
  one eligible countdown can reappear and unrelated suppression stays intact
  (`MockCalendarService` held-fetch seam).
- Recheck after skip: countdown presentation, countdown completion, and
  reminder submit do not fire for a now-skipped event. Coordinator tests
  inject an authorization/delivery seam so skip across the reminder wait
  is proven without `UNUserNotificationCenter` (that API crashes in XCTest).
- `probableSnapshotForManualStart` still skips `.pending`.
- Existing `dismissedEventIds` tests are rewritten for occurrence skip.

Workspace/UI tests:

- Context menu actions call skip/unskip.
- Skipped row remains in the upcoming list (within cap).
- Series action hidden when `isRecurring == false`.

CLI tests: annotation on the existing event array; membership unchanged for
declined / excluded-calendar fixtures. Compare the pre-feature event payload
with the DTO after removing `skipped` and `skipScope`: existing fields and
values must match, including optional-field omission and date encoding.
Assert that `isRecurring` is absent and that an unskipped row emits
`skipped: false` and `skipScope: null`.

Do not send event titles in telemetry assertions.

Verification command (after implementation):

```sh
swift test --filter MeetingMonitorTests
swift test --filter MeetingAutoStartCoordinatorTests
swift test --filter MeetingsWorkspaceViewModelTests
swift test --filter CalendarUpcomingJSONTests
```

Full `swift test` once at the end of the task, not per slice, unless the
user scopes verification differently.

## Files (expected)

Core:

- `Sources/MacParakeetCore/Calendar/MeetingMonitor.swift`
- `Sources/MacParakeetCore/Calendar/CalendarEvent.swift` (`eventKey` helper,
  `isRecurring`)
- `Sources/MacParakeetCore/Calendar/CalendarService.swift` (set `isRecurring`)
- `Sources/MacParakeetCore/AppPreferences.swift` (`CalendarAutoStartPreferences`)
- `Sources/MacParakeetCore/Calendar/README.md`

View models / app:

- `Sources/MacParakeetViewModels/SettingsViewModel.swift`
- `Sources/MacParakeetViewModels/MeetingsWorkspaceViewModel.swift`
- `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift`
- `Sources/MacParakeet/Views/Meetings/MeetingsView.swift` (`CalendarEventRow`)
- `Sources/CLI/Commands/CalendarCommand.swift`
- `Sources/CLI/CHANGELOG.md`
- `spec/contracts/cli-json-v1.md` (add `calendar upcoming --json` entry)

Tests as named above. Rewrite `testDismissedEventsAreSkipped` and
`testAutoStartUserCancelDoesNotTriggerRecording` off `dismissedEventIds`.

## Invariants

- Core audio/transcripts stay on-device. Skip keys are local identifiers.
- Deletion of recordings is unrelated; skip never discards audio.
- Manual start remains independent (ADR-017 §10).
- `MeetingMonitor` stays pure: no EventKit, no UserDefaults, no UI.
- Public CLI JSON changes stay additive and documented.
- Skip never closes an unrelated countdown or stops a live recording.
