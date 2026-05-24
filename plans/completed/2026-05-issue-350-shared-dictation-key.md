# Issue #350: Shared Dictation Key

Status: **COMPLETED** — implemented on 2026-05-24.
Owner: Core app team
Updated: 2026-05-24

## Problem

Issue #350 asks for the same single-key workflow that Fn already supports, but
with Right Command:

```text
Hold Right Command       -> push-to-talk dictation
Double-tap Right Command -> hands-free dictation
Tap Right Command again  -> stop hands-free dictation
```

The user can assign Right Command to push-to-talk today, but Settings blocks
assigning the same Right Command trigger to hands-free mode. Their workaround is
Right Command for push-to-talk plus backtick for hands-free, but backtick is a
typing key and correctly carries an interference warning.

## Decision

Support exact shared dictation triggers. If hands-free and push-to-talk are set
to the exact same non-disabled `HotkeyTrigger`, MacParakeet treats that trigger
as a shared dictation key and routes it through the existing combined
hold/double-tap gesture controller.

This is not a new "double-tap hotkey" trigger type. The stored trigger remains
the physical key or chord. The gesture semantics are inferred from the two
dictation roles sharing the exact same trigger.

## Product Rule

1. Exact same trigger in both dictation rows:
   - hold -> push-to-talk
   - double-tap -> hands-free start
   - tap while hands-free is active -> stop
2. Distinct triggers:
   - push-to-talk stays hold-only
   - hands-free stays single-tap toggle
3. Overlapping but non-exact triggers remain conflicts:
   - generic Command vs Right Command
   - Right Command vs Right Command+Right Option
   - Control vs Control+Option

Exact equality matters because it keeps the mental model crisp: one physical
trigger can own both dictation gestures, but near-overlaps still risk accidental
activation and should stay blocked.

## UX

Keep the current Settings shape. Do not add a new toggle or a separate
"double-tap" binding UI.

When the two dictation rows share the exact same trigger:

- Both rows show the same trigger label.
- The hands-free row detail changes to "Double-tap to start; tap again to stop."
- The guide panel changes from "Tap" to "Double-tap" for hands-free mode.
- Conflict text is not shown.

When the rows use distinct triggers, retain the existing copy:

- push-to-talk: "Hold to dictate, release to stop."
- hands-free: "Tap to start; tap again to stop."

## Implementation Plan

1. Add a shared-dictation predicate.
   - Prefer a small helper such as
     `HotkeyTrigger.isSharedDictationGesture(handsFree:pushToTalk:)`.
   - Return true only when both triggers are enabled and exactly equal.
   - Keep the existing Fn helper as a compatibility/default-label convenience
     or fold it through the generalized helper if that keeps call sites clearer.

2. Update `AppHotkeyCoordinator`.
   - Exact shared trigger -> one `DictationHotkeyPlan.Spec` using
     `.doubleTapAndHold`.
   - Distinct triggers -> current `.singleTapToggle` plus `.holdOnly`.
   - Non-exact overlaps -> current conflict behavior.
   - Update menu title so shared Right Command reads like a combined gesture,
     not a conflict.

3. Update Settings validation and conflict display.
   - `SettingsDictationHotkeyConflictPolicy` should allow exact shared triggers.
   - Keep blocking non-exact overlaps.
   - Keep auxiliary hotkey conflict behavior unchanged.

4. Preserve shared custom triggers on launch.
   - `SettingsViewModel.resolveDictationHotkeyTriggers` currently migrates
     duplicate non-Fn dictation triggers away.
   - Change that migration so exact shared triggers such as Right Command are
     preserved instead of replaced by the default hands-free trigger.
   - Continue migrating ambiguous overlapping-but-not-equal pairs to a safe
     configuration.

5. Update Settings copy.
   - Replace `usesDefaultDictationGesturePreset` usage with a generalized
     shared-trigger check where the behavior is what matters.
   - Keep "Double-tap Fn" label overrides only where the literal default label
     should mention Fn.

6. Amend ADR-009.
   - Replace the Fn-only exception wording with the generalized rule:
     hands-free and push-to-talk may share the exact same trigger, in which
     case the shared hold/double-tap gesture applies.

## Tests

Add focused coverage for:

1. `AppHotkeyCoordinator.dictationHotkeyPlan` returns one `.doubleTapAndHold`
   spec for shared Right Command.
2. The planner still reports conflicts for non-exact overlaps.
3. Settings peer validation allows exact shared Right Command.
4. Settings peer validation blocks generic Command vs Right Command.
5. `SettingsViewModel.resolveDictationHotkeyTriggers` preserves stored shared
   Right Command for both roles.
6. Existing Fn default behavior remains unchanged.

Run:

```bash
swift test --filter Hotkey
swift test --filter SettingsViewModel
swift test
```

## Out of Scope

- No new persistent trigger kind.
- No user-facing "double-tap mode" toggle.
- No changes to meeting/file/YouTube/Transform hotkey semantics.
- No broad hotkey architecture rewrite.

## Acceptance Criteria

- A user can set both dictation rows to Right Command.
- The app starts one combined dictation hotkey manager for that shared trigger.
- Hold starts push-to-talk and release stops it.
- Double-tap starts hands-free mode.
- A later tap stops hands-free mode.
- Settings copy reflects the inferred double-tap behavior.
- Non-exact overlaps remain blocked.
