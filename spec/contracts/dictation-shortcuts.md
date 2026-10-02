# Dictation shortcuts

## Purpose

Ordinary dictation has a primary and an optional additional pair of shortcuts,
each with push-to-talk and hands-free roles. All shortcuts are global across
connected keyboards. This solves #1197 (Fn on the Mac keyboard and another key
on an external keyboard, active together) without device profiles, new capture
sessions, or changes to audio, transcription, formatting, paste, or privacy
behavior.

The contract protects what the shortcuts promise to every other part of the app
and to scripted callers: where the additional shortcuts are stored, which
triggers collide, which gestures each pair provides, which shortcut owns a take,
and that one shortcut's use never silently ends another's take.

## Producers

- `SettingsViewModel` and `HotkeyTrigger` persist the two additional triggers in
  app UserDefaults and post the existing role notification when one changes.
- `AppHotkeyCoordinator.dictationHotkeyPlan` merges the primary pair, AI polish,
  and the additional pair into one accepted plan.
  `makeDictationHotkeyManager(spec:in:)` builds one `HotkeyManager` per accepted
  spec and configures it with every other accepted trigger as a peer.
- `HotkeyConflictPolicy` decides collisions for Settings, onboarding, and the
  coordinator's auxiliary shortcuts.
- Settings > Capture > Dictation keeps the primary rows. Its Additional
  shortcuts disclosure holds the two optional recorders, explains that both
  shortcuts stay active, and summarizes the configured gestures when collapsed.
  Each recorder keeps the standard validation warnings (a chosen standalone key
  is intercepted system-wide) and its Disable action.

## Consumers

- `HotkeyManager` and `HotkeyGestureController` turn physical events into
  start, stop, cancel, and discard outputs.
- The dictation flow starts, stops, cancels, and undoes takes from those outputs
  and reports recording-mode changes back through the coordinator.
- The menu bar hint, the Settings and onboarding conflict checks, the meeting
  and file/URL transcription shortcuts, and Transform shortcut registration
  read the additional triggers as reservations.
- `macparakeet-cli` Transform shortcut assignment (`appHotkeyCollision`) reads
  the two UserDefaults keys directly and rejects a collision with either
  additional trigger, with its existing error shape.

## Stable fields

### Storage and defaults

- The additional triggers are `HotkeyTrigger` JSON under the app UserDefaults
  keys `alternateHandsFreeHotkeyTrigger` and `alternatePushToTalkHotkeyTrigger`.
  Missing or invalid values resolve to disabled, and disabling one slot leaves
  the other unchanged. No default key is claimed.
- Primary defaults and legacy migrations are unchanged (shared Fn). The
  additional slots never migrate from or replace the primary pair.
- A change to either slot uses the existing role notification to refresh the
  shortcuts, menu hints, and Transform reservations.

### Collision semantics

- Within each pair, identical enabled triggers create one combined manager:
  hold to talk, double-tap for hands-free, tap to stop. Different triggers keep
  the existing single-tap hands-free and hold-only gestures. Sharing one trigger
  across both slots of the additional pair is allowed.
- Across pairs, duplicate or physically overlapping triggers are rejected.
  Additional shortcuts reserve their triggers against AI polish, meetings,
  file/URL transcription, and Transforms, and each of those reserves against
  them. The existing bare-modifier versus chord exception remains.
- Between the additional pair and the primary pair or AI polish, two chords on
  the same terminal key are rejected even with different modifiers. Both
  keyboards can send that key, so a held take could not tell a peer's key
  release from its owner's. Within one pair, and within the primary pair and AI
  polish, the long-standing rule is unchanged and such chords may coexist.
  Settings, onboarding, and the runtime plan apply this one rule.
- Runtime plans keep primary and AI-polish bindings ahead of conflicting
  additional bindings imported outside Settings. A rejected binding reports a
  conflict instead of installing a competing tap.
- Bare Fn is not an overlap with an Fn chord such as Fn+Space, so both may be
  accepted across pairs. Whenever any accepted shortcut is an Fn chord, every
  bare-Fn hold or double-tap shortcut waits out the tap threshold before it
  starts a held take, so the chord is not suppressed by an earlier Fn start.
- Transform CLI assignment respects both additional keys and keeps its existing
  collision error shape.

### Ownership, Escape, and discard

- A hold-to-talk recording can only resume its owning shortcut after mode sync
  or listener refresh; another trigger's release must not stop it. Ordinary
  persistent recordings can stop through either ordinary hands-free shortcut.
  AI-polish recordings remain separate from ordinary dictation shortcuts.
