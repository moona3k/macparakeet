# Dictation shortcuts

## Scope and invariants

Ordinary dictation has a primary and optional additional pair of shortcuts, each
with push-to-talk and hands-free roles. All shortcuts are global across connected
keyboards. This solves #1197 without device profiles, new capture sessions, or
changes to audio, transcription, formatting, paste, or privacy behavior.

- Primary defaults and legacy migrations remain unchanged (shared Fn).
- Additional slots default to disabled. Their `HotkeyTrigger` JSON values use
  `alternateHandsFreeHotkeyTrigger` and `alternatePushToTalkHotkeyTrigger` in
  app UserDefaults. Invalid/missing values resolve to disabled. Disabling one
  slot leaves the others unchanged. Changes use the existing role notification
  to refresh shortcuts, menu hints, and Transform reservations.
- Within each pair, identical enabled triggers create one combined manager:
  hold to talk, double-tap for hands-free, tap to stop. Different triggers retain
  the existing single-tap hands-free and hold-only gestures.
- Across pairs, duplicate or physically overlapping triggers are rejected.
  Additional shortcuts reserve their triggers against AI-polish, meetings,
  file/URL transcription, and Transforms. The existing bare-modifier versus
  chord exception remains. Transform CLI assignment respects both new keys
  and retains its existing collision error shape.
- Runtime plans keep primary and AI-polish bindings ahead of conflicting
  additional bindings imported outside Settings. Rejected bindings report a
  conflict rather than installing competing taps.
- A hold-to-talk recording can only resume its owning shortcut after mode sync
  or listener refresh; another trigger's release must not stop it. Ordinary
  persistent recordings can stop through either ordinary hands-free shortcut.
  AI-polish recordings remain separate from ordinary dictation shortcuts.
- One manager dispatches Escape effects across all dictation taps, preserving the
  cancellation Undo window. Other managers still clear pending gesture timers.
- Shortcut recording suspends all production taps. Resume re-reads settings.
  The optional slots participate in onboarding edit/reset conflict checks but
  onboarding continues to teach and rehearse the primary pair only.

## User experience

Settings > Capture > Dictation retains the primary rows. An Additional shortcuts
disclosure contains two optional recorders and explains that both shortcuts stay
active. Its collapsed summary shows configured gestures. Each recorder retains
standard validation warnings and its Disable action. No new default key is
claimed. Existing Delete/typing-key warnings explain that a chosen standalone
key is intercepted system-wide.

## Verification

Focused suites: `AppHotkeyCoordinatorTests`, `HotkeyConflictPolicyTests`,
`SettingsViewModelTests`, `OnboardingShortcutEditorTests`, `TransformsCommandTests`.
Native acceptance: keep Fn on the Mac keyboard, assign Delete to both additional
roles, exercise hold/release and double-tap/stop on both keyboards, stop a
hands-free take from the other keyboard, and verify releasing the other shortcut
cannot end a held take. Test disable/relaunch and conflict recording. Synthetic
manager tests do not establish physical Bluetooth or Accessibility event delivery.
