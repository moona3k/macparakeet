# Keyboard event taps off the main run loop (#1142)

Status: **PR OPEN** (branch `fix/event-taps-off-main`)

## Problem

Every MacParakeet `CGEvent` tap was installed on the main run loop. macOS holds
each keyboard event until a filtering tap's callback returns, so any
main-thread stall in MacParakeet delayed typing in every other app, and a long
enough stall made macOS disable the tap (#1132, #1133).

Default installs have two filtering taps: the meeting shortcut
(`GlobalShortcutManager`, Cmd+Shift+.) and the Transforms registry, which was
installed even with no bound Transforms. Users whose dictation or push-to-talk
trigger is not bare Fn also have a filtering `HotkeyManager` tap. Bare Fn is
listen-only.

## Design

- `EventTapThread` (Core) owns one long-lived thread with its own run loop.
  All taps are created, enabled, torn down and called back on it.
  `performAndWait` runs setup and teardown on that thread, so no callback can
  run while its owner is being released. The tap thread never waits on the
  main thread.
- `BackgroundEventTap` (Core) wraps create, install, timeout re-enable and
  `EventTapTeardown` for a tap whose handler runs on `EventTapThread`.
- `GlobalShortcutManager` and `TransformsHotkeyRegistry` run their matching
  logic on the tap thread. Their triggers already hop to the main actor.
  The Transforms dispatch table is lock-protected because the main thread
  replaces it. The registry installs its tap only while at least one binding
  exists.
- `HotkeyManager` splits its work. The tap thread decides whether to swallow
  an event (`HotkeyTapFilter`, which depends only on the trigger and the event
  stream) and forwards a value snapshot to the main queue in order. The
  existing gesture state machine, timers and callbacks stay on the main thread
  unchanged, so the synchronous refused-start reset and peer suppression keep
  working. Each start gets a generation, and queued events from a stopped tap
  are dropped.
- The streaming-cursor interrupt token uses `BackgroundEventTap`, which
  removes its `DispatchQueue.main.sync` start and teardown.

## Invariants

- Tap options and masks are unchanged: bare Fn stays listen-only, configured
  shortcuts are still consumed, and modifier-side matching is unchanged.
- Hold, double-tap and Escape handling run the same main-thread state machine
  with the same event timestamps.
- Marked streaming-cursor events still pass through untouched.
- Timeout and user-input disables re-enable the same tap.
- Teardown still invalidates the Mach port (#1136).

A main-thread stall now delays only gesture processing, which is inherently
UI-bound. It no longer delays keystrokes to other apps.

## Verification

- Focused suites: `HotkeyManagerTests`, `GlobalShortcutManagerTests`,
  `TransformsHotkeyRegistryTests`, `StreamingCursorInserterTests`,
  `AppHotkeyCoordinatorTests`, `EventTapTeardownTests`, `BackgroundEventTapTests`.
- `BackgroundEventTapTests` blocks the main thread for 500 ms and checks that a
  process-scoped tap still receives events during the stall (skips without
  Input Monitoring permission).
- Tap-count checks across start/stop cycles for each owner.
- Manual QA: DEBUG `MACPARAKEET_DEBUG_MAIN_STALL_MS` stalls the main thread
  periodically; typing in another app should stay smooth, and configured
  shortcuts should still be consumed.