- One manager dispatches Escape effects across all dictation taps, preserving the
  cancellation Undo window. Other managers clear a pending first press and its
  timers but leave live-take and cancel-window state unchanged on Escape, so
  they stay blocked until the flow resets them. Escape always executes.
- Discarding a provisional hold take (quick tap or interrupting key) releases
  the other taps that the start suppressed; the discarding tap keeps its
  second-tap window.

### Owner-peer interference

Every dictation manager sees the same global event stream with combined modifier
flags, so another shortcut's keys reach the manager that owns a held take.

- A manager's peers are all other accepted triggers in the completed plan:
  the primary pair, the additional pair, and AI polish.
- While a manager owns a held push-to-talk take, including the provisional
  capture before the tap threshold, peer input does not interrupt it. Peer
  input is a configured peer modifier (a side-specific peer matches only its own
  side), the modifier prefix of a peer chord, the exact key of a peer key
  trigger, the terminal key of a peer chord while its modifiers are held, and
  the Fn key macOS reports when Fn is a peer. When an event carries no side
  bits, a side-specific peer is not ruled out, so the generic flag falls back to
  it, as side-specific triggers match when macOS reports only that flag.
- A claimed peer key stays claimed until its keyUp, even if its chord modifiers
  release first. The claim ends with the take.
- When macOS disables and re-enables a tap during a held take, held peer
  modifiers and claimed peer keys are judged as in the live paths, so the
  owner's release still stops the take. Claims for keys no longer physically
  down are dropped. Outside a held take recovery stays conservative.
- Everything else still interrupts: ordinary typing, a chord's terminal key
  without its modifiers, another key under a chord prefix, an unconfigured
  modifier, and the opposite side of a side-specific peer.
- Suppressed peers never acquire ownership. Before a take starts, any other
  input still interrupts the pending press. Owner release always executes and
  stops the take once.
- Matching follows the physical event the way the peer recognizes itself. It is
  not `HotkeyTrigger.overlaps`, which compares configurations. Interruption is
  never disabled as a whole, and passive Fn key bookkeeping and raw modifier
  flags are still recorded for peer input.

### Recording and onboarding

- Shortcut recording suspends all production taps. Resume re-reads settings.
- The optional slots participate in onboarding edit/reset conflict checks, but
  onboarding continues to teach and rehearse the primary pair only.

## Non-stable fields

- Settings layout and copy: the Additional shortcuts disclosure, its helper
  text, row order, and the collapsed summary.
- Menu bar hint wording.
- Diagnostic log text and the internal types that implement the policy.
- Exact debounce and tail milliseconds. The rule that a bare-Fn take outwaits the
  tap threshold when an Fn chord is accepted is stable.
- Existing Delete and typing-key warnings, which may be reworded.

## Versioning and compatibility

- The two UserDefaults key names and their `HotkeyTrigger` JSON are stable.
  Adding a slot is additive: a new key that defaults to disabled, reserved
  against every existing surface in both directions.
- Renaming or removing a key needs a migration that reads the old key and keeps
  decoding old values; do not drop persisted shortcuts silently.
- Collision semantics are stable. Loosening a rejection is additive. Rejecting a
  previously accepted combination for a persisted value needs a runtime conflict
  report, never a silent drop.
- The CLI reads the same keys and applies the same reservations as the app, so a
  key or collision change is also a CLI behavior change.

## Tests that enforce this

Focused suites: `AppHotkeyCoordinatorTests`, `HotkeyPeerInputPolicyTests`,
`HotkeyGestureControllerTests`, `HotkeyConflictPolicyTests`,
`SettingsViewModelTests`, `OnboardingShortcutEditorTests`,
`TransformsCommandTests`.

The coordinator tests deliver every physical event to all managers with combined
flags, in both delivery orders, for each owner trigger kind, and assert no
cancellation or discard, one start, and exactly one stop on owner release. They
also pin the interference negative controls above.

Native acceptance (not established by synthetic manager tests, which do not show
physical Bluetooth or Accessibility event delivery): keep Fn on the Mac
keyboard, assign Delete to both additional roles, exercise hold/release and
double-tap/stop on both keyboards, stop a hands-free take from the other
keyboard, and verify that pressing and releasing the other shortcut cannot end a
held take. Test disable/relaunch and conflict recording.

## When this contract changes

- Update this document and the matching focused tests in the same change.
- A new or renamed persisted key needs its migration, the role notification, and
  reservations on every surface listed under Consumers.
- A collision or reservation change updates `Sources/CLI/CHANGELOG.md`, since
  Transform assignment shares the policy.
- A user-visible change updates `spec/02-features.md` and the dictation shortcut
  amendment in `spec/adr/009-custom-hotkey.md`.
- Settings layout and copy changes need none of the above unless they change a
  stable field.
