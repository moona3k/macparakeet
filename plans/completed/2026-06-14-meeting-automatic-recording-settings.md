# Meeting Recording settings — "Automatic recording" grouping

> Status: **IMPLEMENTED** (2026-06-14)
> Scope: Settings → Meeting Recording card IA reframe. No engine/behavior change.
> Shipped on branch `settings/meeting-automatic-recording`; build + full
> `swift test` green; dual SwiftUI review (no blockers).

## Problem

The Meeting Recording settings card presents the two halves of the recording
lifecycle inconsistently, which reads as lopsided:

- **Auto-stop** is a single inline toggle ("Auto-stop ended meetings") near the
  top of the card.
- **Auto-start already exists** but is buried at the bottom as a visually
  unrelated "Calendar auto-start" subsection, gated behind a cold "Grant
  Calendar Access" button, with a 3-way "Calendar behavior" menu picker
  (Off / Notify before meetings / Start recording automatically).

A user scanning the card sees a stop toggle and asks "where's the matching
start?" — the answer is there, but it doesn't read as the peer of stop.

## Why they aren't naively symmetric (design constraint)

Start and stop deliberately use **different signals**, because different signals
are reliable in each direction:

- **Start = calendar** (ADR-017). Meeting *start* times are reliable.
- **Stop = activity** (ADR-023) — meeting-app quit + prolonged dual-channel
  silence + a veto countdown. Meeting *end* times are unreliable, so
  calendar-driven auto-stop was removed (ADR-017 amendment).
- Activity-*detected* auto-start (ADR-024) is foundation-only (flag off, no UI)
  — the future symmetric peer, not shippable today.

So the fix is **information architecture, not a new feature or a bare twin
toggle** (a bare "Auto-start" toggle would falsely imply activity-based start
like auto-stop).

## Design

Introduce one **"Automatic recording"** subsection inside the Meeting Recording
card that frames start and stop as a matched pair, each keeping the control
depth its real mechanism needs. Reuse the existing inline subsection-header
treatment (SF symbol + semibold secondary caption) already used for the old
"Calendar auto-start" heading.

New Meeting Recording card order (top → bottom):

1. Meeting hotkey (manual start/stop) — unchanged
2. Audio sources — unchanged
3. Auto-save meetings to disk (+ format/folder) — unchanged
4. **Automatic recording** (new group)
   - **Start recording automatically** — calendar-driven (adaptive row)
   - **Stop recording automatically** — activity-driven (toggle)
5. Pending recovery (conditional) — moved to end (transient, exceptional state)

### Start row (CalendarSettingsView reframe)

Collapse the separate "Calendar access" permission row + "Calendar behavior"
mode row into ONE adaptive "Start recording automatically" row whose trailing
control depends on permission state — this gives **in-context permission
prompting** (you opt into auto-start, and *that* asks for Calendar access)
and makes the feature discoverable before access is granted:

- `.notDetermined`: detail "Start a recording when a scheduled meeting begins.
  Needs Calendar access — your events stay on your Mac." → trailing **Turn On…**
  button (requests permission; existing flow auto-selects `.notify` on grant).
- `.denied`: detail "Calendar access is blocked. Re-enable it in System
  Settings → Privacy & Security → Calendars." → trailing **Open System
  Settings** button.
- `.granted`: detail = existing mode description → trailing **menu Picker**
  (Off / Notify me / Start automatically).

When granted and mode ≠ `.off`, keep the existing disclosed sub-rows unchanged:
notification-off warning, "Remind me" lead time, "Which events count" filter,
per-calendar include list. Picker gains an explicit `accessibilityLabel`.

### Stop row

Reword the auto-stop toggle for parallelism with start, preserving the veto
information:

- Title: "Stop recording automatically"
- Detail: "Stop after a meeting app quits, or both channels stay quiet for a few
  minutes. A countdown lets you keep recording first."

## Out of scope

- `MeetingsView` `CalendarInlineControlsRow` (Library surface; its own segmented
  picker, already divergent). Untouched.
- Auto-stop configurability (countdown/silence knobs) — stays a single toggle.
- Speaker detection relocation — noted as a possible follow-up, not done here.
- Any ViewModel/persistence/telemetry/coordinator change. Pure view layer +
  copy. Bindings (`calendarAutoStartMode`, `meetingAutoStopEnabled`, sub-row
  settings) and their `didSet` side effects are unchanged.

## Files

- `Sources/MacParakeet/Views/Settings/SettingsView.swift` — reorder meeting card
  body; replace `meetingCalendarSection` + standalone auto-stop row with
  `meetingAutomationSection`; reword stop toggle.
- `Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift` — adaptive
  start row replacing separate permission + mode rows; concise picker labels;
  a11y label; doc-comment refresh.
- Docs: refresh `spec/04-ui-patterns.md` meeting-settings description if stale.

## Invariants (must not change)

- All calendar sub-settings remain reachable and bound to the same UserDefaults.
- `.denied` vs `.notDetermined` paths stay distinct (macOS prompts once).
- Notification-authorization pairing on grant/mode-change is preserved.
- Auto-stop toggle still gated by `AppFeatures.meetingAutoStopEnabled`; calendar
  still gated by `AppFeatures.calendarEnabled`.

## Test / verification plan

- `swift build` + `swift test` green (view-layer change; logic untested by
  design, so this confirms no regressions).
- Fresh code review (Swift/SwiftUI reviewer + second-opinion pass).
- Visual QA of the live dev app Settings card if headless capture is feasible.
