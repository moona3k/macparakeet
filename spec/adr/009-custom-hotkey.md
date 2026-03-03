# ADR-009: Custom Hotkey Support

> Status: **ACCEPTED** | Date: 2026-03-02

## Context

MacParakeet's hotkey system used a `TriggerKey` enum that only supported 5 modifier keys (Fn, Control, Option, Shift, Command) via a dropdown picker. The architecture monitored `flagsChanged` events exclusively, making regular keys like End, F13, Home, etc. undetectable.

A customer with a mechanical keyboard requested mapping dictation to the "End" key, which was impossible with the enum-based design.

## Decision

Replace `TriggerKey` enum with a `HotkeyTrigger` struct that supports both modifier keys and regular key codes via a "record a shortcut" UI.

### Key Design Choices

1. **Single keys only, no combos** — Key combos (Cmd+K) conflict with system shortcuts and create ambiguity for double-tap/hold gesture detection. Single keys fully cover the use case.

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
