# ADR-009: Custom Hotkey Support

> Status: **ACCEPTED** | Date: 2026-03-02

## Context

MacParakeet's hotkey system used a `TriggerKey` enum that only supported 5 modifier keys (Fn, Control, Option, Shift, Command) via a dropdown picker. The architecture monitored `flagsChanged` events exclusively, making regular keys like End, F13, Home, etc. undetectable.

A customer with a mechanical keyboard requested mapping dictation to the "End" key, which was impossible with the enum-based design.

## Decision

Replace `TriggerKey` enum with a `HotkeyTrigger` struct that supports both modifier keys and regular key codes via a "record a shortcut" UI.

### Key Design Choices

1. **Initial single-key model** — The original design avoided key combos because common combos conflict with system shortcuts and created ambiguity for shared double-tap/hold detection. The chord-support amendments below add explicit modifier+key and modifier-only shortcuts.

2. **`HotkeyTrigger` struct with `kind` discriminator** — A `.modifier` vs `.keyCode` discriminator cleanly separates the two event detection paths while sharing the same state machine.

3. **Event swallowing for regular key triggers** — When a non-modifier key is the trigger, `keyDown`/`keyUp` events are swallowed (return `nil` from CGEvent callback) to prevent the key from reaching the active app. Modifier triggers continue to pass through.

4. **No bare-tap filtering for regular keys** — The "bare-tap" problem (Ctrl+C shouldn't trigger on Ctrl release) is modifier-specific. Regular keys have no chord ambiguity.

5. **Escape permanently reserved** — Cannot be assigned as hotkey. Preserves the cancel-dictation escape hatch.

6. **Edge detection for key-repeat** — macOS sends repeated `keyDown` for held keys. A `triggerKeyIsPressed` boolean ignores repeats, mirroring the existing `targetModifierWasPressed` pattern for modifiers.

7. **Backward-compatible UserDefaults** — New format is JSON; legacy plain strings ("fn", "control") are auto-detected and work seamlessly for upgrading users.

8. **Warning-not-blocking for typing keys** — Space, Return, Tab, arrow keys, and letter/number keys show a warning but are accepted. Only Escape is blocked.

## Consequences

- Users can assign any single key (F13, End, Home, etc.) as the dictation hotkey
- The state machine (`FnKeyStateMachine`) is unchanged — it's already key-agnostic
- `HotkeyManager` branches on `trigger.kind` to handle modifier vs keyCode event paths
- Settings UI uses a "record a shortcut" pattern instead of a dropdown picker
- Upgrading users with legacy `TriggerKey` values in UserDefaults will seamlessly continue working

## Amendment: Chord Hotkey Support (2026-03-13)

### Context

Community issue #17 requested modifier+key combos (e.g., Cmd+9) because Logitech mice can map buttons to keyboard shortcuts but not to single keys like F13. Chords are the standard macOS hotkey pattern — lower risk than single-key triggers and solve the mouse-mapping problem cleanly.

### Changes

1. **New `.chord` kind** added to `HotkeyTrigger.Kind` — stores `chordModifiers: [String]` (e.g. `["command"]`) alongside `keyCode`.
2. **Release-any-part stops** — For hold-to-talk with Cmd+9, releasing either Cmd or 9 ends dictation.
3. **Key swallowed, modifiers passed** — The trigger key event is swallowed; modifier flag changes pass through to the active app.
4. **Required modifiers must be present** — Mask to 5 relevant bits (fn⌃⌥⇧⌘) before comparing. Caps Lock, NumPad, etc. are stripped.
5. **Fn allowed in key chords** — Fn+Space is supported as a custom hands-free dictation shortcut. The default dictation behavior is a shared bare-Fn gesture preset: double-tap Fn for hands-free and hold Fn for push-to-talk.
6. **FnKeyStateMachine unchanged** — Key-agnostic. Chords generate role-specific down/up signals, including hands-free single-tap toggle and hold-to-talk.
7. **Modifier names stored as `[String]`** — Not raw `CGEventFlags.rawValue` (has phantom bits). Readable JSON: `{"kind":"chord","keyCode":25,"chordModifiers":["command"]}`.
8. **HotkeyRecorderView two-phase capture** — Held modifiers show as preview (e.g. "⌘..."); pressing a key with modifiers held creates a chord; releasing all modifiers without a key press creates a bare modifier trigger.
9. **Validation** — Chords are `.allowed` by default. Escape blocked. Cmd+Tab and Cmd+Space warned (system intercepts them).
10. **Shared dictation gestures** — Hands-free and push-to-talk may share the exact same trigger, in which case that trigger uses the combined gesture model: hold for push-to-talk, double-tap for hands-free, and tap again to stop hands-free. Settings still blocks overlapping but non-identical triggers (for example, generic Command vs Right Command, or Right Command vs Right Command+Right Option). Legacy single-hotkey installs migrate to the shared default gesture when appropriate, or to distinct shortcuts where possible.

### Original decision preserved

Single-key triggers (`.modifier` and `.keyCode`) continue to work exactly as before. Chords are additive.

## Amendment: Modifier-Only Chord Hotkey Support (2026-05-09)

### Context

Community issue #234 requested hotkeys such as Right Command+Right Option. The existing model supported single modifiers, side-specific single modifiers, standalone keys, and modifier+key chords, but not combinations made only of modifiers.

### Changes

1. **New `.modifierChord` kind** added to `HotkeyTrigger.Kind` — stores 2+ `ModifierComponent` values, each with a generic modifier name and optional physical key code for left/right specificity.
2. **Exact modifier-set matching** — Modifier-only chords trigger only when the configured modifier set is pressed. Extra Control/Option/Shift/Command keys interrupt the bare-tap gesture instead of also matching a smaller chord.
3. **Side-specific components** — Advanced recording can persist combinations such as Right Option+Right Command, while normal recording persists generic Option+Command behavior.
4. **Shared matching helper** — Dictation hotkeys and auxiliary shortcuts use the same side-specific modifier masks so generic and physical-side behavior stays consistent.
5. **Overlap detection replaces equality-only conflicts** — Settings and runtime startup reject physically overlapping shortcuts, including generic-vs-side-specific overlaps and bare-key-vs-modifier+key chord collisions.
6. **Fn remains excluded** — Fn/Globe stays bare-modifier-only and is not valid inside modifier-only chords.

### Original decision preserved

Existing `.modifier`, `.keyCode`, and `.chord` persisted values decode unchanged. Modifier-only chords are additive and use the existing key-agnostic gesture controller for the configured role semantics.
